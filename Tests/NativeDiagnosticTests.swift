import Darwin
import Foundation

enum NativeDiagnosticTests {
  enum Failure: Error { case assertion(String) }
  private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.assertion(message) }
  }
  static func fixture() -> Bool {
    let args = CommandLine.arguments
    guard args.count >= 4, args[1] == "--guarded-fixture" else { return false }
    let file = URL(fileURLWithPath: args[3])
    if args[2] == "descendant" {
      // No new spawn attributes: this child inherits the guarded process group
      // and stdout pipe, then remains alive after this parent returns.
      var argv = [args[0], "--guarded-fixture", "idle", file.path].map { strdup($0) } + [nil]
      var envp: [UnsafeMutablePointer<CChar>?] = [nil]
      defer { for pointer in argv { free(pointer) } }
      var pid: pid_t = 0
      guard posix_spawn(&pid, args[0], nil, nil, &argv, &envp) == 0 else { exit(1) }
      Thread.sleep(forTimeInterval: 0.15)
      return true
    }
    try? String(getpid()).write(to: file, atomically: true, encoding: .utf8)
    signal(SIGTERM, SIG_IGN)
    if args[2] == "flood" || args[2] == "stderr" {
      let bytes = [UInt8](repeating: 120, count: 8192)
      for _ in 0..<128 {
        bytes.withUnsafeBytes {
          _ = Darwin.write(args[2] == "stderr" ? 2 : 1, $0.baseAddress, $0.count)
        }
      }
    }
    while true { pause() }
  }
  static func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mochilog-native-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let device = NativeDiagnostics.Device(
      physicalDeviceID: UUID(),
      name: String(repeating: "test", count: 100), model: "test model", pairingConfirmed: true,
      automaticPauseUntil: nil,
      routes: DiagnosticRoutes.Report(
        manual: nil, peer: nil,
        peerAt: nil, hints: [], hintsAt: nil, verified: nil, verifiedAt: nil, candidates: []),
      collection: nil)
    let events = (0..<700).map { "event-\($0) " + String(repeating: "x", count: 840) }
    let snapshot = NativeDiagnostics.capture(status: "test", devices: [device], events: events)
    let bytes = try NativeDiagnostics.encode(snapshot)
    try check(
      bytes.count <= NativeDiagnostics.maxBytes && snapshot.recentEvents.count == 50,
      "diagnostic report must be bounded")
    try check(
      snapshot.recentEvents.first?.hasPrefix("event-650 ") == true, "latest events retained")
    try check(
      snapshot.resources.residentBytes > 0 && snapshot.resources.processID == getpid(),
      "native resource measurements")
    try check(!String(decoding: bytes, as: UTF8.self).contains("secret"), "no pairing secrets")
    let many = NativeDiagnostics.capture(
      status: "test", devices: Array(repeating: device, count: 1000), events: [])
    try check(many.devices.count == 32 && many.truncated, "device cap")
    var invalid = snapshot; invalid.status = String(repeating: "x", count: 1_000_000)
    do {
      _ = try NativeDiagnostics.encode(invalid); throw Failure.assertion("unbounded DTO accepted")
    } catch NativeDiagnostics.Failure.tooLarge {}
    let oversized = root.appendingPathComponent("oversized.json")
    try Data(repeating: 120, count: 2_000_000).write(to: oversized)
    try check(
      BoundedDiagnosticFile.read(oversized, maximum: 8192) == nil, "reject before file decoding")
    let store = DiagnosticSnapshotStore(root: root)
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let expired = store.directory.appendingPathComponent("2000-01-01.json")
    try Data().write(to: expired)
    try store.save(snapshot, retentionDays: 30)
    try check(!FileManager.default.fileExists(atPath: expired.path), "expired snapshot removed")
    let current = store.directory.appendingPathComponent("current.json")
    try check(try Data(contentsOf: current) == bytes, "atomic current snapshot")
    let daily = store.directory.appendingPathComponent(
      SupportDiagnostics.dayString(Date()) + ".json")
    try check(try Data(contentsOf: daily) == bytes, "daily snapshot")
    store.clear();
    try check(!FileManager.default.fileExists(atPath: current.path), "delete snapshots")
    for _ in 0..<200 { try autoreleasepool { _ = try NativeDiagnostics.encode(snapshot) } }
    let before = GuardedProcess.residentBytes()
    for _ in 0..<1000 { try autoreleasepool { _ = try NativeDiagnostics.encode(snapshot) } }
    let growth = Int64(GuardedProcess.residentBytes()) - Int64(before)
    try check(growth < 16 * 1024 * 1024, "repeated exports retain too much memory")
    print(
      "PASS: native diagnostics, bounded DTOs/files, retention, 1000 exports; outputBytes=\(bytes.count), residentGrowthBytes=\(growth)"
    )
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    func killed(_ file: URL) throws {
      guard let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text) else {
        return
      }
      // A killed descendant can briefly be a zombie until launchd reaps it.
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      let alive =
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != 5
      try check(!alive, "helper/descendant still alive: \(pid)")
    }
    for mode in ["idle", "flood", "stderr", "descendant", "cancel", "memory"] {
      let file = root.appendingPathComponent(mode + ".pid")
      let cancel = GuardedProcess.Cancellation()
      if mode == "cancel" {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancel.cancel() }
      }
      let started = ProcessInfo.processInfo.systemUptime
      do {
        let result = try GuardedProcess.run(
          executable,
          arguments: [
            "--guarded-fixture", ["cancel", "memory"].contains(mode) ? "idle" : mode, file.path,
          ],
          environment: ["PATH": "/usr/bin:/bin"], timeout: 1, outputLimit: 32768, errorLimit: 32768,
          residentLimit: mode == "memory" ? 1 : 1024 * 1024 * 1024, cancellation: cancel)
        try check(mode == "descendant" && result.exitCode == 0, "fixture unexpectedly returned")
      } catch GuardedProcess.Failure.timeout {
        try check(mode == "idle", "unexpected timeout \(mode)")
      } catch GuardedProcess.Failure.outputLimit {
        try check(["flood", "stderr"].contains(mode), "unexpected overflow")
      } catch GuardedProcess.Failure.memoryLimit {
        try check(mode == "memory", "unexpected memory limit")
      } catch is CancellationError { try check(mode == "cancel", "unexpected cancellation") }
      try check(ProcessInfo.processInfo.systemUptime - started < 3, "deadline not bounded")
      Thread.sleep(forTimeInterval: 0.1)
      if mode != "memory" {
        try check(FileManager.default.fileExists(atPath: file.path), "fixture PID missing")
      }
      try killed(file)
    }
    try check(GuardedProcess.activeCount == 0, "ownership leaked")
    print(
      "PASS: helper deadline, ignored SIGTERM, cancellation, stdout/stderr caps, memory guard and inherited-pipe descendants"
    )
  }
}
