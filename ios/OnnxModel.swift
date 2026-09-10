import Foundation

/// Swift-friendly wrapper over `OnnxSession` for float32 models.
final class OnnxModel {
  let session: OnnxSession
  let inputNames: [String]
  let outputNames: [String]

  init(url: URL) throws {
    session = try OnnxSession(modelPath: url.path)
    inputNames = session.inputNames
    outputNames = session.outputNames
  }

  /// Declared shape of the first input, `-1` for symbolic dimensions.
  var firstInputShape: [Int] {
    session.firstInputShape.map { $0.intValue }
  }

  static func floatTensor(_ values: [Float], shape: [Int]) -> OnnxTensor {
    let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    return OnnxTensor.floatTensor(data, shape: shape.map { NSNumber(value: $0) })
  }

  static func int64Scalar(_ value: Int64) -> OnnxTensor {
    OnnxTensor.int64Scalar(value)
  }

  static func floats(from tensor: OnnxTensor) -> [Float] {
    tensor.data.withUnsafeBytes { raw -> [Float] in
      Array(raw.bindMemory(to: Float.self))
    }
  }

  /// Single float input -> first output as flat floats.
  func run(_ input: [Float], shape: [Int]) throws -> [Float] {
    guard let inputName = inputNames.first, let outputName = outputNames.first else {
      throw WakeWordError("ONNX model has no input/output")
    }
    let outputs = try session.run([inputName: OnnxModel.floatTensor(input, shape: shape)])
    guard let out = outputs[outputName] else {
      throw WakeWordError("ONNX model produced no output")
    }
    return OnnxModel.floats(from: out)
  }

  func run(inputs: [String: OnnxTensor]) throws -> [String: [Float]] {
    let outputs = try session.run(inputs)
    var result: [String: [Float]] = [:]
    for (name, tensor) in outputs {
      result[name] = OnnxModel.floats(from: tensor)
    }
    return result
  }
}
