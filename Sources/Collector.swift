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
      throw CollectorError.failed(String(errorText.suffix(1_000)))
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

  static func pending(for device: PairedDevice) throws -> [URL] {
    let files = try FileManager.default.contentsOfDirectory(at: directory(for: device),
      includingPropertiesForKeys: nil)
    return files.filter { $0.lastPathComponent.hasPrefix("Analytics-")
      && $0.lastPathComponent.hasSuffix(".ips.ca.synced") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
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

  static func collect(_ device: PairedDevice) throws -> Int {
    let listing = try run(["crash", "ls", "--native", "--udid", device.udid,
      "--remote-file", "/Retired", "--depth", "1"], timeout: 90)
    let remoteFiles = listing.split(separator: "\n").map(String.init).filter {
      $0.hasPrefix("/Retired/Analytics-") && !$0.hasPrefix("/Retired/Analytics-Census-")
        && $0.hasSuffix(".ips.ca.synced")
    }
    let destination = try directory(for: device)
    let delivered = delivered(for: device)
    var count = 0
    for remote in remoteFiles {
      let name = URL(fileURLWithPath: remote).lastPathComponent
      guard name.range(of: #"^Analytics-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}.*\.ips\.ca\.synced$"#,
        options: .regularExpression) != nil else { continue }
      let local = destination.appendingPathComponent(name)
      guard !delivered.contains(name) else { continue }
      guard !FileManager.default.fileExists(atPath: local.path) else { continue }
      let staging = destination.appendingPathComponent(".staging-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: staging) }
      _ = try run(["crash", "pull", staging.path, "--remote-file", remote,
        "--native", "--udid", device.udid], timeout: 180)
      let downloaded = staging.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: downloaded.path) else {
        throw CollectorError.failed("\(name) の取得結果が見つかりません")
      }
      try FileManager.default.moveItem(at: downloaded, to: local)
      count += 1
    }
    return count
  }
}
