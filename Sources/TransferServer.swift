import CryptoKit
import Foundation
import Network

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
  private let queue = DispatchQueue(label: "net.ryuya-dev.MochiLog.mac-transfer")
  private var listener: NWListener?
  private var state: CompanionState
  private var nonces: [UUID: Date] = [:]
  var onStatus: ((String) -> Void)?
  var onConfirmed: ((UUID) -> Void)?

  init(state: CompanionState) { self.state = state }

  func update(state: CompanionState) { queue.async { self.state = state } }

  func start() throws {
    let listener = try NWListener(using: .tcp)
    listener.service = NWListener.Service(name: state.hostID.uuidString,
      type: "_mochilog._tcp")
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.stateUpdateHandler = { [weak self] status in
      switch status {
      case .ready: self?.onStatus?(MacTransferL10n.text("mt_m_15"))
      case .failed(let error): self?.onStatus?(MacTransferL10n.format("mt_m_16", error.localizedDescription))
      default: break
      }
    }
    self.listener = listener
    listener.start(queue: queue)
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
    guard let request = try? JSONDecoder().decode(PullRequest.self, from: requestData),
      request.hostID == state.hostID,
      let device = state.devices.first(where: { $0.physicalDeviceID == request.physicalDeviceID }),
      Date().timeIntervalSince(nonces[request.nonce] ?? .distantPast) > 300
    else { connection.cancel(); return }
    let message = "\(request.hostID.uuidString)|\(request.physicalDeviceID.uuidString)|\(request.nonce.uuidString)|\(request.ack ?? "")"
    let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8),
      using: SymmetricKey(data: device.secret)))
    guard let received = Data(hex: request.mac), received == expected else {
      connection.cancel(); return
    }
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
      connection.send(content: prefix + combined, completion: .contentProcessed { _ in
        connection.cancel()
      })
    } catch {
      onStatus?(MacTransferL10n.format("mt_m_18", error.localizedDescription))
      connection.cancel()
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
