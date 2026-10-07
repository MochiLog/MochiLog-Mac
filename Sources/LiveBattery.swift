import Foundation
import CryptoKit
import CoreFoundation

/// Session-only diagnostic cache. Never encoded into CompanionState or log storage.
struct LiveBatterySnapshot: Codable, Equatable {
  let version: Int
  let values: [String: Int]
  let revision: String
  let acquiredAt: String
  let charging: Bool?

  static func decode(_ data: Data) throws -> LiveBatterySnapshot {
    guard data.count <= 8192,
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
    guard !values.filter({ $0.key != "CurrentCapacity" }).isEmpty else {
      throw CollectorError.failed("battery_unavailable")
    }
    let charging = (raw["IsCharging"] as? NSNumber).flatMap {
      CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil
    }
    return LiveBatterySnapshot(version: 1, values: values, revision: revision,
      acquiredAt: acquired, charging: charging)
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
  func response(for id: UUID, revision: String?) -> Data? {
    lock.lock(); defer { lock.unlock() }
    var object: [String: Any] = ["type": "live-battery", "version": 1,
      "state": failures.contains(id) ? "unavailable" : "waiting"]
    if let snapshot = snapshots[id] {
      object["state"] = failures.contains(id) ? "stale" : "current"
      object["acquiredAt"] = snapshot.acquiredAt
      object["revision"] = snapshot.revision
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
  static func currentBattery(_ device: PairedDevice) throws -> LiveBatterySnapshot {
    guard let tool = Bundle.main.url(forResource: "pymobiledevice3", withExtension: nil,
      subdirectory: "Collector") else { throw CollectorError.helperMissing }
    let process = Process()
    process.executableURL = tool
    process.arguments = ["battery-snapshot", "--udid", device.udid]
      + (device.manualAddress.map { ["--host", $0] } ?? [])
    process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "NO_COLOR": "1"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    // Output is filtered to a fixed set of small scalars by the collector.
    let lock = NSLock()
    var output = Data()
    var overflow = false
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      lock.lock(); defer { lock.unlock() }
      if output.count + chunk.count <= 8192 { output.append(chunk) }
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
    if output.count + tail.count <= 8192 { output.append(tail) } else { overflow = true }
    guard process.terminationStatus == 0, !overflow else { throw CollectorError.failed("battery_unavailable") }
    return try LiveBatterySnapshot.decode(output)
  }
}
