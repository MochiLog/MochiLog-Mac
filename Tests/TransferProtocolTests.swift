import CryptoKit
import Foundation
import Network

private enum TestFailure: Error {
  case failed(String)
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw TestFailure.failed(message) }
}

private func discover(_ name: String) throws -> NWEndpoint {
  let browser = NWBrowser(for: .bonjour(type: "_mochilog._tcp", domain: nil), using: .tcp)
  let queue = DispatchQueue(label: "mochilog.transfer.test.browser")
  let ready = DispatchSemaphore(value: 0)
  var endpoint: NWEndpoint?
  browser.browseResultsChangedHandler = { results, _ in
    for result in results {
      if case .service(let candidate, _, _, _) = result.endpoint, candidate == name {
        endpoint = result.endpoint
        ready.signal()
        break
      }
    }
  }
  browser.start(queue: queue)
  defer { browser.cancel() }
  guard ready.wait(timeout: .now() + 10) == .success, let endpoint else {
    throw TestFailure.failed("Bonjour service was not discovered")
  }
  return endpoint
}

private func request(_ endpoint: NWEndpoint, hostID: UUID, device: PairedDevice,
  nonce: UUID = UUID(), ack: String = "", validMAC: Bool = true,
  diagnostics: Data? = nil, expectNoResponse: Bool = false) throws -> Data {
  let message = "\(hostID.uuidString)|\(device.physicalDeviceID.uuidString)|\(nonce.uuidString)|\(ack)"
  let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8),
    using: SymmetricKey(data: device.secret))
    .map { String(format: "%02x", $0) }.joined()
  var payload: [String: String] = [
    "hostID": hostID.uuidString,
    "physicalDeviceID": device.physicalDeviceID.uuidString,
    "nonce": nonce.uuidString,
    "ack": ack,
    "mac": validMAC ? mac : String(repeating: "0", count: 64)
  ]
  if let diagnostics {
    payload["clientDiagnostics"] = diagnostics.base64EncodedString()
    payload["clientDiagnosticsMAC"] = HMAC<SHA256>.authenticationCode(
      for: Data("diagnostics|\(nonce.uuidString)|".utf8) + diagnostics,
      using: SymmetricKey(data: device.secret))
      .map { String(format: "%02x", $0) }.joined()
  }
  let data = try JSONSerialization.data(withJSONObject: payload) + Data([10])
  let connection = NWConnection(to: endpoint, using: .tcp)
  let queue = DispatchQueue(label: "mochilog.transfer.test.connection")
  let finished = DispatchSemaphore(value: 0)
  var received = Data()
  var connectionError: Error?
  func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      chunk, _, complete, error in
      if let chunk { received.append(chunk) }
      if let error { connectionError = error }
      if complete || error != nil {
        finished.signal()
      } else {
        receive()
      }
    }
  }
  connection.stateUpdateHandler = { state in
    switch state {
    case .ready:
      connection.send(content: data, completion: .contentProcessed { error in
        if let error {
          connectionError = error
          finished.signal()
        } else { receive() }
      })
    case .failed(let error):
      connectionError = error
      finished.signal()
    default: break
    }
  }
  connection.start(queue: queue)
  defer { connection.cancel() }
  guard finished.wait(timeout: .now() + (expectNoResponse ? 3 : 10)) == .success else {
    if expectNoResponse { return Data() }
    throw TestFailure.failed("Transfer request timed out")
  }
  if let connectionError, validMAC { throw connectionError }
  return received
}

private func opened(_ response: Data, secret: Data) throws -> (String, Data) {
  try check(response.count >= 4, "Missing response length")
  let length = response.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  try check(Int(length) == response.count - 4, "Incorrect response length")
  let box = try AES.GCM.SealedBox(combined: response.dropFirst(4))
  let plain = try AES.GCM.open(box, using: SymmetricKey(data: secret))
  try check(plain.count >= 2, "Missing filename length")
  let nameLength = Int(plain[0]) * 256 + Int(plain[1])
  try check(plain.count >= nameLength + 2, "Incomplete filename")
  let name = String(decoding: plain[2..<(nameLength + 2)], as: UTF8.self)
  return (name, Data(plain.dropFirst(nameLength + 2)))
}

@main
struct TransferProtocolTests {
  static func main() throws {
    setbuf(stdout, nil)
    guard ProcessInfo.processInfo.environment["MOCHILOG_TRANSFER_TEST_ROOT"] != nil else {
      throw TestFailure.failed("Set an isolated MOCHILOG_TRANSFER_TEST_ROOT")
    }
    let filename = "Analytics-2026-09-26-120000.ips.ca.synced"
    let source = "ProxiedDevice-abcdef1234"
    let hostToken = "Host::\(filename)"
    let watchToken = "Watch::\(source)::\(filename)"
    let hostContent = Data("synthetic iPhone payload".utf8)
    let watchContent = Data("synthetic Watch payload".utf8)
    let device = PairedDevice(udid: "test-iphone", name: "Test iPhone",
      model: "iPhone18,3", physicalDeviceID: UUID(),
      secret: Data((0..<32).map { UInt8($0) }))
    let hostID = UUID()
    let state = CompanionState(hostID: hostID, devices: [device])
    try hostContent.write(to: Collector.directory(for: device, kind: .host)
      .appendingPathComponent(filename))
    try watchContent.write(to: Collector.directory(for: device, kind: .watch,
      source: source).appendingPathComponent(filename))
    let server = TransferServer(state: state)
    try server.start()
    let endpoint = try discover(hostID.uuidString)

    print("Checking invalid MAC")
    let rejected = try request(endpoint, hostID: hostID, device: device,
      validMAC: false, expectNoResponse: true)
    try check(rejected.isEmpty, "Invalid MAC was accepted")
    let afterInvalidMAC = try Collector.pending(for: device)
    try check(afterInvalidMAC.count == 2, "Invalid MAC changed the queue")

    let firstNonce = UUID()
    let phoneReport = Data(#"{"schema":1,"platform":"iOS","recentEvents":["synthetic"]}"#.utf8)
    print("Checking first authenticated transfer")
    let first = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: firstNonce, diagnostics: phoneReport), secret: device.secret)
    try check(first.0 == hostToken && first.1 == hostContent,
      "Host payload or token was incorrect")
    try check(Collector.loadState().devices.first?.confirmedAt != nil,
      "First valid request did not confirm pairing")
    try check(SupportDiagnostics.phoneReport(for: device) != nil,
      "Authenticated phone diagnostics were not stored")

    print("Checking replay rejection")
    let replay = try request(endpoint, hostID: hostID, device: device,
      nonce: firstNonce, expectNoResponse: true)
    try check(replay.isEmpty, "Replayed nonce was accepted")
    print("Checking host ACK and Watch transfer")
    let second = try opened(request(endpoint, hostID: hostID, device: device,
      ack: hostToken), secret: device.secret)
    try check(second.0 == watchToken && second.1 == watchContent,
      "Watch payload collided with same-named host file")
    let afterHostACK = try Collector.pending(for: device)
    try check(afterHostACK.count == 1,
      "Acknowledged host payload was not removed")
    print("Checking Watch ACK and terminal reply")
    let terminal = try opened(request(endpoint, hostID: hostID, device: device,
      ack: watchToken), secret: device.secret)
    try check(terminal.0.isEmpty, "Final reply was not terminal")
    let report = try JSONSerialization.jsonObject(with: terminal.1) as? [String: Any]
    try check(report?["platform"] as? String == "macOS", "Mac diagnostics missing")
    let afterWatchACK = try Collector.pending(for: device)
    try check(afterWatchACK.isEmpty, "Acknowledged Watch payload remained")
    try check(Collector.delivered(for: device) == Set([hostToken, watchToken]),
      "Delivered token ledger is incorrect")
    let repeatPull = try opened(request(endpoint, hostID: hostID, device: device),
      secret: device.secret)
    try check(repeatPull.0.isEmpty, "Delivered payload appeared again")
    print("PASS: authenticated transfer, replay rejection, host/Watch separation, acknowledgements, diagnostics, and repeat pull")
  }
}
