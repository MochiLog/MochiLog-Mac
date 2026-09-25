import AppKit
import Darwin
import Foundation
import ServiceManagement

enum MacAppPreferences {
  static let menuBarKey = "MochiLogShowMenuBar"
  static let hideDockKey = "MochiLogHideDock"

  static func applyDockVisibility() {
    let defaults = UserDefaults.standard
    let hide = defaults.bool(forKey: menuBarKey) && defaults.bool(forKey: hideDockKey)
    NSApp.setActivationPolicy(hide ? .accessory : .regular)
  }

  static var launchesAtLogin: Bool {
    SMAppService.mainApp.status == .enabled
  }

  static func setLaunchAtLogin(_ enabled: Bool) throws {
    if enabled {
      if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
    } else if SMAppService.mainApp.status != .notRegistered {
      try SMAppService.mainApp.unregister()
    }
  }
}

enum SingleInstanceGuard {
  private static var lockHandle: Int32 = -1

  static func claim() {
    let file = Collector.root.appendingPathComponent("app-instance.lock")
    lockHandle = open(file.path, O_CREAT | O_RDWR, 0o600)
    guard lockHandle >= 0, flock(lockHandle, LOCK_EX | LOCK_NB) == 0 else {
      if let bundle = Bundle.main.bundleIdentifier {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
          .first(where: { $0.processIdentifier != getpid() })?
          .activate(options: [.activateAllWindows])
      }
      exit(EXIT_SUCCESS)
    }
  }
}
