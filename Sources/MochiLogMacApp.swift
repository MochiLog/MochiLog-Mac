import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import Network
import Sparkle
import SwiftUI

@main
struct MochiLogMacApp: App {
  @NSApplicationDelegateAdaptor(MochiLogMacAppDelegate.self) private var appDelegate
  @StateObject private var model = CompanionModel()
  @AppStorage(MacAppPreferences.menuBarKey) private var showMenuBar = true
  @AppStorage(MacAppPreferences.hideDockKey) private var hideDock = false
  private let updaterController: SPUStandardUpdaterController

  init() {
    MacAppPreferences.ensureMenuBarForBackgroundMode()
    SingleInstanceGuard.claim()
    CrashDiagnostics.start()
    updaterController = SPUStandardUpdaterController(startingUpdater: true,
      updaterDelegate: nil, userDriverDelegate: nil)
  }

  var body: some Scene {
    Window("MochiLog Mac", id: "main") {
      CompanionView(checkForUpdates: { updaterController.checkForUpdates(nil) })
        .environmentObject(model)
        .frame(minWidth: 780, minHeight: 620)
        .onAppear { MacAppPreferences.applyDockVisibility() }
        .onChange(of: showMenuBar) { _, _ in MacAppPreferences.applyDockVisibility() }
        .onChange(of: hideDock) { _, _ in MacAppPreferences.applyDockVisibility() }
    }
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") { updaterController.checkForUpdates(nil) }
      }
    }

    MenuBarExtra("MochiLog Mac", systemImage: "battery.100percent",
      isInserted: $showMenuBar) {
      MacMenuBarContent(model: model,
        checkForUpdates: { updaterController.checkForUpdates(nil) })
    }
  }
}

final class MochiLogMacAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    MacAppPreferences.quitOnWindowClose
  }
}

private struct MacMenuBarContent: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var model: CompanionModel
  let checkForUpdates: () -> Void

  var body: some View {
    Button(MacTransferL10n.text("mt_000")) {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
    }
    Button(MacTransferL10n.text("mt_001")) {
      Task { await model.collectAll(manual: true) }
    }.disabled(model.isBusy || model.state.devices.isEmpty)
    Button(MacTransferL10n.text("mt_send_now")) {
      model.sendQueuedNow()
    }.disabled(model.isBusy || !model.state.devices.contains(where: { $0.confirmedAt != nil }))
    Button(MacTransferL10n.text("mt_002")) {
      checkForUpdates()
    }
    Divider()
    Text(model.status)
    Divider()
    Button(MacTransferL10n.text("mt_003")) { NSApp.terminate(nil) }
  }
}

private enum OSPairingState {
  case unavailable, checking, awaitingWireless, verified, failed
}

private struct AppPresence {
  let isForeground: Bool
  let date: Date
}

private enum AppPresenceDisplay {
  case foreground, transferring, background, noResponse, unknown
}

@MainActor
final class CompanionModel: ObservableObject {
  @Published var devices: [ConnectedDevice] = []
  @Published private var pendingUSBDevice: ConnectedDevice?
  @Published var selectedUDID: String?
  @Published var status = MacTransferL10n.text("mt_m_00") {
    didSet { if status != oldValue { SupportDiagnostics.record(status) } }
  }
  @Published var pairingCode: String?
  @Published var isPairingSystem = false
  @Published var isPairingUSB = false
  @Published fileprivate var osPairingState: OSPairingState = .unavailable
  fileprivate var isRefreshing = false
  @Published var isBusy = false
  @Published var collectionDone = 0
  @Published var collectionTotal = 0
  @Published var staleAnalyticsDeviceIDs: Set<UUID> = []
  @Published var lastAppRequestAt: [UUID: Date] = [:]
  @Published var legacyClientIDs: Set<UUID> = []
  @Published private var appPresence: [UUID: AppPresence] = [:]
  @Published private var activeTransfers: [UUID: Int] = [:]
  @Published private var presenceClock = Date()
  @Published var showPairingQR = false
  @Published var pairingInvitation: PairingInvitation?
  @Published var state = Collector.loadState()
  @Published var liveBatterySnapshots: [UUID: LiveBatterySnapshot] = [:]
  @Published var liveBatteryFailures: Set<UUID> = []
  @Published var liveBatteryBusy: Set<UUID> = []
  private var liveBatteryInterest: [UUID: Date] = [:]
  private var liveBatteryViews: Set<UUID> = []
  private var lastBatteryAttempt: [UUID: Date] = [:]
  private var server: TransferServer?
  private var pairProcess: Process?
  private var lastAutomaticDecision: [UUID: String] = [:]
  private var automaticFailures: [UUID: (message: String, first: Date, count: Int)] = [:]

  private func finishAutomaticFailures(for device: PairedDevice, outcome: String) {
    guard let failure = automaticFailures.removeValue(forKey: device.physicalDeviceID),
      failure.count > 1 else { return }
    SupportDiagnostics.record("\(device.name): automatic collection \(outcome) after \(failure.count) attempts; first=\(SupportDiagnostics.localTime(failure.first)); last error=\(failure.message)")
  }

  private func recordCollectionFailure(for device: PairedDevice, trigger: String,
    error: Error, manual: Bool) {
    let message = error.localizedDescription
    if manual {
      SupportDiagnostics.record("\(device.name): collection failed; trigger=manual request; error=\(message)")
      return
    }
    if var previous = automaticFailures[device.physicalDeviceID], previous.message == message {
      previous.count += 1
      automaticFailures[device.physicalDeviceID] = previous
      if previous.count.isMultiple(of: 12) {
        SupportDiagnostics.record("\(device.name): automatic collection still waiting; trigger=\(trigger); attempts=\(previous.count); first=\(SupportDiagnostics.localTime(previous.first)); error=\(message)")
      }
    } else {
      finishAutomaticFailures(for: device, outcome: "failure changed")
      automaticFailures[device.physicalDeviceID] = (message, Date(), 1)
      SupportDiagnostics.record("\(device.name): collection failed; trigger=\(trigger); error=\(message)")
    }
  }

  init() {
    try? BatteryLogStorage.prune()
    let server = TransferServer(state: state)
    self.server = server
    server.onLiveBatteryRequested = { [weak self] id, manual in
      Task { @MainActor in
        self?.liveBatteryInterest[id] = Date()
        await self?.refreshBattery(id, manual: manual)
      }
    }
    server.onStatus = { [weak self] message in
      Task { @MainActor in self?.status = message }
    }
    server.onConfirmed = { [weak self] _ in
      Task { @MainActor in
        self?.state = Collector.loadState()
        self?.showPairingQR = false
        self?.pairingInvitation = nil
        self?.status = MacTransferL10n.text("mt_m_01")
      }
    }
    server.onPairingCompleted = { [weak self] in
      Task { @MainActor in self?.state = Collector.loadState() }
    }
    server.onPairingRevoked = { [weak self] in
      Task { @MainActor in self?.state = Collector.loadState() }
    }
    server.onAuthenticatedRequest = { [weak self] deviceID, date in
      Task { @MainActor in self?.lastAppRequestAt[deviceID] = date }
    }
    server.onLegacyClient = { [weak self] deviceID in
      Task { @MainActor in self?.legacyClientIDs.insert(deviceID) }
    }
    server.onSecureClient = { [weak self] deviceID in
      Task { @MainActor in self?.legacyClientIDs.remove(deviceID) }
    }
    server.onAppPresence = { [weak self] deviceID, isForeground, date in
      Task { @MainActor in
        self?.appPresence[deviceID] = AppPresence(isForeground: isForeground, date: date)
      }
    }
    server.onTransferActivity = { [weak self] deviceID, active in
      Task { @MainActor in
        guard let self else { return }
        let count = self.activeTransfers[deviceID, default: 0]
        self.activeTransfers[deviceID] = max(0, count + (active ? 1 : -1))
      }
    }
    do { try server.start() }
    catch { status = MacTransferL10n.format("mt_m_02", error.localizedDescription) }
    Task {
      await refresh()
      await collectAll(trigger: "app launch")
    }
    Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.collectAll(trigger: "5-minute timer") }
    }
    Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.presenceClock = Date()
        for device in self.state.devices where (self.liveBatteryViews.contains(device.physicalDeviceID)
          && NSApp.windows.contains(where: { $0.isVisible }))
          || Date().timeIntervalSince(self.liveBatteryInterest[device.physicalDeviceID] ?? .distantPast) < 45 {
          await self.refreshBattery(device.physicalDeviceID)
        }
      }
    }
  }

  func watchBattery(_ id: UUID, visible: Bool) {
    if visible { liveBatteryViews.insert(id); Task { await refreshBattery(id) } }
    else { liveBatteryViews.remove(id) }
  }

  func refreshBattery(_ id: UUID, manual: Bool = false) async {
    guard !liveBatteryBusy.contains(id),
      let device = state.devices.first(where: { $0.physicalDeviceID == id }),
      manual || Date().timeIntervalSince(lastBatteryAttempt[id] ?? .distantPast) >=
        (liveBatteryFailures.contains(id) ? 60 : 15) else { return }
    lastBatteryAttempt[id] = Date()
    liveBatteryBusy.insert(id)
    let started = ProcessInfo.processInfo.systemUptime
    SupportDiagnostics.record("Battery snapshot started; device=\(id.uuidString), trigger=\(manual ? "manual" : "automatic"), logCollectionBusy=\(isBusy)")
    defer {
      liveBatteryBusy.remove(id); lastBatteryAttempt[id] = Date()
      SupportDiagnostics.record("Battery snapshot finished; device=\(id.uuidString), elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)), failed=\(liveBatteryFailures.contains(id))")
    }
    do {
      let peerAddress = server?.liveBatteryPeerAddress(for: id)
      let snapshot = try await Task.detached { try Collector.currentBattery(device, peerAddress: peerAddress) }.value
      guard state.devices.contains(where: { $0.physicalDeviceID == id }) else {
        server?.liveBattery.remove(id); liveBatterySnapshots.removeValue(forKey: id); return
      }
      liveBatterySnapshots[id] = snapshot
      liveBatteryFailures.remove(id)
      server?.liveBattery.set(snapshot, for: id)
    } catch {
      liveBatteryFailures.insert(id)
      server?.liveBattery.set(nil, for: id)
    }
  }

  func sendBatteryNow(_ id: UUID) async {
    await refreshBattery(id, manual: true)
    server?.announceQueuedFiles()
  }

  fileprivate func presenceState(for deviceID: UUID) -> AppPresenceDisplay {
    if activeTransfers[deviceID, default: 0] > 0 { return .transferring }
    guard let presence = appPresence[deviceID] else { return .unknown }
    guard presence.isForeground else { return .background }
    return presenceClock.timeIntervalSince(presence.date) <= 150
      ? .foreground : .noResponse
  }

  var selectableDevices: [ConnectedDevice] {
    var result = devices
    if let pendingUSBDevice,
      !result.contains(where: { $0.udid == pendingUSBDevice.udid }) {
      result.append(pendingUSBDevice)
    }
    result += state.devices.filter { saved in
      !result.contains(where: { $0.udid == saved.udid })
    }.map { saved in
      ConnectedDevice(udid: saved.udid, name: saved.name, model: saved.model)
    }
    return result
  }
  var selected: ConnectedDevice? { selectableDevices.first { $0.udid == selectedUDID } }
  var pairedSelected: PairedDevice? { state.devices.first { $0.udid == selectedUDID } }

  func unpairSelected() throws {
    guard let device = pairedSelected else { return }
    try server?.revoke(device.physicalDeviceID)
    state = Collector.loadState()
    pairingInvitation = nil
    showPairingQR = false
    status = MacTransferL10n.text("mt_unpair_pending")
  }

  func setManualDeviceAddress(_ address: String?) throws {
    guard let udid = selectedUDID,
      let index = state.devices.firstIndex(where: { $0.udid == udid }) else { return }
    let value = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !value.isEmpty {
      guard IPv4Address(value) != nil, value != "0.0.0.0",
        !value.hasPrefix("127.") else {
        throw CollectorError.failed("Enter a valid iPhone or iPad IPv4 address")
      }
    }
    var updated = state
    updated.devices[index].manualAddress = value.isEmpty ? nil : value
    try Collector.saveState(updated)
    state = updated
  }
  var isOSPairingVerified: Bool {
    if case .verified = osPairingState { return true }
    return false
  }

  func refresh() async {
    guard !isRefreshing, !isBusy else { return }
    isRefreshing = true
    isBusy = true
    defer { isBusy = false; isRefreshing = false }
    do {
      devices = try await Task.detached(priority: .utility) { try Collector.browse() }.value
      if let pendingUSBDevice,
        devices.contains(where: { $0.udid == pendingUSBDevice.udid }) {
        self.pendingUSBDevice = nil
      }
      status = MacTransferL10n.format("mt_m_03", devices.count)
      if selectedUDID == nil { selectedUDID = selectableDevices.first?.udid }
      await verifySelectedOSPairing()
    } catch { status = MacTransferL10n.format("mt_m_04", error.localizedDescription) }
  }

  func verifySelectedOSPairing() async {
    guard let udid = selectedUDID else {
      osPairingState = .unavailable
      return
    }
    osPairingState = .checking
    do {
      let isUSBConnected = try await Task.detached(priority: .utility) {
        try Collector.isUSBConnected(udid: udid)
      }.value
      guard selectedUDID == udid else { return }
      if isUSBConnected {
        osPairingState = .awaitingWireless
        return
      }
      try await Task.detached(priority: .utility) {
        try Collector.verifyOSPairing(udid: udid)
      }.value
      if selectedUDID == udid { osPairingState = .verified }
    } catch {
      if selectedUDID == udid { osPairingState = .failed }
    }
  }

  func pairApp() {
    guard let selected, isOSPairingVerified else { return }
    pairingInvitation = server?.beginPairing(for: selected, existing: pairedSelected)
    showPairingQR = pairingInvitation != nil
    status = MacTransferL10n.format("mt_m_05", selected.name)
  }

  var pairingURL: String? {
    guard let invitation = pairingInvitation else { return nil }
    var components = URLComponents()
    components.scheme = "mochilog-mac"
    components.host = "pair"
    components.queryItems = [
      .init(name: "v", value: "3"),
      .init(name: "transfer", value: "3"),
      .init(name: "platform", value: "macOS"),
      .init(name: "host", value: invitation.hostID.uuidString),
      .init(name: "model", value: invitation.model),
      .init(name: "session", value: invitation.sessionID.uuidString),
      .init(name: "public", value: invitation.publicKey.base64EncodedString()),
      .init(name: "ipv4", value: invitation.lanAddresses.joined(separator: ",")),
      .init(name: "port", value: String(invitation.lanPort))
    ]
    if let existingID = invitation.existingPhysicalDeviceID {
      components.queryItems?.append(.init(name: "device", value: existingID.uuidString))
    }
    if let tailnet = invitation.tailnetAddress {
      components.queryItems?.append(.init(name: "tailnet", value: tailnet))
      components.queryItems?.append(.init(name: "tailnetPort",
        value: String(invitation.tailnetPort ?? TransferServer.tailnetPort)))
    }
    return components.url?.absoluteString
  }

  func collectAll(manual: Bool = false, trigger: String = "manual request") async {
    guard !state.devices.isEmpty else { return }
    guard !isBusy else {
      SupportDiagnostics.record("Collection trigger skipped: \(trigger); another collection is in progress")
      return
    }
    var japan = Calendar(identifier: .gregorian)
    japan.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let now = Date()
    let collectionOpen = japan.component(.hour, from: now) >= 9
    let dayFormatter = DateFormatter()
    dayFormatter.calendar = japan
    dayFormatter.timeZone = japan.timeZone
    dayFormatter.dateFormat = "yyyy-MM-dd"
    let today = dayFormatter.string(from: now)
    let devices = state.devices.filter { device in
      if manual { return true }
      let reason: String?
      let resume: Date
      if !collectionOpen {
        reason = "before the daily collection window"
        resume = japan.nextDate(after: now, matching: DateComponents(hour: 9),
          matchingPolicy: .nextTime) ?? now.addingTimeInterval(24 * 60 * 60)
      } else if let until = device.automaticPauseUntil, until > now {
        reason = "mobile app confirmed all required daily logs"
        resume = until
      } else if BatteryLogStorage.hasRequiredDailyLogs(for: device, on: today) {
        reason = "verified current-day host and known Watch logs are stored"
        resume = japan.nextDate(after: now, matching: DateComponents(hour: 9),
          matchingPolicy: .nextTime) ?? now.addingTimeInterval(24 * 60 * 60)
      } else {
        reason = nil
        resume = now
      }
      if let reason {
        finishAutomaticFailures(for: device, outcome: "paused")
        let key = "\(reason)|\(Int(resume.timeIntervalSince1970))"
        if lastAutomaticDecision[device.physicalDeviceID] != key {
          SupportDiagnostics.record("\(device.name): automatic collection stopped; trigger=\(reason); resume=\(SupportDiagnostics.localTime(resume))")
          lastAutomaticDecision[device.physicalDeviceID] = key
        }
        return false
      }
      if lastAutomaticDecision.removeValue(forKey: device.physicalDeviceID) != nil {
        SupportDiagnostics.record("\(device.name): automatic collection resumed; trigger=\(trigger)")
      }
      return true
    }
    guard !devices.isEmpty else { return }
    isBusy = true
    defer { isBusy = false }
    var savedAny = false
    for device in devices {
      let started = ProcessInfo.processInfo.systemUptime
      do {
        if manual || automaticFailures[device.physicalDeviceID] == nil {
          SupportDiagnostics.record("\(device.name): collection started; trigger=\(manual ? "manual request" : trigger)")
        }
        collectionDone = 0
        collectionTotal = 0
        let report = try await Task.detached(priority: .utility) { [weak self] in
          try Collector.collect(device) { done, total in
            Task { @MainActor [weak self] in
              self?.collectionDone = done
              self?.collectionTotal = total
              self?.status = MacTransferL10n.format("mt_m_07", device.name, done, total)
            }
          }
        }.value
        finishAutomaticFailures(for: device, outcome: "recovered")
        SupportDiagnostics.saveCollection(report, error: nil, for: device)
        let isStale = report.newestHostAnalyticsAt.map {
          Date().timeIntervalSince($0) >= 48 * 60 * 60
        } ?? true
        if isStale {
          staleAnalyticsDeviceIDs.insert(device.physicalDeviceID)
        } else {
          staleAnalyticsDeviceIDs.remove(device.physicalDeviceID)
        }
        savedAny = savedAny || report.saved > 0
        SupportDiagnostics.record("\(device.name): collection finished; saved=\(report.saved), excluded=\(report.skipped), deferred=\(report.deferred), failed=\(report.failed), elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
        if selectedUDID == device.udid { osPairingState = .verified }
        status = report.failed == 0
          ? MacTransferL10n.format("mt_m_08", device.name, report.saved, report.skipped)
          : MacTransferL10n.format("mt_m_09", device.name, report.saved, report.skipped, report.failed, report.lastError ?? "")
      } catch {
        recordCollectionFailure(for: device, trigger: trigger, error: error, manual: manual)
        SupportDiagnostics.saveCollection(nil, error: error, for: device)
        if selectedUDID == device.udid { osPairingState = .failed }
        status = "\(device.name): \(error.localizedDescription)"
      }
    }
    if savedAny { server?.announceQueuedFiles() }
  }

  func sendQueuedNow() {
    guard !isBusy else { return }
    let queued: Int
    do {
      queued = try state.devices.filter { $0.confirmedAt != nil }.reduce(0) {
        try $0 + Collector.pending(for: $1).count
      }
    } catch {
      status = error.localizedDescription
      return
    }
    guard queued > 0 else {
      status = MacTransferL10n.text("mt_send_empty")
      return
    }
    server?.announceQueuedFiles()
    status = MacTransferL10n.format("mt_send_queued", queued)
  }

  func startSystemPairing() {
    guard !isPairingSystem else { return }
    guard let helper = Bundle.main.url(forResource: "pymobiledevice3", withExtension: nil,
      subdirectory: "Collector") else {
      status = MacTransferL10n.text("mt_m_10")
      return
    }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = helper
    process.arguments = ["remote", "pair-host", "--name", "MochiLog Mac", "--timeout", "180"]
    process.standardOutput = pipe
    process.standardError = pipe
    process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
      "TERM": "dumb", "NO_COLOR": "1", "PYTHONUNBUFFERED": "1"]
    pairProcess = process
    isPairingSystem = true
    pairingCode = nil
    status = MacTransferL10n.text("mt_m_11")
    do { try process.run() }
    catch {
      isPairingSystem = false
      status = MacTransferL10n.format("mt_m_12", error.localizedDescription)
      return
    }
    let handle = pipe.fileHandleForReading
    Task.detached { [weak self] in
      var output = ""
      while true {
        let data = handle.availableData
        if data.isEmpty { break }
        output += String(decoding: data, as: UTF8.self)
        if let range = output.range(of: #"Enter this code on your device: [0-9]{6}"#,
          options: .regularExpression) {
          let code = String(output[range].suffix(6))
          await MainActor.run { [weak self] in self?.pairingCode = code }
        }
      }
      process.waitUntilExit()
      await MainActor.run { [weak self] in
        self?.isPairingSystem = false
        self?.pairingCode = nil
        self?.status = process.terminationStatus == 0
          ? MacTransferL10n.text("mt_m_13")
          : MacTransferL10n.text("mt_m_14")
        Task { [weak self] in await self?.refresh() }
      }
    }
  }

  func stopSystemPairing() { pairProcess?.terminate() }

  func prepareUSBPairing() async {
    guard !isPairingUSB else { return }
    isPairingUSB = true
    status = MacTransferL10n.text("mt_usb_progress")
    defer { isPairingUSB = false }
    do {
      let device = try await Task.detached(priority: .utility) {
        try Collector.prepareUSBPairing()
      }.value
      pendingUSBDevice = device
      selectedUDID = device.udid
      await refresh()
      osPairingState = .awaitingWireless
      status = MacTransferL10n.format("mt_usb_success", device.name)
    } catch {
      status = MacTransferL10n.format("mt_usb_error", error.localizedDescription)
    }
  }
}

private struct CompanionView: View {
  private enum Page: String, CaseIterable, Identifiable {
    case overview, devices, currentBattery, batteryLogs, support, settings
    var id: Self { self }
    var titleKey: String {
      switch self {
      case .overview: "mt_nav_overview"
      case .devices: "mt_nav_devices"
      case .currentBattery: "live_title"
      case .batteryLogs: "mt_battery_logs"
      case .support: "mt_022"
      case .settings: "mt_nav_settings"
      }
    }
    var symbol: String {
      switch self {
      case .overview: "square.grid.2x2"
      case .devices: "iphone.gen3"
      case .currentBattery: "battery.100percent"
      case .batteryLogs: "archivebox"
      case .support: "questionmark.circle"
      case .settings: "gearshape"
      }
    }
  }

  let checkForUpdates: () -> Void
  @EnvironmentObject private var model: CompanionModel
  @State private var page: Page? = .overview
  @State private var showingSupport = false
  @State private var showingDebugLog = false
  @State private var showingLicenses = false
  @State private var supportDeviceID: String?
  @State private var launchesAtLogin = MacAppPreferences.launchesAtLogin
  @State private var preferencesError: String?
  @State private var manualDeviceAddress = ""
  @State private var showingUnpairConfirmation = false
  @AppStorage(MacAppPreferences.menuBarKey) private var showMenuBar = true
  @AppStorage(MacAppPreferences.hideDockKey) private var hideDock = false
  @AppStorage(MacAppPreferences.quitOnWindowCloseKey) private var quitOnWindowClose = false
  private var supportDevice: PairedDevice? {
    model.state.devices.first(where: { $0.udid == supportDeviceID })
      ?? model.state.devices.first(where: { $0.udid == model.selectedUDID })
      ?? model.state.devices.first
  }

  var body: some View {
    NavigationSplitView {
      List(Page.allCases, selection: $page) { item in
        Label(MacTransferL10n.text(item.titleKey), systemImage: item.symbol)
          .tag(item)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack(spacing: 14) {
            Image(systemName: page?.symbol ?? "square.grid.2x2")
              .font(.title2).foregroundStyle(.green)
              .frame(width: 44, height: 44)
              .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
              Text(MacTransferL10n.text(page?.titleKey ?? "mt_nav_overview"))
                .font(.largeTitle.bold())
              Text(MacTransferL10n.text("mt_004"))
                .font(.subheadline).foregroundStyle(.secondary)
            }
          }
          switch page ?? .overview {
          case .overview: overview
          case .devices: devices
          case .currentBattery: currentBattery
          case .batteryLogs: BatteryLogLibraryView()
          case .support: support
          case .settings: settings
          }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(30)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .sheet(isPresented: $showingSupport) {
      if let device = supportDevice {
        MacTransferSupportView(device: device)
      }
    }
    .sheet(isPresented: $showingDebugLog) {
      MacTransferDebugLogView(device: supportDevice)
    }
    .sheet(isPresented: $showingLicenses) {
      MacLicensesView()
    }
  }

  private var overview: some View {
    VStack(alignment: .leading, spacing: 22) {
      pairedDevices
      if !model.legacyClientIDs.isEmpty {
        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Label(MacTransferL10n.text("mt_mobile_update_needed"),
              systemImage: "exclamationmark.shield")
              .foregroundStyle(.orange)
            Link(MacTransferL10n.text("mt_mobile_update_link"),
              destination: URL(string: "https://apps.apple.com/app/mochilog/id6756904240")!)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
      }
      GroupBox(MacTransferL10n.text("mt_guide_title")) {
        VStack(alignment: .leading, spacing: 16) {
          workflowDiagram
          DisclosureGroup(MacTransferL10n.text("mt_flow_details")) {
            VStack(alignment: .leading, spacing: 14) {
              guidePoint("mt_guide_collect_title", "mt_guide_collect_detail",
                symbol: "macbook.and.iphone")
              guidePoint("mt_guide_import_title", "mt_guide_import_detail",
                symbol: "arrow.down.doc")
              guidePoint("mt_guide_without_title", "mt_guide_without_detail",
                symbol: "iphone")
            }.padding(.top, 8)
          }
          Text(MacTransferL10n.text("mt_guide_footer"))
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      }
      GroupBox(MacTransferL10n.text("mt_nav_activity")) {
        VStack(alignment: .leading, spacing: 18) {
          Text(model.status).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          if model.isBusy {
            if model.collectionTotal > 0 {
              ProgressView(value: Double(model.collectionDone),
                total: Double(model.collectionTotal))
              Text("\(model.collectionDone)/\(model.collectionTotal)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else { ProgressView() }
          }
          Button {
            Task { await model.collectAll(manual: true) }
          } label: {
            Label(MacTransferL10n.text("mt_001"), systemImage: "arrow.down.doc")
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isBusy || model.state.devices.isEmpty)
          Button { model.sendQueuedNow() } label: {
            Label(MacTransferL10n.text("mt_send_now"), systemImage: "paperplane")
          }
          .disabled(model.isBusy || !model.state.devices.contains(where: { $0.confirmedAt != nil }))
          Text(MacTransferL10n.text("mt_send_hint"))
            .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
      }
      GroupBox(MacTransferL10n.text("mt_help_title")) {
        VStack(alignment: .leading, spacing: 14) {
          helpDiagram
          DisclosureGroup(MacTransferL10n.text("mt_help_remote_title")) {
            Text(MacTransferL10n.text("mt_help_remote_detail"))
              .foregroundStyle(.secondary).padding(.top, 8)
          }
          Button(MacTransferL10n.text("mt_help_support")) { page = .support }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
    }
  }

  private var pairedDevices: some View {
      GroupBox(MacTransferL10n.text("mt_nav_connected")) {
        VStack(alignment: .leading, spacing: 12) {
          if model.state.devices.isEmpty {
            Text(MacTransferL10n.text("mt_nav_no_devices"))
              .foregroundStyle(.secondary)
          } else {
            ForEach(model.state.devices) { device in
              VStack(alignment: .leading, spacing: 12) {
              HStack {
                Image(systemName: "iphone.gen3").foregroundStyle(.green)
                VStack(alignment: .leading) {
                  Text(device.name).fontWeight(.medium)
                  Text(device.model).font(.caption).foregroundStyle(.secondary)
                  let presence = model.presenceState(for: device.physicalDeviceID)
                  Label(presenceTitle(for: presence), systemImage: presenceSymbol(for: presence))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(presenceColor(for: presence))
                  if let lastRequest = model.lastAppRequestAt[device.physicalDeviceID] {
                    Text(MacTransferL10n.format("mt_last_request",
                      DateFormatter.localizedString(from: lastRequest,
                        dateStyle: .short, timeStyle: .short)))
                      .font(.caption).foregroundStyle(.secondary)
                  } else {
                    Text(MacTransferL10n.text("mt_no_request"))
                      .font(.caption).foregroundStyle(.secondary)
                  }
                  if model.staleAnalyticsDeviceIDs.contains(device.physicalDeviceID) {
                    Label(MacTransferL10n.text("mt_analytics_stale_title"),
                      systemImage: "exclamationmark.triangle")
                      .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    Text(MacTransferL10n.text("mt_analytics_stale_detail"))
                      .font(.caption).foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
                Spacer()
                if device.confirmedAt != nil {
                  Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    .help(MacTransferL10n.text("mt_paired"))
                }
              }

              }
            }
          }
          Text(MacTransferL10n.text("mt_presence_note"))
            .font(.caption).foregroundStyle(.secondary)
          Button(MacTransferL10n.text("mt_nav_manage_devices")) { page = .devices }
            .buttonStyle(.link)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
  }

  private var currentBattery: some View {
    VStack(alignment: .leading, spacing: 20) {
      if model.state.devices.isEmpty {
        Text(MacTransferL10n.text("mt_nav_no_devices")).foregroundStyle(.secondary)
        Button(MacTransferL10n.text("mt_nav_manage_devices")) { page = .devices }
      }
      ForEach(model.state.devices) { device in
        VStack(alignment: .leading, spacing: 12) {
          Label(device.name, systemImage: device.model.hasPrefix("iPad") ? "ipad" : "iphone")
            .font(.title3.weight(.semibold))
          Text(device.model).font(.caption).foregroundStyle(.secondary)
              LiveBatteryCard(snapshot: model.liveBatterySnapshots[device.physicalDeviceID],
                failed: model.liveBatteryFailures.contains(device.physicalDeviceID),
                busy: model.liveBatteryBusy.contains(device.physicalDeviceID),
                receive: { Task { await model.refreshBattery(device.physicalDeviceID, manual: true) } },
                send: { Task { await model.sendBatteryNow(device.physicalDeviceID) } })
                .onAppear { model.watchBattery(device.physicalDeviceID, visible: true) }
                .onDisappear { model.watchBattery(device.physicalDeviceID, visible: false) }
        }
      }
    }
  }

  private func guidePoint(_ titleKey: String, _ detailKey: String,
    symbol: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.title3.weight(.medium))
        .foregroundStyle(.green)
        .frame(width: 26)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(MacTransferL10n.text(titleKey)).font(.headline)
        Text(MacTransferL10n.text(detailKey))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var workflowDiagram: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 6) {
        flowNode("macbook", "mt_guide_collect_title", tint: .green)
        flowArrow
        flowNode("lock.shield", "mt_flow_secure", tint: .blue)
        flowArrow
        flowNode("iphone.gen3", "mt_guide_import_title", tint: .orange)
      }
      VStack(alignment: .leading, spacing: 7) {
        compactFlowNode("macbook", "mt_guide_collect_title", tint: .green)
        compactFlowArrow
        compactFlowNode("lock.shield", "mt_flow_secure", tint: .blue)
        compactFlowArrow
        compactFlowNode("iphone.gen3", "mt_guide_import_title", tint: .orange)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 16))
  }

  private func flowNode(_ symbol: String, _ titleKey: String,
    tint: Color) -> some View {
    VStack(spacing: 9) {
      Image(systemName: symbol)
        .font(.title2.weight(.medium))
        .foregroundStyle(tint)
        .frame(width: 54, height: 54)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
      Text(MacTransferL10n.text(titleKey))
        .font(.caption.weight(.semibold))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: 108, alignment: .top)
    .accessibilityElement(children: .combine)
  }

  private var flowArrow: some View {
    Image(systemName: "arrow.right")
      .font(.caption.weight(.bold))
      .foregroundStyle(.tertiary)
      .frame(width: 18, height: 54)
      .accessibilityHidden(true)
  }

  private func compactFlowNode(_ symbol: String, _ titleKey: String,
    tint: Color) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.title3).foregroundStyle(tint)
        .frame(width: 44, height: 44)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
      Text(MacTransferL10n.text(titleKey)).font(.subheadline.weight(.semibold))
    }
    .accessibilityElement(children: .combine)
  }

  private var compactFlowArrow: some View {
    Image(systemName: "arrow.down")
      .font(.caption.bold()).foregroundStyle(.tertiary)
      .frame(width: 44).accessibilityHidden(true)
  }

  private var pairingDiagram: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 8) {
        pairingStage(1, "wifi", "mt_pair_os_short")
        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
          .frame(height: 56).accessibilityHidden(true)
        pairingStage(2, "qrcode", "mt_pair_qr_short")
        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
          .frame(height: 56).accessibilityHidden(true)
        pairingStage(3, "checkmark.circle", "mt_pair_ready_short")
      }
      VStack(alignment: .leading, spacing: 7) {
        compactFlowNode("wifi", "mt_pair_os_short", tint: .green)
        compactFlowArrow
        compactFlowNode("qrcode", "mt_pair_qr_short", tint: .green)
        compactFlowArrow
        compactFlowNode("checkmark.circle", "mt_pair_ready_short", tint: .green)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 16))
  }

  private func pairingStage(_ number: Int, _ symbol: String,
    _ titleKey: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.title2).foregroundStyle(.green)
        .frame(width: 54, height: 54)
        .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
          Text("\(number)").font(.caption2.bold()).foregroundStyle(.white)
            .frame(width: 20, height: 20).background(.green, in: Circle())
            .offset(x: 7, y: -7)
        }
      Text(MacTransferL10n.text(titleKey))
        .font(.caption.weight(.semibold)).multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: 150, alignment: .top)
    .accessibilityElement(children: .combine)
  }

  private var helpDiagram: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 8) {
        helpStage(1, "doc.text.magnifyingglass", "mt_help_missing_title",
          "mt_help_missing_detail")
        helpStage(2, "macbook", "mt_help_collect_title", "mt_help_collect_detail")
        helpStage(3, "iphone.gen3", "mt_help_import_title", "mt_help_import_detail")
      }
      VStack(alignment: .leading, spacing: 8) {
        helpStage(1, "doc.text.magnifyingglass", "mt_help_missing_title",
          "mt_help_missing_detail")
        helpStage(2, "macbook", "mt_help_collect_title", "mt_help_collect_detail")
        helpStage(3, "iphone.gen3", "mt_help_import_title", "mt_help_import_detail")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func helpStage(_ number: Int, _ symbol: String,
    _ titleKey: String, _ detailKey: String) -> some View {
    DisclosureGroup {
      Text(MacTransferL10n.text(detailKey))
        .font(.caption).foregroundStyle(.secondary)
        .padding(.top, 8)
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Image(systemName: symbol).font(.title3).foregroundStyle(.green)
          Spacer(minLength: 4)
          Text("\(number)")
            .font(.caption2.bold()).foregroundStyle(.white)
            .frame(width: 22, height: 22).background(.green, in: Circle())
        }
        Text(MacTransferL10n.text(titleKey))
          .font(.subheadline.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(minWidth: 150, alignment: .topLeading)
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 14))
  }

  private func presenceTitle(for state: AppPresenceDisplay) -> String {
    switch state {
    case .foreground: MacTransferL10n.text("mt_presence_foreground")
    case .transferring: MacTransferL10n.text("mt_presence_transferring")
    case .background: MacTransferL10n.text("mt_presence_background")
    case .noResponse: MacTransferL10n.text("mt_presence_no_response")
    case .unknown: MacTransferL10n.text("mt_presence_unknown")
    }
  }

  private func presenceSymbol(for state: AppPresenceDisplay) -> String {
    switch state {
    case .foreground: "checkmark.circle.fill"
    case .transferring: "arrow.up.doc"
    case .background: "moon.zzz"
    case .noResponse: "wifi.exclamationmark"
    case .unknown: "questionmark.circle"
    }
  }

  private func presenceColor(for state: AppPresenceDisplay) -> Color {
    switch state {
    case .foreground, .transferring: .green
    case .noResponse: .orange
    case .background, .unknown: .secondary
    }
  }

  private var devices: some View {
    VStack(alignment: .leading, spacing: 22) {
      if model.state.devices.isEmpty && !model.isOSPairingVerified {
        firstConnectionHero
      }
      GroupBox(MacTransferL10n.text("mt_005")) {
        VStack(alignment: .leading, spacing: 10) {
          pairingDiagram
          DisclosureGroup(MacTransferL10n.text("mt_pair_details")) {
            VStack(alignment: .leading, spacing: 10) {
              Text(MacTransferL10n.text("mt_006"))
              Text(MacTransferL10n.text("mt_007"))
              Text(MacTransferL10n.text("mt_008"))
              Text(MacTransferL10n.text("mt_009"))
            }.padding(.top, 8)
          }
          Divider()
          Label(MacTransferL10n.text("mt_usb_wireless_title"),
            systemImage: "wifi")
            .font(.headline)
          Text(MacTransferL10n.text("mt_usb_wireless_detail"))
            .foregroundStyle(.secondary)
          HStack {
            Button(model.isPairingSystem ? MacTransferL10n.text("mt_010")
              : MacTransferL10n.text("mt_011")) {
              model.isPairingSystem ? model.stopSystemPairing() : model.startSystemPairing()
            }
            .disabled(model.isPairingUSB)
            if let code = model.pairingCode {
              Text(code).font(.system(.title2, design: .monospaced).bold())
                .textSelection(.enabled)
            }
          }
          Divider()
          Label(MacTransferL10n.text("mt_usb_title"), systemImage: "cable.connector")
            .font(.headline)
          Text(MacTransferL10n.text("mt_usb_detail"))
            .foregroundStyle(.secondary)
          Button {
            Task { await model.prepareUSBPairing() }
          } label: {
            if model.isPairingUSB { ProgressView().controlSize(.small) }
            Text(MacTransferL10n.text("mt_usb_button"))
          }
          .disabled(model.isPairingUSB || model.isPairingSystem)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
      GroupBox(MacTransferL10n.text("mt_012")) {
        VStack(alignment: .leading, spacing: 18) {
          HStack {
            Picker(MacTransferL10n.text("mt_013"), selection: $model.selectedUDID) {
              Text(MacTransferL10n.text("mt_014")).tag(String?.none)
              ForEach(model.selectableDevices) { device in
                Text("\(device.name) (\(device.model))").tag(Optional(device.udid))
              }
            }
            .onChange(of: model.selectedUDID) { _, _ in
              manualDeviceAddress = model.pairedSelected?.manualAddress ?? ""
              if !model.isRefreshing {
                Task { await model.verifySelectedOSPairing() }
              }
            }
            Button {
              Task { await model.refresh() }
            } label: { Image(systemName: "arrow.clockwise") }
              .help(MacTransferL10n.text("mt_015"))
          }
          if model.pairedSelected != nil {
            Button(role: .destructive) {
              showingUnpairConfirmation = true
            } label: {
              Label(MacTransferL10n.text("mt_unpair_button"),
                systemImage: "person.crop.circle.badge.xmark")
            }
            Divider()
            Text(MacTransferL10n.text("mt_manual_device_ip_title"))
              .font(.headline)
            Text(MacTransferL10n.text("mt_manual_device_ip_detail"))
              .font(.caption).foregroundStyle(.secondary)
            HStack {
              TextField("192.168.1.20", text: $manualDeviceAddress)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
              Button(MacTransferL10n.text("mt_manual_device_ip_save")) {
                do { try model.setManualDeviceAddress(manualDeviceAddress) }
                catch { preferencesError = error.localizedDescription }
              }
              Button(MacTransferL10n.text("mt_manual_device_ip_clear")) {
                do {
                  try model.setManualDeviceAddress(nil)
                  manualDeviceAddress = ""
                } catch { preferencesError = error.localizedDescription }
              }
            }
            if let preferencesError { Text(preferencesError).foregroundStyle(.red) }
          }
          if let selected = model.selected, model.isOSPairingVerified {
            Label(MacTransferL10n.text("mt_os_paired"),
              systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
            if model.showPairingQR, let url = model.pairingURL,
              let image = QRCode.image(for: url) {
              HStack(alignment: .top, spacing: 20) {
                Image(nsImage: image).interpolation(.none).resizable()
                  .frame(width: 210, height: 210)
                VStack(alignment: .leading, spacing: 8) {
                  Text(selected.name).font(.headline)
                  Text(MacTransferL10n.text("mt_019"))
                  Text(MacTransferL10n.text("mt_pair_code_instruction"))
                    .font(.caption).foregroundStyle(.secondary)
                  if let invitation = model.pairingInvitation {
                    Text(invitation.code)
                      .font(.system(.title, design: .monospaced).weight(.bold))
                      .textSelection(.enabled)
                  }
                  Button(MacTransferL10n.text("mt_021")) {
                    model.showPairingQR = false
                  }
                }
              }
            } else if model.pairedSelected == nil {
              Button(MacTransferL10n.text("mt_016")) { model.pairApp() }
                .buttonStyle(.borderedProminent)
            } else {
              HStack {
                Label(MacTransferL10n.text("mt_017"),
                  systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button(MacTransferL10n.text("mt_018")) { model.pairApp() }
              }
            }
          } else if case .checking = model.osPairingState {
            HStack {
              ProgressView().controlSize(.small)
              Text(MacTransferL10n.text("mt_os_checking"))
            }
          } else if case .awaitingWireless = model.osPairingState {
            Label(MacTransferL10n.text("mt_os_awaiting_wireless"),
              systemImage: "wifi")
              .foregroundStyle(.orange)
          } else if case .failed = model.osPairingState {
            Label(MacTransferL10n.text("mt_os_unreachable"),
              systemImage: "wifi.exclamationmark")
              .foregroundStyle(.orange)
          } else {
            Label(MacTransferL10n.text("mt_os_pair_first"),
              systemImage: "exclamationmark.circle")
              .foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
    }
    .onAppear {
      manualDeviceAddress = model.pairedSelected?.manualAddress ?? ""
      Task { await model.refresh() }
    }
    .confirmationDialog(MacTransferL10n.text("mt_unpair_title"),
      isPresented: $showingUnpairConfirmation, titleVisibility: .visible) {
      Button(MacTransferL10n.text("mt_unpair_button"), role: .destructive) {
        do { try model.unpairSelected() }
        catch { preferencesError = error.localizedDescription }
      }
    } message: {
      Text(MacTransferL10n.text("mt_unpair_detail"))
    }
  }

  private var firstConnectionHero: some View {
    HStack(spacing: 28) {
      VStack(alignment: .leading, spacing: 15) {
        Image(systemName: "cable.connector")
          .font(.title2.weight(.medium))
          .foregroundStyle(.blue)
          .frame(width: 52, height: 52)
          .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        Text(MacTransferL10n.text("mt_intro_title"))
          .font(.system(size: 31, weight: .semibold))
        Text(MacTransferL10n.text("mt_intro_detail"))
          .font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Label(MacTransferL10n.text(model.selectableDevices.isEmpty
          ? "mt_intro_waiting" : "mt_intro_found"),
          systemImage: model.selectableDevices.isEmpty
            ? "cable.connector" : "checkmark.circle")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(model.selectableDevices.isEmpty ? .blue : .green)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(spacing: 0) {
        RoundedRectangle(cornerRadius: 23)
          .fill(LinearGradient(colors: [.indigo, .blue],
            startPoint: .topLeading, endPoint: .bottomTrailing))
          .frame(width: 126, height: 210)
          .overlay {
            Image(systemName: "battery.100percent")
              .font(.system(size: 39)).foregroundStyle(.white.opacity(0.85))
          }
          .overlay(alignment: .top) {
            Capsule().fill(.black.opacity(0.75))
              .frame(width: 42, height: 8).padding(.top, 9)
          }
          .overlay {
            RoundedRectangle(cornerRadius: 23)
              .strokeBorder(.gray.opacity(0.8), lineWidth: 3)
          }
        RoundedRectangle(cornerRadius: 3).fill(.gray)
          .frame(width: 18, height: 19)
        Rectangle().fill(.gray.opacity(0.7))
          .frame(width: 6, height: 24)
      }
      .frame(width: 170)
      .accessibilityHidden(true)
    }
    .padding(28)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 22))
  }

  private var support: some View {
    VStack(alignment: .leading, spacing: 22) {
      GroupBox(MacTransferL10n.text("mt_022")) {
        VStack(alignment: .leading, spacing: 16) {
          Text(MacTransferL10n.text("mt_023"))
          Picker(MacTransferL10n.text("mt_024"), selection: $supportDeviceID) {
            Text(MacTransferL10n.text("mt_014")).tag(String?.none)
            ForEach(model.state.devices) { device in
              Text("\(device.name) (\(device.model))").tag(Optional(device.udid))
            }
          }.frame(maxWidth: 420)
          HStack {
            Button(MacTransferL10n.text("mt_025")) { showingSupport = true }
              .buttonStyle(.borderedProminent).disabled(supportDevice == nil)
            Button(MacTransferL10n.text("mt_026")) { showingDebugLog = true }
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
      GroupBox(MacTransferL10n.text("mt_nav_about")) {
        VStack(alignment: .leading, spacing: 12) {
          Button(MacTransferL10n.text("mt_l_00")) { showingLicenses = true }
          Link(MacTransferL10n.text("mt_l_07"),
            destination: URL(string: "https://mochilog.ryuya-dev.net/privacy")!)
          Link(MacTransferL10n.text("mt_l_08"),
            destination: URL(string: "https://mochilog.ryuya-dev.net/terms")!)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
    }
    .onAppear {
      if supportDeviceID == nil { supportDeviceID = model.state.devices.first?.udid }
    }
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 22) {
      GroupBox(MacTransferL10n.text("mt_027")) {
        VStack(alignment: .leading, spacing: 14) {
          Toggle(MacTransferL10n.text("mt_028"),
            isOn: Binding(get: { launchesAtLogin }, set: { desired in
              do {
                try MacAppPreferences.setLaunchAtLogin(desired)
                launchesAtLogin = MacAppPreferences.launchesAtLogin
                preferencesError = nil
              } catch {
                launchesAtLogin = MacAppPreferences.launchesAtLogin
                preferencesError = error.localizedDescription
              }
            }))
          Toggle(MacTransferL10n.text("mt_029"), isOn: $showMenuBar)
            .disabled(!quitOnWindowClose)
          Toggle(MacTransferL10n.text("mt_030"), isOn: $hideDock)
            .disabled(!showMenuBar)
          Picker(MacTransferL10n.text("mt_close_behavior"), selection: $quitOnWindowClose) {
            Text(MacTransferL10n.text("mt_close_keep_running")).tag(false)
            Text(MacTransferL10n.text("mt_close_quit")).tag(true)
          }
          .pickerStyle(.radioGroup)
          .onChange(of: quitOnWindowClose) { _, shouldQuit in
            if !shouldQuit { showMenuBar = true }
          }
          Text(MacTransferL10n.text("mt_close_help"))
            .font(.caption)
            .foregroundStyle(.secondary)
          if let preferencesError { Text(preferencesError).foregroundStyle(.red) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
      GroupBox(MacTransferL10n.text("mt_nav_updates")) {
        Button(MacTransferL10n.text("mt_002")) { checkForUpdates() }
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
    }
  }
}

private enum QRCode {
  static func image(for text: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let image = filter.outputImage,
      let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: 210, height: 210))
  }
}
