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

/// Conservative display allowlist. Unknown paths and invalid representations stay in details.
struct BatterySummaryRow: Identifiable {
  let key: String
  let value: String?
  var kind = "number"
  var unit = ""
  var id: String { key }
  func display(text: (String) -> String) -> String {
    guard let value else { return text("live_missing") }
    return kind == "boolean" ? text(value == "true" ? "live_true" : "live_false") : value + unit
  }
}

enum BatteryPresentation {
  // Wire compatibility preserves legacy core fields; display uses verified exact paths only.
  static let primaryKeys = ["CycleCount", "DesignCapacity"]
  static func primary(_ field: RawBatteryField) -> BatterySummaryRow? {
    guard field.path.count == 1, let key = field.path.first, primaryKeys.contains(key),
      field.kind == "number", let value = Int(field.value),
      (key == "CycleCount" ? 0...100000 : 1...200000).contains(value) else { return nil }
    return BatterySummaryRow(key: key, value: value.formatted(), unit: key == "CycleCount" ? "" : " mAh")
  }
  static let extraKeys = ["IsCharging", "FullyCharged", "ExternalConnected", "ExternalChargeCapable",
    "AppleRawExternalConnected", "BatteryInstalled", "AtCriticalLevel", "Voltage", "Amperage", "InstantAmperage", "Serial"]
  static func extra(_ field: RawBatteryField) -> BatterySummaryRow? {
    guard field.path.count == 1, let key = field.path.first, extraKeys.contains(key) else { return nil }
    if ["Voltage", "Amperage", "InstantAmperage"].contains(key) {
      guard field.kind == "number", let value = Int64(field.value),
        (key == "Voltage" ? 0...100000 : -2000000...2000000).contains(value) else { return nil }
      return BatterySummaryRow(key: key, value: field.value, unit: key == "Voltage" ? " mV" : " mA")
    }
    if key == "Serial" {
      guard field.kind == "string", !field.value.isEmpty else { return nil }
      return BatterySummaryRow(key: key, value: field.value, kind: "string")
    }
    guard field.kind == "boolean", ["true", "false"].contains(field.value) else { return nil }
    return BatterySummaryRow(key: key, value: field.value, kind: "boolean")
  }
  static func summary(values: [String: Int], charging: Bool?, fields: [RawBatteryField]) -> [BatterySummaryRow] {
    var rows = primaryKeys.map { key in
      if let field = fields.first(where: { $0.path == [key] }), let row = primary(field) { return row }
      // Old helpers attest a root CycleCount, but their capacity fields have no provenance.
      return BatterySummaryRow(key: key, value: fields.isEmpty && key == "CycleCount" ? values[key].map { $0.formatted() } : nil,
        unit: key == "CycleCount" ? "" : " mAh")
    }
    for key in extraKeys {
      if key == "IsCharging", let charging {
        rows.append(BatterySummaryRow(key: key, value: charging ? "true" : "false", kind: "boolean"))
      } else if let field = fields.first(where: { $0.path == [key] }), let row = extra(field) { rows.append(row) }
    }
    return rows
  }
  static func details(values: [String: Int], charging: Bool?, fields: [RawBatteryField]) -> [RawBatteryField] {
    fields.filter { field in
      if let row = extra(field) {
        // A contradictory raw charging flag must remain inspectable.
        return row.key == "IsCharging" && charging != nil && row.value != (charging! ? "true" : "false")
      }
      return primary(field) == nil
    }
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
    if data.starts(with: Data("<?xml".utf8)) { return try fromRegistry(data) }
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

  /// Native interpretation of the helper's lossless plist. Legacy JSON remains supported.
  static func fromRegistry(_ data: Data) throws -> LiveBatterySnapshot {
    guard data.count <= 1048576,
      let registry = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
      !registry.isEmpty else { throw RawBatteryField.Failure.invalid }
    var fields: [RawBatteryField] = []
    func visit(_ value: Any, path: [String]) throws {
      guard path.count <= 32, fields.count < 10000 else { throw RawBatteryField.Failure.invalid }
      if let dictionary = value as? [String: Any], !dictionary.isEmpty {
        for key in dictionary.keys.sorted() {
          guard key.count <= 512 else { throw RawBatteryField.Failure.invalid }
          try visit(dictionary[key]!, path: path + [key])
        }
        return
      }
      if let array = value as? [Any], !array.isEmpty {
        for (index, entry) in array.enumerated() { try visit(entry, path: path + ["[\(index)]"]) }
        return
      }
      let kind: String
      let text: String
      switch value {
      case let number as NSNumber:
        let boolean = CFGetTypeID(number) == CFBooleanGetTypeID()
        kind = boolean ? "boolean" : "number"
        text = boolean ? (number.boolValue ? "true" : "false") : number.stringValue
      case let string as String: kind = "string"; text = string
      case let blob as Data: kind = "data"; text = blob.base64EncodedString()
      case let date as Date: kind = "date"; text = ISO8601DateFormatter().string(from: date)
      case is [String: Any]: kind = "dictionary"; text = "{}"
      case is [Any]: kind = "array"; text = "[]"
      default: throw RawBatteryField.Failure.invalid
      }
      guard text.count <= 131072 else { throw RawBatteryField.Failure.invalid }
      fields.append(RawBatteryField(path: path, kind: kind, value: text))
    }
    try visit(registry, path: [])
    let battery = registry["BatteryData"] as? [String: Any] ?? [:]
    let limits = ["CycleCount": 0...100000, "DesignCapacity": 1...200000,
      "FullChargeCapacity": 1...200000, "NominalChargeCapacity": 1...200000,
      "AppleRawMaxCapacity": 1...200000, "CurrentCapacity": 0...100]
    var values: [String: Int] = [:]
    for (key, range) in limits {
      let raw = ["CycleCount", "CurrentCapacity"].contains(key) ? registry[key] : (battery[key] ?? registry[key])
      if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, number.doubleValue == Double(number.intValue), range.contains(number.intValue) {
        values[key] = number.intValue
      }
    }
    let charging = (registry["IsCharging"] as? NSNumber).flatMap {
      CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil
    }
    var core: [String: Any] = values
    if let charging { core["IsCharging"] = charging }
    let coreData = try JSONSerialization.data(withJSONObject: core, options: [.sortedKeys, .withoutEscapingSlashes])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let details = try encoder.encode(fields)
    guard details.count <= 262144 else { throw RawBatteryField.Failure.invalid }
    let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    return LiveBatterySnapshot(version: 1, values: values, revision: hash(coreData),
      acquiredAt: ISO8601DateFormatter().string(from: Date()), charging: charging,
      detailsJSON: String(decoding: details, as: UTF8.self), detailsRevision: hash(details))
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
    guard let tool = Bundle.main.url(forResource: "mochilog-collector", withExtension: nil,
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
