import AppKit
import Foundation
import SwiftUI

struct MacTransferDebugLogView: View {
  @Environment(\.dismiss) private var dismiss
  let device: PairedDevice?
  @State private var revision = 0
  @State private var selectedDay: String?
  @State private var showingDeleteConfirmation = false

  private var macLog: String {
    _ = revision
    return selectedDay.map { SupportDiagnostics.logText(for: $0) }
      ?? SupportDiagnostics.macLogText()
  }

  private var days: [String] { _ = revision; return SupportDiagnostics.archiveDays() }

  private var phoneLog: String {
    _ = revision
    guard let device, let url = SupportDiagnostics.phoneReport(for: device),
      let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let events = object["recentEvents"] as? [String] else { return "" }
    return events.joined(separator: "\n")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(MacTransferL10n.text("mt_042"))
        .font(.title2.bold())
      Text(MacTransferL10n.text("mt_043"))
        .foregroundStyle(.secondary)
      HStack {
        Picker(MacTransferL10n.text("mt_log_date"), selection: $selectedDay) {
          ForEach(days, id: \.self) { day in Text(day).tag(Optional(day)) }
        }
        .frame(maxWidth: 230)
        Picker(MacTransferL10n.text("mt_log_retention"), selection: Binding(
          get: { SupportDiagnostics.retentionDays },
          set: { SupportDiagnostics.retentionDays = $0; revision += 1;
            selectedDay = days.first }
        )) {
          ForEach([7, 30, 90, 180, 365], id: \.self) { days in
            Text("\(days)").tag(days)
          }
        }
        .frame(maxWidth: 170)
        Spacer()
        Button(MacTransferL10n.text("mt_log_delete"), role: .destructive) {
          showingDeleteConfirmation = true
        }
      }
      HStack(alignment: .top, spacing: 16) {
        logPanel(MacTransferL10n.text("mt_044"), text: macLog)
        logPanel(MacTransferL10n.text("mt_045"), text: phoneLog)
      }
      HStack {
        Button(MacTransferL10n.text("mt_015")) {
          revision += 1
          if selectedDay == nil { selectedDay = days.first }
        }
        Spacer()
        Button(MacTransferL10n.text("mt_037")) { dismiss() }
      }
    }
    .padding(24)
    .frame(minWidth: 760, minHeight: 440)
    .onAppear { selectedDay = days.first }
    .confirmationDialog(MacTransferL10n.text("mt_log_delete_confirm"),
      isPresented: $showingDeleteConfirmation) {
      Button(MacTransferL10n.text("mt_log_delete"), role: .destructive) {
        SupportDiagnostics.deleteLogs()
        revision += 1
        selectedDay = nil
      }
    }
  }

  private func logPanel(_ title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Button(MacTransferL10n.text("mt_046")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }.disabled(text.isEmpty)
      }
      ScrollView {
        Text(text.isEmpty ? (MacTransferL10n.text("mt_047")) : text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
    .frame(maxWidth: .infinity)
  }
}
