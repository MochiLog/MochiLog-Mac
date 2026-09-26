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
  let clientDiagnostics: String?
  let clientDiagnosticsMAC: String?
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
  var onStatus: ((String) -> Void)?
  var onConfirmed: ((UUID) -> Void)?
  var onAuthenticatedRequest: ((UUID, Date) -> Void)?

  init(state: CompanionState) { self.state = state }

  func update(state: CompanionState) { queue.async { self.state = state } }

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
        let response = queue.sync { makeResponse(to: Data(request[..<newline])) }
        guard let response else { return }
        var offset = 0
        while offset < response.count {
          let written = response.withUnsafeBytes { bytes in
            Darwin.send(client, bytes.baseAddress!.advanced(by: offset),
              response.count - offset, 0)
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
    guard let response = makeResponse(to: requestData) else {
      connection.cancel()
      return
    }
    connection.send(content: response, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private func makeResponse(to requestData: Data) -> Data? {
    guard let request = try? JSONDecoder().decode(PullRequest.self, from: requestData),
      request.hostID == state.hostID,
      let device = state.devices.first(where: { $0.physicalDeviceID == request.physicalDeviceID }),
      Date().timeIntervalSince(nonces[request.nonce] ?? .distantPast) > 300
    else { return nil }
    let message = "\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)|\(request.ack ?? "")"
    let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8),
      using: SymmetricKey(data: device.secret)))
    guard let received = Data(hex: request.mac), received == expected else { return nil }
    onAuthenticatedRequest?(device.physicalDeviceID, Date())
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
    nonces[request.nonce] = Date()
    nonces = nonces.filter { Date().timeIntervalSince($0.value) < 300 }
    if let encoded = request.clientDiagnostics,
      let signature = request.clientDiagnosticsMAC,
      let report = Data(base64Encoded: encoded), report.count <= 8192,
      let supplied = Data(hex: signature) {
      let expectedReportMAC = Data(HMAC<SHA256>.authenticationCode(
        for: Data("diagnostics|\(request.nonce.uuidString)|".utf8) + report,
        using: SymmetricKey(data: device.secret)))
      if supplied == expectedReportMAC {
        try? SupportDiagnostics.savePhoneReport(report, for: device)
      }
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
      let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: device.secret))
      guard let combined = sealed.combined else { throw CollectorError.failed(MacTransferL10n.text("mt_c_08")) }
      var length = UInt32(combined.count).bigEndian
      let prefix = withUnsafeBytes(of: &length) { Data($0) }
      return prefix + combined
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
