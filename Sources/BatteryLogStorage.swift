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

enum BatteryLogStorage {
  private static let archiveName = "BatteryLogArchive"
  private static let capacityKey = "BatteryLogArchiveLimitMB"
  private static let monthsKey = "BatteryLogArchiveRetentionMonths"
  private static let retainKey = "BatteryLogArchiveAfterDelivery"
  static var archiveRoot: URL { Collector.root.appendingPathComponent(archiveName, isDirectory: true) }

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
    guard retainsAfterDelivery else {
      try FileManager.default.removeItem(at: file)
      return
    }
    let queue = try Collector.directory(for: device).standardizedFileURL
    let source = file.standardizedFileURL
    guard source.path.hasPrefix(queue.path + "/") else {
      throw CollectorError.failed("Invalid battery log queue path")
    }
    let relative = String(source.path.dropFirst(queue.path.count + 1))
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
    try prune()
  }

  static func list(devices: [PairedDevice]) -> [StoredBatteryLog] {
    var rows: [StoredBatteryLog] = []
    let names = Dictionary(uniqueKeysWithValues: devices.map { ($0.physicalDeviceID, $0.name) })
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
      try FileManager.default.copyItem(at: item.url, to: destination)
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
