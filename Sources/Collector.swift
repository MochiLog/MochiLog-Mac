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
  var id: String { udid }
}

struct CompanionState: Codable {
  var hostID: UUID = UUID()
  var devices: [PairedDevice] = []
}

enum CollectorError: LocalizedError {
  case helperMissing, failed(String)
  var errorDescription: String? {
    switch self {
    case .helperMissing: "同梱のログ収集ツールが見つかりません。DMGからアプリを再インストールしてください。"
    case .failed(let message): message
    }
  }
}

struct CollectionReport {
  let saved: Int
  let skipped: Int
  let failed: Int
  let lastError: String?
}

enum LogKind: String {
  case host = "Host"
  case watch = "Watch"
}

private struct RemoteLog {
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
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MochiLog Mac", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }()

  static var stateURL: URL { root.appendingPathComponent("paired-devices.json") }

  static func loadState() -> CompanionState {
    guard let data = try? Data(contentsOf: stateURL),
      let state = try? JSONDecoder().decode(CompanionState.self, from: data)
    else { return CompanionState() }
    return state
  }

  static func saveState(_ state: CompanionState) throws {
    let data = try JSONEncoder().encode(state)
    try data.write(to: stateURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
  }

  static func run(_ arguments: [String], timeout: TimeInterval = 120) throws -> String {
    guard let helper = Bundle.main.url(forResource: "pymobiledevice3", withExtension: nil,
      subdirectory: "Collector") else { throw CollectorError.helperMissing }
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
    if process.isRunning { process.terminate(); throw CollectorError.failed("ログ収集がタイムアウトしました") }
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
        throw CollectorError.failed("収集ツールがシグナル\(process.terminationStatus)で異常終了しました\(detail.map { ": \($0)" } ?? "")")
      }
      throw CollectorError.failed("収集ツールが終了コード\(process.terminationStatus)で停止\(detail.map { ": \($0)" } ?? "")")
    }
    return text
  }

  static func browse() throws -> [ConnectedDevice] {
    let text = try run(["remote", "browse", "--native", "--timeout", "4"], timeout: 20)
    guard let data = text.data(using: .utf8),
      let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { throw CollectorError.failed("端末一覧を読み取れませんでした") }
    return rows.compactMap { row in
      guard let udid = row["udid"] as? String, let model = row["model"] as? String,
        model.hasPrefix("iPhone") || model.hasPrefix("iPad")
      else { return nil }
      return ConnectedDevice(udid: udid, name: row["name"] as? String ?? model, model: model)
    }
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
      options: .regularExpression) != nil else { throw CollectorError.failed("診断ログの端末識別子が不正です") }
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
    if parent == (try directory(for: device)) { return file.lastPathComponent }
    if let kind = LogKind(rawValue: parent.lastPathComponent) {
      return "\(kind.rawValue)::\(file.lastPathComponent)"
    }
    let source = parent.lastPathComponent
    guard let kind = LogKind(rawValue: parent.deletingLastPathComponent().lastPathComponent),
      parent == (try directory(for: device, kind: kind, source: source)) else {
      throw CollectorError.failed("待機列のパスが不正です")
    }
    return "\(kind.rawValue)::\(source)::\(file.lastPathComponent)"
  }

  static func pending(for device: PairedDevice) throws -> [URL] {
    let root = try directory(for: device)
    guard let enumerator = FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    let files = enumerator.compactMap { $0 as? URL }
    return files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      && $0.lastPathComponent.hasPrefix("Analytics-")
      && $0.lastPathComponent.hasSuffix(".ips.ca.synced") }
      .sorted { $0.path < $1.path }
  }

  static func delivered(for device: PairedDevice) -> Set<String> {
    let url = root.appendingPathComponent("delivered-\(device.physicalDeviceID.uuidString).json")
    guard let data = try? Data(contentsOf: url),
      let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(names)
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
    let rootListing = try run(["crash", "ls", "--native", "--udid", device.udid,
      "--remote-file", "/", "--depth", "1"], timeout: 90)
    let proxiedSources = rootListing.split(separator: "\n").map(String.init).filter {
      $0.range(of: #"^/ProxiedDevice-[a-fA-F0-9]+$"#,
        options: .regularExpression) != nil
    }
    let listing = try run(["crash", "ls", "--native", "--udid", device.udid,
      "--remote-file", "/Retired", "--depth", "1"], timeout: 90)
    var remoteFiles = listing.split(separator: "\n").map {
      RemoteLog(path: String($0), source: nil)
    }
    for sourcePath in proxiedSources {
      let source = String(sourcePath.dropFirst())
      do {
        let listed = try run(["crash", "ls", "--native", "--udid", device.udid,
          "--remote-file", "\(sourcePath)/Retired", "--depth", "1"], timeout: 90)
        remoteFiles += listed.split(separator: "\n").map {
          RemoteLog(path: String($0), source: source)
        }
      } catch {
        // One unavailable paired accessory must not block the host's logs.
        continue
      }
    }
    remoteFiles = remoteFiles.filter { remote in
      let prefix = remote.source.map { "/\($0)/Retired/Analytics-" } ?? "/Retired/Analytics-"
      return remote.path.hasPrefix(prefix) && !remote.name.hasPrefix("Analytics-Census-")
        && !remote.name.localizedCaseInsensitiveContains("session")
        && remote.name.hasSuffix(".ips.ca.synced")
    }
    let destination = try directory(for: device)
    let delivered = delivered(for: device)
    let newFiles = remoteFiles.filter { remote in
      let name = remote.name
      guard name.range(of: #"^Analytics-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}.*\.ips\.ca\.synced$"#,
        options: .regularExpression) != nil else { return false }
      if delivered.contains(remote.token) { return false }
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
    var saved = 0
    var skipped = 0
    var failed = 0
    var lastError: String?
    for (index, remote) in newFiles.enumerated() {
      let name = remote.name
      do {
        let staging = destination.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let downloaded = staging.appendingPathComponent(name)
        var pullError: Error?
        for attempt in 0..<2 {
          do {
            _ = try run(["crash", "pull", staging.path, "--remote-file", remote.path,
              "--native", "--udid", device.udid], timeout: 180)
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
          saved += 1
        } else {
          try markDelivered(remote.token, for: device)
          skipped += 1
        }
      } catch {
        failed += 1
        lastError = error.localizedDescription
      }
      progress?(index + 1, newFiles.count)
    }
    return CollectionReport(saved: saved, skipped: skipped, failed: failed,
      lastError: lastError)
  }
}
