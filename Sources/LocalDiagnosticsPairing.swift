import CryptoKit
import Foundation
import Darwin

/// Explicit own-device delegation; never exported through logs/support/history.
enum LocalDiagnosticsPairing {
  static func control(for device: PairedDevice) -> Data? {
    guard device.udid.range(of: "^[A-Fa-f0-9-]{16,64}$", options: .regularExpression) != nil else { return nil }
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    let legacy = home.appendingPathComponent(".pymobiledevice3", isDirectory: true)
    let directory = FileManager.default.fileExists(atPath: legacy.path) ? legacy : home.appendingPathComponent(".local/share/pymobiledevice3", isDirectory: true)
    let path = directory.appendingPathComponent("remote_" + device.udid + ".plist")
    guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
      let data = try? Data(contentsOf: path),
      let record = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
      let pub = record["public_key"] as? Data, pub.count == 32,
      let priv = record["private_key"] as? Data, priv.count == 32 else { return unavailable() }
    // Python's platform.node() uses the kernel hostname verbatim. Foundation
    // normalizes its spelling/case, which changes UUIDv3 and breaks pair-verify.
    var hostname = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
    guard gethostname(&hostname, hostname.count) == 0 else { return unavailable() }
    let pairingHostname = String(cString: hostname)
    let hostID = identifier(hostname: pairingHostname)
    var pairing: [String: Any] = ["public_key": pub, "private_key": priv,
      "identifier": record["identifier"] as? String ?? record["host_identifier"] as? String ?? hostID]
    if let irk = (record["alt_irk"] ?? record["peer_alt_irk"]) as? Data { pairing["alt_irk"] = irk }
    guard let plist = try? PropertyListSerialization.data(fromPropertyList: pairing, format: .binary, options: 0) else { return nil }
    return try? JSONSerialization.data(withJSONObject: ["type": "local-diagnostics-pairing", "version": 1,
      "expectedUDID": device.udid, "physicalDeviceID": device.physicalDeviceID.uuidString,
      "pairing": plist.base64EncodedString()])
  }
  static func unavailable() -> Data? {
    try? JSONSerialization.data(withJSONObject: ["type": "local-diagnostics-pairing", "version": 1, "unavailable": true])
  }
  static func identifier(hostname: String) -> String {
    var ns = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!.uuid
    let namespace = withUnsafeBytes(of: &ns) { Data($0) }
    var digest = Array(Insecure.MD5.hash(data: namespace + Data(hostname.utf8)))
    digest[6] = (digest[6] & 0x0f) | 0x30; digest[8] = (digest[8] & 0x3f) | 0x80
    return UUID(uuid: (digest[0],digest[1],digest[2],digest[3],digest[4],digest[5],digest[6],digest[7],digest[8],digest[9],digest[10],digest[11],digest[12],digest[13],digest[14],digest[15])).uuidString
  }
}
