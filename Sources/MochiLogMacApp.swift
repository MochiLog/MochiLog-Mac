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
        .frame(minWidth: 680, minHeight: 660)
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
    Button(MacTransferL10n.text("mt_002")) {
      checkForUpdates()
    }
    Divider()
    Text(model.status)
    Divider()
    Button(MacTransferL10n.text("mt_003")) { NSApp.terminate(nil) }
  }
}

@MainActor
final class CompanionModel: ObservableObject {
  @Published var devices: [ConnectedDevice] = []
  @Published var selectedUDID: String?
  @Published var status = "端末を検索してください" {
    didSet { if status != oldValue { SupportDiagnostics.record(status) } }
  }
  @Published var pairingCode: String?
  @Published var isPairingSystem = false
  @Published var isBusy = false
  @Published var collectionDone = 0
  @Published var collectionTotal = 0
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
        self?.status = "iPhoneとのペアリングが完了しました"
      }
    }
    do { try server.start() }
    catch { status = "転送待機を開始できません: \(error.localizedDescription)" }
    Task {
      await refresh()
      await collectAll()
    }
    Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.collectAll() }
    }
  }

  var selected: ConnectedDevice? { devices.first { $0.udid == selectedUDID } }
  var pairedSelected: PairedDevice? { state.devices.first { $0.udid == selectedUDID } }

  func refresh() async {
    isBusy = true
    defer { isBusy = false }
    do {
      devices = try await Task.detached(priority: .utility) { try Collector.browse() }.value
      status = "\(devices.count)台の端末が見つかりました"
      if selectedUDID == nil { selectedUDID = devices.first?.udid }
    } catch { status = "端末検索に失敗: \(error.localizedDescription)" }
  }

  func pairApp() {
    guard let selected else { return }
    guard state.devices.first(where: { $0.udid == selected.udid }) == nil else { return }
    let new = PairedDevice(udid: selected.udid, name: selected.name, model: selected.model,
      physicalDeviceID: UUID(), secret: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    state.devices.append(new)
    do {
      try Collector.saveState(state)
      server?.update(state: state)
      showPairingQR = true
      status = "\(selected.name)のQRコードをiPhoneで読み取ってください"
    } catch { status = "ペアリング情報を保存できません: \(error.localizedDescription)" }
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
    return components.url?.absoluteString
  }

  func collectAll() async {
    guard !state.devices.isEmpty else { return }
    isBusy = true
    defer { isBusy = false }
    for device in state.devices {
      do {
        collectionDone = 0
        collectionTotal = 0
        let report = try await Task.detached(priority: .utility) { [weak self] in
          try Collector.collect(device) { done, total in
            Task { @MainActor [weak self] in
              self?.collectionDone = done
              self?.collectionTotal = total
              self?.status = "\(device.name): \(done)/\(total)件を取得"
            }
          }
        }.value
        SupportDiagnostics.saveCollection(report, error: nil, for: device)
        status = report.failed == 0
          ? "\(device.name): 電池ログ\(report.saved)件保存、対象外\(report.skipped)件を除外"
          : "\(device.name): \(report.saved)件保存、対象外\(report.skipped)件、取得失敗\(report.failed)件。次回再試行します。\(report.lastError ?? "")"
      } catch {
        SupportDiagnostics.saveCollection(nil, error: error, for: device)
        status = "\(device.name): \(error.localizedDescription)"
      }
    }
  }

  func startSystemPairing() {
    guard !isPairingSystem else { return }
    guard let helper = Bundle.main.url(forResource: "pymobiledevice3", withExtension: nil,
      subdirectory: "Collector") else {
      status = "同梱のログ収集ツールがありません"
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
    status = "iPhoneの『設定 → デベロッパ → ペアリング済みMac』を開いてください"
    do { try process.run() }
    catch {
      isPairingSystem = false
      status = "OSペアリングを開始できません: \(error.localizedDescription)"
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
          ? "Macと端末のOSペアリングが完了しました。端末を検索してください。"
          : "OSペアリングが完了しませんでした。条件を確認して再試行してください。"
        Task { [weak self] in await self?.refresh() }
      }
    }
  }

  func stopSystemPairing() { pairProcess?.terminate() }
}

private struct CompanionView: View {
  let checkForUpdates: () -> Void
  @EnvironmentObject private var model: CompanionModel
  @State private var showingSupport = false
  @State private var showingDebugLog = false
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
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Image(systemName: "iphone.and.arrow.forward")
            .font(.largeTitle).foregroundStyle(.green)
          VStack(alignment: .leading) {
            Text("MochiLog Mac").font(.largeTitle.bold())
            Text(MacTransferL10n.text("mt_004"))
              .foregroundStyle(.secondary)
          }
        }
        GroupBox(MacTransferL10n.text("mt_005")) {
          VStack(alignment: .leading, spacing: 9) {
            Text(MacTransferL10n.text("mt_006"))
            Text(MacTransferL10n.text("mt_007"))
            Text(MacTransferL10n.text("mt_008"))
            Text(MacTransferL10n.text("mt_009"))
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        HStack {
          Button(model.isPairingSystem ? (MacTransferL10n.text("mt_010"))
            : (MacTransferL10n.text("mt_011"))) {
              model.isPairingSystem ? model.stopSystemPairing() : model.startSystemPairing()
            }
          if let code = model.pairingCode {
            Text(code).font(.system(size: 26, weight: .bold, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        GroupBox(MacTransferL10n.text("mt_012")) {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Picker(MacTransferL10n.text("mt_013"), selection: $model.selectedUDID) {
                Text(MacTransferL10n.text("mt_014")).tag(String?.none)
                ForEach(model.devices) { device in
                  Text("\(device.name) (\(device.model))").tag(Optional(device.udid))
                }
              }
              Button(MacTransferL10n.text("mt_015")) { Task { await model.refresh() } }
            }
            if let selected = model.selected {
              if model.pairedSelected == nil {
                Button(MacTransferL10n.text("mt_016")) {
                  model.pairApp()
                }
              } else if model.pairedSelected?.confirmedAt != nil && !model.showPairingQR {
                HStack {
                  Label(MacTransferL10n.text("mt_017"),
                    systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                  Button(MacTransferL10n.text("mt_018")) {
                    model.showPairingQR = true
                  }
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
                      Button(MacTransferL10n.text("mt_021")) {
                        model.showPairingQR = false
                      }
                    }
                  }
                }
              }
            }
          }.padding(8)
        }
        HStack {
          Button(MacTransferL10n.text("mt_001")) {
            Task { await model.collectAll() }
          }.disabled(model.isBusy || model.state.devices.isEmpty)
          if model.isBusy { ProgressView() }
          if model.isBusy && model.collectionTotal > 0 {
            ProgressView(value: Double(model.collectionDone), total: Double(model.collectionTotal))
              .frame(width: 160)
            Text("\(model.collectionDone)/\(model.collectionTotal)")
              .monospacedDigit()
          }
          Text(model.status).foregroundStyle(.secondary).textSelection(.enabled)
        }
        GroupBox(MacTransferL10n.text("mt_022")) {
          VStack(alignment: .leading, spacing: 8) {
            Text(MacTransferL10n.text("mt_023"))
            HStack {
              Picker(MacTransferL10n.text("mt_024"), selection: $supportDeviceID) {
                Text(MacTransferL10n.text("mt_014")).tag(String?.none)
                ForEach(model.state.devices) { device in
                  Text("\(device.name) (\(device.model))").tag(Optional(device.udid))
                }
              }.frame(maxWidth: 320)
              Spacer()
              Button(MacTransferL10n.text("mt_025")) {
                showingSupport = true
              }.disabled(supportDevice == nil)
              Button(MacTransferL10n.text("mt_026")) {
                showingDebugLog = true
              }
            }
          }.padding(8)
            .onAppear {
              if supportDeviceID == nil { supportDeviceID = model.state.devices.first?.udid }
            }
        }
        GroupBox(MacTransferL10n.text("mt_027")) {
          VStack(alignment: .leading, spacing: 10) {
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
            Toggle(MacTransferL10n.text("mt_030"),
              isOn: $hideDock)
              .disabled(!showMenuBar)
            Button(MacTransferL10n.text("mt_002")) {
              checkForUpdates()
            }
            if let preferencesError { Text(preferencesError).foregroundStyle(.red) }
          }.padding(8)
        }
      }.padding(24)
    }
    .sheet(isPresented: $showingSupport) {
      if let device = supportDevice {
        MacTransferSupportView(device: device)
      }
    }
    .sheet(isPresented: $showingDebugLog) {
      MacTransferDebugLogView(device: supportDevice)
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
