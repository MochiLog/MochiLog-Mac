import Foundation

enum SupportDiagnostics {
  private static var eventsURL: URL { Collector.root.appendingPathComponent("support-events.json") }
  private static var archiveDirectory: URL {
    Collector.root.appendingPathComponent("DebugLogs", isDirectory: true)
  }
  private static let retentionKey = "MochiLogDebugRetentionDays"
  private static let migratedKey = "MochiLogDebugArchiveMigrated"
  private static let eventLock = NSLock()

  static var retentionDays: Int {
    get {
      let saved = UserDefaults.standard.integer(forKey: retentionKey)
      return saved == 0 ? 30 : min(365, max(1, saved))
    }
    set {
      eventLock.lock()
      defer { eventLock.unlock() }
      UserDefaults.standard.set(min(365, max(1, newValue)), forKey: retentionKey)
      pruneArchive()
    }
  }

  static func archiveDays() -> [String] {
    eventLock.lock()
    defer { eventLock.unlock() }
    migrateLegacyEvents()
    return storedDays()
  }

  static func logText(for day: String) -> String {
    eventLock.lock()
    defer { eventLock.unlock() }
    migrateLegacyEvents()
    guard validDay(day) else { return "" }
    return (try? String(contentsOf: archiveURL(for: day), encoding: .utf8)) ?? ""
  }

  static func deleteLogs() {
    eventLock.lock()
    defer { eventLock.unlock() }
    for day in storedDays() { try? FileManager.default.removeItem(at: archiveURL(for: day)) }
    try? FileManager.default.removeItem(at: eventsURL)
    UserDefaults.standard.set(true, forKey: migratedKey)
  }

  static func dayString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private static func validDay(_ day: String) -> Bool {
    day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
      options: .regularExpression) != nil
  }

  private static func archiveURL(for day: String) -> URL {
    archiveDirectory.appendingPathComponent("\(day).log")
  }

  private static func storedDays() -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(at: archiveDirectory,
      includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { file in
      guard file.pathExtension == "log" else { return nil }
      let day = file.deletingPathExtension().lastPathComponent
      return validDay(day) ? day : nil
    }.sorted(by: >)
  }

  @discardableResult
  private static func appendArchivedEvent(_ event: String) -> Bool {
    let day = String(event.prefix(10))
    guard validDay(day) else { return false }
    do {
      try FileManager.default.createDirectory(at: archiveDirectory,
        withIntermediateDirectories: true)
      let url = archiveURL(for: day)
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      try FileManager.default.setAttributes([.posixPermissions: 0o600],
        ofItemAtPath: url.path)
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data((event + "\n").utf8))
      return true
    } catch { return false }
  }

  private static func migrateLegacyEvents() {
    guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
    let events = (try? JSONDecoder().decode([String].self,
      from: Data(contentsOf: eventsURL))) ?? []
    guard events.allSatisfy({ appendArchivedEvent($0) }) else { return }
    UserDefaults.standard.set(true, forKey: migratedKey)
    pruneArchive()
  }

  private static func pruneArchive() {
    let cutoff = dayString(Calendar.current.date(byAdding: .day,
      value: 1 - retentionDays, to: Date()) ?? Date())
    for day in storedDays() where day < cutoff {
      try? FileManager.default.removeItem(at: archiveURL(for: day))
    }
  }

  static func localTime(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .autoupdatingCurrent
    return formatter.string(from: date)
  }

  static func record(_ message: String) {
    eventLock.lock()
    defer { eventLock.unlock() }
    migrateLegacyEvents()
    let normalized = String(message.replacingOccurrences(of: "\n", with: " ").prefix(200))
    var events = (try? JSONDecoder().decode([String].self,
      from: Data(contentsOf: eventsURL))) ?? []
    guard events.last?.hasSuffix(" | \(normalized)") != true else { return }
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .autoupdatingCurrent
    let event = "\(formatter.string(from: Date())) | \(normalized)"
    events.append(event)
    if events.count > 500 { events.removeFirst(events.count - 500) }
    try? JSONEncoder().encode(events).write(to: eventsURL, options: .atomic)
    if appendArchivedEvent(event) { pruneArchive() }
  }

  static func macLogText() -> String {
    let events = (try? JSONDecoder().decode([String].self,
      from: Data(contentsOf: eventsURL))) ?? []
    return ([CrashDiagnostics.summary()].compactMap { $0 } + events).joined(separator: "\n")
  }

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
    if let error = error as? CollectorError {
      switch error {
      case .timeout: category = "timeout"
      case .signal: category = "helper_signal"
      default: category = "collection_error"
      }
    } else if error != nil {
      category = "collection_error"
    } else { category = report?.failed == 0 ? "completed" : "partial_failure" }
    var object: [String: Any] = [
      "schema": 1,
      "collectedAt": ISO8601DateFormatter().string(from: Date()),
      "result": category,
      "saved": report?.saved ?? 0,
      "excluded": report?.skipped ?? 0,
      "failed": report?.failed ?? 0
    ]
    if let newest = report?.newestHostAnalyticsAt {
      object["newestHostAnalyticsAt"] = ISO8601DateFormatter().string(from: newest)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    let destination = file("collection", for: device)
    try? data.write(to: destination, options: .atomic)
  }

  static func macReport(for device: PairedDevice) -> Data {
    let collection = file("collection", for: device)
    let lastCollection = (try? JSONSerialization.jsonObject(with: Data(contentsOf: collection)))
      as? [String: Any] ?? [:]
    var recentEvents = Array(macLogText().split(separator: "\n").suffix(30)).map(String.init)
    var object: [String: Any] = [
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
      "lastCollection": lastCollection,
      "recentEvents": recentEvents
    ]
    object["lastAppDiagnostic"] = CrashDiagnostics.summary()
    while true {
      let data = (try? JSONSerialization.data(withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
      if data.count <= 16_384 || recentEvents.isEmpty { return data }
      recentEvents.removeFirst()
      object["recentEvents"] = recentEvents
    }
  }

  static func mailAttachments(for device: PairedDevice, incidentDate: Date) throws -> [URL] {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MochiLog-Support-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let mac = directory.appendingPathComponent("mochilog-mac-diagnostics.json")
    try macReport(for: device).write(to: mac, options: .atomic)
    var attachments = [mac]
    for offset in -2...0 {
      guard let date = Calendar.current.date(byAdding: .day, value: offset,
        to: incidentDate) else { continue }
      let day = dayString(date)
      let log = directory.appendingPathComponent("mochilog-mac-debug-\(day).log")
      try logText(for: day).write(to: log, atomically: true, encoding: .utf8)
      attachments.append(log)
    }
    if let diagnostic = CrashDiagnostics.latest() {
      let target = directory.appendingPathComponent("mochilog-mac-app-diagnostic.json")
      try diagnostic.write(to: target, options: .atomic)
      attachments.append(target)
    }
    if let phone = phoneReport(for: device) {
      let target = directory.appendingPathComponent("mochilog-iphone-diagnostics.json")
      try FileManager.default.copyItem(at: phone, to: target)
      attachments.append(target)
    }
    return attachments
  }
}
