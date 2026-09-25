import CryptoKit
import Foundation
import Network

private struct PullRequest: Decodable {
  let hostID: UUID
  let physicalDeviceID: UUID
  let nonce: UUID
  let ack: String?
  let mac: String
}

/// Local-only, authenticated pull server. The full filename and log are encrypted.
final class TransferServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "net.ryuya-dev.MochiLog.mac-transfer")
  private var listener: NWListener?
  private var state: CompanionState
  private var nonces: [UUID: Date] = [:]
  var onStatus: ((String) -> Void)?

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
      case .ready: self?.onStatus?("iPhoneからの接続を待機中")
      case .failed(let error): self?.onStatus?("接続待機に失敗: \(error.localizedDescription)")
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
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
      guard let self, error == nil, !complete else { connection.cancel(); return }
      var bytes = accumulated
      if let data { bytes.append(data) }
      guard bytes.count <= 4096 else { connection.cancel(); return }
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
    nonces[request.nonce] = Date()
    nonces = nonces.filter { Date().timeIntervalSince($0.value) < 300 }
    do {
      let directory = try Collector.directory(for: device)
      if let ack = request.ack,
        ack == URL(fileURLWithPath: ack).lastPathComponent,
        ack.hasPrefix("Analytics-"), ack.hasSuffix(".ips.ca.synced") {
        let acknowledged = directory.appendingPathComponent(ack)
        if FileManager.default.fileExists(atPath: acknowledged.path) {
          try Collector.markDelivered(ack, for: device)
          try FileManager.default.removeItem(at: acknowledged)
        }
      }
      let next = try Collector.pending(for: device).first
      let name = next?.lastPathComponent ?? ""
      let content = try next.map { try Data(contentsOf: $0, options: .mappedIfSafe) } ?? Data()
      guard content.count <= 64 * 1024 * 1024,
        let nameData = name.data(using: .utf8), nameData.count <= 1024
      else { throw CollectorError.failed("ログファイルが転送上限を超えました") }
      var plain = Data()
      plain.append(UInt8(nameData.count >> 8))
      plain.append(UInt8(nameData.count & 0xff))
      plain.append(nameData)
      plain.append(content)
      let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: device.secret))
      guard let combined = sealed.combined else { throw CollectorError.failed("暗号化に失敗しました") }
      var length = UInt32(combined.count).bigEndian
      let prefix = withUnsafeBytes(of: &length) { Data($0) }
      connection.send(content: prefix + combined, completion: .contentProcessed { _ in
        connection.cancel()
      })
    } catch {
      onStatus?("転送に失敗: \(error.localizedDescription)")
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
