import AVFoundation
import Foundation
import NitroModules

class HybridWakeWord: HybridWakeWordSpec {
  private let queue = DispatchQueue(label: "com.nitrowakeword.engine", qos: .userInitiated)
  private var engine: OpenWakeWordEngine?
  private var capture: AudioCapture?
  private var manageAudioSession = true
  private var pendingChunks = 0

  private var detectionListener: ((WakeWordDetection) -> Void)?
  private var scoreListener: ((String, Double) -> Void)?
  private var errorListener: ((String) -> Void)?

  // MARK: - Properties

  public var isLoaded: Bool { engine != nil }
  public var isListening: Bool { capture?.isRunning ?? false }

  // MARK: - Lifecycle

  public func load(config: WakeWordConfig) throws -> Promise<Void> {
    return Promise.async { [self] in
      self.stop()
      guard !config.models.isEmpty else {
        throw WakeWordError("config.models must contain at least one model")
      }
      guard let melURL = ModelResolver.resolve("melspectrogram.onnx"),
            let embeddingURL = ModelResolver.resolve("embedding_model.onnx") else {
        throw WakeWordError("Base models not found. Is NitroWakeWordModels.bundle in the app?")
      }
      let vadThreshold = Float(config.vadThreshold ?? 0.3)
      let vadURL = vadThreshold > 0 ? ModelResolver.resolve("silero_vad.onnx") : nil
      if vadThreshold > 0 && vadURL == nil {
        throw WakeWordError("silero_vad.onnx not found but vadThreshold > 0")
      }

      var keywords: [(keyword: String, url: URL, threshold: Float, patience: Int)] = []
      for model in config.models {
        guard let url = ModelResolver.resolve(model.model) else {
          throw WakeWordError("Model not found: \(model.model)")
        }
        keywords.append((
          keyword: model.keyword ?? ModelResolver.defaultKeyword(for: model.model),
          url: url,
          threshold: Float(model.threshold ?? 0.5),
          patience: Int(model.patience ?? 1)
        ))
      }

      let built = try OpenWakeWordEngine(
        melURL: melURL,
        embeddingURL: embeddingURL,
        vadURL: vadURL,
        vadThreshold: vadThreshold,
        refractoryMs: config.refractoryMs ?? 1000,
        keywords: keywords
      )
      self.queue.sync {
        self.engine = built
        self.manageAudioSession = config.manageAudioSession ?? true
      }
    }
  }

  public func unload() throws {
    stop()
    queue.sync { engine = nil }
  }

  public func start() throws -> Promise<Void> {
    return Promise.async { [self] in
      guard self.engine != nil else {
        throw WakeWordError("Call load() before start()")
      }
      guard try self.hasMicrophonePermission() else {
        throw WakeWordError("Microphone permission not granted")
      }
      if self.capture?.isRunning == true { return }

      let capture = AudioCapture(
        chunkSize: OpenWakeWordEngine.chunkSize,
        manageSession: self.manageAudioSession,
        onChunk: { [weak self] chunk in self?.enqueue(chunk) },
        onError: { [weak self] message in self?.errorListener?(message) }
      )
      try capture.start()
      self.capture = capture
    }
  }

  public func stop() {
    capture?.stop()
    capture = nil
  }

  public func setThreshold(keyword: String, threshold: Double) throws {
    queue.async { [weak self] in
      self?.engine?.setThreshold(keyword: keyword, threshold: Float(threshold))
    }
  }

  // MARK: - Listeners

  public func setDetectionListener(listener: @escaping (WakeWordDetection) -> Void) throws {
    detectionListener = listener
  }

  public func clearDetectionListener() throws {
    detectionListener = nil
  }

  public func setScoreListener(listener: @escaping (String, Double) -> Void) throws {
    scoreListener = listener
  }

  public func clearScoreListener() throws {
    scoreListener = nil
  }

  public func setErrorListener(listener: @escaping (String) -> Void) throws {
    errorListener = listener
  }

  public func clearErrorListener() throws {
    errorListener = nil
  }

  // MARK: - Permissions

  public func hasMicrophonePermission() throws -> Bool {
    if #available(iOS 17.0, *) {
      return AVAudioApplication.shared.recordPermission == .granted
    }
    return AVAudioSession.sharedInstance().recordPermission == .granted
  }

  public func requestMicrophonePermission() throws -> Promise<Bool> {
    let promise = Promise<Bool>()
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission { granted in
        promise.resolve(withResult: granted)
      }
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        promise.resolve(withResult: granted)
      }
    }
    return promise
  }

  // MARK: - Processing

  private func enqueue(_ chunk: [Float]) {
    // Drop audio instead of building an unbounded backlog on slow devices.
    if pendingChunks > 8 { return }
    pendingChunks += 1
    queue.async { [weak self] in
      guard let self else { return }
      defer { self.pendingChunks -= 1 }
      guard let engine = self.engine else { return }
      do {
        let result = try engine.process(chunk)
        if let scoreListener = self.scoreListener {
          for (keyword, score) in result.scores {
            scoreListener(keyword, Double(score))
          }
        }
        if let detectionListener = self.detectionListener {
          for detection in result.detections {
            detectionListener(WakeWordDetection(
              keyword: detection.keyword,
              score: Double(detection.score),
              timestamp: detection.timestamp
            ))
          }
        }
      } catch {
        self.errorListener?("Inference failed: \(error.localizedDescription)")
      }
    }
  }
}
