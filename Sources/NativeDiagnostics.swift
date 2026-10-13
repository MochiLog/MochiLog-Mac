import Darwin
import Foundation

/// Files are bounded before decoding, including damaged or externally replaced files.
enum BoundedDiagnosticFile {
  static func read(_ url: URL, maximum: Int) -> Data? {
    guard maximum > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maximum + 1), data.count <= maximum else { return nil }
    return data
  }
}

enum NativeDiagnostics {
  static let maxDevices = 32, maxEvents = 50, maxBytes = 256 * 1024
  struct Resources: Codable {
    let processID: Int32
    let residentBytes: UInt64
    let peakResidentBytes: UInt64
    let activeHelpers: Int
  }
  struct Collection: Codable {
    var result: String
    var saved, excluded, deferred, failed, retryHeld: Int
    var acquisitionComplete: Bool
  }
  struct Device: Codable {
    let physicalDeviceID: UUID
    var name, model: String
    let pairingConfirmed: Bool
    let automaticPauseUntil: String?
    var routes: DiagnosticRoutes.Report
    var collection: Collection?
  }
  struct Snapshot: Codable {
    var schema = 1
    var type = "mochilog-native-diagnostics"
    let generatedAt: String
    var appVersion, build, osVersion, status: String
    let resources: Resources
    var devices: [Device]
    var recentEvents: [String]
    var truncated: Bool
  }
  enum Failure: Error { case tooLarge }
  static func resources() -> Resources {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Resources(processID: getpid(), residentBytes: GuardedProcess.residentBytes(),
      peakResidentBytes: UInt64(max(0, usage.ru_maxrss)), activeHelpers: GuardedProcess.activeCount)
  }
  static func capture(status: String, devices: [Device], events: [String], at date: Date = Date()) -> Snapshot {
    let limited = Array(devices.prefix(maxDevices)).map { device -> Device in
      var copy = device
      copy.name = String(copy.name.prefix(128)); copy.model = String(copy.model.prefix(64))
      copy.routes.manual = copy.routes.manual.map { String($0.prefix(64)) }
      copy.routes.hints = Array(copy.routes.hints.prefix(4))
      copy.routes.candidates = Array(copy.routes.candidates.prefix(8))
      if var collection = copy.collection {
        collection.result = String(collection.result.prefix(64)); copy.collection = collection
      }
      return copy
    }
    return Snapshot(generatedAt: SupportDiagnostics.localTime(date),
      appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
      build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
      osVersion: String(ProcessInfo.processInfo.operatingSystemVersionString.prefix(256)),
      status: String(status.prefix(512)), resources: resources(), devices: limited,
      recentEvents: events.suffix(maxEvents).map { String($0.prefix(512)) },
      truncated: devices.count > maxDevices || events.count > maxEvents)
  }
  static func encode(_ snapshot: Snapshot) throws -> Data {
    // Validate before serialization; arbitrary raw objects never reach the encoder.
    guard snapshot.schema == 1, snapshot.type == "mochilog-native-diagnostics",
      snapshot.appVersion.count <= 128, snapshot.build.count <= 128,
      snapshot.osVersion.count <= 256, snapshot.status.count <= 512,
      snapshot.generatedAt.count <= 64,
      snapshot.devices.count <= maxDevices, snapshot.recentEvents.count <= maxEvents,
      snapshot.recentEvents.allSatisfy({ $0.count <= 512 }),
      snapshot.devices.allSatisfy({ $0.name.count <= 128 && $0.model.count <= 64
        && ($0.automaticPauseUntil?.count ?? 0) <= 64 && ($0.collection?.result.count ?? 0) <= 64
        && $0.routes.isBounded }) else { throw Failure.tooLarge }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(snapshot)
    guard data.count <= maxBytes else { throw Failure.tooLarge }
    return data
  }
}

final class DiagnosticSnapshotStore: @unchecked Sendable {
  private let lock = NSLock()
  let directory: URL
  init(root: URL) { directory = root.appendingPathComponent("NativeDiagnostics", isDirectory: true) }
  func save(_ snapshot: NativeDiagnostics.Snapshot, retentionDays: Int, at date: Date = Date()) throws {
    let data = try NativeDiagnostics.encode(snapshot)
    lock.lock(); defer { lock.unlock() }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["current.json", SupportDiagnostics.dayString(date) + ".json"] {
      let target = directory.appendingPathComponent(name)
      try data.write(to: target, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    pruneUnlocked(retentionDays: retentionDays, at: date)
  }
  func prune(retentionDays: Int, at date: Date = Date()) {
    lock.lock(); defer { lock.unlock() }
    pruneUnlocked(retentionDays: retentionDays, at: date)
  }
  private func pruneUnlocked(retentionDays: Int, at date: Date) {
    let cutoff = SupportDiagnostics.dayString(Calendar.current.date(byAdding: .day,
      value: 1 - min(365, max(7, retentionDays)), to: date) ?? date)
    for file in (try? FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: nil)) ?? [] {
      let day = file.deletingPathExtension().lastPathComponent
      if file.pathExtension == "json", day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
        options: .regularExpression) != nil, day < cutoff {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }
  func clear() {
    lock.lock(); defer { lock.unlock() }
    try? FileManager.default.removeItem(at: directory)
  }
}
