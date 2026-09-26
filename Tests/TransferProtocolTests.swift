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
  diagnostics: Data? = nil, presence: String? = nil, version2: Bool = true,
  expectNoResponse: Bool = false, delayedChunks: Bool = false,
  overridePayload: [String: String]? = nil) throws -> Data {
  let message = presence == "background"
    ? "v2|background|\(hostID.uuidString)|\(device.physicalDeviceID.uuidString)|\(nonce.uuidString)"
    : "\(version2 ? "v2|" : "")\(hostID.uuidString)|\(device.physicalDeviceID.uuidString)|\(nonce.uuidString)|\(ack)"
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
  if version2 { payload["version"] = "2" }
  if let presence {
    payload["presence"] = presence
    payload["presenceMAC"] = HMAC<SHA256>.authenticationCode(
      for: Data("presence|\(nonce.uuidString)|\(presence)".utf8),
      using: SymmetricKey(data: device.secret))
      .map { String(format: "%02x", $0) }.joined()
  }
  if let diagnostics {
    if version2 {
      let context = Data("v2|diagnostics|\(hostID.uuidString)|\(device.physicalDeviceID.uuidString)|\(nonce.uuidString)".utf8)
      payload["clientDiagnosticsBox"] = try AES.GCM.seal(diagnostics,
        using: SymmetricKey(data: device.secret), authenticating: context)
        .combined!.base64EncodedString()
    } else {
      payload["clientDiagnostics"] = diagnostics.base64EncodedString()
      payload["clientDiagnosticsMAC"] = HMAC<SHA256>.authenticationCode(
        for: Data("diagnostics|\(nonce.uuidString)|".utf8) + diagnostics,
        using: SymmetricKey(data: device.secret))
        .map { String(format: "%02x", $0) }.joined()
    }
  }
  let data = try JSONSerialization.data(withJSONObject: overridePayload ?? payload)
    + Data([10])
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
      if delayedChunks {
        queue.asyncAfter(deadline: .now() + 0.25) {
          connection.send(content: Data(data.prefix(100)), completion: .contentProcessed { error in
            if let error { connectionError = error; finished.signal(); return }
            queue.asyncAfter(deadline: .now() + 0.25) {
              connection.send(content: Data(data.dropFirst(100)), completion: .contentProcessed { error in
                if let error { connectionError = error; finished.signal() }
                else { receive() }
              })
            }
          })
        }
      } else {
        connection.send(content: data, completion: .contentProcessed { error in
          if let error { connectionError = error; finished.signal() }
          else { receive() }
        })
      }
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

private func opened(_ response: Data, secret: Data,
  context: (UUID, UUID, UUID)? = nil) throws -> (String, Data) {
  try check(response.count >= 4, "Missing response length")
  let length = response.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  try check(Int(length) == response.count - 4, "Incorrect response length")
  let box = try AES.GCM.SealedBox(combined: response.dropFirst(4))
  let plain: Data
  if let (hostID, deviceID, nonce) = context {
    plain = try AES.GCM.open(box, using: SymmetricKey(data: secret),
      authenticating: Data("v2|response|\(hostID.uuidString)|\(deviceID.uuidString)|\(nonce.uuidString)".utf8))
  } else {
    plain = try AES.GCM.open(box, using: SymmetricKey(data: secret))
  }
  try check(plain.count >= 2, "Missing filename length")
  let nameLength = Int(plain[0]) * 256 + Int(plain[1])
  try check(plain.count >= nameLength + 2, "Incomplete filename")
  let name = String(decoding: plain[2..<(nameLength + 2)], as: UTF8.self)
  return (name, Data(plain.dropFirst(nameLength + 2)))
}

@main
struct TransferProtocolTests {
  static func main() throws {
    print("Checking device discovery fallback after native timeout")
    let fallback = try Collector.browse { args, _ in
      if args.first == "remote" { throw CollectorError.timeout }
      if args.first == "usbmux" { return #"["offline", "ipad"]"# }
      if args.last == "offline" { throw CollectorError.timeout }
      return #"{"ProductType":"iPad16,6","DeviceName":"Test iPad"}"#
    }
    try check(fallback.count == 1 && fallback[0].udid == "ipad",
      "A native timeout or offline peer must not hide a reachable Wi-Fi device")
    let merged = try Collector.browse { args, _ in
      if args.first == "remote" { return #"[{"udid":"ipad","model":"iPad16,6"}]"# }
      if args.first == "usbmux" { return #"["ipad"]"# }
      throw TestFailure.failed("Already discovered device was probed again")
    }
    try check(merged.count == 1, "Discovery paths must not duplicate a device")
    do {
      _ = try Collector.browse { _, _ in throw CollectorError.timeout }
      throw TestFailure.failed("Complete discovery failure was hidden")
    } catch CollectorError.discoveryTimeout { }

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
    print("Checking plaintext-key migration to Keychain")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
      as! [String: Any]
    var legacyDevices = legacy["devices"] as! [[String: Any]]
    legacyDevices[0]["secret"] = device.secret.base64EncodedString()
    legacy["devices"] = legacyDevices
    try JSONSerialization.data(withJSONObject: legacy).write(to: Collector.stateURL)
    let migrated = Collector.loadState()
    try check(migrated.devices.first?.secret == device.secret,
      "Legacy pairing key was not recovered")
    let savedState = try String(contentsOf: Collector.stateURL, encoding: .utf8)
    try check(!savedState.contains("\"secret\""),
      "Plaintext pairing key remained in the metadata file")
    try hostContent.write(to: Collector.directory(for: device, kind: .host)
      .appendingPathComponent(filename))
    try watchContent.write(to: Collector.directory(for: device, kind: .watch,
      source: source).appendingPathComponent(filename))
    let server = TransferServer(state: state)
    var authenticatedRequests = 0
    var presenceEvents: [Bool] = []
    var transferEvents: [Bool] = []
    server.onAuthenticatedRequest = { _, _ in authenticatedRequests += 1 }
    server.onAppPresence = { _, isForeground, _ in presenceEvents.append(isForeground) }
    server.onTransferActivity = { _, active in transferEvents.append(active) }
    try server.start()
    let endpoint = try discover(hostID.uuidString)

    print("Checking immediate-send announcement")
    let announcement = DispatchSemaphore(value: 0)
    let browserReady = DispatchSemaphore(value: 0)
    let announcementBrowser = NWBrowser(
      for: .bonjourWithTXTRecord(type: "_mochilog._tcp", domain: nil), using: .tcp)
    announcementBrowser.stateUpdateHandler = { state in
      if case .ready = state { browserReady.signal() }
    }
    announcementBrowser.browseResultsChangedHandler = { results, _ in
      if results.contains(where: { result in
        guard case .service(let name, _, _, _) = result.endpoint,
          name == hostID.uuidString,
          case .bonjour(let record) = result.metadata else { return false }
        return record["revision"] == "1"
      }) { announcement.signal() }
    }
    announcementBrowser.start(queue: DispatchQueue(label: "mochilog.transfer.test.announcement"))
    try check(browserReady.wait(timeout: .now() + 5) == .success,
      "Announcement browser did not start")
    server.announceQueuedFiles()
    try check(announcement.wait(timeout: .now() + 10) == .success,
      "Send-now did not notify the Bonjour browser")
    announcementBrowser.cancel()

    print("Checking legacy protocol rejection and invalid MAC")
    let legacyReply = try request(endpoint, hostID: hostID, device: device,
      version2: false, expectNoResponse: true)
    try check(legacyReply.isEmpty, "Legacy request bypassed nonce-bound response protection")
    let rejected = try request(endpoint, hostID: hostID, device: device,
      validMAC: false, expectNoResponse: true)
    try check(rejected.isEmpty, "Invalid MAC was accepted")
    try check(authenticatedRequests == 0, "Invalid MAC appeared as a connected app")
    try check(presenceEvents.isEmpty, "Invalid MAC changed app presence")
    let afterInvalidMAC = try Collector.pending(for: device)
    try check(afterInvalidMAC.count == 2, "Invalid MAC changed the queue")

    let firstNonce = UUID()
    let phoneReport = Data(#"{"schema":1,"platform":"iOS","recentEvents":["synthetic"]}"#.utf8)
    print("Checking first authenticated transfer")
    let first = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: firstNonce, diagnostics: phoneReport), secret: device.secret,
      context: (hostID, device.physicalDeviceID, firstNonce))
    try check(first.0 == hostToken && first.1 == hostContent,
      "Host payload or token was incorrect")
    try check(authenticatedRequests == 1, "Authenticated app contact was not recorded")
    try check(presenceEvents == [true], "Client request did not register as foreground")
    try check(transferEvents == [true, false], "Transfer activity did not close cleanly")
    try check(Collector.loadState().devices.first?.confirmedAt != nil,
      "First valid request did not confirm pairing")
    try check(SupportDiagnostics.phoneReport(for: device) != nil,
      "Authenticated phone diagnostics were not stored")

    print("Checking replay rejection")
    let replay = try request(endpoint, hostID: hostID, device: device,
      nonce: firstNonce, expectNoResponse: true)
    try check(replay.isEmpty, "Replayed nonce was accepted")
    try check(authenticatedRequests == 1, "Replay appeared as a new app contact")
    print("Checking authenticated background notice")
    let backgroundNonce = UUID()
    let backgroundReply = try request(endpoint, hostID: hostID, device: device,
      nonce: backgroundNonce, presence: "background", expectNoResponse: true)
    try check(backgroundReply.isEmpty, "Background notice started a log transfer")
    try check(presenceEvents.last == false, "Background notice was not recorded")
    try check(transferEvents == [true, false], "Background notice appeared as a file transfer")
    let afterNoticeCount = presenceEvents.count
    _ = try request(endpoint, hostID: hostID, device: device,
      nonce: backgroundNonce, presence: "background", expectNoResponse: true)
    try check(presenceEvents.count == afterNoticeCount, "Replayed background notice changed presence")
    let afterBackground = try Collector.pending(for: device)
    try check(afterBackground.count == 2,
      "Background notice changed the delivery queue")
    print("Checking host ACK and Watch transfer")
    let secondNonce = UUID()
    let second = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: secondNonce, ack: hostToken), secret: device.secret,
      context: (hostID, device.physicalDeviceID, secondNonce))
    try check(second.0 == watchToken && second.1 == watchContent,
      "Watch payload collided with same-named host file")
    let afterHostACK = try Collector.pending(for: device)
    try check(afterHostACK.count == 1,
      "Acknowledged host payload was not removed")
    print("Checking Watch ACK and terminal reply")
    let terminalNonce = UUID()
    let terminal = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: terminalNonce, ack: watchToken), secret: device.secret,
      context: (hostID, device.physicalDeviceID, terminalNonce))
    try check(terminal.0.isEmpty, "Final reply was not terminal")
    let report = try JSONSerialization.jsonObject(with: terminal.1) as? [String: Any]
    try check(report?["platform"] as? String == "macOS", "Mac diagnostics missing")
    let afterWatchACK = try Collector.pending(for: device)
    try check(afterWatchACK.isEmpty, "Acknowledged Watch payload remained")
    try check(Collector.delivered(for: device) == Set([hostToken, watchToken]),
      "Delivered token ledger is incorrect")
    let repeatNonce = UUID()
    let repeatPull = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: repeatNonce), secret: device.secret,
      context: (hostID, device.physicalDeviceID, repeatNonce))
    try check(repeatPull.0.isEmpty, "Delivered payload appeared again")
    print("Checking v2 encrypted diagnostics and nonce-bound response")
    let v2Name = "Analytics-2026-09-26-130000.ips.ca.synced"
    let v2Content = Data("v2 battery payload".utf8)
    try v2Content.write(to: Collector.directory(for: device, kind: .host)
      .appendingPathComponent(v2Name))
    if let oldReport = SupportDiagnostics.phoneReport(for: device) {
      try FileManager.default.removeItem(at: oldReport)
    }
    let v2Nonce = UUID()
    let v2Response = try request(endpoint, hostID: hostID, device: device,
      nonce: v2Nonce, diagnostics: phoneReport, version2: true)
    let v2Opened = try opened(v2Response, secret: device.secret,
      context: (hostID, device.physicalDeviceID, v2Nonce))
    try check(v2Opened.0 == "Host::\(v2Name)" && v2Opened.1 == v2Content,
      "V2 encrypted response did not contain the expected log")
    try check(SupportDiagnostics.phoneReport(for: device) != nil,
      "V2 encrypted diagnostics were not accepted")
    do {
      _ = try opened(v2Response, secret: device.secret,
        context: (hostID, device.physicalDeviceID, UUID()))
      throw TestFailure.failed("A captured response was accepted for a new request")
    } catch CryptoKitError.authenticationFailure { }
    let v2Replay = try request(endpoint, hostID: hostID, device: device,
      nonce: v2Nonce, version2: true, expectNoResponse: true)
    try check(v2Replay.isEmpty, "A repeated v2 request was accepted")
    let v2FinalNonce = UUID()
    let v2Final = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: v2FinalNonce, ack: "Host::\(v2Name)", version2: true),
      secret: device.secret,
      context: (hostID, device.physicalDeviceID, v2FinalNonce))
    try check(v2Final.0.isEmpty, "V2 acknowledgement did not finish the transfer")
    print("Checking delayed fragmented requests on the VPN receiver")
    server.startTestTailnetReceiver()
    let vpnEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
      port: NWEndpoint.Port(rawValue: TransferServer.tailnetPort)!)
    let vpnNonce = UUID()
    let vpnReply = try opened(request(vpnEndpoint, hostID: hostID, device: device,
      nonce: vpnNonce, delayedChunks: true), secret: device.secret,
      context: (hostID, device.physicalDeviceID, vpnNonce))
    try check(vpnReply.0.isEmpty, "Delayed VPN request did not receive terminal response")
    print("Checking public-key QR pairing and six-digit keyed confirmation")
    let selected = ConnectedDevice(udid: "secure-iphone", name: "Secure iPhone",
      model: "iPhone18,3")
    let invitation = server.beginPairing(for: selected, existing: nil)
    try check(invitation.publicKey.count == 32 && invitation.code.count == 6,
      "Secure pairing invitation is incomplete")
    let clientPrivate = Curve25519.KeyAgreement.PrivateKey()
    let clientPublic = clientPrivate.publicKey.rawRepresentation
    let macPublic = try Curve25519.KeyAgreement.PublicKey(
      rawRepresentation: invitation.publicKey)
    let shared = try clientPrivate.sharedSecretFromKeyAgreement(with: macPublic)
    let derived = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
      salt: Data(invitation.sessionID.uuidString.utf8),
      sharedInfo: Data("MochiLog pair v2|\(hostID.uuidString)|\(invitation.physicalDeviceID.uuidString)".utf8),
      outputByteCount: 32)
    let pairingKey = derived.withUnsafeBytes { Data($0) }
    let initPayload = ["type": "pair-init", "sessionID": invitation.sessionID.uuidString,
      "clientPublicKey": clientPublic.base64EncodedString()]
    let challenge = try request(endpoint, hostID: hostID, device: device,
      overridePayload: initPayload)
    let challengeObject = try JSONSerialization.jsonObject(with: challenge) as! [String: String]
    try check(challengeObject["type"] == "pair-challenge",
      "Mac did not answer public-key initiation")
    let expectedChallenge = HMAC<SHA256>.authenticationCode(
      for: Data("pair-challenge|\(invitation.sessionID.uuidString)".utf8),
      using: SymmetricKey(data: pairingKey))
      .map { String(format: "%02x", $0) }.joined()
    try check(challengeObject["proof"] == expectedChallenge,
      "Mac did not prove possession of its QR private key")
    let wrongCode = invitation.code == "000000" ? "000001" : "000000"
    let badMAC = HMAC<SHA256>.authenticationCode(
      for: Data("pair-confirm|\(invitation.sessionID.uuidString)|\(wrongCode)".utf8),
      using: SymmetricKey(data: pairingKey))
      .map { String(format: "%02x", $0) }.joined()
    let badConfirmation = try request(endpoint, hostID: hostID, device: device,
      expectNoResponse: true, overridePayload: ["type": "pair-confirm",
        "sessionID": invitation.sessionID.uuidString,
        "clientPublicKey": clientPublic.base64EncodedString(),
        "confirmationMAC": badMAC])
    try check(badConfirmation.isEmpty &&
      !Collector.loadState().devices.contains(where: { $0.udid == selected.udid }),
      "Wrong pairing code registered a device")
    let correctMAC = HMAC<SHA256>.authenticationCode(
      for: Data("pair-confirm|\(invitation.sessionID.uuidString)|\(invitation.code)".utf8),
      using: SymmetricKey(data: pairingKey))
      .map { String(format: "%02x", $0) }.joined()
    let completion = try request(endpoint, hostID: hostID, device: device,
      overridePayload: ["type": "pair-confirm",
        "sessionID": invitation.sessionID.uuidString,
        "clientPublicKey": clientPublic.base64EncodedString(),
        "confirmationMAC": correctMAC])
    let completionObject = try JSONSerialization.jsonObject(with: completion) as! [String: String]
    let expectedCompletion = HMAC<SHA256>.authenticationCode(
      for: Data("pair-complete|\(invitation.sessionID.uuidString)".utf8),
      using: SymmetricKey(data: pairingKey))
      .map { String(format: "%02x", $0) }.joined()
    try check(completionObject["proof"] == expectedCompletion,
      "Pairing completion proof was invalid")
    let newlyPaired = try checkPairedDevice(selected.udid, key: pairingKey)
    let pairedNonce = UUID()
    let pairedReply = try opened(request(endpoint, hostID: hostID,
      device: newlyPaired, nonce: pairedNonce, version2: true),
      secret: pairingKey,
      context: (hostID, invitation.physicalDeviceID, pairedNonce))
    try check(pairedReply.0.isEmpty, "Newly paired client could not pull securely")
    print("PASS: authenticated transfer, replay rejection, host/Watch separation, acknowledgements, diagnostics, and repeat pull")
  }
}

private func checkPairedDevice(_ udid: String, key: Data) throws -> PairedDevice {
  let state = Collector.loadState()
  guard let device = state.devices.first(where: { $0.udid == udid }) else {
    throw TestFailure.failed("Confirmed device was not stored")
  }
  try check(device.secret == key, "Keychain did not retain the derived pairing key")
  let metadata = try String(contentsOf: Collector.stateURL, encoding: .utf8)
  try check(!metadata.contains("\"secret\""), "Derived key leaked into JSON metadata")
  return device
}
