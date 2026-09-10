import AVFoundation
import Foundation

/// Opens the microphone through `AVAudioEngine`, resamples to 16 kHz mono and
/// delivers fixed 1280-sample chunks scaled to the int16 range (as floats).
final class AudioCapture {
  typealias ChunkHandler = ([Float]) -> Void
  typealias ErrorHandler = (String) -> Void

  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var pending: [Float] = []
  private let chunkSize: Int
  private let manageSession: Bool
  private let onChunk: ChunkHandler
  private let onError: ErrorHandler
  private var observers: [NSObjectProtocol] = []
  private(set) var isRunning = false

  private lazy var targetFormat = AVAudioFormat(
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

  func start() throws {
    guard !isRunning else { return }
    if manageSession {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
      )
      try session.setActive(true, options: [])
    }
    try installTap()
    try engine.start()
    isRunning = true
    registerObservers()
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    unregisterObservers()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    pending.removeAll()
    converter = nil
  }

  private func installTap() throws {
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw WakeWordError("Microphone input format unavailable (sampleRate=\(inputFormat.sampleRate))")
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      throw WakeWordError("Cannot convert \(inputFormat) to 16 kHz mono")
    }
    self.converter = converter
    let ratio = targetFormat.sampleRate / inputFormat.sampleRate

    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      guard let self, let converter = self.converter else { return }
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
      guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else { return }
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
        self.onError("Audio conversion failed: \(error?.localizedDescription ?? "unknown")")
        return
      }
      guard out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
      let count = Int(out.frameLength)
      var samples = [Float](repeating: 0, count: count)
      for i in 0..<count {
        samples[i] = max(-32768, min(32767, channel[i] * 32767))
      }
      self.push(samples)
    }
  }

  private func push(_ samples: [Float]) {
    pending.append(contentsOf: samples)
    while pending.count >= chunkSize {
      let chunk = Array(pending[0..<chunkSize])
      pending.removeFirst(chunkSize)
      onChunk(chunk)
    }
  }

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
        self.restart()
      @unknown default:
        break
      }
    })
    observers.append(center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.restart()
    })
    observers.append(center.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      self?.restart()
    })
  }

  private func unregisterObservers() {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
  }

  private func restart() {
    guard isRunning else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    do {
      if manageSession {
        try AVAudioSession.sharedInstance().setActive(true, options: [])
      }
      try installTap()
      try engine.start()
    } catch {
      onError("Audio engine restart failed: \(error.localizedDescription)")
    }
  }
}
