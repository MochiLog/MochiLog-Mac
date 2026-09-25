import Foundation

enum SupportDiagnostics {
  private static func file(_ name: String, for device: PairedDevice) -> URL {
    Collector.root.appendingPathComponent("support-\(device.physicalDeviceID.uuidString)-\(name).json")
  }

  static func savePhoneReport(_ data: Data, for device: PairedDevice) throws {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["schema"] as? Int == 1 else { return }
    let destination = file("iphone", for: device)
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  static func phoneReport(for device: PairedDevice) -> URL? {
    let url = file("iphone", for: device)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  static func saveCollection(_ report: CollectionReport?, error: Error?, for device: PairedDevice) {
    let category: String
    if let error {
      let message = error.localizedDescription
      category = message.contains("タイムアウト") ? "timeout" :
        message.contains("シグナル") ? "helper_signal" : "collection_error"
    } else { category = report?.failed == 0 ? "completed" : "partial_failure" }
    let object: [String: Any] = [
      "schema": 1,
      "collectedAt": ISO8601DateFormatter().string(from: Date()),
      "result": category,
      "saved": report?.saved ?? 0,
      "excluded": report?.skipped ?? 0,
      "failed": report?.failed ?? 0
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    let destination = file("collection", for: device)
    try? data.write(to: destination, options: .atomic)
  }

  static func macReport(for device: PairedDevice) -> Data {
    let collection = file("collection", for: device)
    let lastCollection = (try? JSONSerialization.jsonObject(with: Data(contentsOf: collection)))
      as? [String: Any] ?? [:]
    let object: [String: Any] = [
      "schema": 1,
      "generatedAt": ISO8601DateFormatter().string(from: Date()),
      "platform": "macOS",
      "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
      "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
      "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
      "deviceModel": device.model,
      "pairingConfirmed": device.confirmedAt != nil,
      "pendingFiles": (try? Collector.pending(for: device).count) ?? -1,
      "deliveredFiles": Collector.delivered(for: device).count,
      "lastCollection": lastCollection
    ]
    return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
  }

  static func mailAttachments(for device: PairedDevice) throws -> [URL] {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MochiLog-Support-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let mac = directory.appendingPathComponent("mochilog-mac-diagnostics.json")
    try macReport(for: device).write(to: mac, options: .atomic)
    var attachments = [mac]
    if let phone = phoneReport(for: device) {
      let target = directory.appendingPathComponent("mochilog-iphone-diagnostics.json")
      try FileManager.default.copyItem(at: phone, to: target)
      attachments.append(target)
    }
    return attachments
  }
}
