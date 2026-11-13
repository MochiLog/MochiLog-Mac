import Foundation
import ServiceManagement

enum MacSupportSettings {
  static func capture() -> Data {
    let defaults = UserDefaults.standard
    let login: String
    if #available(macOS 13, *), Bundle.main.bundleURL.pathExtension == "app" {
      switch SMAppService.mainApp.status {
      case .enabled: login = "enabled"
      case .notRegistered: login = "not-registered"
      case .requiresApproval: login = "requires-approval"
      case .notFound: login = "not-found"
      @unknown default: login = "unknown"
      }
    } else {
      login = "unsupported"
    }
    return SupportSettingsSnapshot.encode(
      platform: "macOS",
      toggles: [
        "menuBar": defaults.object(forKey: "MochiLogShowMenuBar") as? Bool ?? true,
        "hideDock": defaults.bool(forKey: "MochiLogHideDock"),
        "quitOnWindowClose": defaults.bool(forKey: "MochiLogQuitOnWindowClose"),
        "releaseUIWhenHidden": defaults.object(forKey: "MochiLogReleaseUiWhenHidden") as? Bool
          ?? true,
        "automaticUpdateChecks": defaults.bool(forKey: "automaticUpdateChecks"),
        "retainDeliveredLogs": BatteryLogStorage.retainsAfterDelivery,
      ],
      limits: [
        "debugRetentionDays": SupportDiagnostics.retentionDays,
        "batteryArchiveLimitMB": BatteryLogStorage.limitMB,
        "batteryArchiveRetentionMonths": BatteryLogStorage.retentionMonths,
      ],
      permissions: [
        "localNetwork": .init(
          "unknown", source: "no-general-public-query-API; see networkObservations"),
        "firewallAppRule": .init(
          "unknown",
          source: "not-queried; inbound access cannot be inferred from a listening socket"),
        "launchAtLogin": .init(login, source: "SMAppService.mainApp.status"),
      ])
  }
}
