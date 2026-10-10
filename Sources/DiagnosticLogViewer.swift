import Foundation

/// Read-only categorization of local and received archives. Never rewrites the
/// append-only exchange stream, and retains unsupported future formats as general.
enum DiagnosticLogViewer {
  static func categories(in text: String) -> [String] {
    var result = Set<String>()
    visit(text) { category, _, _ in result.insert(category) }
    return DiagnosticLogArchive.categories.filter { result.contains($0) }
  }

  static func text(_ text: String, category: String?) -> String {
    guard let category, DiagnosticLogArchive.categories.contains(category) else { return text }
    var result: [String] = []
    var lastHeader: String?
    visit(text) { actual, header, line in
      guard actual == category else { return }
      if lastHeader != header { result.append(header); lastHeader = header }
      result.append(line)
    }
    return result.joined(separator: "\n")
  }

  private static func visit(_ text: String, consume: (String, String, String) -> Void) {
    var header = "# {\"type\":\"mochilog-diagnostic-log\",\"formatVersion\":1,\"appVersion\":\"unknown\",\"build\":\"unknown\"}"
    var fixedCategory: String?
    var supported = true
    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
      if line.hasPrefix("# "), let data = String(line.dropFirst(2)).data(using: .utf8),
        let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        metadata["type"] as? String == "mochilog-diagnostic-log",
        let version = metadata["formatVersion"] as? Int {
        header = line
        supported = version == 1 || version == 2
        let category = metadata["category"] as? String
        fixedCategory = category.flatMap { DiagnosticLogArchive.categories.contains($0) ? $0 : nil }
        continue
      }
      let category = supported ? (fixedCategory ?? DiagnosticLogArchive.category(for: line)) : "general"
      consume(category, header, line)
    }
  }
}
