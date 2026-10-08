import CryptoKit
import Foundation

/// Grants are deliberately memory-only: a restart requires fresh confirmation.
final class CloudLogSharing {
  private var grants: [UUID: (scope: String, at: Date)] = [:]
  private var lastDecision: [String: String] = [:]
  private var digests: [String: (size: Int64, modified: Date, digest: String)] = [:]
  static let lease: TimeInterval = 15 * 60
  func update(_ id: UUID, scope: String?, now: Date) {
    let was = self.scope(id, now: now)
    if was != (scope.flatMap { CloudSharedLogToken.validScope($0) ? $0 : nil }) {
      SupportDiagnostics.record("Cloud sharing: consent changed device=\(id.uuidString), state=\(scope.flatMap { CloudSharedLogToken.validScope($0) ? $0 : nil } == nil ? "off/unavailable" : "confirmed"), leaseSeconds=\(Int(Self.lease))")
    }
    if let scope, CloudSharedLogToken.validScope(scope) { grants[id] = (scope, now) }
    else { grants.removeValue(forKey: id) }
  }
  func scope(_ id: UUID, now: Date) -> String? {
    guard let grant = grants[id], now.timeIntervalSince(grant.at) >= 0,
      now.timeIntervalSince(grant.at) < Self.lease else { return nil }
    return grant.scope
  }
  func eligible(_ token: CloudSharedLogToken, recipient: UUID,
    devices: [PairedDevice], now: Date) -> Bool {
    let reason: String
    if token.origin == recipient { return false }
    if !devices.contains(where: { $0.physicalDeviceID == token.origin }) { reason = "source no longer paired" }
    else if !devices.contains(where: { $0.physicalDeviceID == recipient }) { reason = "recipient no longer paired" }
    else if scope(recipient, now: now) == nil { reason = "recipient consent absent/expired" }
    else if scope(token.origin, now: now) == nil { reason = "source consent absent/expired" }
    else if scope(recipient, now: now) != token.scope || scope(token.origin, now: now) != token.scope { reason = "account scopes differ" }
    else { reason = "allowed: both sync settings and same account confirmed" }
    let key = "\(token.origin.uuidString)|\(recipient.uuidString)"
    if lastDecision[key] != reason {
      lastDecision[key] = reason
      SupportDiagnostics.record("Cloud sharing: source=\(token.origin.uuidString), recipient=\(recipient.uuidString), pairedDevices=\(devices.count), decision=\(reason)")
    }
    return reason.hasPrefix("allowed:")
  }
  func resolve(_ token: String, recipient: UUID, devices: [PairedDevice], now: Date) -> URL? {
    guard let parsed = CloudSharedLogToken.parse(token),
      eligible(parsed, recipient: recipient, devices: devices, now: now),
      let source = devices.first(where: { $0.physicalDeviceID == parsed.origin }) else { return nil }
    if let queued = try? Collector.queueFile(for: parsed.base, device: source),
      FileManager.default.fileExists(atPath: queued.path) { return queued }
    return BatteryLogStorage.list(devices: devices).first {
      !$0.pending && $0.deviceID == parsed.origin && base($0) == parsed.base
    }?.url
  }
  private func base(_ row: StoredBatteryLog) -> String {
    ([row.kind] + (row.source.map { [$0] } ?? []) + [row.name]).joined(separator: "::")
  }
  private static func receiptKey(_ token: String, digest: String) -> String {
    guard let parsed = CloudSharedLogToken.parse(token) else { return "invalid" }
    return "\(parsed.origin.uuidString)|\(parsed.base)|\(digest)"
  }
  private func ledgerURL(_ recipient: UUID) -> URL {
    Collector.root.appendingPathComponent("cloud-delivered-\(recipient.uuidString).json")
  }
  private func receipts(_ recipient: UUID) throws -> [String: Double] {
    let url = ledgerURL(recipient)
    if !FileManager.default.fileExists(atPath: url.path) { return [:] }
    return try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: url))
  }
  private func digest(_ file: URL) throws -> String {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max
    let modified = attributes[.modificationDate] as? Date ?? .distantPast
    guard size <= 64 * 1024 * 1024 else { throw CollectorError.failed("Shared log exceeds size limit") }
    if let cached = digests[file.path], cached.size == size, cached.modified == modified { return cached.digest }
    let value = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    if digests.count >= 512 { digests.removeAll(keepingCapacity: true) }
    digests[file.path] = (size, modified, value)
    return value
  }
  func acknowledge(_ token: String, file: URL, recipient: UUID) throws {
    // ACK verification uses the current bytes, never a cached digest.
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard ((attributes[.size] as? NSNumber)?.int64Value ?? Int64.max) <= 64 * 1024 * 1024 else { throw CollectorError.failed("Shared log exceeds size limit") }
    let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    var values = try receipts(recipient)
    values[Self.receiptKey(token, digest: digest)] = Date().timeIntervalSince1970
    if values.count > 10_000 {
      for entry in values.sorted(by: { $0.value < $1.value }).prefix(values.count - 10_000) {
        values.removeValue(forKey: entry.key)
      }
    }
    let url = ledgerURL(recipient)
    try JSONEncoder().encode(values).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    // A foreign ACK never consumes the source queue or its daily receipt.
  }
  func next(recipient: UUID, devices: [PairedDevice], now: Date) -> (token: String, file: URL)? {
    guard let scope = scope(recipient, now: now) else { return nil }
    guard let receipts = try? receipts(recipient) else {
      SupportDiagnostics.record("Cloud sharing: recipient=\(recipient.uuidString), blocked: receipt ledger unreadable")
      return nil
    }
    for row in BatteryLogStorage.list(devices: devices).sorted(by: { $0.url.path < $1.url.path }) {
      let token = CloudSharedLogToken(scope: scope, origin: row.deviceID, base: base(row))
      guard CloudSharedLogToken.validBase(token.base),
        eligible(token, recipient: recipient, devices: devices, now: now),
        row.size <= 64 * 1024 * 1024,
        let digest = try? digest(row.url) else { continue }
      if receipts[Self.receiptKey(token.value, digest: digest)] == nil { return (token.value, row.url) }
    }
    return nil
  }
}
