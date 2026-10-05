import Foundation

struct StoredBatteryLog: Identifiable {
  let id: String
  let url: URL
  let deviceID: UUID
  let deviceName: String
  let kind: String
  let source: String?
  let size: Int64
  let storedAt: Date
  let pending: Bool

  var name: String { url.lastPathComponent }
  var logDay: String { String(name.dropFirst("Analytics-".count).prefix(10)) }
}

struct VerifiedBatteryReceipt: Codable {
  let kind: String
  let source: String?
  let day: String
}

enum BatteryLogStorage {
  private static let archiveName = "BatteryLogArchive"
  private static let capacityKey = "BatteryLogArchiveLimitMB"
  private static let monthsKey = "BatteryLogArchiveRetentionMonths"
  private static let retainKey = "BatteryLogArchiveAfterDelivery"
  static var archiveRoot: URL { Collector.root.appendingPathComponent(archiveName, isDirectory: true) }
  private static func receiptsURL(for device: PairedDevice) -> URL {
    Collector.root.appendingPathComponent("verified-receipts-\(device.physicalDeviceID.uuidString).json")
  }

  private static func receipts(for device: PairedDevice) -> [VerifiedBatteryReceipt] {
    guard let data = try? Data(contentsOf: receiptsURL(for: device)),
      let values = try? JSONDecoder().decode([VerifiedBatteryReceipt].self, from: data)
    else { return [] }
    return values
  }

  private static func recordReceipt(_ receipt: VerifiedBatteryReceipt,
    for device: PairedDevice) throws {
    let url = receiptsURL(for: device)
    let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -14,
      to: Date()) ?? .distantPast
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "yyyy-MM-dd"
    let oldestDay = formatter.string(from: cutoff)
    var values = receipts(for: device).filter { $0.day >= oldestDay }
    if !values.contains(where: { $0.kind == receipt.kind && $0.source == receipt.source &&
      $0.day == receipt.day }) { values.append(receipt) }
    try JSONEncoder().encode(values).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  static var retainsAfterDelivery: Bool {
    get { UserDefaults.standard.bool(forKey: retainKey) }
    set { UserDefaults.standard.set(newValue, forKey: retainKey) }
  }

  static var limitMB: Int {
    get { max(1, UserDefaults.standard.object(forKey: capacityKey) as? Int ?? 500) }
    set { UserDefaults.standard.set(max(1, newValue), forKey: capacityKey); try? prune() }
  }

  static var retentionMonths: Int {
    get { max(1, UserDefaults.standard.object(forKey: monthsKey) as? Int ?? 1) }
    set { UserDefaults.standard.set(max(1, newValue), forKey: monthsKey); try? prune() }
  }

  static func archiveAcknowledged(_ file: URL, device: PairedDevice) throws {
    let resendMarker = URL(fileURLWithPath: file.path + ".force-resend")
    let queue = try Collector.directory(for: device).standardizedFileURL
    let source = file.standardizedFileURL
    guard source.path.hasPrefix(queue.path + "/") else {
      throw CollectorError.failed("Invalid battery log queue path")
    }
    let relative = String(source.path.dropFirst(queue.path.count + 1))
    let parts = relative.split(separator: "/").map(String.init)
    guard (parts.count == 2 && parts[0] == "Host") ||
      (parts.count == 3 && parts[0] == "Watch"),
      let name = parts.last, name.hasPrefix("Analytics-"), name.count >= 20 else {
      throw CollectorError.failed("Invalid battery log queue path")
    }
    try recordReceipt(VerifiedBatteryReceipt(kind: parts[0],
      source: parts.count == 3 ? parts[1] : nil,
      day: String(name.dropFirst("Analytics-".count).prefix(10))), for: device)
    guard retainsAfterDelivery else {
      try FileManager.default.removeItem(at: file)
      try? FileManager.default.removeItem(at: resendMarker)
      return
    }
    let destination = archiveRoot.appendingPathComponent(device.physicalDeviceID.uuidString)
      .appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: source)
    } else {
      try FileManager.default.moveItem(at: source, to: destination)
      try FileManager.default.setAttributes([.modificationDate: Date(), .posixPermissions: 0o600],
        ofItemAtPath: destination.path)
    }
    try? FileManager.default.removeItem(at: resendMarker)
    try prune()
  }

  static func list(devices: [PairedDevice]) -> [StoredBatteryLog] {
    var rows: [StoredBatteryLog] = []
    let names = devices.reduce(into: [UUID: String]()) { result, device in
      result[device.physicalDeviceID] = device.name
    }
    for device in devices {
      if let queue = try? Collector.directory(for: device) {
        rows += scan(queue, deviceID: device.physicalDeviceID,
          deviceName: device.name, pending: true)
      }
    }
    if let folders = try? FileManager.default.contentsOfDirectory(at: archiveRoot,
      includingPropertiesForKeys: [.isDirectoryKey]) {
      for folder in folders {
        guard let deviceID = UUID(uuidString: folder.lastPathComponent) else { continue }
        rows += scan(folder, deviceID: deviceID,
          deviceName: names[deviceID] ?? deviceID.uuidString, pending: false)
      }
    }
    return rows.sorted { $0.storedAt > $1.storedAt }
  }

  // Only verified battery logs reach the queue or archive. Do not infer a
  // watch-free iPhone from an empty Watch folder: its log may arrive later.
  static func hasRequiredDailyLogs(for device: PairedDevice, on day: String) -> Bool {
    hasRequiredDailyLogs(model: device.model, rows: list(devices: [device]), on: day,
      receipts: receipts(for: device))
  }

  static func hasRequiredDailyLogs(model: String, rows: [StoredBatteryLog],
    on day: String, receipts: [VerifiedBatteryReceipt] = []) -> Bool {
    guard rows.contains(where: { $0.kind == "Host" && $0.logDay == day }) ||
      receipts.contains(where: { $0.kind == "Host" && $0.day == day }) else {
      return false
    }
    if model.hasPrefix("iPad") { return true }
    guard model.hasPrefix("iPhone") else { return false }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = formatter.timeZone
    guard let date = formatter.date(from: day),
      let weekStart = calendar.date(byAdding: .day,
        value: -6, to: date) else { return false }
    let oldestRelevantDay = formatter.string(from: weekStart)
    let expectedWatches = Set(rows.filter {
      $0.kind == "Watch" && $0.logDay >= oldestRelevantDay && $0.logDay <= day
    }.compactMap(\.source) + receipts.filter {
      $0.kind == "Watch" && $0.day >= oldestRelevantDay && $0.day <= day
    }.compactMap(\.source))
    guard !expectedWatches.isEmpty else { return false }
    let todayWatches = Set(rows.filter {
      $0.kind == "Watch" && $0.logDay == day
    }.compactMap(\.source) + receipts.filter {
      $0.kind == "Watch" && $0.day == day
    }.compactMap(\.source))
    return expectedWatches.isSubset(of: todayWatches)
  }

  private static func scan(_ root: URL, deviceID: UUID, deviceName: String,
    pending: Bool) -> [StoredBatteryLog] {
    guard let files = FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
    else { return [] }
    return files.compactMap { element -> StoredBatteryLog? in
      guard let url = element as? URL,
        url.lastPathComponent.hasPrefix("Analytics-"),
        url.lastPathComponent.hasSuffix(".ips.ca.synced"),
        let values = try? url.resourceValues(forKeys: [
          .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
        values.isRegularFile == true else { return nil }
      let rootPath = root.standardizedFileURL.path
      let filePath = url.standardizedFileURL.path
      guard filePath.hasPrefix(rootPath + "/") else { return nil }
      let relative = String(filePath.dropFirst(rootPath.count + 1))
      let parts = relative.split(separator: "/").map(String.init)
      guard parts.count == 1 || ((parts.count == 2 || parts.count == 3) &&
        ["Host", "Watch"].contains(parts[0])) else { return nil }
      let kind = parts.count == 1 ? "Host" : parts[0]
      return StoredBatteryLog(id: "\(pending ? "pending" : "archive")/\(deviceID.uuidString)/\(relative)",
        url: url, deviceID: deviceID, deviceName: deviceName, kind: kind,
        source: parts.count == 3 ? parts[1] : nil,
        size: Int64(values.fileSize ?? 0),
        storedAt: values.contentModificationDate ?? .distantPast,
        pending: pending)
    }
  }

  static func delete(_ items: [StoredBatteryLog]) throws {
    for item in items {
      guard !item.pending else { continue }
      try FileManager.default.removeItem(at: item.url)
    }
  }

  static func requeue(_ items: [StoredBatteryLog], devices: [PairedDevice]) throws -> Int {
    var copied = 0
    for item in items where !item.pending {
      guard let device = devices.first(where: { $0.physicalDeviceID == item.deviceID }) else {
        continue
      }
      let archived = archiveRoot.appendingPathComponent(item.deviceID.uuidString)
      let archivePath = archived.standardizedFileURL.path
      let filePath = item.url.standardizedFileURL.path
      guard filePath.hasPrefix(archivePath + "/") else { continue }
      let relative = String(filePath.dropFirst(archivePath.count + 1))
      let destination = try Collector.directory(for: device).appendingPathComponent(relative)
      guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      do {
        try FileManager.default.copyItem(at: item.url, to: destination)
        try Data().write(to: URL(fileURLWithPath: destination.path + ".force-resend"),
          options: .atomic)
      } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
      }
      copied += 1
    }
    return copied
  }

  static func export(_ items: [StoredBatteryLog], to directory: URL) throws {
    for item in items {
      let subfolder = directory.appendingPathComponent(item.deviceID.uuidString)
        .appendingPathComponent(item.kind)
        .appendingPathComponent(item.source ?? "")
      try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
      let destination = subfolder.appendingPathComponent(item.name)
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw CocoaError(.fileWriteFileExists)
      }
      try FileManager.default.copyItem(at: item.url, to: destination)
    }
  }

  static func prune(now: Date = Date()) throws {
    let root = archiveRoot
    guard FileManager.default.fileExists(atPath: root.path),
      let files = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
    else { return }
    let cutoff = Calendar.current.date(byAdding: .month, value: -retentionMonths, to: now) ?? now
    var retained: [(URL, Int64, Date)] = []
    for case let url as URL in files {
      guard url.lastPathComponent.hasSuffix(".ips.ca.synced"),
        let values = try? url.resourceValues(forKeys: [
          .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
        values.isRegularFile == true else { continue }
      let date = values.contentModificationDate ?? .distantPast
      if date < cutoff { try FileManager.default.removeItem(at: url) }
      else { retained.append((url, Int64(values.fileSize ?? 0), date)) }
    }
    let limit = Int64(limitMB) * 1_000_000
    var total = retained.reduce(Int64(0)) { $0 + $1.1 }
    for (url, size, _) in retained.sorted(by: { $0.2 < $1.2 }) where total > limit {
      try FileManager.default.removeItem(at: url)
      total -= size
    }
  }
}
