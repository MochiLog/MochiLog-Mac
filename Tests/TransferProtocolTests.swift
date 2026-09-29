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
    print("Checking empty wireless diagnostic listings fall back to the native route")
    let rootListing = try Collector.remoteRootListing(udid: "ipad") { args, _ in
      if args.first == "usbmux" { return #"["ipad"]"# }
      if args.contains("--mobdev2") { return "" }
      if args.contains("--native") { return "/Retired\n/DiagnosticLogs\n" }
      throw TestFailure.failed("Unexpected diagnostic command")
    }
    try check(rootListing.1.contains("--native") && rootListing.0.contains("/Retired"),
      "An empty Wi-Fi lockdown result hid a working native diagnostic route")
    do {
      _ = try Collector.remoteRootListing(udid: "ipad") { args, _ in
        args.first == "usbmux" ? #"["ipad"]"# : ""
      }
      throw TestFailure.failed("Empty diagnostic results were reported as a successful collection")
    } catch CollectorError.failed { }

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
    let uncertain = FileManager.default.temporaryDirectory
      .appendingPathComponent("mochilog-unclassified-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: uncertain) }
    try Data(repeating: 0x20, count: 1_000_000).write(to: uncertain)
    let shouldRecheckLarge = try Collector.shouldRecheckUnclassified(uncertain)
    try check(shouldRecheckLarge,
      "A large unclassified Analytics download must remain eligible for retry")
    try Data("short unrelated diagnostic".utf8).write(to: uncertain)
    let shouldRecheckSmall = try Collector.shouldRecheckUnclassified(uncertain)
    try check(!shouldRecheckSmall,
      "A small unrelated diagnostic should be excluded")
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
    let unfinished = try Collector.directory(for: device)
      .appendingPathComponent(".staging-test", isDirectory: true)
    try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
    try Data("unfinished diagnostic".utf8).write(to: unfinished
      .appendingPathComponent("Analytics-2026-09-01-000000.ips.ca.synced"))
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
    BatteryLogStorage.retainsAfterDelivery = true
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
    print("Checking archived log manual resend over encrypted transport")
    let archivedHost = BatteryLogStorage.list(devices: [device]).filter {
      !$0.pending && $0.kind == "Host" && $0.name == filename
    }
    let requeuedHost = try BatteryLogStorage.requeue(archivedHost, devices: [device])
    try check(archivedHost.count == 1 && requeuedHost == 1,
      "Acknowledged host log was not available for manual resend")
    let resendNonce = UUID()
    let resent = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: resendNonce), secret: device.secret,
      context: (hostID, device.physicalDeviceID, resendNonce))
    try check(resent.0 == hostToken && resent.1 == hostContent,
      "Manual resend did not deliver the selected raw log")
    let resendACKNonce = UUID()
    let resendEnd = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: resendACKNonce, ack: resent.0), secret: device.secret,
      context: (hostID, device.physicalDeviceID, resendACKNonce))
    let afterResendACK = try Collector.pending(for: device)
    try check(resendEnd.0.isEmpty && afterResendACK.isEmpty,
      "Repeated acknowledgement left the resend pending")
    try BatteryLogStorage.delete(BatteryLogStorage.list(devices: [device]).filter { !$0.pending })
    BatteryLogStorage.retainsAfterDelivery = false
    print("Checking authenticated automatic-collection pause")
    let pauseUntil = String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970))
    let pauseNonce = UUID()
    let pauseMessage = "daily-pause|v1|\(hostID.uuidString)|\(device.physicalDeviceID.uuidString)|\(pauseNonce.uuidString)|\(pauseUntil)"
    let pauseMAC = HMAC<SHA256>.authenticationCode(for: Data(pauseMessage.utf8),
      using: SymmetricKey(data: device.secret))
      .map { String(format: "%02x", $0) }.joined()
    let baseMAC = HMAC<SHA256>.authenticationCode(for: Data(
      "v2|\(hostID.uuidString)|\(device.physicalDeviceID.uuidString)|\(pauseNonce.uuidString)|".utf8),
      using: SymmetricKey(data: device.secret))
      .map { String(format: "%02x", $0) }.joined()
    var pausePayload = ["version": "2", "hostID": hostID.uuidString,
      "physicalDeviceID": device.physicalDeviceID.uuidString,
      "nonce": pauseNonce.uuidString, "ack": "", "mac": baseMAC,
      "dailyPauseUntil": pauseUntil, "dailyPauseMAC": String(repeating: "0", count: 64)]
    let invalidPause = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: pauseNonce, overridePayload: pausePayload), secret: device.secret,
      context: (hostID, device.physicalDeviceID, pauseNonce))
    try check(invalidPause.0.isEmpty &&
      Collector.loadState().devices.first?.automaticPauseUntil == nil,
      "Invalid daily pause proof changed the saved state")
    pausePayload["dailyPauseMAC"] = pauseMAC
    let acceptedNonce = UUID()
    pausePayload["nonce"] = acceptedNonce.uuidString
    pausePayload["mac"] = HMAC<SHA256>.authenticationCode(for: Data(
      "v2|\(hostID.uuidString)|\(device.physicalDeviceID.uuidString)|\(acceptedNonce.uuidString)|".utf8),
      using: SymmetricKey(data: device.secret))
      .map { String(format: "%02x", $0) }.joined()
    pausePayload["dailyPauseMAC"] = HMAC<SHA256>.authenticationCode(for: Data(
      "daily-pause|v1|\(hostID.uuidString)|\(device.physicalDeviceID.uuidString)|\(acceptedNonce.uuidString)|\(pauseUntil)".utf8),
      using: SymmetricKey(data: device.secret))
      .map { String(format: "%02x", $0) }.joined()
    let acceptedPause = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: acceptedNonce, overridePayload: pausePayload), secret: device.secret,
      context: (hostID, device.physicalDeviceID, acceptedNonce))
    let pauseAck = try JSONSerialization.jsonObject(with: acceptedPause.1) as? [String: String]
    try check(acceptedPause.0.isEmpty && pauseAck?["type"] == "daily-pause-ack" &&
      pauseAck?["until"] == pauseUntil &&
      Collector.loadState().devices.first?.automaticPauseUntil != nil,
      "Authenticated pause was not acknowledged and persisted")
    let pauseReplay = try request(endpoint, hostID: hostID, device: device,
      nonce: acceptedNonce, expectNoResponse: true)
    try check(pauseReplay.isEmpty,
      "A pause nonce was accepted twice")
    let resumeNonce = UUID()
    let resumePayload = ["version": "2", "hostID": hostID.uuidString,
      "physicalDeviceID": device.physicalDeviceID.uuidString,
      "nonce": resumeNonce.uuidString, "ack": "",
      "mac": HMAC<SHA256>.authenticationCode(for: Data(
        "v2|\(hostID.uuidString)|\(device.physicalDeviceID.uuidString)|\(resumeNonce.uuidString)|".utf8),
        using: SymmetricKey(data: device.secret))
        .map { String(format: "%02x", $0) }.joined(),
      "dailyResumeMAC": HMAC<SHA256>.authenticationCode(for: Data(
        "daily-resume|v1|\(hostID.uuidString)|\(device.physicalDeviceID.uuidString)|\(resumeNonce.uuidString)".utf8),
        using: SymmetricKey(data: device.secret))
        .map { String(format: "%02x", $0) }.joined()]
    let resumeReply = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: resumeNonce, overridePayload: resumePayload), secret: device.secret,
      context: (hostID, device.physicalDeviceID, resumeNonce))
    let resumeAck = try JSONSerialization.jsonObject(with: resumeReply.1) as? [String: String]
    try check(resumeAck?["type"] == "daily-resume-ack" &&
      Collector.loadState().devices.first?.automaticPauseUntil == nil,
      "Authenticated resume did not clear the saved pause")
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
    print("Checking authenticated daily debug archive exchange")
    SupportDiagnostics.record("archive exchange fixture")
    let archiveDay = SupportDiagnostics.dayString(Date())
    let compactDay = archiveDay.replacingOccurrences(of: "-", with: "")
    let phoneLine = Data("phone archive line\n".utf8)
    let archiveReport = try JSONSerialization.data(withJSONObject: [
      "schema": 1, "platform": "iOS", "archiveRefresh": true,
      "archiveManifest": [compactDay: phoneLine.count],
      "archiveChunk": ["day": compactDay, "offset": 0,
        "data": phoneLine.base64EncodedString()],
      "archiveRequest": ["day": compactDay, "offset": 0]
    ] as [String: Any])
    let archiveNonce = UUID()
    let archiveReply = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: archiveNonce, diagnostics: archiveReport), secret: device.secret,
      context: (hostID, device.physicalDeviceID, archiveNonce))
    try check(archiveReply.0.isEmpty, "Archive exchange did not return a terminal report")
    try check(SupportDiagnostics.phoneLogText(for: device, day: archiveDay) ==
      String(data: phoneLine, encoding: .utf8), "Phone archive chunk was not saved")
    let archiveObject = try JSONSerialization.jsonObject(with: archiveReply.1)
      as? [String: Any]
    let computerChunk = archiveObject?["archiveChunk"] as? [String: Any]
    try check(computerChunk?["day"] as? String == compactDay &&
      Data(base64Encoded: computerChunk?["data"] as? String ?? "") != nil,
      "Computer archive chunk was not returned")
    let duplicateNonce = UUID()
    _ = try request(endpoint, hostID: hostID, device: device,
      nonce: duplicateNonce, diagnostics: archiveReport)
    try check(SupportDiagnostics.phoneLogText(for: device, day: archiveDay) ==
      String(data: phoneLine, encoding: .utf8), "Retried archive chunk was duplicated")
    for offset in 1...4 {
      guard let date = Calendar.current.date(byAdding: .day, value: -offset,
        to: Date()) else { continue }
      let day = SupportDiagnostics.dayString(date)
      let compact = day.replacingOccurrences(of: "-", with: "")
      let historical = try JSONSerialization.data(withJSONObject: [
        "schema": 1,
        "archiveChunk": ["day": compact, "offset": 0,
          "data": phoneLine.base64EncodedString()]
      ] as [String: Any])
      try SupportDiagnostics.savePhoneReport(historical, for: device)
    }
    try check(SupportDiagnostics.phoneArchiveDays(for: device).count >= 5,
      "Five incident dates were not retained for support")
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
    print("Checking v3 pairing preserves the mobile device's existing physical ID")
    let mobilePhysicalID = UUID()
    let secondPhone = ConnectedDevice(udid: "v3-iphone", name: "Existing iPhone",
      model: "iPhone18,3")
    let v3Invitation = server.beginPairing(for: secondPhone, existing: nil)
    let v3Private = Curve25519.KeyAgreement.PrivateKey()
    let v3Public = v3Private.publicKey.rawRepresentation
    let v3MacPublic = try Curve25519.KeyAgreement.PublicKey(
      rawRepresentation: v3Invitation.publicKey)
    let v3Shared = try v3Private.sharedSecretFromKeyAgreement(with: v3MacPublic)
    let v3Key = v3Shared.hkdfDerivedSymmetricKey(using: SHA256.self,
      salt: Data(v3Invitation.sessionID.uuidString.utf8),
      sharedInfo: Data("MochiLog pair v3|\(hostID.uuidString)|\(mobilePhysicalID.uuidString)".utf8),
      outputByteCount: 32).withUnsafeBytes { Data($0) }
    let v3Base = ["sessionID": v3Invitation.sessionID.uuidString,
      "version": "3", "physicalDeviceID": mobilePhysicalID.uuidString,
      "clientPublicKey": v3Public.base64EncodedString()]
    let v3Init = try request(endpoint, hostID: hostID, device: device,
      overridePayload: v3Base.merging(["type": "pair-init"]) { _, new in new })
    let v3Challenge = try JSONSerialization.jsonObject(with: v3Init) as! [String: String]
    let v3Proof = HMAC<SHA256>.authenticationCode(
      for: Data("pair-challenge|\(v3Invitation.sessionID.uuidString)".utf8),
      using: SymmetricKey(data: v3Key)).map { String(format: "%02x", $0) }.joined()
    try check(v3Challenge["proof"] == v3Proof, "V3 challenge failed")
    let v3CodeMAC = HMAC<SHA256>.authenticationCode(
      for: Data("pair-confirm|\(v3Invitation.sessionID.uuidString)|\(v3Invitation.code)".utf8),
      using: SymmetricKey(data: v3Key)).map { String(format: "%02x", $0) }.joined()
    let v3Complete = try request(endpoint, hostID: hostID, device: device,
      overridePayload: v3Base.merging(["type": "pair-confirm",
        "confirmationMAC": v3CodeMAC]) { _, new in new })
    try check(!v3Complete.isEmpty, "V3 pairing was not confirmed")
    let v3Paired = try checkPairedDevice(secondPhone.udid, key: v3Key)
    try check(v3Paired.physicalDeviceID == mobilePhysicalID,
      "V3 pairing replaced the mobile device's physical ID")
    try server.revoke(device.physicalDeviceID)
    let afterRevocation = Collector.loadState()
    try check(afterRevocation.devices.contains(where: { $0.physicalDeviceID == mobilePhysicalID }) &&
      afterRevocation.revokedDevices.contains(where: {
        $0.physicalDeviceID == device.physicalDeviceID
      }), "Removing one pairing affected another device")
    let revokedNonce = UUID()
    let removal = try opened(request(endpoint, hostID: hostID, device: device,
      nonce: revokedNonce), secret: device.secret,
      context: (hostID, device.physicalDeviceID, revokedNonce))
    let removalControl = try JSONSerialization.jsonObject(with: removal.1) as! [String: String]
    try check(removal.0.isEmpty && removalControl["type"] == "unpair",
      "Revoked phone did not receive an encrypted removal command")
    let replayedRemoval = try request(endpoint, hostID: hostID, device: device,
      nonce: revokedNonce, expectNoResponse: true)
    try check(replayedRemoval.isEmpty, "Revocation command accepted a replayed pull nonce")
    let unpairNonce = UUID()
    let identity = "\(hostID.uuidString)|\(device.physicalDeviceID.uuidString)|\(unpairNonce.uuidString)"
    let proof = HMAC<SHA256>.authenticationCode(
      for: Data("unpair|v1|\(identity)".utf8),
      using: SymmetricKey(data: device.secret))
      .map { String(format: "%02x", $0) }.joined()
    let acknowledgment = try request(endpoint, hostID: hostID, device: device,
      overridePayload: ["type": "unpair", "version": "1",
        "hostID": hostID.uuidString,
        "physicalDeviceID": device.physicalDeviceID.uuidString,
        "nonce": unpairNonce.uuidString, "proof": proof])
    let acknowledgmentObject = try JSONSerialization.jsonObject(with: acknowledgment)
      as! [String: String]
    let expectedAck = HMAC<SHA256>.authenticationCode(
      for: Data("unpair-ack|v1|\(identity)".utf8),
      using: SymmetricKey(data: device.secret))
      .map { String(format: "%02x", $0) }.joined()
    try check(acknowledgmentObject["proof"] == expectedAck,
      "Idempotent revocation acknowledgement was not authenticated")
    let badRevocation = try request(endpoint, hostID: hostID, device: v3Paired,
      expectNoResponse: true, overridePayload: ["type": "unpair", "version": "1",
        "hostID": hostID.uuidString,
        "physicalDeviceID": mobilePhysicalID.uuidString,
        "nonce": UUID().uuidString, "proof": String(repeating: "0", count: 64)])
    try check(badRevocation.isEmpty && Collector.loadState().devices.contains(where: {
      $0.physicalDeviceID == mobilePhysicalID
    }), "Invalid removal proof affected another pairing")
    let mobileNonce = UUID()
    let mobileIdentity = "\(hostID.uuidString)|\(mobilePhysicalID.uuidString)|\(mobileNonce.uuidString)"
    let mobileProof = HMAC<SHA256>.authenticationCode(
      for: Data("unpair|v1|\(mobileIdentity)".utf8),
      using: SymmetricKey(data: v3Key))
      .map { String(format: "%02x", $0) }.joined()
    let mobileRemoval = try request(endpoint, hostID: hostID, device: v3Paired,
      overridePayload: ["type": "unpair", "version": "1",
        "hostID": hostID.uuidString,
        "physicalDeviceID": mobilePhysicalID.uuidString,
        "nonce": mobileNonce.uuidString, "proof": mobileProof])
    let mobileAnswer = try JSONSerialization.jsonObject(with: mobileRemoval) as! [String: String]
    try check(mobileAnswer["type"] == "unpair-ack",
      "Phone-initiated removal was not acknowledged")
    try check(!Collector.loadState().devices.contains(where: {
      $0.physicalDeviceID == mobilePhysicalID
    }) && Collector.loadState().revokedDevices.contains(where: {
      $0.physicalDeviceID == mobilePhysicalID
    }),
      "Phone-initiated removal did not persist on the Mac")
    print("Checking battery log retention, export, and manual resend")
    let storageDevice = PairedDevice(udid: "storage-test", name: "Storage Test",
      model: "iPhone18,3", physicalDeviceID: UUID(),
      secret: Data(repeating: 1, count: 32))
    let storageFile = try Collector.directory(for: storageDevice, kind: .host)
      .appendingPathComponent("Analytics-2026-09-29-090000.ips.ca.synced")
    try Data("raw diagnostic bytes".utf8).write(to: storageFile)
    BatteryLogStorage.retainsAfterDelivery = false
    try BatteryLogStorage.archiveAcknowledged(storageFile, device: storageDevice)
    try check(!FileManager.default.fileExists(atPath: storageFile.path) &&
      BatteryLogStorage.list(devices: [storageDevice]).isEmpty,
      "Immediate-delete mode retained an acknowledged log")
    try Data("raw diagnostic bytes".utf8).write(to: storageFile)
    BatteryLogStorage.retainsAfterDelivery = true
    try BatteryLogStorage.archiveAcknowledged(storageFile, device: storageDevice)
    var stored = BatteryLogStorage.list(devices: [storageDevice])
    try check(stored.count == 1 && !stored[0].pending,
      "Keep mode did not archive the acknowledged log")
    let exportFolder = Collector.root.appendingPathComponent("test-export")
    try BatteryLogStorage.export(stored, to: exportFolder)
    try check(FileManager.default.fileExists(atPath: exportFolder
      .appendingPathComponent(storageDevice.physicalDeviceID.uuidString)
      .appendingPathComponent("Host").appendingPathComponent(storageFile.lastPathComponent).path),
      "Battery log export did not preserve the raw file")
    let requeued = try BatteryLogStorage.requeue(stored, devices: [storageDevice])
    try check(requeued == 1 && FileManager.default.fileExists(atPath: storageFile.path),
      "Manual resend did not restore the pending queue file")
    stored = BatteryLogStorage.list(devices: [storageDevice])
    try check(stored.count == 2, "Pending and archived copies were not both listed")
    try BatteryLogStorage.archiveAcknowledged(storageFile, device: storageDevice)
    try BatteryLogStorage.delete(stored.filter { !$0.pending })
    try check(BatteryLogStorage.list(devices: [storageDevice]).isEmpty,
      "Deleting the archived log left a stored copy")
    BatteryLogStorage.retainsAfterDelivery = false
    if let udid = ProcessInfo.processInfo.environment["MOCHILOG_DIRECT_DEVICE_ID"],
      let address = ProcessInfo.processInfo.environment["MOCHILOG_DIRECT_DEVICE_IP"] {
      let probe = PairedDevice(udid: udid, name: "Direct RSD probe", model: "iPad",
        physicalDeviceID: UUID(), secret: Data(repeating: 0, count: 32),
        manualAddress: address)
      let report = try Collector.collect(probe)
      try check(report.failed == 0 && report.saved + report.skipped > 0,
        "Direct RSD collection did not finish: \(report.lastError ?? "no files")")
      print("PASS: direct RSD real device collection saved \(report.saved), skipped \(report.skipped)")
    }
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
