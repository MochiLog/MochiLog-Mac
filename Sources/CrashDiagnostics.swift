import Foundation
import MetricKit

/// Keeps the most recent OS diagnostic locally until the user chooses to send a support email.
enum CrashDiagnostics {
  private static let lock = NSLock()
  private static let file = Collector.root.appendingPathComponent("last-app-diagnostic.json")
  private static let manager = MetricManager()
  private static var observer: Task<Void, Never>?

  static func start() {
    guard observer == nil else { return }
    observer = Task.detached {
      for await report in manager.diagnosticReports {
        let kind: String
        switch report.result {
        case .crash: kind = "crash"
        case .hang: kind = "hang"
        default: continue
        }
        guard let diagnostic = try? JSONEncoder().encode(report) else { continue }
        save(kind: kind, diagnostic: diagnostic)
      }
    }
  }

  static func latest() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return try? Data(contentsOf: file)
  }

  static func summary() -> String? {
    guard let data = latest(),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = object["kind"] as? String,
      let receivedAt = object["receivedAt"] as? String else { return nil }
    return "OS diagnostic: \(kind) received \(receivedAt)"
  }

  private static func save(kind: String, diagnostic: Data) {
    // A bounded report prevents a corrupt or unusually large payload filling app storage.
    guard diagnostic.count <= 1_048_576,
      let report = try? JSONSerialization.jsonObject(with: diagnostic),
      let data = try? JSONSerialization.data(withJSONObject: [
        "schema": 1, "platform": "macOS", "kind": kind,
        "receivedAt": ISO8601DateFormatter().string(from: Date()),
        "report": report
      ], options: [.prettyPrinted, .sortedKeys]) else { return }
    lock.lock()
    defer { lock.unlock() }
    do {
      try data.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch { /* Diagnostics must never interrupt the app. */ }
  }
}
