import AppKit
import SwiftUI

struct BatteryLogLibraryView: View {
  @EnvironmentObject private var model: CompanionModel
  @State private var rows: [StoredBatteryLog] = []
  @State private var selected: Set<String> = []
  @State private var search = ""
  @State private var retain = BatteryLogStorage.retainsAfterDelivery
  @State private var limitMB = BatteryLogStorage.limitMB
  @State private var months = BatteryLogStorage.retentionMonths
  @State private var showingDelete = false
  @State private var notice: String?

  private var visibleRows: [StoredBatteryLog] {
    guard !search.isEmpty else { return rows }
    return rows.filter { item in
      [item.deviceName, item.kind, item.name, item.logDay]
        .contains { $0.localizedCaseInsensitiveContains(search) }
    }
  }

  private var selectedRows: [StoredBatteryLog] { rows.filter { selected.contains($0.id) } }
  private var archiveBytes: Int64 { rows.filter { !$0.pending }.reduce(0) { $0 + $1.size } }
  private var pendingBytes: Int64 { rows.filter(\.pending).reduce(0) { $0 + $1.size } }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      GroupBox(MacTransferL10n.text("mt_battery_storage_policy")) {
        VStack(alignment: .leading, spacing: 12) {
          Toggle(MacTransferL10n.text("mt_battery_keep_after_send"), isOn: $retain)
            .onChange(of: retain) { _, value in BatteryLogStorage.retainsAfterDelivery = value }
          Text(MacTransferL10n.text("mt_battery_keep_hint"))
            .font(.caption).foregroundStyle(.secondary)
          HStack(spacing: 18) {
            Stepper(value: $limitMB, in: 100...100_000, step: 100) {
              Text("\(MacTransferL10n.text("mt_battery_limit")): \(limitMB) MB")
            }
            Stepper(value: $months, in: 1...60) {
              Text("\(MacTransferL10n.text("mt_battery_months")): \(months)")
            }
          }
          .onChange(of: limitMB) { _, value in BatteryLogStorage.limitMB = value; refresh() }
          .onChange(of: months) { _, value in BatteryLogStorage.retentionMonths = value; refresh() }
        }
        .padding(8)
      }

      HStack {
        Label("\(MacTransferL10n.text("mt_battery_archive_usage")): \(ByteCountFormatter.string(fromByteCount: archiveBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(limitMB) * 1_000_000, countStyle: .file))",
          systemImage: "externaldrive")
        Spacer()
        Text("\(MacTransferL10n.text("mt_battery_pending_usage")): \(ByteCountFormatter.string(fromByteCount: pendingBytes, countStyle: .file))")
          .foregroundStyle(.secondary)
      }
      HStack {
        TextField(MacTransferL10n.text("mt_battery_search"), text: $search)
          .textFieldStyle(.roundedBorder)
        Button(MacTransferL10n.text("mt_015")) { refresh() }
      }
      List(visibleRows, selection: $selected) { item in
        HStack(spacing: 12) {
          Image(systemName: item.pending ? "arrow.up.circle" : "archivebox")
            .foregroundStyle(item.pending ? .orange : .green)
          VStack(alignment: .leading, spacing: 3) {
            Text(item.deviceName).fontWeight(.medium)
            Text("\(item.logDay) · \(item.kind == "Watch" ? "Apple Watch" : "iPhone / iPad")")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
            .monospacedDigit().foregroundStyle(.secondary)
          Text(MacTransferL10n.text(item.pending ? "mt_battery_pending" : "mt_battery_saved"))
            .font(.caption).foregroundStyle(item.pending ? .orange : .secondary)
        }
        .help(item.name)
        .tag(item.id)
      }
      .frame(minHeight: 260)
      HStack {
        Button(MacTransferL10n.text("mt_battery_export")) { exportSelection() }
          .disabled(selectedRows.isEmpty)
        Button(MacTransferL10n.text("mt_battery_resend")) { resendSelection() }
          .disabled(!selectedRows.contains(where: { !$0.pending }))
        Spacer()
        Button(MacTransferL10n.text("mt_battery_delete"), role: .destructive) {
          showingDelete = true
        }
        .disabled(!selectedRows.contains(where: { !$0.pending }))
      }
      Text(MacTransferL10n.text("mt_battery_pending_hint"))
        .font(.caption).foregroundStyle(.secondary)
      if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
    }
    .onAppear { refresh() }
    .confirmationDialog(MacTransferL10n.text("mt_battery_delete_confirm"),
      isPresented: $showingDelete) {
      Button(MacTransferL10n.text("mt_battery_delete"), role: .destructive) {
        do {
          try BatteryLogStorage.delete(selectedRows)
          selected.removeAll()
          refresh()
        } catch { notice = error.localizedDescription }
      }
    }
  }

  private func refresh() {
    do { try BatteryLogStorage.prune() }
    catch { notice = error.localizedDescription }
    rows = BatteryLogStorage.list(devices: model.state.devices)
    selected.formIntersection(Set(rows.map(\.id)))
  }

  private func exportSelection() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = MacTransferL10n.text("mt_battery_export")
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      try BatteryLogStorage.export(selectedRows, to: destination)
      notice = "\(selectedRows.count) \(MacTransferL10n.text("mt_battery_exported"))"
    } catch { notice = error.localizedDescription }
  }

  private func resendSelection() {
    do {
      let count = try BatteryLogStorage.requeue(selectedRows, devices: model.state.devices)
      model.sendQueuedNow()
      notice = "\(count) \(MacTransferL10n.text("mt_battery_requeued"))"
      refresh()
    } catch { notice = error.localizedDescription }
  }
}
