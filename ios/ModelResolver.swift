import Foundation

/// Resolves a model reference to a file URL.
///
/// Order: absolute path -> app main bundle -> `NitroWakeWordModels.bundle`
/// shipped with this library.
enum ModelResolver {
  static func resolve(_ reference: String) -> URL? {
    if reference.hasPrefix("/") {
      return FileManager.default.fileExists(atPath: reference)
        ? URL(fileURLWithPath: reference)
        : nil
    }
    if reference.hasPrefix("file://"), let url = URL(string: reference) {
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    let nsRef = reference as NSString
    let ext = nsRef.pathExtension.isEmpty ? "onnx" : nsRef.pathExtension
    let name = nsRef.pathExtension.isEmpty ? reference : nsRef.deletingPathExtension

    if let url = Bundle.main.url(forResource: name, withExtension: ext) {
      return url
    }
    for bundle in candidateBundles() {
      if let url = bundle.url(forResource: name, withExtension: ext) {
        return url
      }
    }
    return nil
  }

  /// Display label derived from the reference: `hey_jarvis_v0.1.onnx` -> `hey_jarvis_v0.1`.
  static func defaultKeyword(for reference: String) -> String {
    let file = (reference as NSString).lastPathComponent as NSString
    return file.pathExtension.isEmpty ? String(file) : file.deletingPathExtension
  }

  private static func candidateBundles() -> [Bundle] {
    var bundles: [Bundle] = []
    let hosts = [Bundle(for: HybridWakeWord.self), Bundle.main]
    for host in hosts {
      if let url = host.url(forResource: "NitroWakeWordModels", withExtension: "bundle"),
         let bundle = Bundle(url: url) {
        bundles.append(bundle)
      }
    }
    return bundles
  }
}
