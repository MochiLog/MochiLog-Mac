import Foundation
import CryptoKit
import CoreFoundation

struct RawBatteryField: Codable, Equatable {
  let path: [String]
  let kind: String
  let value: String
  var group: String { path.count > 1 ? path[0] : "" }
  var label: String { (path.count > 1 ? Array(path.dropFirst()) : path).joined(separator: " › ") }
  enum Failure: Error { case invalid }
  static func decode(_ text: String, revision: String) throws -> [RawBatteryField] {
    let data = Data(text.utf8)
    guard data.count <= 262144,
      revision.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == revision else { throw Failure.invalid }
    let fields = try JSONDecoder().decode([RawBatteryField].self, from: data)
    guard !fields.isEmpty, fields.count <= 10000,
      fields.allSatisfy({ !$0.path.isEmpty && $0.path.count <= 32 && $0.path.allSatisfy({ $0.count <= 512 })
        && ["null", "boolean", "number", "string", "data", "date", "dictionary", "array"].contains($0.kind)
        && $0.value.utf8.count <= 524288 }) else { throw Failure.invalid }
    return fields
  }
}

/// Session-only diagnostic cache. Never encoded into CompanionState or log storage.
struct LiveBatterySnapshot: Codable, Equatable {
  let version: Int
  let values: [String: Int]
  let revision: String
  let acquiredAt: String
  let charging: Bool?
  var detailsJSON: String? = nil
  var detailsRevision: String? = nil
  var fields: [RawBatteryField] {
    guard let detailsJSON, let detailsRevision else { return [] }
    return (try? RawBatteryField.decode(detailsJSON, revision: detailsRevision)) ?? []
  }

  static func decode(_ data: Data) throws -> LiveBatterySnapshot {
    guard data.count <= 1048576,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["version"] as? Int == 1,
      let raw = object["values"] as? [String: Any],
      let revision = object["revision"] as? String,
      revision.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      let acquired = object["acquiredAt"] as? String,
      ISO8601DateFormatter().date(from: acquired) != nil else {
      throw CollectorError.failed("battery_unavailable")
    }
    let limits = ["CycleCount": 0...100000, "DesignCapacity": 1...200000,
      "FullChargeCapacity": 1...200000, "NominalChargeCapacity": 1...200000,
      "AppleRawMaxCapacity": 1...200000, "CurrentCapacity": 0...100]
    var values: [String: Int] = [:]
    for (key, range) in limits {
      if let number = raw[key] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, number.doubleValue == Double(number.intValue),
        range.contains(number.intValue) { values[key] = number.intValue }
    }
    let details = object["detailsJSON"] as? String
    let detailsRevision = object["detailsRevision"] as? String
    if let details, let detailsRevision { _ = try RawBatteryField.decode(details, revision: detailsRevision) }
    else if details != nil || detailsRevision != nil { throw CollectorError.failed("battery_unavailable") }
    guard !values.filter({ $0.key != "CurrentCapacity" }).isEmpty || details != nil else {
      throw CollectorError.failed("battery_unavailable")
    }
    let charging = (raw["IsCharging"] as? NSNumber).flatMap {
      CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil
    }
    return LiveBatterySnapshot(version: 1, values: values, revision: revision,
      acquiredAt: acquired, charging: charging, detailsJSON: details, detailsRevision: detailsRevision)
  }
}

final class LiveBatteryCache: @unchecked Sendable {
  private let lock = NSLock()
  private var snapshots: [UUID: LiveBatterySnapshot] = [:]
  private var failures: Set<UUID> = []
  func set(_ snapshot: LiveBatterySnapshot?, for id: UUID) {
    lock.lock(); defer { lock.unlock() }
    if let snapshot { snapshots[id] = snapshot; failures.remove(id) }
    else { failures.insert(id) }
  }
  func remove(_ id: UUID) {
    lock.lock(); defer { lock.unlock() }
    snapshots.removeValue(forKey: id); failures.remove(id)
  }
  func response(for id: UUID, revision: String?, includesDetails: Bool = false, detailsRevision: String? = nil) -> Data? {
    lock.lock(); defer { lock.unlock() }
    var object: [String: Any] = ["type": "live-battery", "version": 1,
      "state": failures.contains(id) ? "unavailable" : "waiting"]
    if let snapshot = snapshots[id] {
      object["state"] = failures.contains(id) ? "stale" : "current"
      object["acquiredAt"] = snapshot.acquiredAt
      object["revision"] = snapshot.revision
      if includesDetails, let detailText = snapshot.detailsJSON, let detailDigest = snapshot.detailsRevision {
        object["detailsVersion"] = 1
        object["detailsRevision"] = detailDigest
        if detailsRevision != detailDigest { object["detailsJSON"] = detailText }
      }
      if revision != snapshot.revision {
        object["values"] = snapshot.values
        if let charging = snapshot.charging { object["charging"] = charging }
      }
    }
    return try? JSONSerialization.data(withJSONObject: object)
  }
}

extension Collector {
  /// Private pipes only: current values never touch run()'s output/error files.
  static func currentBattery(_ device: PairedDevice, peerAddress: String? = nil) throws -> LiveBatterySnapshot {
    guard let tool = Bundle.main.url(forResource: "pymobiledevice3", withExtension: nil,
      subdirectory: "Collector") else { throw CollectorError.helperMissing }
    let process = Process()
    process.executableURL = tool
    process.arguments = ["battery-snapshot", "--udid", device.udid]
      + (device.manualAddress.map { ["--host", $0] }
        ?? peerAddress.map { ["--fallback-host", $0] } ?? [])
    process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "NO_COLOR": "1"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    // Output stays in bounded private memory; it never enters diagnostic log storage.
    let lock = NSLock()
    var output = Data()
    var overflow = false
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      lock.lock(); defer { lock.unlock() }
      if output.count + chunk.count <= 1048576 { output.append(chunk) }
      else { overflow = true }
    }
    defer { pipe.fileHandleForReading.readabilityHandler = nil; try? pipe.fileHandleForReading.close() }
    try process.run()
    let deadline = Date().addingTimeInterval(45)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning { process.terminate(); throw CollectorError.timeout }
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    lock.lock(); defer { lock.unlock() }
    if output.count + tail.count <= 1048576 { output.append(tail) } else { overflow = true }
    guard process.terminationStatus == 0, !overflow else { throw CollectorError.failed("battery_unavailable") }
    return try LiveBatterySnapshot.decode(output)
  }
}
