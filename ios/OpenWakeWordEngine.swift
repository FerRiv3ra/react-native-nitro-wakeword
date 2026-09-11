import Foundation

/// openWakeWord inference pipeline (see NOTICE):
///
/// 16 kHz mono int16-scaled float audio, processed in 80 ms chunks (1280 samples).
/// Each chunk: melspectrogram over the last 1760 samples -> 8 new mel frames (32 bins),
/// transformed `x / 10 + 2`; the last 76 mel frames -> one 96-dim speech embedding;
/// the last `N` embeddings (`N` = classifier window, usually 16) -> keyword score.
/// Optionally gated by Silero VAD.
final class OpenWakeWordEngine {
  static let sampleRate = 16000
  static let chunkSize = 1280
  static let melContext = 480          // 3 extra hops so that 1280 samples yield 8 frames
  static let melWindow = 76
  static let melBins = 32
  static let embeddingDim = 96
  static let vadFrame = 512
  static let vadHistory = 12           // ~1 s of 80 ms chunks

  struct Detection {
    let keyword: String
    let score: Float
    let timestamp: Double
  }

  final class Keyword {
    let keyword: String
    let model: OnnxModel
    let window: Int
    var threshold: Float
    let patience: Int
    var consecutive = 0
    var lastDetection: Double = 0

    init(keyword: String, model: OnnxModel, window: Int, threshold: Float, patience: Int) {
      self.keyword = keyword
      self.model = model
      self.window = window
      self.threshold = threshold
      self.patience = patience
    }
  }

  private let melModel: OnnxModel
  private let embeddingModel: OnnxModel
  private let vadModel: OnnxModel?
  private let vadThreshold: Float
  private let refractorySeconds: Double
  private(set) var keywords: [Keyword]

  private var raw = [Float](repeating: 0, count: chunkSize + melContext)
  private var mel = [Float](repeating: 1, count: melWindow * melBins)
  private var melFramesSeen = 0
  private var features: [Float]
  private var featuresSeen = 0
  private let maxWindow: Int

  private var vadH = [Float](repeating: 0, count: 2 * 64)
  private var vadC = [Float](repeating: 0, count: 2 * 64)
  private var vadPending: [Float] = []
  private var vadScores = [Float](repeating: 0, count: vadHistory)
  private var vadIndex = 0

  init(
    melURL: URL,
    embeddingURL: URL,
    vadURL: URL?,
    vadThreshold: Float,
    refractoryMs: Double,
    keywords: [(keyword: String, url: URL, threshold: Float, patience: Int)]
  ) throws {
    melModel = try OnnxModel(url: melURL)
    embeddingModel = try OnnxModel(url: embeddingURL)
    if vadThreshold > 0, let vadURL {
      vadModel = try OnnxModel(url: vadURL)
    } else {
      vadModel = nil
    }
    self.vadThreshold = vadThreshold
    refractorySeconds = refractoryMs / 1000

    var loaded: [Keyword] = []
    for entry in keywords {
      let model = try OnnxModel(url: entry.url)
      let window = try OpenWakeWordEngine.resolveWindow(model, name: entry.keyword)
      loaded.append(Keyword(
        keyword: entry.keyword, model: model, window: window,
        threshold: entry.threshold, patience: max(1, entry.patience)
      ))
    }
    self.keywords = loaded
    maxWindow = loaded.map(\.window).max() ?? 16
    features = [Float](repeating: 0, count: maxWindow * OpenWakeWordEngine.embeddingDim)

    try warmUp()
  }

  /// Reads the classifier window from the declared input shape `[1, N, 96]`;
  /// falls back to probing common sizes when the dimension is symbolic.
  private static func resolveWindow(_ model: OnnxModel, name: String) throws -> Int {
    let shape = model.firstInputShape
    if shape.count == 3, shape[1] > 0 {
      return shape[1]
    }
    let candidates = [16, 28, 20, 24, 32, 12, 36, 40, 48, 64, 8]
    for n in candidates {
      let zeros = [Float](repeating: 0, count: n * embeddingDim)
      if let _ = try? model.run(zeros, shape: [1, n, embeddingDim]) {
        return n
      }
    }
    throw WakeWordError("Could not determine input window of classifier '\(name)'. Expected [1, N, 96].")
  }

  private func warmUp() throws {
    // Fill mel + feature buffers with "silence" features, like openWakeWord does on init.
    let zeros = [Float](repeating: 0, count: OpenWakeWordEngine.chunkSize)
    let chunks = OpenWakeWordEngine.melWindow / 8 + maxWindow + 2
    for _ in 0..<chunks {
      _ = try processChunk(zeros, emit: false)
    }
    for keyword in keywords {
      keyword.consecutive = 0
      keyword.lastDetection = 0
    }
    vadScores = [Float](repeating: 0, count: OpenWakeWordEngine.vadHistory)
  }

  /// Flushes every buffer back to "silence". Call before (re)starting capture:
  /// the mel/embedding windows still hold the audio that triggered the last
  /// detection, and would fire again on the first chunk after a stop/start.
  func reset() throws {
    raw = [Float](repeating: 0, count: raw.count)
    mel = [Float](repeating: 1, count: mel.count)
    melFramesSeen = 0
    features = [Float](repeating: 0, count: features.count)
    featuresSeen = 0
    vadH = [Float](repeating: 0, count: 2 * 64)
    vadC = [Float](repeating: 0, count: 2 * 64)
    vadPending.removeAll()
    vadIndex = 0
    try warmUp()
  }

  func setThreshold(keyword: String, threshold: Float) {
    keywords.first { $0.keyword == keyword }?.threshold = threshold
  }

  /// Processes exactly one 1280-sample chunk. Returns per-keyword scores and detections.
  func process(_ chunk: [Float]) throws -> (scores: [(String, Float)], detections: [Detection]) {
    try processChunk(chunk, emit: true)
  }

  private func processChunk(_ chunk: [Float], emit: Bool) throws -> (scores: [(String, Float)], detections: [Detection]) {
    precondition(chunk.count == OpenWakeWordEngine.chunkSize, "chunk must be 1280 samples")

    if vadModel != nil {
      try runVad(chunk)
    }

    // Sliding raw buffer: [ previous 480 | new 1280 ]
    let context = OpenWakeWordEngine.melContext
    raw.replaceSubrange(0..<context, with: raw[(raw.count - context)...])
    raw.replaceSubrange(context..<raw.count, with: chunk)

    let melOut = try melModel.run(raw, shape: [1, raw.count])
    let bins = OpenWakeWordEngine.melBins
    let newFrames = melOut.count / bins
    guard newFrames > 0 else { return ([], []) }
    let transformed = melOut.map { $0 / 10 + 2 }
    appendFrames(transformed, frames: newFrames, into: &mel, frameSize: bins)
    melFramesSeen += newFrames
    guard melFramesSeen >= OpenWakeWordEngine.melWindow else { return ([], []) }

    let embedding = try embeddingModel.run(
      mel, shape: [1, OpenWakeWordEngine.melWindow, bins, 1]
    )
    appendFrames(embedding, frames: 1, into: &features, frameSize: OpenWakeWordEngine.embeddingDim)
    featuresSeen += 1

    var scores: [(String, Float)] = []
    var detections: [Detection] = []
    let speech = vadModel == nil || (vadScores.max() ?? 0) >= vadThreshold
    let now = Date().timeIntervalSince1970

    for keyword in keywords {
      guard featuresSeen >= keyword.window else { continue }
      // VAD gate closed: the score would be forced to 0 anyway, skip the classifier.
      var score: Float = 0
      if speech {
        let dim = OpenWakeWordEngine.embeddingDim
        let slice = Array(features[(features.count - keyword.window * dim)...])
        score = try keyword.model.run(slice, shape: [1, keyword.window, dim]).first ?? 0
      }
      scores.append((keyword.keyword, score))
      guard emit else { continue }

      if score >= keyword.threshold {
        keyword.consecutive += 1
      } else {
        keyword.consecutive = 0
      }
      if keyword.consecutive >= keyword.patience,
         now - keyword.lastDetection >= refractorySeconds {
        keyword.lastDetection = now
        keyword.consecutive = 0
        detections.append(Detection(keyword: keyword.keyword, score: score, timestamp: now * 1000))
      }
    }
    return (scores, detections)
  }

  /// Shifts `buffer` left by `frames * frameSize` and appends that many values.
  private func appendFrames(_ values: [Float], frames: Int, into buffer: inout [Float], frameSize: Int) {
    let incoming = min(frames * frameSize, values.count)
    guard incoming > 0 else { return }
    if incoming >= buffer.count {
      buffer = Array(values.suffix(buffer.count))
      return
    }
    buffer.removeFirst(incoming)
    buffer.append(contentsOf: values.prefix(incoming))
  }

  private func runVad(_ chunk: [Float]) throws {
    guard let vad = vadModel else { return }
    // Silero expects audio normalised to [-1, 1].
    vadPending.append(contentsOf: chunk.map { $0 / 32768 })
    let frame = OpenWakeWordEngine.vadFrame
    var latest: Float? = nil
    while vadPending.count >= frame {
      let input = Array(vadPending[0..<frame])
      vadPending.removeFirst(frame)
      let outputs = try vad.run(inputs: [
        "input": OnnxModel.floatTensor(input, shape: [1, frame]),
        "sr": OnnxModel.int64Scalar(Int64(OpenWakeWordEngine.sampleRate)),
        "h": OnnxModel.floatTensor(vadH, shape: [2, 1, 64]),
        "c": OnnxModel.floatTensor(vadC, shape: [2, 1, 64]),
      ])
      if let hn = outputs["hn"] { vadH = hn }
      if let cn = outputs["cn"] { vadC = cn }
      if let out = outputs["output"] { latest = out.first }
    }
    if let latest {
      vadScores[vadIndex] = latest
      vadIndex = (vadIndex + 1) % vadScores.count
    }
  }
}
