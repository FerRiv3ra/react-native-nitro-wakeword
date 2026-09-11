import AVFoundation
import Foundation

/// Opens the microphone through `AVAudioEngine`, resamples to 16 kHz mono and
/// delivers fixed 1280-sample chunks scaled to the int16 range (as floats).
///
/// Route changes (Bluetooth connect/disconnect, headphones), interruptions
/// (calls, Siri) and media-server resets restart the engine. The tap is
/// installed with `format: nil` and the converter is rebuilt whenever the
/// incoming buffer format changes, so a stale hardware format can never be
/// handed to AVAudioEngine (that raises an uncatchable NSException).
final class AudioCapture {
  typealias ChunkHandler = ([Float]) -> Void
  typealias ErrorHandler = (String) -> Void

  private var engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var pending: [Float] = []
  private let chunkSize: Int
  private let manageSession: Bool
  private let onChunk: ChunkHandler
  private let onError: ErrorHandler
  private var observers: [NSObjectProtocol] = []
  private var restartWork: DispatchWorkItem?
  private var restartAttempts = 0
  private var lastRestart = Date.distantPast
  private(set) var isRunning = false

  private static let maxRestartAttempts = 5
  private static let restartDebounce: TimeInterval = 0.3
  /// Notifications caused by our own restart arrive within this window and are ignored.
  private static let restartCooldown: TimeInterval = 1.0

  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: Double(OpenWakeWordEngine.sampleRate),
    channels: 1,
    interleaved: false
  )!

  init(chunkSize: Int, manageSession: Bool, onChunk: @escaping ChunkHandler, onError: @escaping ErrorHandler) {
    self.chunkSize = chunkSize
    self.manageSession = manageSession
    self.onChunk = onChunk
    self.onError = onError
  }

  // MARK: - Public

  func start() throws {
    guard !isRunning else { return }
    try configureSession()
    try activateSession()
    try startEngine()
    isRunning = true
    lastRestart = Date()
    registerObservers()
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    restartWork?.cancel()
    restartWork = nil
    unregisterObservers()
    tearDownEngine()
    pending.removeAll()
  }

  // MARK: - Engine

  /// Sets the category once. Changing it from inside a restart would post a
  /// `.categoryChange` route notification and restart the engine forever.
  private func configureSession() throws {
    guard manageSession else { return }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .default,
      options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
    )
  }

  private func activateSession() throws {
    guard manageSession else { return }
    try AVAudioSession.sharedInstance().setActive(true, options: [])
  }

  private func startEngine() throws {
    let input = engine.inputNode
    let hardwareFormat = input.outputFormat(forBus: 0)
    guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
      throw WakeWordError("Microphone input format unavailable (sampleRate=\(hardwareFormat.sampleRate))")
    }
    converter = nil
    // `format: nil` lets the engine pick the node's current format, so a stale
    // cached format after a route change can never cause a mismatch.
    input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
      self?.handle(buffer)
    }
    engine.prepare()
    try engine.start()
  }

  private func tearDownEngine() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    engine.reset()
    converter = nil
  }

  /// Runs on the audio render thread.
  private func handle(_ buffer: AVAudioPCMBuffer) {
    let inputFormat = buffer.format
    guard inputFormat.sampleRate > 0, buffer.frameLength > 0 else { return }

    if converter == nil || converter!.inputFormat != inputFormat {
      guard let fresh = AVAudioConverter(from: inputFormat, to: targetFormat) else {
        onError("Cannot convert \(inputFormat) to 16 kHz mono")
        return
      }
      converter = fresh
    }
    guard let converter else { return }

    let ratio = targetFormat.sampleRate / inputFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

    var consumed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return buffer
    }
    if status == .error {
      onError("Audio conversion failed: \(error?.localizedDescription ?? "unknown")")
      return
    }
    guard out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
    let count = Int(out.frameLength)
    var samples = [Float](repeating: 0, count: count)
    for i in 0..<count {
      samples[i] = max(-32768, min(32767, channel[i] * 32767))
    }
    push(samples)
  }

  private func push(_ samples: [Float]) {
    pending.append(contentsOf: samples)
    while pending.count >= chunkSize {
      let chunk = Array(pending[0..<chunkSize])
      pending.removeFirst(chunkSize)
      onChunk(chunk)
    }
  }

  // MARK: - Restart

  /// Coalesces the burst of notifications a route change produces into one
  /// restart, and retries while the hardware format is still settling.
  private func scheduleRestart(reason: String) {
    guard isRunning else { return }
    guard Date().timeIntervalSince(lastRestart) > AudioCapture.restartCooldown else { return }
    restartWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.restart(reason: reason) }
    restartWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + AudioCapture.restartDebounce, execute: work)
  }

  private func restart(reason: String) {
    guard isRunning else { return }
    tearDownEngine()
    pending.removeAll()
    do {
      try activateSession()
      try startEngine()
      restartAttempts = 0
      lastRestart = Date()
    } catch {
      restartAttempts += 1
      if restartAttempts < AudioCapture.maxRestartAttempts {
        // Hardware format is often still 0 Hz right after a route change.
        let delay = 0.5 * Double(restartAttempts)
        let work = DispatchWorkItem { [weak self] in self?.restart(reason: reason) }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
      } else {
        restartAttempts = 0
        onError("Audio engine restart failed after \(reason): \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Notifications

  private func registerObservers() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self,
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      switch type {
      case .began:
        self.engine.pause()
      case .ended:
        self.scheduleRestart(reason: "interruption")
      @unknown default:
        break
      }
    })
    observers.append(center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self,
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
      switch reason {
      case .newDeviceAvailable, .oldDeviceUnavailable, .wakeFromSleep, .routeConfigurationChange:
        self.scheduleRestart(reason: "route change (\(reason.rawValue))")
      case .categoryChange, .override, .unknown, .noSuitableRouteForCategory:
        // Triggered by session configuration (often our own); the engine keeps running.
        break
      @unknown default:
        break
      }
    })
    observers.append(center.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      self?.scheduleRestart(reason: "engine configuration change")
    })
    observers.append(center.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      // The old engine is unusable after a media server reset.
      self.engine = AVAudioEngine()
      self.scheduleRestart(reason: "media services reset")
    })
  }

  private func unregisterObservers() {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
  }
}
