import Foundation

/// All state belongs to queue. A progressing response has no absolute duration cap.
final class TransferWriteLoop: @unchecked Sendable {
  typealias Sender = (Data, @escaping (Error?) -> Void) -> Void
  private let packet: Data
  private let queue: DispatchQueue
  private let idleTimeout: TimeInterval
  private let sender: Sender
  private let completion: (Error?) -> Void
  private var timer: DispatchSourceTimer?
  private var offset = 0
  private var stopped = false

  init(
    packet: Data, queue: DispatchQueue, idleTimeout: TimeInterval = 25,
    sender: @escaping Sender, completion: @escaping (Error?) -> Void
  ) {
    self.packet = packet
    self.queue = queue
    self.idleTimeout = idleTimeout
    self.sender = sender
    self.completion = completion
  }

  func start() {
    queue.async { [self] in
      guard !stopped, timer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      self.timer = timer
      timer.setEventHandler { [weak self] in self?.finish(URLError(.timedOut)) }
      timer.schedule(deadline: .now() + idleTimeout)
      timer.resume()
      sendNext()
    }
  }

  func cancel() {
    queue.async { [self] in finish(CocoaError(.userCancelled)) }
  }

  private func sendNext() {
    guard !stopped else { return }
    guard offset < packet.count else {
      finish(nil)
      return
    }
    let end = min(packet.count, offset + 64 * 1024)
    sender(packet.subdata(in: offset..<end)) { [self] error in
      queue.async { [self] in
        guard !stopped else { return }
        if let error {
          finish(error)
          return
        }
        offset = end
        timer?.schedule(deadline: .now() + idleTimeout)
        sendNext()
      }
    }
  }

  private func finish(_ error: Error?) {
    guard !stopped else { return }
    stopped = true
    timer?.cancel()
    timer = nil
    completion(error)
  }

  deinit { timer?.cancel() }
}
