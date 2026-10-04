import CryptoKit
import Foundation

struct ConnectedDevice: Codable, Identifiable, Hashable {
  let udid: String
  let name: String
  let model: String
  var id: String { udid }
}

struct PairedDevice: Codable, Identifiable {
  let udid: String
  let name: String
  let model: String
  let physicalDeviceID: UUID
  let secret: Data
  var confirmedAt: Date? = nil
  var manualAddress: String? = nil
  var automaticPauseUntil: Date? = nil
  var id: String { udid }

  private enum CodingKeys: String, CodingKey {
    case udid, name, model, physicalDeviceID, secret, confirmedAt, manualAddress,
      automaticPauseUntil
  }

  init(udid: String, name: String, model: String, physicalDeviceID: UUID,
    secret: Data, confirmedAt: Date? = nil, manualAddress: String? = nil,
    automaticPauseUntil: Date? = nil) {
    self.udid = udid
    self.name = name
    self.model = model
    self.physicalDeviceID = physicalDeviceID
    self.secret = secret
    self.confirmedAt = confirmedAt
    self.manualAddress = manualAddress
    self.automaticPauseUntil = automaticPauseUntil
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    udid = try values.decode(String.self, forKey: .udid)
    name = try values.decode(String.self, forKey: .name)
    model = try values.decode(String.self, forKey: .model)
    physicalDeviceID = try values.decode(UUID.self, forKey: .physicalDeviceID)
    // Read the first beta's plaintext key only for the one-time Keychain migration.
    secret = try values.decodeIfPresent(Data.self, forKey: .secret) ?? Data()
    confirmedAt = try values.decodeIfPresent(Date.self, forKey: .confirmedAt)
    manualAddress = try values.decodeIfPresent(String.self, forKey: .manualAddress)
    automaticPauseUntil = try values.decodeIfPresent(Date.self, forKey: .automaticPauseUntil)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(udid, forKey: .udid)
    try values.encode(name, forKey: .name)
    try values.encode(model, forKey: .model)
    try values.encode(physicalDeviceID, forKey: .physicalDeviceID)
    try values.encodeIfPresent(confirmedAt, forKey: .confirmedAt)
    try values.encodeIfPresent(manualAddress, forKey: .manualAddress)
    try values.encodeIfPresent(automaticPauseUntil, forKey: .automaticPauseUntil)
  }
}

struct CompanionState: Codable {
  var hostID: UUID = UUID()
  var devices: [PairedDevice] = []
  // Retain the old key only to authenticate an offline device's eventual
  // revocation request. Revoked devices are never collected or sent logs.
  var revokedDevices: [PairedDevice] = []

  private enum CodingKeys: String, CodingKey { case hostID, devices, revokedDevices }

  init(hostID: UUID = UUID(), devices: [PairedDevice] = [],
    revokedDevices: [PairedDevice] = []) {
    self.hostID = hostID
    self.devices = devices
    self.revokedDevices = revokedDevices
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    hostID = try values.decode(UUID.self, forKey: .hostID)
    devices = try values.decodeIfPresent([PairedDevice].self, forKey: .devices) ?? []
    revokedDevices = try values.decodeIfPresent([PairedDevice].self, forKey: .revokedDevices) ?? []
  }
}

enum CollectorError: LocalizedError {
  case helperMissing, timeout, discoveryTimeout, signal(Int32, String), exitCode(Int32, String), failed(String)
  var errorDescription: String? {
    switch self {
    case .helperMissing: MacTransferL10n.text("mt_c_00")
    case .timeout: MacTransferL10n.text("mt_c_01")
    case .discoveryTimeout: MacTransferL10n.text("mt_discovery_timeout")
    case .signal(let code, let detail): MacTransferL10n.format("mt_c_02", code, detail)
    case .exitCode(let code, let detail): MacTransferL10n.format("mt_c_03", code, detail)
    case .failed(let message): message
    }
  }
}

struct CollectionReport {
  let saved: Int
  let skipped: Int
  let failed: Int
  let deferred: Int
  let lastError: String?
  let newestHostAnalyticsAt: Date?
}

enum LogKind: String {
  case host = "Host"
  case watch = "Watch"
}

struct RemoteLog {
  let path: String
  let source: String? // ProxiedDevice directory on the paired iPhone.
  var name: String { URL(fileURLWithPath: path).lastPathComponent }
  var token: String {
    if let source { return "Watch::\(source)::\(name)" }
    return "Host::\(name)"
  }
}

enum Collector {
  static let root: URL = {
    #if TRANSFER_TESTING
    if let path = ProcessInfo.processInfo.environment["MOCHILOG_TRANSFER_TEST_ROOT"] {
      let base = URL(fileURLWithPath: path, isDirectory: true)
      try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      return base
    }
    #endif
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MochiLog Mac", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }()

  static var stateURL: URL { root.appendingPathComponent("paired-devices.json") }

  static func loadState() -> CompanionState {
    guard let data = try? Data(contentsOf: stateURL),
      var state = try? JSONDecoder().decode(CompanionState.self, from: data)
    else { return CompanionState() }
    var needsMigration = false
    for index in (state.devices + state.revokedDevices).indices {
      let device = (state.devices + state.revokedDevices)[index]
      if device.secret.count == 32 {
        // Do not remove the old copy unless every key reaches the Keychain.
        guard (try? PairingKeyStore.save(device.secret, for: device.physicalDeviceID)) != nil
        else { return state }
        needsMigration = true
      } else if let secret = PairingKeyStore.load(for: device.physicalDeviceID) {
        let restored = PairedDevice(udid: device.udid, name: device.name,
          model: device.model, physicalDeviceID: device.physicalDeviceID,
          secret: secret, confirmedAt: device.confirmedAt,
          manualAddress: device.manualAddress,
          automaticPauseUntil: device.automaticPauseUntil)
        if index < state.devices.count { state.devices[index] = restored }
        else { state.revokedDevices[index - state.devices.count] = restored }
      }
    }
    if needsMigration { try? saveState(state) }
    return state
  }

  static func saveState(_ state: CompanionState) throws {
    for device in state.devices + state.revokedDevices {
      guard device.secret.count == 32 else { throw CollectorError.failed("Pairing key unavailable") }
      try PairingKeyStore.save(device.secret, for: device.physicalDeviceID)
    }
    let data = try JSONEncoder().encode(state)
    try data.write(to: stateURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
  }

  static func run(_ arguments: [String], timeout: TimeInterval = 120) throws -> String {
    #if TRANSFER_TESTING
    let testHelper = ProcessInfo.processInfo.environment["MOCHILOG_TEST_COLLECTOR"]
      .map { URL(fileURLWithPath: $0) }
    #else
    let testHelper: URL? = nil
    #endif
    guard let helper = testHelper ?? Bundle.main.url(forResource: "pymobiledevice3",
      withExtension: nil, subdirectory: "Collector") else {
      throw CollectorError.helperMissing
    }
    let process = Process()
    process.executableURL = helper
    process.arguments = arguments
    process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "TERM": "dumb", "NO_COLOR": "1"]
    let outputURL = root.appendingPathComponent("process-\(UUID().uuidString).out")
    let errorURL = root.appendingPathComponent("process-\(UUID().uuidString).err")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    defer {
      try? FileManager.default.removeItem(at: outputURL)
      try? FileManager.default.removeItem(at: errorURL)
    }
    let output = try FileHandle(forWritingTo: outputURL)
    let errors = try FileHandle(forWritingTo: errorURL)
    defer { try? output.close(); try? errors.close() }
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if process.isRunning { process.terminate(); throw CollectorError.timeout }
    let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
    guard process.terminationStatus == 0 else {
      let errorText = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? text
      let log = root.appendingPathComponent("last-collector-error.log")
      try? errorText.write(to: log, atomically: true, encoding: .utf8)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
      let meaningful = errorText.split(separator: "\n").last(where: {
        $0.contains("ERROR") || $0.contains("Error") || $0.contains("Traceback")
      })
      let detail = meaningful.map { String($0.suffix(300)) }
      if process.terminationReason == .uncaughtSignal {
        throw CollectorError.signal(process.terminationStatus, detail ?? "")
      }
      throw CollectorError.exitCode(process.terminationStatus, detail ?? "")
    }
    return text
  }

  static func browse(runCommand: ([String], TimeInterval) throws -> String = {
    try Collector.run($0, timeout: $1)
  }) throws -> [ConnectedDevice] {
    var devices: [ConnectedDevice] = []
    var nativeError: Error?
    do {
      let text = try runCommand(["remote", "browse", "--native", "--timeout", "4"], 20)
      guard let data = text.data(using: .utf8),
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
      else { throw CollectorError.failed(MacTransferL10n.text("mt_c_04")) }
      devices = rows.compactMap { row in
        guard let udid = row["udid"] as? String, let model = row["model"] as? String,
          model.hasPrefix("iPhone") || model.hasPrefix("iPad") else { return nil }
        return ConnectedDevice(udid: udid, name: row["name"] as? String ?? model, model: model)
      }
    } catch { nativeError = error }

    // RemotePairing discovery can time out on one unavailable peer. Still try
    // the independent Wi-Fi lockdown discovery used by USB-trusted devices.
    if let text = try? runCommand(["usbmux", "list", "--network", "--simple"], 20),
      let data = text.data(using: .utf8),
      let udids = try? JSONDecoder().decode([String].self, from: data) {
      for udid in udids where !devices.contains(where: { $0.udid == udid }) {
        guard let info = try? runCommand(["lockdown", "info", "--mobdev2", "--udid", udid], 20),
          let data = info.data(using: .utf8),
          let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let model = values["ProductType"] as? String,
          model.hasPrefix("iPhone") || model.hasPrefix("iPad") else { continue }
        devices.append(ConnectedDevice(udid: udid,
          name: values["DeviceName"] as? String ?? model, model: model))
      }
    }
    if devices.isEmpty, let nativeError {
      if case CollectorError.timeout = nativeError { throw CollectorError.discoveryTimeout }
      throw nativeError
    }
    return devices
  }

  /// Request RemotePairing over an already trusted USB lockdown connection.
  /// This records the USB setup attempt; wireless access is checked separately
  /// after the cable is removed before the app pairing flow can continue.
  static func prepareUSBPairing() throws -> ConnectedDevice {
    let text = try run(["usbmux", "list", "--usb", "--simple"], timeout: 20)
    guard let data = text.data(using: .utf8),
      let udids = try JSONSerialization.jsonObject(with: data) as? [String]
    else { throw CollectorError.failed(MacTransferL10n.text("mt_c_04")) }
    guard udids.count == 1, let udid = udids.first else {
      throw CollectorError.failed(MacTransferL10n.text(
        udids.isEmpty ? "mt_usb_no_device" : "mt_usb_multiple_devices"))
    }
    if (try? run(["lockdown", "info", "--udid", udid], timeout: 20)) == nil {
      _ = try run(["lockdown", "pair", "--udid", udid], timeout: 90)
    }
    let info = try run(["lockdown", "info", "--udid", udid], timeout: 20)
    guard let infoData = info.data(using: .utf8),
      let values = try JSONSerialization.jsonObject(with: infoData) as? [String: Any],
      let model = values["ProductType"] as? String,
      let version = values["ProductVersion"] as? String,
      (Int(version.split(separator: ".").first ?? "0") ?? 0) >= 27,
      model.hasPrefix("iPhone") || model.hasPrefix("iPad") else {
      throw CollectorError.failed(MacTransferL10n.text("mt_usb_unsupported"))
    }
    _ = try run(["lockdown", "wifi-connections", "on", "--udid", udid], timeout: 20)
    let state = try run(["lockdown", "wifi-connections", "--udid", udid], timeout: 20)
    guard let stateData = state.data(using: .utf8),
      let settings = try JSONSerialization.jsonObject(with: stateData) as? [String: Any],
      settings["EnableWifiConnections"] as? Bool == true else {
      throw CollectorError.failed(MacTransferL10n.text("mt_usb_wifi_failed"))
    }
    // This creates a pymobiledevice3 RemotePairing record. The collector uses
    // Apple's native route, so USB command success alone must not unlock QR.
    _ = try run(["lockdown", "remotepairing", "--pair", "--udid", udid], timeout: 45)
    return ConnectedDevice(udid: udid, name: values["DeviceName"] as? String ?? model,
      model: model)
  }

  /// A live read of the diagnostics service, not just a cached pair record.
  /// A trusted USB setup can use Wi-Fi lockdown even when Apple's native
  /// RemotePairing route remains unauthenticated. Both paths are wireless.
  static func verifyOSPairing(udid: String) throws {
    _ = try remoteRootListing(udid: udid)
  }

  private static func usbmuxDeviceIDs(_ connection: String) throws -> [String] {
    let text = try run(["usbmux", "list", connection, "--simple"], timeout: 20)
    guard let data = text.data(using: .utf8),
      let udids = try JSONSerialization.jsonObject(with: data) as? [String]
    else { throw CollectorError.failed(MacTransferL10n.text("mt_c_04")) }
    return udids
  }

  static func isUSBConnected(udid: String) throws -> Bool {
    try usbmuxDeviceIDs("--usb").contains(udid)
  }

  static func remoteRootListing(udid: String,
    runCommand: ([String], TimeInterval) throws -> String = {
      try Collector.run($0, timeout: $1)
    }) throws -> (String, [String]) {
    let native = ["--native", "--udid", udid]
    let network = ["--mobdev2", "--udid", udid]
    let root = ["--remote-file", "/", "--depth", "1"]
    if let listing = try? runCommand(["crash", "ls"] + native + root, 45),
      !listing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return (listing, native)
    }
    let networkIDs = try? JSONDecoder().decode([String].self,
      from: Data(try runCommand(["usbmux", "list", "--network", "--simple"], 20).utf8))
    if networkIDs?.contains(udid) == true,
      let listing = try? runCommand(["crash", "ls"] + network + root, 45),
      !listing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return (listing, network)
    }
    throw CollectorError.failed(MacTransferL10n.text("mt_empty_diagnostic_listing"))
  }

  static func directory(for device: PairedDevice) throws -> URL {
    let url = root.appendingPathComponent("Queue", isDirectory: true)
      .appendingPathComponent(device.physicalDeviceID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func directory(for device: PairedDevice, kind: LogKind) throws -> URL {
    let url = try directory(for: device).appendingPathComponent(kind.rawValue,
      isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func directory(for device: PairedDevice, kind: LogKind, source: String?) throws -> URL {
    let base = try directory(for: device, kind: kind)
    guard let source else { return base }
    guard source.hasPrefix("ProxiedDevice-"), source.range(of: #"^ProxiedDevice-[a-fA-F0-9]+$"#,
      options: .regularExpression) != nil else { throw CollectorError.failed(MacTransferL10n.text("mt_c_05")) }
    let url = base.appendingPathComponent(source, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func queueFile(for token: String, device: PairedDevice) throws -> URL? {
    let parts = token.components(separatedBy: "::")
    let name: String
    let base: URL
    if parts.count == 1 {
      name = parts[0]
      base = try directory(for: device) // early beta's flat queue
    } else if parts.count == 2, let kind = LogKind(rawValue: parts[0]) {
      name = parts[1]
      base = try directory(for: device, kind: kind)
    } else if parts.count == 3, let kind = LogKind(rawValue: parts[0]) {
      name = parts[2]
      base = try directory(for: device, kind: kind, source: parts[1])
    } else { return nil }
    guard name == URL(fileURLWithPath: name).lastPathComponent,
      name.hasPrefix("Analytics-"), name.hasSuffix(".ips.ca.synced") else { return nil }
    return base.appendingPathComponent(name)
  }

  static func queueToken(for file: URL, device: PairedDevice) throws -> String {
    let parent = file.deletingLastPathComponent()
    if parent.standardizedFileURL.path == (try directory(for: device)).standardizedFileURL.path {
      return file.lastPathComponent
    }
    if let kind = LogKind(rawValue: parent.lastPathComponent) {
      return "\(kind.rawValue)::\(file.lastPathComponent)"
    }
    let source = parent.lastPathComponent
    guard let kind = LogKind(rawValue: parent.deletingLastPathComponent().lastPathComponent),
      parent.standardizedFileURL.path == (try directory(for: device, kind: kind,
        source: source)).standardizedFileURL.path else {
      throw CollectorError.failed(MacTransferL10n.text("mt_c_06"))
    }
    return "\(kind.rawValue)::\(source)::\(file.lastPathComponent)"
  }

  static func pending(for device: PairedDevice) throws -> [URL] {
    let root = try directory(for: device)
    guard let enumerator = FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    let files = enumerator.compactMap { $0 as? URL }
    let standardizedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let rootPath = standardizedRoot.hasSuffix("/")
      ? String(standardizedRoot.dropLast()) : standardizedRoot
    return files.filter { file in
      guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
        file.lastPathComponent.hasPrefix("Analytics-"),
        file.lastPathComponent.hasSuffix(".ips.ca.synced") else { return false }
      let path = file.resolvingSymlinksInPath().standardizedFileURL.path
      guard path.hasPrefix(rootPath + "/") else { return false }
      let relative = String(path.dropFirst(rootPath.count + 1))
      let parts = relative.split(separator: "/")
      return parts.count == 1 ||
        ((parts.count == 2 || parts.count == 3) &&
          ["Host", "Watch"].contains(String(parts[0])))
    }
      .sorted { $0.path < $1.path }
  }

  static func delivered(for device: PairedDevice) -> Set<String> {
    let url = root.appendingPathComponent("delivered-\(device.physicalDeviceID.uuidString).json")
    guard let data = try? Data(contentsOf: url),
      let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(names)
  }

  private static func recheckURL(for device: PairedDevice) -> URL {
    root.appendingPathComponent("recheck-\(device.physicalDeviceID.uuidString).json")
  }

  private static func rechecks(for device: PairedDevice) -> [String: Date] {
    guard let data = try? Data(contentsOf: recheckURL(for: device)),
      let values = try? JSONDecoder().decode([String: Date].self, from: data)
    else { return [:] }
    return values
  }

  private static func saveRechecks(_ values: [String: Date], for device: PairedDevice) throws {
    let url = recheckURL(for: device)
    try JSONEncoder().encode(values).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  // A large Analytics file can be returned incompletely by the diagnostics
  // service while the device changes lock state. Do not permanently discard it.
  static func shouldRecheckUnclassified(_ url: URL) throws -> Bool {
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    if bytes.count >= 1_000_000 { return true }
    let markers = ["last_value_CycleCount", "last_value_NominalChargeCapacity",
      "last_value_AppleRawMaxCapacity"]
    return markers.contains { bytes.range(of: Data($0.utf8)) != nil }
  }

  // A short download can be a truncated daily report when the device changes
  // lock state mid-transfer. Keep likely battery reports eligible for retry.
  static func isLikelyDailyReport(_ remote: RemoteLog) -> Bool {
    guard remote.name.range(of: #"^Analytics-[0-9]{4}-[0-9]{2}-[0-9]{2}-09[0-1][0-9][0-9][0-9]"#,
      options: .regularExpression) != nil else { return false }
    return remote.source != nil || remote.name.range(of: #"\.[0-9]+\.ips\.ca\.synced$"#,
      options: .regularExpression) != nil
  }

  static func markDelivered(_ name: String, for device: PairedDevice) throws {
    let url = root.appendingPathComponent("delivered-\(device.physicalDeviceID.uuidString).json")
    var names = delivered(for: device)
    names.insert(name)
    try JSONEncoder().encode(names.sorted()).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  /// A cheap transport-side filter, not a battery parser. The phone remains
  /// the only place that interprets measurements and creates records.
  static func batteryLogKind(_ url: URL) throws -> LogKind? {
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    var lines = 0
    for byte in bytes where byte == 10 {
      lines += 1
      if lines >= 100 { break }
    }
    guard lines >= 100 else { return nil }
    let required = ["last_value_CycleCount", "last_value_NominalChargeCapacity",
      "last_value_AppleRawMaxCapacity"]
    guard required.allSatisfy({ bytes.range(of: Data($0.utf8)) != nil }),
      let firstLineEnd = bytes.firstIndex(of: 10),
      let header = try? JSONSerialization.jsonObject(with: bytes.prefix(upTo: firstLineEnd))
        as? [String: Any],
      let os = header["os_version"] as? String else { return nil }
    let lower = os.lowercased()
    if lower.contains("watch") { return .watch }
    if lower.contains("iphone") || lower.contains("ipad") || lower.contains("ios") {
      return .host
    }
    return nil
  }

  static func collect(_ device: PairedDevice,
    progress: ((Int, Int) -> Void)? = nil) throws -> CollectionReport {
    var remoteFiles: [RemoteLog] = []
    var connection: [String] = []
    if let address = device.manualAddress {
      let text = try run(["direct-rsd", "scan", "--udid", device.udid,
        "--host", address, "--port", "49152"], timeout: 120)
      guard let data = text.data(using: .utf8),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let files = object["files"] as? [[String: Any]] else {
        throw CollectorError.failed("Invalid direct diagnostic listing")
      }
      remoteFiles = files.compactMap { item in
        guard let path = item["path"] as? String else { return nil }
        return RemoteLog(path: path, source: item["source"] as? String)
      }
    } else {
      let (rootListing, chosenConnection) = try remoteRootListing(udid: device.udid)
      connection = chosenConnection
      let proxiedSources = rootListing.split(separator: "\n").map(String.init).filter {
        $0.range(of: #"^/ProxiedDevice-[a-fA-F0-9]+$"#,
          options: .regularExpression) != nil
      }
      let listing = try run(["crash", "ls"] + connection +
        ["--remote-file", "/Retired", "--depth", "1"], timeout: 90)
      remoteFiles = listing.split(separator: "\n").map {
        RemoteLog(path: String($0), source: nil)
      }
      remoteFiles += rootListing.split(separator: "\n").map {
        RemoteLog(path: String($0), source: nil)
      }
      for sourcePath in proxiedSources {
        let source = String(sourcePath.dropFirst())
        do {
          let listed = try run(["crash", "ls"] + connection +
            ["--remote-file", "\(sourcePath)/Retired", "--depth", "1"], timeout: 90)
          remoteFiles += listed.split(separator: "\n").map {
            RemoteLog(path: String($0), source: source)
          }
          let current = try run(["crash", "ls"] + connection +
            ["--remote-file", sourcePath, "--depth", "1"], timeout: 90)
          remoteFiles += current.split(separator: "\n").map {
            RemoteLog(path: String($0), source: source)
          }
        } catch {
          // One unavailable paired accessory must not block the host's logs.
          continue
        }
      }
    }
    remoteFiles = analyticsCandidates(remoteFiles)
    let timestamp = DateFormatter()
    timestamp.locale = Locale(identifier: "en_US_POSIX")
    timestamp.timeZone = .current
    timestamp.dateFormat = "yyyy-MM-dd-HHmmss"
    let newestHostAnalyticsAt = remoteFiles.lazy.filter { $0.source == nil }
      .compactMap { timestamp.date(from: String($0.name.dropFirst(10).prefix(17))) }
      .max()
    let destination = try directory(for: device)
    let delivered = delivered(for: device)
    var rechecks = rechecks(for: device)
    let now = Date()
    let newFiles = remoteFiles.filter { remote in
      let name = remote.name
      guard name.range(of: #"^Analytics-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}.*\.ips\.ca\.synced$"#,
        options: .regularExpression) != nil else { return false }
      if delivered.contains(remote.token) { return false }
      if let retryAt = rechecks[remote.token], retryAt > now { return false }
      if let source = remote.source, delivered.contains("Host::\(source)::\(name)") {
        return false
      }
      if remote.source == nil && delivered.contains(name) { return false }
      let host = try? directory(for: device, kind: .host, source: remote.source)
        .appendingPathComponent(name)
      let watch = try? directory(for: device, kind: .watch, source: remote.source)
        .appendingPathComponent(name)
      return ![host, watch].compactMap { $0 }.contains {
        FileManager.default.fileExists(atPath: $0.path)
      }
    }
    progress?(0, newFiles.count)
    var directStaging: URL?
    defer { if let directStaging { try? FileManager.default.removeItem(at: directStaging) } }
    if let address = device.manualAddress, !newFiles.isEmpty {
      let staging = destination.appendingPathComponent(".direct-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      directStaging = staging
      let manifest = staging.appendingPathComponent("manifest.json")
      let items = newFiles.map { ["path": $0.path] }
      try JSONSerialization.data(withJSONObject: items).write(to: manifest)
      _ = try run(["direct-rsd", "pull-batch", "--udid", device.udid,
        "--host", address, "--port", "49152", "--manifest", manifest.path,
        "--output", staging.path], timeout: TimeInterval(min(1800, max(180, newFiles.count * 180))))
    }
    var saved = 0
    var skipped = 0
    var failed = 0
    var deferred = 0
    var lastError: String?
    for (index, remote) in newFiles.enumerated() {
      let name = remote.name
      do {
        let staging = destination.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let downloaded = (directStaging?.appendingPathComponent(String(index)) ?? staging)
          .appendingPathComponent(name)
        var pullError: Error?
        for attempt in 0..<(directStaging == nil ? 2 : 0) {
          do {
            _ = try run(["crash", "pull", staging.path, "--remote-file", remote.path]
              + connection, timeout: 180)
            pullError = nil
            break
          } catch {
            pullError = error
            if attempt == 0 { try? FileManager.default.removeItem(at: downloaded) }
          }
        }
        if let pullError { throw pullError }
        guard FileManager.default.fileExists(atPath: downloaded.path) else {
          throw CollectorError.failed("\(name) の取得結果が見つかりません")
        }
        if let kind = try batteryLogKind(downloaded) {
          let local = try directory(for: device, kind: kind, source: remote.source)
            .appendingPathComponent(name)
          try FileManager.default.moveItem(at: downloaded, to: local)
          if rechecks.removeValue(forKey: remote.token) != nil {
            try saveRechecks(rechecks, for: device)
          }
          saved += 1
        } else if try shouldRecheckUnclassified(downloaded) || !remote.path.contains("/Retired/") ||
          isLikelyDailyReport(remote) {
          let retryAt = Date().addingTimeInterval(30 * 60)
          rechecks[remote.token] = retryAt
          try saveRechecks(rechecks, for: device)
          deferred += 1
          let size = (try? downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
          SupportDiagnostics.record("\(device.name): deferred unclassified \(name); bytes=\(size); retry=\(SupportDiagnostics.localTime(retryAt))")
        } else {
          try markDelivered(remote.token, for: device)
          if rechecks.removeValue(forKey: remote.token) != nil {
            try saveRechecks(rechecks, for: device)
          }
          skipped += 1
        }
      } catch {
        failed += 1
        lastError = error.localizedDescription
      }
      progress?(index + 1, newFiles.count)
    }
    return CollectionReport(saved: saved, skipped: skipped, failed: failed, deferred: deferred,
      lastError: lastError, newestHostAnalyticsAt: newestHostAnalyticsAt)
  }

  static func analyticsCandidates(_ files: [RemoteLog]) -> [RemoteLog] {
    var seen = Set<String>()
    return files.filter { remote in
      let base = remote.source.map { "/\($0)/" } ?? "/"
      let validLocation = remote.path.hasPrefix(base + "Retired/Analytics-") ||
        remote.path.hasPrefix(base + "Analytics-")
      return validLocation && !remote.name.hasPrefix("Analytics-Census-") &&
        !remote.name.localizedCaseInsensitiveContains("session") &&
        remote.name.hasSuffix(".ips.ca.synced") && seen.insert(remote.token).inserted
    }
  }
}
