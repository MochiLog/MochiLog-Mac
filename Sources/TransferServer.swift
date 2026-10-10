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
  let dailyPauseUntil: String?
  let dailyPauseMAC: String?
  let dailyResumeMAC: String?
  let liveBatterySourceID: UUID?
  let liveBatterySharedVersion: String?
  let liveBatteryVersion: String?
  let liveBatteryRevision: String?
  let liveBatteryDetailsVersion: String?
  let liveBatteryDetailsRevision: String?
  let liveBatteryRefresh: String?
  let localDiagnosticsPairing: String?
  let cloudSharingVersion: String?
  let logSourceIdentityVersion: String?
  let cloudSharingScope: String?
  let cloudSharingOnly: String?
  let offerVersion: String?
  let offerMAC: String?
  let offerToken: String?
  let offerDigest: String?
  let offerDecision: String?
  let offerDecisionMAC: String?
}

private struct SealedPullRequest: Decodable {
  let version: String
  let hostID: UUID
  let physicalDeviceID: UUID
  let nonce: UUID
  let issuedAt: Int64
  let box: String
}

private struct ReplayState: Codable {
  var used: [UUID: Date] = [:]
  var upgraded: Set<UUID> = []
}

private struct PreparedResponse {
  let data: Data
  let deviceID: UUID
  var requestID: UUID? = nil
  var file: String = "control"
}

struct PairingInvitation {
  let sessionID: UUID
  let hostID: UUID
  let physicalDeviceID: UUID
  let existingPhysicalDeviceID: UUID?
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
  let version: String?
  let physicalDeviceID: UUID?
}

private struct RevocationRequest: Decodable {
  let type: String
  let version: String
  let hostID: UUID
  let physicalDeviceID: UUID
  let nonce: UUID
  let proof: String
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
  var negotiatedPhysicalDeviceID: UUID?
  var negotiatedVersion: String?
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
  private var liveBatteryPeerAddresses: [UUID: String] = [:]
  func liveBatteryPeerAddress(for id: UUID) -> String? { queue.sync { liveBatteryPeerAddresses[id] } }
  private var state: CompanionState
  private var replayState: ReplayState?
  private var activeLANConnections: [ObjectIdentifier: NWConnection] = [:]
  private var announcementRevision = 0
  private var pairingSession: PairingSession?
  private let cloudSharing = CloudLogSharing()
  let liveBattery = LiveBatteryCache()
  var onLiveBatteryRequested: ((UUID, Bool) -> Void)?
  var onStatus: ((String) -> Void)?
  var onConfirmed: ((UUID) -> Void)?
  var onAuthenticatedRequest: ((UUID, Date) -> Void)?
  var onAppPresence: ((UUID, Bool, Date) -> Void)?
  var onTransferActivity: ((UUID, Bool) -> Void)?
  var onPairingCompleted: (() -> Void)?
  var onPairingRevoked: (() -> Void)?
  var onLegacyClient: ((UUID) -> Void)?
  var onSecureClient: ((UUID) -> Void)?

  init(state: CompanionState) {
    self.state = state
    let url = Collector.root.appendingPathComponent("transfer-replay.json")
    if !FileManager.default.fileExists(atPath: url.path) {
      replayState = ReplayState()
    } else if let data = try? Data(contentsOf: url) {
      replayState = try? JSONDecoder().decode(ReplayState.self, from: data)
    }
  }

  private func saveReplayState(_ value: ReplayState) -> Bool {
    let url = Collector.root.appendingPathComponent("transfer-replay.json")
    do {
      try JSONEncoder().encode(value).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600],
        ofItemAtPath: url.path)
      replayState = value
      return true
    } catch {
      onStatus?("Replay protection could not be saved: \(error.localizedDescription)")
      return false
    }
  }

  func update(state: CompanionState) { queue.async { self.state = state } }

  func revoke(_ physicalDeviceID: UUID) throws {
    try queue.sync {
      guard let index = state.devices.firstIndex(where: {
        $0.physicalDeviceID == physicalDeviceID
      }) else { return }
      var updated = state
      let device = updated.devices.remove(at: index)
      updated.revokedDevices.removeAll { $0.physicalDeviceID == physicalDeviceID }
      updated.revokedDevices.append(device)
      try Collector.saveState(updated)
      state = updated
      onPairingRevoked?()
    }
  }

  func beginPairing(for selected: ConnectedDevice, existing: PairedDevice?) -> PairingInvitation {
    queue.sync {
      let privateKey = Curve25519.KeyAgreement.PrivateKey()
      let routes = Self.localIPv4Addresses(wifiInterfaces: [])
      let invitation = PairingInvitation(sessionID: UUID(), hostID: state.hostID,
        physicalDeviceID: existing?.physicalDeviceID ?? UUID(),
        existingPhysicalDeviceID: existing?.physicalDeviceID, model: selected.model,
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
  var testListeningPort: UInt16? { queue.sync { listener?.port?.rawValue } }
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
    while request.count <= 32_768 {
      let count = Darwin.recv(client, &buffer, buffer.count, 0)
      guard count > 0 else { return }
      request.append(contentsOf: buffer.prefix(count))
      guard request.count <= 32_768 else { return }
      if let newline = request.firstIndex(of: 10) {
        let body = Data(request[..<newline])
        if let pairingReply = queue.sync(execute: {
          makeRevocationResponse(to: body) ?? makePairingResponse(to: body)
        }) {
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
        var peer = sockaddr_in()
        var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let hasPeer = withUnsafeMutablePointer(to: &peer) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(client, $0, &peerLength) == 0 }
        }
        let peerAddress = hasPeer ? String(cString: inet_ntoa(peer.sin_addr)) : nil
        let preparedAt = ProcessInfo.processInfo.systemUptime
        let response = queue.sync { makeResponse(to: body, peerAddress: peerAddress) }
        guard let response else { return }
        onTransferActivity?(response.deviceID, true)
        defer { onTransferActivity?(response.deviceID, false) }
        let sendingAt = ProcessInfo.processInfo.systemUptime
        var offset = 0
        defer {
          SupportDiagnostics.record("Transfer trace: tailnet write request=\(response.requestID?.uuidString ?? "control"), recipient=\(response.deviceID.uuidString), sent=\(offset)/\(response.data.count), prepareQueueMs=\(Int((sendingAt - preparedAt) * 1000)), writeMs=\(Int((ProcessInfo.processInfo.systemUptime - sendingAt) * 1000)); TCP write only; application processing not confirmed")
        }
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
    guard activeLANConnections.count < 16 else { connection.cancel(); return }
    let identifier = ObjectIdentifier(connection)
    activeLANConnections[identifier] = connection
    connection.stateUpdateHandler = { [weak self] status in
      if case .ready = status { self?.receive(on: connection, accumulated: Data()) }
      if case .failed = status { connection.cancel() }
      if case .cancelled = status { self?.activeLANConnections.removeValue(forKey: identifier) }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 25) { [weak self, weak connection] in
      guard let self, self.activeLANConnections[identifier] != nil else { return }
      connection?.cancel()
      self.activeLANConnections.removeValue(forKey: identifier)
    }
  }

  private func receive(on connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
      guard let self, error == nil, !complete else { connection.cancel(); return }
      var bytes = accumulated
      if let data { bytes.append(data) }
      guard bytes.count <= 32_768 else { connection.cancel(); return }
      if let end = bytes.firstIndex(of: 10) {
        self.respond(to: Data(bytes[..<end]), on: connection)
      } else {
        self.receive(on: connection, accumulated: bytes)
      }
    }
  }

  private func respond(to requestData: Data, on connection: NWConnection) {
    if let pairingReply = makeRevocationResponse(to: requestData)
      ?? makePairingResponse(to: requestData) {
      connection.send(content: pairingReply, completion: .contentProcessed { _ in
        connection.cancel()
      })
      return
    }
    let peerAddress: String? = {
      guard case .hostPort(let host, _) = connection.endpoint else { return nil }
      return String(describing: host)
    }()
    let preparedAt = ProcessInfo.processInfo.systemUptime
    guard let response = makeResponse(to: requestData, peerAddress: peerAddress) else {
      connection.cancel()
      return
    }
    onTransferActivity?(response.deviceID, true)
    let sendingAt = ProcessInfo.processInfo.systemUptime
    connection.send(content: response.data, completion: .contentProcessed { [weak self] error in
      if response.requestID != nil {
        SupportDiagnostics.record("Transfer trace: LAN write request=\(response.requestID!.uuidString), recipient=\(response.deviceID.uuidString), bytes=\(response.data.count), prepareMs=\(Int((sendingAt - preparedAt) * 1000)), writeMs=\(Int((ProcessInfo.processInfo.systemUptime - sendingAt) * 1000)), result=\(error == nil ? "written" : "failed"); TCP write only; application processing not confirmed")
      }
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
    let version = request.version ?? "2"
    guard ["2", "3"].contains(version) else { return nil }
    let physicalDeviceID: UUID
    if version == "3" {
      guard let supplied = request.physicalDeviceID,
        invitation.existingPhysicalDeviceID == nil || invitation.existingPhysicalDeviceID == supplied,
        session.negotiatedPhysicalDeviceID == nil || session.negotiatedPhysicalDeviceID == supplied
      else { return nil }
      physicalDeviceID = supplied
    } else { physicalDeviceID = invitation.physicalDeviceID }
    guard session.negotiatedVersion == nil || session.negotiatedVersion == version,
      session.negotiatedPhysicalDeviceID == nil ||
        session.negotiatedPhysicalDeviceID == physicalDeviceID else { return nil }
    let key: Data
    if let existing = session.key {
      key = existing
    } else {
      guard let shared = try? session.privateKey.sharedSecretFromKeyAgreement(
        with: publicKey) else { return nil }
      let derived = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
        salt: Data(request.sessionID.uuidString.utf8),
        sharedInfo: Data("MochiLog pair v\(version)|\(invitation.hostID.uuidString)|\(physicalDeviceID.uuidString)".utf8),
        outputByteCount: 32)
      key = derived.withUnsafeBytes { Data($0) }
      session.clientPublicKey = publicData
      session.key = key
      session.negotiatedPhysicalDeviceID = physicalDeviceID
      session.negotiatedVersion = version
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
        model: session.selected.model, physicalDeviceID: physicalDeviceID,
        secret: key, manualAddress: state.devices.first(where: {
          $0.udid == session.selected.udid })?.manualAddress)
      if let index = updated.devices.firstIndex(where: { $0.udid == session.selected.udid }) {
        updated.devices[index] = newDevice
      } else { updated.devices.append(newDevice) }
      updated.revokedDevices.removeAll { $0.physicalDeviceID == physicalDeviceID }
      guard (try? Collector.saveState(updated)) != nil else { return nil }
      state = updated
      if var replay = replayState {
        replay.upgraded.remove(physicalDeviceID)
        guard saveReplayState(replay) else { return nil }
      }
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

  private func makeRevocationResponse(to requestData: Data) -> Data? {
    guard let request = try? JSONDecoder().decode(RevocationRequest.self, from: requestData),
      request.type == "unpair", request.version == "1", request.hostID == state.hostID,
      let device = (state.devices + state.revokedDevices).first(where: {
        $0.physicalDeviceID == request.physicalDeviceID
      }),
      let supplied = Data(hex: request.proof) else { return nil }
    let identity = "\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)"
    let expected = Data(HMAC<SHA256>.authenticationCode(
      for: Data("unpair|v1|\(identity)".utf8),
      using: SymmetricKey(data: device.secret)))
    guard supplied == expected else { return nil }
    if let index = state.devices.firstIndex(where: {
      $0.physicalDeviceID == request.physicalDeviceID
    }) {
      var updated = state
      updated.revokedDevices.append(updated.devices.remove(at: index))
      guard (try? Collector.saveState(updated)) != nil else { return nil }
      state = updated
      onPairingRevoked?()
    }
    let proof = HMAC<SHA256>.authenticationCode(
      for: Data("unpair-ack|v1|\(identity)".utf8),
      using: SymmetricKey(data: device.secret))
      .map { String(format: "%02x", $0) }.joined()
    return (try? JSONSerialization.data(withJSONObject: [
      "type": "unpair-ack", "nonce": request.nonce.uuidString, "proof": proof
    ])) .map { $0 + Data([10]) }
  }

  private func decodePullRequest(_ data: Data) -> (PullRequest, Bool)? {
    if let envelope = try? JSONDecoder().decode(SealedPullRequest.self, from: data),
      envelope.version == "3" {
      let now = Date().timeIntervalSince1970
      guard abs(now - Double(envelope.issuedAt)) <= 300,
        let device = (state.devices + state.revokedDevices).first(where: {
          $0.physicalDeviceID == envelope.physicalDeviceID
        }),
        let combined = Data(base64Encoded: envelope.box), combined.count <= 24_576,
        let sealed = try? AES.GCM.SealedBox(combined: combined) else { return nil }
      let context = Data("v3|request|\(envelope.hostID.uuidString)|\(envelope.physicalDeviceID.uuidString)|\(envelope.nonce.uuidString)|\(envelope.issuedAt)".utf8)
      guard let plain = try? AES.GCM.open(sealed,
        using: SymmetricKey(data: device.secret), authenticating: context),
        let request = try? JSONDecoder().decode(PullRequest.self, from: plain),
        request.hostID == envelope.hostID,
        request.physicalDeviceID == envelope.physicalDeviceID,
        request.nonce == envelope.nonce else { return nil }
      return (request, true)
    }
    guard let request = try? JSONDecoder().decode(PullRequest.self, from: data)
    else { return nil }
    return (request, false)
  }

  private func makeResponse(to requestData: Data, peerAddress: String? = nil) -> PreparedResponse? {
    guard let (request, secure) = decodePullRequest(requestData),
      request.version == "2",
      request.hostID == state.hostID,
      let device = (state.devices + state.revokedDevices).first(where: {
        $0.physicalDeviceID == request.physicalDeviceID
      }),
      var replay = replayState,
      !replay.upgraded.contains(device.physicalDeviceID) || secure,
      replay.used[request.nonce] == nil
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
    let started = ProcessInfo.processInfo.systemUptime
    defer {
      if request.liveBatteryVersion == nil {
        SupportDiagnostics.record("Transfer trace: prepared request=\(request.nonce.uuidString), recipient=\(device.physicalDeviceID.uuidString), elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)), cloudPolicy=\(request.cloudSharingOnly != nil)")
      }
    }
    if secure { onSecureClient?(device.physicalDeviceID) }
    else { onLegacyClient?(device.physicalDeviceID) }
    let now = Date()
    replay.used[request.nonce] = now
    replay.used = replay.used.filter { now.timeIntervalSince($0.value) < 600 }
    if secure { replay.upgraded.insert(device.physicalDeviceID) }
    guard saveReplayState(replay) else { return nil }
    if state.revokedDevices.contains(where: {
      $0.physicalDeviceID == device.physicalDeviceID
    }) {
      guard !backgroundNotice else { return nil }
      let control = try? JSONSerialization.data(withJSONObject: ["type": "unpair"])
      guard let control else { return nil }
      let plain = Data([0, 0]) + control
      let context = Data("v2|response|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)".utf8)
      guard let sealed = try? AES.GCM.seal(plain,
        using: SymmetricKey(data: device.secret), authenticating: context).combined
      else { return nil }
      var length = UInt32(sealed.count).bigEndian
      return PreparedResponse(data: withUnsafeBytes(of: &length) { Data($0) } + sealed,
        deviceID: device.physicalDeviceID)
    }
    // Learn only the authenticated socket peer; never trust a client-supplied address.
    if secure, let peerAddress, let address = IPv4Address(peerAddress) {
      let bytes = Array(address.rawValue)
      if bytes[0] == 100 && (64...127).contains(bytes[1]) {
        liveBatteryPeerAddresses[device.physicalDeviceID] = peerAddress
      }
    }
    onAuthenticatedRequest?(device.physicalDeviceID, now)
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
    if request.localDiagnosticsPairing == nil && (request.liveBatteryVersion == nil || request.liveBatterySharedVersion == "1") {
      cloudSharing.update(device.physicalDeviceID,
        scope: secure && request.cloudSharingVersion == "1" ? request.cloudSharingScope : nil, now: now)
    }
    if request.localDiagnosticsPairing != nil {
      guard secure, request.localDiagnosticsPairing == "1", request.ack == "", request.offerToken == nil,
        let control = LocalDiagnosticsPairing.control(for: device) else { return nil }
      return try? encryptedLogResponse(control, name: "", request: request, device: device)
    }
    if request.cloudSharingOnly != nil {
      guard secure, request.cloudSharingOnly == "1", request.cloudSharingVersion == "1",
        request.ack == "", request.offerToken == nil else { return nil }
      let pending = cloudSharing.next(recipient: device.physicalDeviceID, devices: state.devices, now: now) != nil
      var policy = ["type": "cloud-sharing-policy", "cloudSharingVersion": "1",
        "pending": pending ? "true" : "false"]
      if request.logSourceIdentityVersion == "1", let scope = cloudSharing.scope(device.physicalDeviceID, now: now) {
        let models = Dictionary(uniqueKeysWithValues: state.devices.filter {
          cloudSharing.scope($0.physicalDeviceID, now: now) == scope
        }.prefix(64).map { ($0.physicalDeviceID.uuidString, $0.model) })
        if let data = try? JSONSerialization.data(withJSONObject: models), let json = String(data: data, encoding: .utf8) {
          policy["sourceModels"] = json
          SupportDiagnostics.record("Import identity policy: recipient=\(device.physicalDeviceID.uuidString), authenticatedModels=\(models.count)")
        }
      }
      let control = try? JSONSerialization.data(withJSONObject: policy)
      guard let control else { return nil }
      return try? encryptedLogResponse(control, name: "", request: request, device: device)
    }
    if request.liveBatteryVersion != nil {
      // Optional fields require whole-request v3 authentication. No log ACK,
      // daily-pause changes, diagnostics persistence, or file queue access here.
      guard secure, request.liveBatteryVersion == "1", request.ack == "" else { return nil }
      let scope = cloudSharing.scope(device.physicalDeviceID, now: now)
      let allowed = state.devices.filter { source in
        source.physicalDeviceID == device.physicalDeviceID ||
          (request.liveBatterySharedVersion == "1" && scope != nil &&
            cloudSharing.scope(source.physicalDeviceID, now: now) == scope)
      }
      let sourceID = request.liveBatterySourceID ?? device.physicalDeviceID
      guard allowed.contains(where: { $0.physicalDeviceID == sourceID }),
        let bytes = liveBattery.response(for: sourceID,
          revision: request.liveBatteryRevision, includesDetails: request.liveBatteryDetailsVersion == "1",
          detailsRevision: request.liveBatteryDetailsRevision),
        var object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return nil }
      if request.liveBatterySharedVersion == "1" {
        object["sharedVersion"] = 1
        object["sourcePhysicalDeviceID"] = sourceID.uuidString
        object["scope"] = scope ?? ""
        object["sources"] = allowed.prefix(64).map {
          ["physicalDeviceID": $0.physicalDeviceID.uuidString, "model": $0.model]
        }
      }
      guard let control = try? JSONSerialization.data(withJSONObject: object) else { return nil }
      onLiveBatteryRequested?(sourceID, request.liveBatteryRefresh == "1")
      return try? encryptedLogResponse(control, name: "", request: request, device: device)
    }

    if let encoded = request.clientDiagnosticsBox,
      let combined = Data(base64Encoded: encoded), combined.count <= 8_256,
      let box = try? AES.GCM.SealedBox(combined: combined),
      let report = try? AES.GCM.open(box, using: SymmetricKey(data: device.secret),
        authenticating: Data("v2|diagnostics|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)".utf8)),
      report.count <= 8_192 {
      try? SupportDiagnostics.savePhoneReport(report, for: device)
    }
    if let supplied = request.dailyResumeMAC.flatMap(Data.init(hex:)),
      supplied == Data(HMAC<SHA256>.authenticationCode(
        for: Data("daily-resume|v1|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)".utf8),
        using: SymmetricKey(data: device.secret))),
      let index = state.devices.firstIndex(where: {
        $0.physicalDeviceID == request.physicalDeviceID
      }) {
      do {
        state.devices[index].automaticPauseUntil = nil
        try Collector.saveState(state)
        SupportDiagnostics.record("\(device.name): automatic collection resumed; trigger=authenticated mobile request at \(SupportDiagnostics.localTime(now))")
        onPairingCompleted?()
        let control = try JSONSerialization.data(withJSONObject: ["type": "daily-resume-ack", "cloudSharingVersion": "1"])
        let context = Data("v2|response|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)".utf8)
        let sealed = try AES.GCM.seal(Data([0, 0]) + control,
          using: SymmetricKey(data: device.secret), authenticating: context)
        guard let combined = sealed.combined else { return nil }
        var length = UInt32(combined.count).bigEndian
        return PreparedResponse(data: withUnsafeBytes(of: &length) { Data($0) } + combined,
          deviceID: device.physicalDeviceID)
      } catch {
        onStatus?("Automatic collection resume could not be saved: \(error.localizedDescription)")
        return nil
      }
    }
    if let untilText = request.dailyPauseUntil,
      let untilSeconds = TimeInterval(untilText),
      untilSeconds > now.timeIntervalSince1970,
      untilSeconds <= now.addingTimeInterval(26 * 60 * 60).timeIntervalSince1970,
      let supplied = request.dailyPauseMAC.flatMap(Data.init(hex:)),
      supplied == Data(HMAC<SHA256>.authenticationCode(
        for: Data("daily-pause|v1|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)|\(untilText)".utf8),
        using: SymmetricKey(data: device.secret))),
      let index = state.devices.firstIndex(where: {
        $0.physicalDeviceID == request.physicalDeviceID
      }) {
      do {
        state.devices[index].automaticPauseUntil = Date(timeIntervalSince1970: untilSeconds)
        try Collector.saveState(state)
        SupportDiagnostics.record("\(device.name): automatic collection stopped; trigger=confirmed daily receipt; resume=\(SupportDiagnostics.localTime(Date(timeIntervalSince1970: untilSeconds)))")
        onPairingCompleted?()
        let control = try JSONSerialization.data(withJSONObject: [
          "type": "daily-pause-ack", "until": untilText, "cloudSharingVersion": "1"
        ])
        let context = Data("v2|response|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)".utf8)
        let sealed = try AES.GCM.seal(Data([0, 0]) + control,
          using: SymmetricKey(data: device.secret), authenticating: context)
        guard let combined = sealed.combined else { return nil }
        var length = UInt32(combined.count).bigEndian
        return PreparedResponse(data: withUnsafeBytes(of: &length) { Data($0) } + combined,
          deviceID: device.physicalDeviceID)
      } catch {
        onStatus?("Automatic collection pause could not be saved: \(error.localizedDescription)")
        return nil
      }
    }
    do {
      if let ack = request.ack, ack.hasPrefix("Shared::") {
        if let file = cloudSharing.resolve(ack, recipient: device.physicalDeviceID, devices: state.devices, now: now) {
          try cloudSharing.acknowledge(ack, file: file, recipient: device.physicalDeviceID)
          SupportDiagnostics.record("Cloud sharing: ACK request=\(request.nonce.uuidString), recipient=\(device.physicalDeviceID.uuidString), file=\(CloudSharedLogToken.debugLabel(ack)); source queue protected")
        }
      } else if let ack = request.ack,
        let acknowledged = try Collector.queueFile(for: ack, device: device) {
        if FileManager.default.fileExists(atPath: acknowledged.path) {
          try Collector.markDelivered(ack, for: device)
          try BatteryLogStorage.archiveAcknowledged(acknowledged, device: device)
        }
      }
      let offerEnabled = request.offerVersion == "1" &&
        request.offerMAC.flatMap(Data.init(hex:)) == Data(HMAC<SHA256>.authenticationCode(
          for: Data("file-offer|v1|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)".utf8),
          using: SymmetricKey(data: device.secret)))
      if request.offerVersion == "1" && !offerEnabled {
        SupportDiagnostics.record("\(device.name): preflight rejected; capability authentication failed")
      }
      if offerEnabled, request.offerToken != nil,
        (request.offerDigest == nil || request.offerDecision == nil ||
          request.offerDecisionMAC == nil) {
        SupportDiagnostics.record("\(device.name): preflight decision rejected; incomplete fields")
      }
      if offerEnabled, let token = request.offerToken, let digest = request.offerDigest,
        let decision = request.offerDecision, ["have", "send"].contains(decision),
        let supplied = request.offerDecisionMAC.flatMap(Data.init(hex:)),
        supplied == Data(HMAC<SHA256>.authenticationCode(
          for: Data("file-decision|v1|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)|\(token)|\(digest)|\(decision)".utf8),
          using: SymmetricKey(data: device.secret))),
        let offered = token.hasPrefix("Shared::")
          ? (secure && request.logSourceIdentityVersion == "1" ? cloudSharing.resolve(token, recipient: device.physicalDeviceID, devices: state.devices, now: now) : nil)
          : try Collector.queueFile(for: token, device: device),
        FileManager.default.fileExists(atPath: offered.path) {
        let attrs = try FileManager.default.attributesOfItem(atPath: offered.path)
        guard ((attrs[.size] as? NSNumber)?.int64Value ?? Int64.max) <= 64 * 1024 * 1024 else { return nil }
        let bytes = try Data(contentsOf: offered, options: .mappedIfSafe)
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let forced = FileManager.default.fileExists(atPath: offered.path + ".force-resend")
        if actual == digest && decision == "have" && !forced {
          if token.hasPrefix("Shared::") {
            try cloudSharing.acknowledge(token, file: offered, recipient: device.physicalDeviceID)
          } else {
            try Collector.markDelivered(token, for: device)
            try BatteryLogStorage.archiveAcknowledged(offered, device: device)
          }
          SupportDiagnostics.record("\(device.name): preflight decision=have, action=skip \(CloudSharedLogToken.debugLabel(token)); SHA-256 \(digest.prefix(12))")
        } else if actual == digest && decision == "send" {
          SupportDiagnostics.record("\(device.name): preflight decision=send, action=transfer \(CloudSharedLogToken.debugLabel(token)); SHA-256 \(digest.prefix(12)); bytes=\(bytes.count)")
          return try encryptedLogResponse(bytes, name: token, request: request, device: device)
        } else {
          let reason = actual != digest ? "digest changed" : "manual resend overrides skip"
          SupportDiagnostics.record("\(device.name): preflight decision=\(decision) not applied for \(CloudSharedLogToken.debugLabel(token)); \(reason); offering current file")
        }
      } else if offerEnabled, let token = request.offerToken,
        request.offerDigest != nil, request.offerDecision != nil {
        SupportDiagnostics.record("\(device.name): preflight decision rejected for \(CloudSharedLogToken.debugLabel(token)); authentication, token, or queue file invalid")
      }
      let own = try Collector.pending(for: device).first
      let shared = own == nil && secure && request.cloudSharingVersion == "1" &&
        request.logSourceIdentityVersion == "1" && offerEnabled
        ? cloudSharing.next(recipient: device.physicalDeviceID, devices: state.devices, now: now) : nil
      let next = own ?? shared?.file
      let name = try shared?.token ?? own.map { try Collector.queueToken(for: $0, device: device) } ?? ""
      let content = try next.map { try Data(contentsOf: $0, options: .mappedIfSafe) } ?? Data()
      if offerEnabled, let next {
        guard content.count <= 64 * 1024 * 1024 else { return nil }
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let forced = FileManager.default.fileExists(atPath: next.path + ".force-resend")
        SupportDiagnostics.record("\(device.name): preflight offer \(CloudSharedLogToken.debugLabel(name)); SHA-256 \(digest.prefix(12)); bytes=\(content.count); forced=\(forced)")
        let sourceID = CloudSharedLogToken.parse(name)?.origin ?? device.physicalDeviceID
        let sourceModel = state.devices.first { $0.physicalDeviceID == sourceID }?.model ?? ""
        SupportDiagnostics.record("Import identity offer: source=\(sourceID.uuidString), recipient=\(device.physicalDeviceID.uuidString), model=\(sourceModel)")
        let control = try JSONSerialization.data(withJSONObject: [
          "type": "file-offer", "token": name, "sha256": digest,
          "sourceModel": sourceModel, "force": forced ? "true" : "false"
        ])
        return try encryptedLogResponse(control, name: "", request: request, device: device)
      }
      guard content.count <= 64 * 1024 * 1024,
        let nameData = name.data(using: .utf8), nameData.count <= 1024
      else { throw CollectorError.failed(MacTransferL10n.text("mt_c_07")) }
      var plain = Data()
      plain.append(UInt8(nameData.count >> 8))
      plain.append(UInt8(nameData.count & 0xff))
      plain.append(nameData)
      plain.append(content)
      if name.isEmpty {
        plain.append(Self.cloudCapability(SupportDiagnostics.macReport(for: device)))
      }
      let responseContext = Data("v2|response|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)".utf8)
      let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: device.secret),
        authenticating: responseContext)
      guard let combined = sealed.combined else { throw CollectorError.failed(MacTransferL10n.text("mt_c_08")) }
      var length = UInt32(combined.count).bigEndian
      let prefix = withUnsafeBytes(of: &length) { Data($0) }
      return PreparedResponse(data: prefix + combined, deviceID: device.physicalDeviceID, requestID: request.nonce, file: CloudSharedLogToken.debugLabel(name))
    } catch {
      onStatus?(MacTransferL10n.format("mt_m_18", error.localizedDescription))
      return nil
    }
  }

  private static func cloudCapability(_ content: Data) -> Data {
    guard var json = (try? JSONSerialization.jsonObject(with: content)) as? [String: Any] else { return content }
    json["cloudSharingVersion"] = "1"
    return (try? JSONSerialization.data(withJSONObject: json)) ?? content
  }

  private func encryptedLogResponse(_ content: Data, name: String, request: PullRequest,
    device: PairedDevice) throws -> PreparedResponse {
    if !name.isEmpty {
      SupportDiagnostics.record("Transfer trace: body request=\(request.nonce.uuidString), recipient=\(device.physicalDeviceID.uuidString), file=\(CloudSharedLogToken.debugLabel(name)), bytes=\(content.count)")
    }
    let nameData = Data(name.utf8)
    guard nameData.count <= 1024 else { throw CollectorError.failed("Invalid log token") }
    var plain = Data([UInt8(nameData.count >> 8), UInt8(nameData.count & 0xff)])
    plain.append(nameData)
    plain.append(name.isEmpty ? Self.cloudCapability(content) : content)
    let context = Data("v2|response|\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)".utf8)
    let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: device.secret),
      authenticating: context)
    guard let combined = sealed.combined else { throw CollectorError.failed("Unable to seal log") }
    var length = UInt32(combined.count).bigEndian
    return PreparedResponse(data: withUnsafeBytes(of: &length) { Data($0) } + combined,
      deviceID: device.physicalDeviceID, requestID: request.nonce, file: CloudSharedLogToken.debugLabel(name))
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
