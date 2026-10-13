import Darwin
import Foundation

/// A bounded lifetime owns the helper, its process group and both output pipes.
/// No shell, temporary output files or blocking EOF reads are involved.
enum GuardedProcess {
  struct Result {
    let output: Data
    let error: Data
    let exitCode: Int32
    let signal: Int32?
  }
  enum Failure: Error { case timeout, outputLimit, memoryLimit, system(Int32) }
  final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    func cancel() { lock.lock(); requested = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return requested }
  }
  private static let lock = NSLock()
  private static var groups: Set<pid_t> = []

  static var activeCount: Int { lock.lock(); defer { lock.unlock() }; return groups.count }

  static func stopAll() {
    lock.lock(); defer { lock.unlock() }
    for pid in groups { Darwin.kill(-pid, SIGKILL) }
  }

  static func residentBytes(for pid: pid_t = getpid()) -> UInt64 {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size
      ? info.pti_resident_size : 0
  }

  static func run(_ executable: URL, arguments: [String], environment: [String: String],
    timeout: TimeInterval, outputLimit: Int = 8 * 1024 * 1024,
    errorLimit: Int = 1024 * 1024, residentLimit: UInt64 = 1024 * 1024 * 1024,
    cancellation: Cancellation? = nil, onOutput: ((Data) -> Void)? = nil) throws -> Result {
    precondition(timeout > 0 && outputLimit > 0 && errorLimit > 0)
    if cancellation?.isCancelled == true { throw CancellationError() }
    var stdout: [Int32] = [-1, -1], stderr: [Int32] = [-1, -1]
    defer { for fd in stdout + stderr where fd >= 0 { Darwin.close(fd) } }
    guard pipe(&stdout) == 0, pipe(&stderr) == 0 else { throw Failure.system(errno) }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    func checked(_ code: Int32) throws { if code != 0 { throw Failure.system(code) } }
    try checked(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try checked(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try checked(posix_spawnattr_setflags(&attributes,
      Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
    try checked(posix_spawnattr_setpgroup(&attributes, 0))
    try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
    try checked(posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO))
    try checked(posix_spawn_file_actions_adddup2(&actions, stderr[1], STDERR_FILENO))
    for fd in stdout + stderr { try checked(posix_spawn_file_actions_addclose(&actions, fd)) }
    var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
    var envp = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for pointer in argv + envp { free(pointer) } }
    var pid: pid_t = 0
    try checked(posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp))
    lock.lock(); groups.insert(pid); lock.unlock()
    var reaped = false
    defer {
      Darwin.kill(-pid, SIGKILL)
      if !reaped {
        let end = ProcessInfo.processInfo.systemUptime + 1
        var ignored: Int32 = 0
        while waitpid(pid, &ignored, WNOHANG) == 0 && ProcessInfo.processInfo.systemUptime < end {
          Thread.sleep(forTimeInterval: 0.01)
        }
      }
      lock.lock(); groups.remove(pid); lock.unlock()
    }
    Darwin.close(stdout[1]); stdout[1] = -1
    Darwin.close(stderr[1]); stderr[1] = -1
    for fd in [stdout[0], stderr[0]] {
      guard fcntl(fd, F_SETFL, O_NONBLOCK) >= 0 else { throw Failure.system(errno) }
    }
    var descriptors = [pollfd(fd: stdout[0], events: Int16(POLLIN | POLLHUP), revents: 0),
      pollfd(fd: stderr[0], events: Int16(POLLIN | POLLHUP), revents: 0)]
    var output = Data(), error = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var nextResourceCheck: TimeInterval = 0
    var status: Int32 = 0
    while true {
      if cancellation?.isCancelled == true { throw CancellationError() }
      let now = ProcessInfo.processInfo.systemUptime
      if now >= deadline { throw Failure.timeout }
      if !reaped && now >= nextResourceCheck {
        if residentBytes(for: pid) > residentLimit { throw Failure.memoryLimit }
        nextResourceCheck = now + 0.25
      }
      let ready = poll(&descriptors, nfds_t(descriptors.count), 50)
      if ready < 0 && errno != EINTR { throw Failure.system(errno) }
      for index in descriptors.indices where descriptors[index].fd >= 0 {
        // Limit drain work so a continuous writer cannot bypass the deadline.
        for _ in 0..<64 {
          let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
          if count == 0 { descriptors[index].fd = -1; break }
          if count < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN { break }
            throw Failure.system(errno)
          }
          if index == 0 {
            guard output.count + count <= outputLimit else { throw Failure.outputLimit }
            let chunk = Data(buffer.prefix(count)); output.append(chunk); onOutput?(chunk)
          } else {
            guard error.count + count <= errorLimit else { throw Failure.outputLimit }
            error.append(contentsOf: buffer.prefix(count))
          }
        }
      }
      if !reaped {
        let finished = waitpid(pid, &status, WNOHANG)
        if finished == pid {
          reaped = true
          // A descendant may still own the pipe after its parent exits.
          Darwin.kill(-pid, SIGKILL)
        } else if finished < 0 && errno != EINTR { throw Failure.system(errno) }
      }
      if reaped && descriptors.allSatisfy({ $0.fd < 0 }) { break }
    }
    let signal = status & 0x7f
    return Result(output: output, error: error,
      exitCode: signal == 0 ? (status >> 8) & 0xff : signal,
      signal: signal == 0 ? nil : signal)
  }
}
