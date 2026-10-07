import Foundation
import CryptoKit

@main
struct LiveBatterySimulatorServer {
  static func main() throws {
    let host = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let device = PairedDevice(udid: "synthetic", name: "iPhone Test", model: "iPhone",
      physicalDeviceID: id, secret: Data(repeating: 7, count: 32))
    let server = TransferServer(state: CompanionState(hostID: host, devices: [device]))
    let values = ["CycleCount": 245, "DesignCapacity": 4000,
      "NominalChargeCapacity": 3820, "AppleRawMaxCapacity": 3850,
      "FullChargeCapacity": 3800, "CurrentCapacity": 67]
    let digest = SHA256.hash(data: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]))
      .map { String(format: "%02x", $0) }.joined()
    server.liveBattery.set(LiveBatterySnapshot(version: 1, values: values, revision: digest,
      acquiredAt: ISO8601DateFormatter().string(from: Date()), charging: nil), for: id)
    server.onLiveBatteryRequested = { _, _ in
      print("authenticated live request")
      fflush(stdout)
    }
    try server.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      print("PORT=\(server.testListeningPort ?? 0)")
      fflush(stdout)
    }
    print("Synthetic live server ready")
    fflush(stdout)
    RunLoop.main.run()
  }
}
