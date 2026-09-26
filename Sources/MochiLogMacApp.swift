import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import Sparkle
import SwiftUI

@main
struct MochiLogMacApp: App {
  @StateObject private var model = CompanionModel()
  @AppStorage(MacAppPreferences.menuBarKey) private var showMenuBar = false
  @AppStorage(MacAppPreferences.hideDockKey) private var hideDock = false
  private let updaterController: SPUStandardUpdaterController

  init() {
    SingleInstanceGuard.claim()
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
      Task { await model.collectAll() }
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
  @Published var lastAppRequestAt: [UUID: Date] = [:]
  @Published private var appPresence: [UUID: AppPresence] = [:]
  @Published private var activeTransfers: [UUID: Int] = [:]
  @Published private var presenceClock = Date()
  @Published var showPairingQR = false
  @Published var state = Collector.loadState()
  private var server: TransferServer?
  private var pairProcess: Process?

  init() {
    let server = TransferServer(state: state)
    self.server = server
    server.onStatus = { [weak self] message in
      Task { @MainActor in self?.status = message }
    }
    server.onConfirmed = { [weak self] _ in
      Task { @MainActor in
        self?.state = Collector.loadState()
        self?.showPairingQR = false
        self?.status = MacTransferL10n.text("mt_m_01")
      }
    }
    server.onAuthenticatedRequest = { [weak self] deviceID, date in
      Task { @MainActor in self?.lastAppRequestAt[deviceID] = date }
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
      await collectAll()
    }
    Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.collectAll() }
    }
    Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.presenceClock = Date() }
    }
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
    guard state.devices.first(where: { $0.udid == selected.udid }) == nil else { return }
    let new = PairedDevice(udid: selected.udid, name: selected.name, model: selected.model,
      physicalDeviceID: UUID(), secret: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    state.devices.append(new)
    do {
      try Collector.saveState(state)
      server?.update(state: state)
      showPairingQR = true
      status = MacTransferL10n.format("mt_m_05", selected.name)
    } catch { status = MacTransferL10n.format("mt_m_06", error.localizedDescription) }
  }

  var pairingURL: String? {
    guard let pairedSelected else { return nil }
    var components = URLComponents()
    components.scheme = "mochilog-mac"
    components.host = "pair"
    components.queryItems = [
      .init(name: "host", value: state.hostID.uuidString),
      .init(name: "device", value: pairedSelected.physicalDeviceID.uuidString),
      .init(name: "model", value: pairedSelected.model),
      .init(name: "key", value: pairedSelected.secret.base64EncodedString())
    ]
    if let tailnet = server?.activeTailnetAddress {
      components.queryItems?.append(.init(name: "tailnet", value: tailnet))
      components.queryItems?.append(.init(name: "tailnetPort", value: String(TransferServer.tailnetPort)))
    }
    return components.url?.absoluteString
  }

  func collectAll() async {
    guard !state.devices.isEmpty, !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    var savedAny = false
    for device in state.devices {
      do {
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
        SupportDiagnostics.saveCollection(report, error: nil, for: device)
        savedAny = savedAny || report.saved > 0
        if selectedUDID == device.udid { osPairingState = .verified }
        status = report.failed == 0
          ? MacTransferL10n.format("mt_m_08", device.name, report.saved, report.skipped)
          : MacTransferL10n.format("mt_m_09", device.name, report.saved, report.skipped, report.failed, report.lastError ?? "")
      } catch {
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
    case overview, devices, support, settings
    var id: Self { self }
    var titleKey: String {
      switch self {
      case .overview: "mt_nav_overview"
      case .devices: "mt_nav_devices"
      case .support: "mt_022"
      case .settings: "mt_nav_settings"
      }
    }
    var symbol: String {
      switch self {
      case .overview: "square.grid.2x2"
      case .devices: "iphone.gen3"
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
  @AppStorage(MacAppPreferences.menuBarKey) private var showMenuBar = false
  @AppStorage(MacAppPreferences.hideDockKey) private var hideDock = false
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
            Task { await model.collectAll() }
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
      GroupBox(MacTransferL10n.text("mt_nav_connected")) {
        VStack(alignment: .leading, spacing: 12) {
          if model.state.devices.isEmpty {
            Text(MacTransferL10n.text("mt_nav_no_devices"))
              .foregroundStyle(.secondary)
          } else {
            ForEach(model.state.devices) { device in
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
                }
                Spacer()
                if device.confirmedAt != nil {
                  Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    .help(MacTransferL10n.text("mt_paired"))
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
      GroupBox(MacTransferL10n.text("mt_005")) {
        VStack(alignment: .leading, spacing: 10) {
          Text(MacTransferL10n.text("mt_006"))
          Text(MacTransferL10n.text("mt_007"))
          Text(MacTransferL10n.text("mt_008"))
          Text(MacTransferL10n.text("mt_009"))
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
              if !model.isRefreshing {
                Task { await model.verifySelectedOSPairing() }
              }
            }
            Button {
              Task { await model.refresh() }
            } label: { Image(systemName: "arrow.clockwise") }
              .help(MacTransferL10n.text("mt_015"))
          }
          if let selected = model.selected, model.isOSPairingVerified {
            Label(MacTransferL10n.text("mt_os_paired"),
              systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
            if model.pairedSelected == nil {
              Button(MacTransferL10n.text("mt_016")) { model.pairApp() }
                .buttonStyle(.borderedProminent)
            } else if model.pairedSelected?.confirmedAt != nil && !model.showPairingQR {
              HStack {
                Label(MacTransferL10n.text("mt_017"),
                  systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button(MacTransferL10n.text("mt_018")) { model.showPairingQR = true }
              }
            } else if let url = model.pairingURL, let image = QRCode.image(for: url) {
              HStack(alignment: .top, spacing: 20) {
                Image(nsImage: image).interpolation(.none).resizable()
                  .frame(width: 210, height: 210)
                VStack(alignment: .leading, spacing: 8) {
                  Text(selected.name).font(.headline)
                  Text(MacTransferL10n.text("mt_019"))
                  Text(MacTransferL10n.text("mt_020"))
                    .font(.caption).foregroundStyle(.secondary)
                  if model.pairedSelected?.confirmedAt != nil {
                    Button(MacTransferL10n.text("mt_021")) { model.showPairingQR = false }
                  }
                }
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
    .onAppear { Task { await model.refresh() } }
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
          Toggle(MacTransferL10n.text("mt_030"), isOn: $hideDock)
            .disabled(!showMenuBar)
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
