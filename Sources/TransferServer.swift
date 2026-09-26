import CryptoKit
import Foundation
import Network
import Darwin

private struct PullRequest: Decodable {
  let hostID: UUID
  let physicalDeviceID: UUID
  let nonce: UUID
  let ack: String?
  let mac: String
  let version: String?
  let presence: String?
  let presenceMAC: String?
  let clientDiagnosticsBox: String?
}

private struct PreparedResponse {
  let data: Data
  let deviceID: UUID
}

struct PairingInvitation {
  let sessionID: UUID
  let hostID: UUID
  let physicalDeviceID: UUID
  let model: String
  let publicKey: Data
  let code: String
  let lanAddresses: [String]
  let lanPort: UInt16
  let tailnetAddress: String?
  let tailnetPort: UInt16?
}

private struct PairingRequest: Decodable {
  let type: String
  let sessionID: UUID
  let clientPublicKey: String
  let confirmationMAC: String?
}

private struct PairingSession {
  let invitation: PairingInvitation
  let selected: ConnectedDevice
  let privateKey: Curve25519.KeyAgreement.PrivateKey
  let expiresAt: Date
  var clientPublicKey: Data?
  var key: Data?
  var attempts = 0
  var confirmed = false
}

/// Local-only, authenticated pull server. The full filename and log are encrypted.
final class TransferServer: @unchecked Sendable {
  #if TRANSFER_TESTING
  static let servicePort: NWEndpoint.Port = .any
  #else
  static let servicePort: NWEndpoint.Port = 54555
  #endif
  static let tailnetPort: UInt16 = 54557
  private let queue = DispatchQueue(label: "net.ryuya-dev.MochiLog.mac-transfer")
  private var listener: NWListener?
  private var pathMonitor: NWPathMonitor?
  private var tailnetReadSource: DispatchSourceRead?
  private var tailnetAddress: String?
  private var activeTailnetClients = 0
  private var state: CompanionState
  private var nonces: [UUID: Date] = [:]
  private var announcementRevision = 0
  private var pairingSession: PairingSession?
  var onStatus: ((String) -> Void)?
  var onConfirmed: ((UUID) -> Void)?
  var onAuthenticatedRequest: ((UUID, Date) -> Void)?
  var onAppPresence: ((UUID, Bool, Date) -> Void)?
  var onTransferActivity: ((UUID, Bool) -> Void)?
  var onPairingCompleted: (() -> Void)?

  init(state: CompanionState) { self.state = state }

  func update(state: CompanionState) { queue.async { self.state = state } }

  func beginPairing(for selected: ConnectedDevice, existing: PairedDevice?) -> PairingInvitation {
    queue.sync {
      let privateKey = Curve25519.KeyAgreement.PrivateKey()
      let routes = Self.localIPv4Addresses(wifiInterfaces: [])
      let invitation = PairingInvitation(sessionID: UUID(), hostID: state.hostID,
        physicalDeviceID: existing?.physicalDeviceID ?? UUID(), model: selected.model,
        publicKey: privateKey.publicKey.rawRepresentation,
        code: String(format: "%06d", Int.random(in: 0...999_999)),
        lanAddresses: routes.lan, lanPort: Self.servicePort.rawValue,
        tailnetAddress: tailnetAddress,
        tailnetPort: tailnetAddress == nil ? nil : Self.tailnetPort)
      pairingSession = PairingSession(invitation: invitation, selected: selected,
        privateKey: privateKey, expiresAt: Date().addingTimeInterval(180))
      return invitation
    }
  }

  func announceQueuedFiles() {
    queue.async {
      self.announcementRevision &+= 1
      self.publishReachableAddresses()
    }
  }

  var activeTailnetAddress: String? { queue.sync { tailnetAddress } }

  func start() throws {
    let listener = try NWListener(using: .tcp, on: Self.servicePort)
    listener.service = NWListener.Service(name: state.hostID.uuidString,
      type: "_mochilog._tcp")
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.stateUpdateHandler = { [weak self] status in
      switch status {
      case .ready:
        self?.publishReachableAddresses()
        self?.onStatus?(MacTransferL10n.text("mt_m_15"))
      case .failed(let error): self?.onStatus?(MacTransferL10n.format("mt_m_16", error.localizedDescription))
      default: break
      }
    }
    self.listener = listener
    listener.start(queue: queue)
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] _ in
      self?.publishReachableAddresses()
    }
    pathMonitor = monitor
    monitor.start(queue: queue)
  }

  private func publishReachableAddresses() {
    guard let listener, let port = listener.port else { return }
    let wifiInterfaces = Set(pathMonitor?.currentPath.availableInterfaces
      .filter { $0.type == .wifi }.map(\.name) ?? [])
    let routes = Self.localIPv4Addresses(wifiInterfaces: wifiInterfaces)
    #if !TRANSFER_TESTING
    updateTailnetSocket(address: routes.tailnet.first)
    #endif
    guard !routes.lan.isEmpty || tailnetAddress != nil else { return }
    var fields = [
      "v": "1",
      "port": String(port.rawValue),
      "ipv4": routes.lan.joined(separator: ","),
      "revision": String(announcementRevision)
    ]
    if let tailnetAddress {
      fields["tailnet"] = tailnetAddress
      fields["tailnetPort"] = String(Self.tailnetPort)
    }
    let record = NWTXTRecord(fields)
    listener.service = NWListener.Service(name: state.hostID.uuidString,
      type: "_mochilog._tcp", txtRecord: record)
  }

  #if TRANSFER_TESTING
  func startTestTailnetReceiver() {
    queue.sync { updateTailnetSocket(address: "127.0.0.1") }
  }
  #endif

  static func tailnetIPv4Address() -> String? {
    localIPv4Addresses(wifiInterfaces: []).tailnet.first
  }

  private func updateTailnetSocket(address: String?) {
    guard address != tailnetAddress else { return }
    tailnetReadSource?.cancel()
    tailnetReadSource = nil
    tailnetAddress = nil
    guard let address else { return }
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    var option: Int32 = 1
    _ = withUnsafePointer(to: &option) {
      setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
    }
    var endpoint = sockaddr_in()
    endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    endpoint.sin_family = sa_family_t(AF_INET)
    endpoint.sin_port = Self.tailnetPort.bigEndian
    let parsed = address.withCString { inet_pton(AF_INET, $0, &endpoint.sin_addr) }
    let bound = withUnsafePointer(to: &endpoint) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard parsed == 1, bound == 0, Darwin.listen(fd, 8) == 0 else {
      Darwin.close(fd)
      onStatus?("Tailscale listener unavailable: \(String(cString: strerror(errno)))")
      return
    }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in
      while true {
        let client = Darwin.accept(fd, nil, nil)
        if client < 0 { break }
        guard let self else { Darwin.close(client); continue }
        guard self.activeTailnetClients < 4 else { Darwin.close(client); continue }
        self.activeTailnetClients += 1
        DispatchQueue.global(qos: .userInitiated).async {
          self.handleTailnetSocket(client)
        }
      }
    }
    source.setCancelHandler { Darwin.close(fd) }
    tailnetReadSource = source
    tailnetAddress = address
    source.resume()
  }

  private func handleTailnetSocket(_ client: Int32) {
    defer {
      Darwin.close(client)
      queue.async { self.activeTailnetClients -= 1 }
    }
    // Darwin's accept inherits O_NONBLOCK from the listening socket. This
    // worker must wait for request bytes, including later TCP fragments.
    let flags = fcntl(client, F_GETFL)
    guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return }
    var noPipe: Int32 = 1
    _ = withUnsafePointer(to: &noPipe) {
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0,
        socklen_t(MemoryLayout<Int32>.size))
    }
    var timeout = timeval(tv_sec: 20, tv_usec: 0)
    withUnsafePointer(to: &timeout) {
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0,
        socklen_t(MemoryLayout<timeval>.size))
      setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, $0,
        socklen_t(MemoryLayout<timeval>.size))
    }
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while request.count <= 16_384 {
      let count = Darwin.recv(client, &buffer, buffer.count, 0)
      guard count > 0 else { return }
      request.append(contentsOf: buffer.prefix(count))
      guard request.count <= 16_384 else { return }
      if let newline = request.firstIndex(of: 10) {
        let body = Data(request[..<newline])
        if let pairingReply = queue.sync(execute: { makePairingResponse(to: body) }) {
          var offset = 0
          while offset < pairingReply.count {
            let written = pairingReply.withUnsafeBytes { bytes in
              Darwin.send(client, bytes.baseAddress!.advanced(by: offset),
                pairingReply.count - offset, 0)
            }
            guard written > 0 else { return }
            offset += written
          }
          _ = Darwin.shutdown(client, SHUT_WR)
          _ = Darwin.recv(client, &buffer, 1, 0)
          return
        }
        let response = queue.sync { makeResponse(to: body) }
        guard let response else { return }
        onTransferActivity?(response.deviceID, true)
        defer { onTransferActivity?(response.deviceID, false) }
        var offset = 0
        while offset < response.data.count {
          let written = response.data.withUnsafeBytes { bytes in
            Darwin.send(client, bytes.baseAddress!.advanced(by: offset),
              response.data.count - offset, 0)
          }
          guard written > 0 else { return }
          offset += written
        }
        _ = Darwin.shutdown(client, SHUT_WR)
        // Keep the socket alive until the peer consumes the final frame. Some
        // packet-tunnel paths otherwise expose an early EOF to NWConnection.
        _ = Darwin.recv(client, &buffer, 1, 0)
        return
      }
    }
  }

  private static func localIPv4Addresses(wifiInterfaces: Set<String>)
    -> (lan: [String], tailnet: [String]) {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { return ([], []) }
    defer { freeifaddrs(first) }
    var lan: [(name: String, address: String)] = []
    var tailnet: [String] = []
    var current = first
    while let entry = current?.pointee {
      defer { current = entry.ifa_next }
      guard let address = entry.ifa_addr,
        address.pointee.sa_family == sa_family_t(AF_INET),
        (entry.ifa_flags & UInt32(IFF_UP)) != 0,
        (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
      let name = String(cString: entry.ifa_name)
      guard name.hasPrefix("en") || name.hasPrefix("utun") else { continue }
      var storage = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      var sockaddr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee
      }
      let ipv4 = withUnsafePointer(to: &sockaddr.sin_addr) {
        inet_ntop(AF_INET, $0, &storage, socklen_t(INET_ADDRSTRLEN))
      }
      guard ipv4 != nil else { continue }
      let value = String(cString: storage)
      let parts = value.split(separator: ".").compactMap { Int($0) }
      if name.hasPrefix("utun"), parts.count == 4,
        parts[0] == 100 && (64...127).contains(parts[1]) {
        tailnet.append(value)
      } else if name.hasPrefix("en") &&
        (value.hasPrefix("10.") || value.hasPrefix("192.168.") ||
        (parts.count == 4 && parts[0] == 172 && (16...31).contains(parts[1]))) {
        lan.append((name, value))
      }
    }
    let sortedLAN = lan.sorted {
      let firstWiFi = wifiInterfaces.contains($0.name)
      let secondWiFi = wifiInterfaces.contains($1.name)
      return firstWiFi == secondWiFi ? $0.name < $1.name : firstWiFi
    }.prefix(4).map(\.address)
    return (sortedLAN, Array(Set(tailnet)).sorted())
  }

  private func handle(_ connection: NWConnection) {
    connection.stateUpdateHandler = { [weak self] status in
      if case .ready = status { self?.receive(on: connection, accumulated: Data()) }
      if case .failed = status { connection.cancel() }
    }
    connection.start(queue: queue)
  }

  private func receive(on connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
      guard let self, error == nil, !complete else { connection.cancel(); return }
      var bytes = accumulated
      if let data { bytes.append(data) }
      guard bytes.count <= 16_384 else { connection.cancel(); return }
      if let end = bytes.firstIndex(of: 10) {
        self.respond(to: Data(bytes[..<end]), on: connection)
      } else {
        self.receive(on: connection, accumulated: bytes)
      }
    }
  }

  private func respond(to requestData: Data, on connection: NWConnection) {
    if let pairingReply = makePairingResponse(to: requestData) {
      connection.send(content: pairingReply, completion: .contentProcessed { _ in
        connection.cancel()
      })
      return
    }
    guard let response = makeResponse(to: requestData) else {
      connection.cancel()
      return
    }
    onTransferActivity?(response.deviceID, true)
    connection.send(content: response.data, completion: .contentProcessed { [weak self] _ in
      self?.onTransferActivity?(response.deviceID, false)
      connection.cancel()
    })
  }

  private func makePairingResponse(to requestData: Data) -> Data? {
    guard let request = try? JSONDecoder().decode(PairingRequest.self, from: requestData),
      ["pair-init", "pair-confirm"].contains(request.type),
      var session = pairingSession,
      session.invitation.sessionID == request.sessionID,
      Date() < session.expiresAt,
      let publicData = Data(base64Encoded: request.clientPublicKey),
      publicData.count == 32,
      let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicData)
    else { return nil }
    guard session.clientPublicKey == nil || session.clientPublicKey == publicData else { return nil }
    let invitation = session.invitation
    let key: Data
    if let existing = session.key {
      key = existing
    } else {
      guard let shared = try? session.privateKey.sharedSecretFromKeyAgreement(
        with: publicKey) else { return nil }
      let derived = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
        salt: Data(request.sessionID.uuidString.utf8),
        sharedInfo: Data("MochiLog pair v2|\(invitation.hostID.uuidString)|\(invitation.physicalDeviceID.uuidString)".utf8),
        outputByteCount: 32)
      key = derived.withUnsafeBytes { Data($0) }
      session.clientPublicKey = publicData
      session.key = key
    }
    let secret = SymmetricKey(data: key)
    if request.type == "pair-init" {
      let proof = HMAC<SHA256>.authenticationCode(
        for: Data("pair-challenge|\(request.sessionID.uuidString)".utf8),
        using: secret).map { String(format: "%02x", $0) }.joined()
      pairingSession = session
      return try? JSONSerialization.data(withJSONObject: [
        "type": "pair-challenge", "sessionID": request.sessionID.uuidString,
        "proof": proof
      ]) + Data([10])
    }
    guard session.attempts < 3,
      let supplied = request.confirmationMAC.flatMap(Data.init(hex:)) else { return nil }
    let confirmationMessage = Data("pair-confirm|\(request.sessionID.uuidString)|\(invitation.code)".utf8)
    guard HMAC<SHA256>.isValidAuthenticationCode(supplied,
      authenticating: confirmationMessage, using: secret)
    else {
      session.attempts += 1
      pairingSession = session
      return nil
    }
    if !session.confirmed {
      var updated = state
      let newDevice = PairedDevice(udid: session.selected.udid, name: session.selected.name,
        model: session.selected.model, physicalDeviceID: invitation.physicalDeviceID,
        secret: key)
      if let index = updated.devices.firstIndex(where: { $0.udid == session.selected.udid }) {
        updated.devices[index] = newDevice
      } else { updated.devices.append(newDevice) }
      guard (try? Collector.saveState(updated)) != nil else { return nil }
      state = updated
      session.confirmed = true
      pairingSession = session
      onPairingCompleted?()
    }
    let proof = HMAC<SHA256>.authenticationCode(
      for: Data("pair-complete|\(request.sessionID.uuidString)".utf8), using: secret)
      .map { String(format: "%02x", $0) }.joined()
    return try? JSONSerialization.data(withJSONObject: [
      "type": "pair-complete", "sessionID": request.sessionID.uuidString,
      "proof": proof
    ]) + Data([10])
  }

  private func makeResponse(to requestData: Data) -> PreparedResponse? {
    guard let request = try? JSONDecoder().decode(PullRequest.self, from: requestData),
      request.version == "2",
      request.hostID == state.hostID,
      let device = state.devices.first(where: { $0.physicalDeviceID == request.physicalDeviceID }),
      Date().timeIntervalSince(nonces[request.nonce] ?? .distantPast) > 300
    else { return nil }
    let message = "v2|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)|\(request.ack ?? "")"
    let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8),
      using: SymmetricKey(data: device.secret)))
    let backgroundMessage = "v2|background|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)"
    let expectedBackground = Data(HMAC<SHA256>.authenticationCode(
      for: Data(backgroundMessage.utf8), using: SymmetricKey(data: device.secret)))
    guard let received = Data(hex: request.mac) else { return nil }
    let backgroundNotice = request.presence == "background" && request.ack == ""
      && received == expectedBackground
    guard backgroundNotice || received == expected else { return nil }
    let now = Date()
    onAuthenticatedRequest?(device.physicalDeviceID, now)
    nonces[request.nonce] = now
    nonces = nonces.filter { now.timeIntervalSince($0.value) < 300 }
    if backgroundNotice {
      onAppPresence?(device.physicalDeviceID, false, now)
      return nil
    }
    let signedPresence: String? = {
      guard let presence = request.presence, ["foreground", "background"].contains(presence),
        let supplied = request.presenceMAC.flatMap(Data.init(hex:)) else { return nil }
      let expectedPresence = Data(HMAC<SHA256>.authenticationCode(
        for: Data("presence|\(request.nonce.uuidString)|\(presence)".utf8),
        using: SymmetricKey(data: device.secret)))
      return supplied == expectedPresence ? presence : nil
    }()
    onAppPresence?(device.physicalDeviceID, signedPresence != "background", now)
    if signedPresence == "background" { return nil }
    if let index = state.devices.firstIndex(where: {
      $0.physicalDeviceID == request.physicalDeviceID
    }), state.devices[index].confirmedAt == nil {
      state.devices[index].confirmedAt = Date()
      do {
        try Collector.saveState(state)
        onConfirmed?(request.physicalDeviceID)
      } catch {
        onStatus?(MacTransferL10n.format("mt_m_17", error.localizedDescription))
      }
    }
    if let encoded = request.clientDiagnosticsBox,
      let combined = Data(base64Encoded: encoded), combined.count <= 8_256,
      let box = try? AES.GCM.SealedBox(combined: combined),
      let report = try? AES.GCM.open(box, using: SymmetricKey(data: device.secret),
        authenticating: Data("v2|diagnostics|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)".utf8)),
      report.count <= 8_192 {
      try? SupportDiagnostics.savePhoneReport(report, for: device)
    }
    do {
      if let ack = request.ack,
        let acknowledged = try Collector.queueFile(for: ack, device: device) {
        if FileManager.default.fileExists(atPath: acknowledged.path) {
          try Collector.markDelivered(ack, for: device)
          try FileManager.default.removeItem(at: acknowledged)
        }
      }
      let next = try Collector.pending(for: device).first
      let name = try next.map { try Collector.queueToken(for: $0, device: device) } ?? ""
      let content = try next.map { try Data(contentsOf: $0, options: .mappedIfSafe) } ?? Data()
      guard content.count <= 64 * 1024 * 1024,
        let nameData = name.data(using: .utf8), nameData.count <= 1024
      else { throw CollectorError.failed(MacTransferL10n.text("mt_c_07")) }
      var plain = Data()
      plain.append(UInt8(nameData.count >> 8))
      plain.append(UInt8(nameData.count & 0xff))
      plain.append(nameData)
      plain.append(content)
      if name.isEmpty {
        plain.append(SupportDiagnostics.macReport(for: device))
      }
      let responseContext = Data("v2|response|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)".utf8)
      let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: device.secret),
        authenticating: responseContext)
      guard let combined = sealed.combined else { throw CollectorError.failed(MacTransferL10n.text("mt_c_08")) }
      var length = UInt32(combined.count).bigEndian
      let prefix = withUnsafeBytes(of: &length) { Data($0) }
      return PreparedResponse(data: prefix + combined, deviceID: device.physicalDeviceID)
    } catch {
      onStatus?(MacTransferL10n.format("mt_m_18", error.localizedDescription))
      return nil
    }
  }
}

private extension Data {
  init?(hex: String) {
    guard hex.count == 64 else { return nil }
    var result = Data()
    for index in stride(from: 0, to: hex.count, by: 2) {
      let start = hex.index(hex.startIndex, offsetBy: index)
      let end = hex.index(start, offsetBy: 2)
      guard let byte = UInt8(hex[start..<end], radix: 16) else { return nil }
      result.append(byte)
    }
    self = result
  }
}
