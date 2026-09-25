import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import SwiftUI

@main
struct MochiLogMacApp: App {
  @StateObject private var model = CompanionModel()

  var body: some Scene {
    WindowGroup {
      CompanionView()
        .environmentObject(model)
        .frame(minWidth: 680, minHeight: 660)
    }
    .windowResizability(.contentSize)
  }
}

@MainActor
final class CompanionModel: ObservableObject {
  @Published var devices: [ConnectedDevice] = []
  @Published var selectedUDID: String?
  @Published var status = "端末を検索してください"
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
        status = report.failed == 0
          ? "\(device.name): 電池ログ\(report.saved)件保存、対象外\(report.skipped)件を除外"
          : "\(device.name): \(report.saved)件保存、対象外\(report.skipped)件、取得失敗\(report.failed)件。次回再試行します。\(report.lastError ?? "")"
      } catch {
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
  @EnvironmentObject private var model: CompanionModel
  private var japanese: Bool { Locale.preferredLanguages.first?.hasPrefix("ja") == true }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Image(systemName: "iphone.and.arrow.forward")
            .font(.largeTitle).foregroundStyle(.green)
          VStack(alignment: .leading) {
            Text("MochiLog Mac").font(.largeTitle.bold())
            Text(japanese ? "ワイヤレスログ転送 · ベータ" : "Wireless log transfer · Beta")
              .foregroundStyle(.secondary)
          }
        }
        GroupBox(japanese ? "利用条件と最初の設定" : "Requirements and first setup") {
          VStack(alignment: .leading, spacing: 9) {
            Text(japanese
              ? "1. macOS 27 / iOS 27、同じWi-Fi、Bluetoothを使用します。iPhoneのロックを解除してください。"
              : "1. Use macOS 27 and iOS 27, the same Wi-Fi, and Bluetooth. Unlock the iPhone.")
            Text(japanese
              ? "2. 初回のみ、iPhoneでデベロッパモードをオンにし、『設定 → デベロッパ → ペアリング済みMac』でこのMacを選びます。下の6桁コードを入力します。OSペアリング後はオフに戻せます。"
              : "2. For first pairing only, enable Developer Mode and open Settings → Developer → Paired Macs. Choose this Mac and enter the six-digit code below. You may turn Developer Mode off afterwards.")
            Text(japanese
              ? "3. 端末を検索して選び、MochiLogのペアリングを作成します。iPhoneアプリの『Mac連携』でQRを読み取ります。"
              : "3. Refresh and select the device, create MochiLog pairing, then scan its QR in the iPhone app's Mac transfer screen.")
            Text(japanese
              ? "4. 解析ログはiPhoneのロック解除中にのみ収集できます。Macが起動中なら定期収集し、iPhoneでMochiLogを開くと受信・解析します。"
              : "4. Analytics logs can be collected only while the iPhone is unlocked. The Mac collects periodically while open; open MochiLog on the iPhone to receive and import.")
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        HStack {
          Button(model.isPairingSystem ? (japanese ? "待機を中止" : "Stop pairing")
            : (japanese ? "OSペアリングを開始" : "Start OS pairing")) {
              model.isPairingSystem ? model.stopSystemPairing() : model.startSystemPairing()
            }
          if let code = model.pairingCode {
            Text(code).font(.system(size: 26, weight: .bold, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        GroupBox(japanese ? "端末とMochiLogのペアリング" : "Devices and MochiLog pairing") {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Picker(japanese ? "端末" : "Device", selection: $model.selectedUDID) {
                Text(japanese ? "選択してください" : "Select a device").tag(String?.none)
                ForEach(model.devices) { device in
                  Text("\(device.name) (\(device.model))").tag(Optional(device.udid))
                }
              }
              Button(japanese ? "再検索" : "Refresh") { Task { await model.refresh() } }
            }
            if let selected = model.selected {
              if model.pairedSelected == nil {
                Button(japanese ? "MochiLogペアリングを作成" : "Create MochiLog pairing") {
                  model.pairApp()
                }
              } else if model.pairedSelected?.confirmedAt != nil && !model.showPairingQR {
                HStack {
                  Label(japanese ? "iPhoneとペアリング済み" : "Paired with iPhone",
                    systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                  Button(japanese ? "QRを再表示" : "Show QR again") {
                    model.showPairingQR = true
                  }
                }
              } else if let url = model.pairingURL, let image = QRCode.image(for: url) {
                HStack(alignment: .top, spacing: 20) {
                  Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: 210, height: 210)
                  VStack(alignment: .leading, spacing: 8) {
                    Text(selected.name).font(.headline)
                    Text(japanese ? "このQRは選択した端末専用です。iPhoneのMochiLogで読み取ってください。再インストール後も同じ個体IDを復元できます。"
                      : "This QR belongs to the selected device. Scan it in MochiLog. The same device ID is restored after reinstalling the iPhone app.")
                    Text(japanese ? "QRには秘密鍵が含まれます。公開・共有しないでください。"
                      : "The QR contains a secret key. Do not publish or share it.")
                      .font(.caption).foregroundStyle(.secondary)
                    if model.pairedSelected?.confirmedAt != nil {
                      Button(japanese ? "QRを隠す" : "Hide QR") {
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
          Button(japanese ? "今すぐログを収集" : "Collect logs now") {
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
      }.padding(24)
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
