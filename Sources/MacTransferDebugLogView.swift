import AppKit
import Foundation
import SwiftUI

struct MacTransferDebugLogView: View {
  @Environment(\.dismiss) private var dismiss
  let device: PairedDevice?
  @State private var revision = 0
  @State private var selectedDay: String?
  @State private var selectedPhoneDay: String?
  @State private var days: [String] = []
  @State private var phoneDays: [String] = []
  @State private var retentionDays = SupportDiagnostics.retentionDays
  @State private var showingDeleteConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(MacTransferL10n.text("mt_042")).font(.title2.bold())
      Text(MacTransferL10n.text("mt_043")).foregroundStyle(.secondary)
      HStack {
        Picker(MacTransferL10n.text("mt_log_retention"), selection: $retentionDays) {
          ForEach([7, 30, 90, 180, 365], id: \.self) { Text("\($0)").tag($0) }
        }.frame(maxWidth: 170)
        Spacer()
        Button(MacTransferL10n.text("mt_log_delete"), role: .destructive) {
          showingDeleteConfirmation = true
        }
      }
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          dayPicker(days, selection: $selectedDay)
          DiagnosticLogPanel(title: MacTransferL10n.text("mt_044"),
            day: selectedDay, device: nil, revision: revision)
        }
        VStack(alignment: .leading, spacing: 8) {
          dayPicker(phoneDays, selection: $selectedPhoneDay)
          DiagnosticLogPanel(title: MacTransferL10n.text("mt_045"),
            day: selectedPhoneDay, device: device, revision: revision, isPhone: true)
        }
      }
      HStack {
        Button(MacTransferL10n.text("mt_015")) { revision += 1 }
        Spacer()
        Button(MacTransferL10n.text("mt_037")) { dismiss() }
      }
    }
    .padding(24)
    .frame(minWidth: 760, minHeight: 440)
    .task(id: revision) {
      let device = device
      let catalog = await Task.detached(priority: .userInitiated) {
        (SupportDiagnostics.archiveDays(),
          device.map { SupportDiagnostics.phoneArchiveDays(for: $0) } ?? [])
      }.value
      guard !Task.isCancelled else { return }
      days = catalog.0
      phoneDays = catalog.1
      if selectedDay == nil || !days.contains(selectedDay!) { selectedDay = days.first }
      if selectedPhoneDay == nil || !phoneDays.contains(selectedPhoneDay!) {
        selectedPhoneDay = phoneDays.first
      }
    }
    .onChange(of: retentionDays) { _, value in
      Task {
        await Task.detached { SupportDiagnostics.retentionDays = value }.value
        revision += 1
      }
    }
    .confirmationDialog(MacTransferL10n.text("mt_log_delete_confirm"),
      isPresented: $showingDeleteConfirmation) {
      Button(MacTransferL10n.text("mt_log_delete"), role: .destructive) {
        Task {
          await Task.detached { SupportDiagnostics.deleteLogs() }.value
          revision += 1
        }
      }
    }
  }

  private func dayPicker(_ days: [String], selection: Binding<String?>) -> some View {
    Picker(MacTransferL10n.text("mt_log_date"), selection: selection) {
      if days.isEmpty { Text("—").tag(Optional<String>.none) }
      ForEach(days, id: \.self) { Text($0).tag(Optional($0)) }
    }.frame(maxWidth: 230)
  }
}

/// The body uses only a loaded snapshot. Archive I/O and category parsing never
/// run during layout, and a cancelled date selection cannot replace newer data.
private struct DiagnosticLogPanel: View {
  let title: String
  let day: String?
  let device: PairedDevice?
  let revision: Int
  var isPhone = false
  @State private var category: String?
  @State private var loadedCategories: [String] = []
  @State private var fullText = ""
  @State private var pages: [String] = []
  @State private var page = 0
  @State private var loading = true

  private struct Request: Hashable {
    let day: String?
    let deviceID: UUID?
    let revision: Int
    let category: String?
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(MacTransferL10n.text("mt_log_category"), selection: $category) {
        Text(MacTransferL10n.text("mt_log_all")).tag(Optional<String>.none)
        ForEach(loadedCategories, id: \.self) { value in
          Text(MacTransferL10n.text("mt_log_" + value.replacingOccurrences(of: "-", with: "_")))
            .tag(Optional(value))
        }
      }.frame(maxWidth: 280)
      HStack {
        Text(title).font(.headline)
        Spacer()
        Button(MacTransferL10n.text("mt_046")) {
          NSPasteboard.general.clearContents()
          // Copy the complete selected category, never just the displayed page.
          NSPasteboard.general.setString(fullText, forType: .string)
        }.disabled(loading || fullText.isEmpty)
      }
      ScrollView {
        if loading {
          ProgressView(MacTransferL10n.text("mt_log_loading")).padding()
        } else {
          Text(pages.indices.contains(page) ? pages[page] : MacTransferL10n.text("mt_047"))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
      }
      .id(page)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
      HStack {
        Button(MacTransferL10n.text("mt_log_previous")) { page -= 1 }
          .disabled(loading || page == 0)
        Spacer()
        Text(String(format: MacTransferL10n.text("mt_log_page"),
          pages.isEmpty ? 0 : page + 1, pages.count)).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(MacTransferL10n.text("mt_log_next")) { page += 1 }
          .disabled(loading || page + 1 >= pages.count)
      }
    }
    .frame(maxWidth: .infinity)
    .onChange(of: day) { category = nil }
    .task(id: Request(day: day, deviceID: device?.physicalDeviceID,
      revision: revision, category: category)) {
      loading = true
      let day = day, device = device, isPhone = isPhone, category = category
      let snapshot = await Task.detached(priority: .userInitiated) {
        let raw: String
        if isPhone {
          if let device, let day { raw = SupportDiagnostics.phoneLogText(for: device, day: day) }
          else if let device, let url = SupportDiagnostics.phoneReport(for: device),
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let events = object["recentEvents"] as? [String] { raw = events.joined(separator: "\n") }
          else { raw = "" }
        } else { raw = day.map { SupportDiagnostics.logText(for: $0) } ?? SupportDiagnostics.macLogText() }
        let filtered = DiagnosticLogViewer.text(raw, category: category)
        return (DiagnosticLogViewer.categories(in: raw), filtered,
          DiagnosticLogViewer.pages(filtered))
      }.value
      guard !Task.isCancelled else { return }
      loadedCategories = snapshot.0
      fullText = snapshot.1
      pages = snapshot.2
      page = 0
      loading = false
    }
  }
}
