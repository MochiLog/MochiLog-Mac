import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor protocol ScreenMemoryOwning: AnyObject { func setScreenVisibility(suspended: Bool) }

enum WindowMemoryPolicy {
  static func suspend(enabled: Bool, visible: Bool, minimized: Bool, appHidden: Bool, closing: Bool)
    -> Bool
  {
    enabled && (!visible || minimized || appHidden || closing)
  }
}

final class ScreenLifetimeToken: ObservableObject {
  // Keep the lifetime probe's publisher local to the screen.
  let objectWillChange = ObservableObjectPublisher()
  private static let lock = NSLock()
  private static var instances: Set<UUID> = []
  static var activeIDs: Set<UUID> { lock.lock(); defer { lock.unlock() }; return instances }
  private let id = UUID()
  init() {
    Self.lock.lock(); Self.instances.insert(id); Self.lock.unlock()
    SupportDiagnostics.record("UI memory: screen state created; instance=\(id)")
  }
  deinit {
    Self.lock.lock(); Self.instances.remove(id); Self.lock.unlock()
    SupportDiagnostics.record("UI memory: screen state destroyed; instance=\(id)")
  }
}

/// The native `.link` style retains its action/view state on the tested macOS
/// 27.2 build, even after its hosting controller is removed. Draw the same text
/// action through SwiftUI so a discarded screen can release its state.
struct ScreenLinkButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
      .opacity(configuration.isPressed ? 0.65 : 1)
      .contentShape(Rectangle())
  }
}

/// Only the foreground SwiftUI tree is discarded. CompanionModel and the
/// authenticated collection/transfer services keep their existing lifetime.
final class WindowMemoryManager: ObservableObject {
  @Published private(set) var suspended = false
  private weak var window: NSWindow?
  private weak var screenOwner: ScreenMemoryOwning?
  private var closing = false
  private var observers: [NSObjectProtocol] = []
  private var generation = 0
  private var verificationStarted = false

  init() {
    for name in [
      NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
      NSWindow.didExposeNotification,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] event in
          guard let self, let target = event.object as? NSWindow, target === self.window else {
            return
          }
          if name == NSWindow.willCloseNotification {
            self.closing = true
          } else if name == NSWindow.didBecomeKeyNotification
            || name == NSWindow.didDeminiaturizeNotification
          {
            self.closing = false
          }
          DispatchQueue.main.async { [weak self] in self?.update() }
        })
    }
    for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in self?.update()
        })
    }
  }
  deinit { for token in observers { NotificationCenter.default.removeObserver(token) } }
  func attach(_ target: NSWindow) {
    if window !== target { window = target; closing = false }
    update()
    if !verificationStarted && CommandLine.arguments.contains("--verify-ui-memory") {
      verificationStarted = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self else { return }
        Task { @MainActor in await self.verifyScreenLifecycle() }
      }
    }
  }
  @MainActor func attachOwner(_ owner: ScreenMemoryOwning) {
    if screenOwner !== owner {
      screenOwner?.setScreenVisibility(suspended: true); screenOwner = owner
    }
    owner.setScreenVisibility(suspended: suspended)
  }
  func update() {
    guard let window else { return }
    let enabled = MacAppPreferences.releaseUiWhenHidden
    let desired = WindowMemoryPolicy.suspend(
      enabled: enabled, visible: window.isVisible,
      minimized: window.isMiniaturized, appHidden: NSApp.isHidden, closing: closing)
    guard suspended != desired else { return }
    suspended = desired; generation += 1
    // Hidden windows may defer SwiftUI transactions. Teardown must happen now,
    // rather than waiting for the window to become visible and render again.
    MainActor.assumeIsolated { screenOwner?.setScreenVisibility(suspended: desired) }
    let token = generation
    let before = GuardedProcess.residentBytes()
    SupportDiagnostics.record(
      "UI memory: \(desired ? "visual tree released" : "screen recreated"); enabled=\(enabled); residentBytes=\(before)"
    )
    if desired {
      // SwiftUI first unmounts the branch and releases its state. Ask the native
      // allocator to return free cached pages after that transaction settles.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self, self.suspended, self.generation == token else { return }
        DispatchQueue.global(qos: .utility).async {
          let reclaimed = malloc_zone_pressure_relief(nil, 0)
          SupportDiagnostics.record(
            "UI memory: allocator relief; returnedBytes=\(reclaimed); residentBytesBefore=\(before); residentBytesAfter=\(GuardedProcess.residentBytes())"
          )
        }
      }
    }
  }

  /// Explicit local integration check against the actual SwiftUI window.
  @MainActor func verifyScreenLifecycle() async {
    struct Cycle: Codable {
      let cycle: Int; let page, operation: String; let released, recreated: Bool;
      let residentBefore, residentAfter: UInt64
    }
    struct Report: Codable {
      let schema: Int, type, generatedAt: String
      let passed, disabledRetainsScreen: Bool
      let samples: [Cycle]
    }
    let previous = UserDefaults.standard.object(forKey: MacAppPreferences.releaseUiKey)
    let previousPage = UserDefaults.standard.object(forKey: "MochiLogLastPage")
    var samples: [Cycle] = [], passed = false, retained = false
    func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    for _ in 0..<20 { if window != nil { break }; await wait(0.1) }
    guard let window else { return }
    window.makeKeyAndOrderFront(nil); await wait(1)
    UserDefaults.standard.set(true, forKey: MacAppPreferences.releaseUiKey)
    for cycle in 0..<3 {
      let page = UserDefaults.standard.string(forKey: "MochiLogLastPage") ?? "overview"
      let before = GuardedProcess.residentBytes()
      let canMinimize = window.styleMask.contains(.miniaturizable)
      let operation =
        cycle == 1 && !canMinimize
        ? "hide window (minimize unavailable)" : ["hide window", "minimize", "hide app"][cycle]
      if cycle == 1 && canMinimize {
        window.miniaturize(nil)
      } else if cycle == 2 {
        NSApp.hide(nil)
      } else {
        window.orderOut(nil)
      }
      update(); await wait(1)
      for _ in 0..<20 where !suspended { await wait(0.1); update() }
      SupportDiagnostics.record(
        "UI memory: verification operation=\(operation); canMinimize=\(canMinimize); minimized=\(window.isMiniaturized); visible=\(window.isVisible); suspended=\(suspended)"
      )
      let released = suspended && ScreenLifetimeToken.activeIDs.isEmpty
      let after = GuardedProcess.residentBytes()
      UserDefaults.standard.set(
        ["settings", "currentBattery", "overview"][cycle], forKey: "MochiLogLastPage")
      if cycle == 1 && canMinimize { window.deminiaturize(nil) }
      if cycle == 2 { NSApp.unhide(nil) }
      window.makeKeyAndOrderFront(nil); closing = false; update(); await wait(0.5)
      let recreated = !suspended && !ScreenLifetimeToken.activeIDs.isEmpty
      samples.append(
        Cycle(
          cycle: cycle, page: page, operation: operation, released: released, recreated: recreated,
          residentBefore: before, residentAfter: after))
    }
    UserDefaults.standard.set(false, forKey: MacAppPreferences.releaseUiKey); update()
    let ids = ScreenLifetimeToken.activeIDs
    window.orderOut(nil); update(); await wait(0.5)
    retained = !suspended && !ids.isEmpty && ids == ScreenLifetimeToken.activeIDs
    window.makeKeyAndOrderFront(nil); closing = false
    if let previous {
      UserDefaults.standard.set(previous, forKey: MacAppPreferences.releaseUiKey)
    } else {
      UserDefaults.standard.removeObject(forKey: MacAppPreferences.releaseUiKey)
    }
    if let previousPage {
      UserDefaults.standard.set(previousPage, forKey: "MochiLogLastPage")
    } else {
      UserDefaults.standard.removeObject(forKey: "MochiLogLastPage")
    }
    update()
    passed = samples.count == 3 && samples.allSatisfy({ $0.released && $0.recreated }) && retained
    let report = Report(
      schema: 1, type: "mochilog-ui-memory-test", generatedAt: SupportDiagnostics.localTime(Date()),
      passed: passed, disabledRetainsScreen: retained, samples: samples)
    if let data = try? JSONEncoder().encode(report) {
      try? data.write(
        to: Collector.root.appendingPathComponent("ui-memory-test.json"), options: .atomic)
    }
    SupportDiagnostics.record("UI memory: local regression check; passed=\(passed)")
  }
}

struct WindowMemoryReference: NSViewRepresentable {
  let manager: WindowMemoryManager
  final class ReferenceView: NSView {
    weak var manager: WindowMemoryManager?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window {
        DispatchQueue.main.async { [weak self, weak window] in
          if let window { self?.manager?.attach(window) }
        }
      }
    }
  }
  func makeNSView(context: Context) -> ReferenceView {
    let view = ReferenceView(); view.manager = manager; return view
  }
  func updateNSView(_ view: ReferenceView, context: Context) {
    view.manager = manager
    if let window = view.window { DispatchQueue.main.async { manager.attach(window) } }
  }
}
