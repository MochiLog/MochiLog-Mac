import Foundation

@main
struct TransferWriteLoopTests {
  static func main() throws {
    let packet = Data((0..<(4 * 64 * 1024 + 13)).map { UInt8($0 % 251) })
    let queue = DispatchQueue(label: "transfer.write.tests")
    let done = DispatchSemaphore(value: 0)
    var received = Data()
    var failure: Error?
    let started = ProcessInfo.processInfo.systemUptime
    let writer = TransferWriteLoop(
      packet: packet, queue: queue, idleTimeout: 1,
      sender: { chunk, completion in
        queue.asyncAfter(deadline: .now() + 0.25) {
          received.append(chunk)
          completion(nil)
        }
      },
      completion: { error in
        failure = error
        done.signal()
      })
    writer.start()
    precondition(done.wait(timeout: .now() + 8) == .success)
    precondition(failure == nil && received == packet)
    precondition(ProcessInfo.processInfo.systemUptime - started > 1)

    var completions = 0
    var late: ((Error?) -> Void)?
    let stalled = TransferWriteLoop(
      packet: packet, queue: queue, idleTimeout: 0.1,
      sender: { _, completion in late = completion },
      completion: { error in
        precondition((error as? URLError)?.code == .timedOut)
        completions += 1
        done.signal()
      })
    stalled.start()
    precondition(done.wait(timeout: .now() + 2) == .success)
    queue.sync { late?(nil) }
    queue.sync {}
    precondition(completions == 1, "A late completion revived a stopped write")

    let cancelled = TransferWriteLoop(
      packet: packet, queue: queue, idleTimeout: 2,
      sender: { _, _ in },
      completion: { error in
        precondition((error as? CocoaError)?.code == .userCancelled)
        done.signal()
      })
    cancelled.start()
    cancelled.cancel()
    precondition(done.wait(timeout: .now() + 2) == .success)
    print(
      "PASS: progressing slow write, exact chunk bytes, idle timeout, late callback and cancellation"
    )
  }
}
