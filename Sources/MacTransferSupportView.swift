import AppKit
import SwiftUI

struct MacTransferSupportView: View {
  @Environment(\.dismiss) private var dismiss
  let device: PairedDevice
  @State private var nickname = ""
  @State private var email = ""
  @State private var message = ""
  @State private var errorMessage: String?
  private var valid: Bool {
    [nickname, email, message].allSatisfy {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(MacTransferL10n.text("mt_022"))
        .font(.title2.bold())
      Text(MacTransferL10n.text("mt_031"))
        .foregroundStyle(.secondary)
      TextField(MacTransferL10n.text("mt_032"), text: $nickname)
      TextField(MacTransferL10n.text("mt_033"), text: $email)
        .textContentType(.emailAddress)
      Text(MacTransferL10n.text("mt_034"))
      TextEditor(text: $message)
        .frame(height: 130)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
      Label(MacTransferL10n.text("mt_035"),
        systemImage: "doc.text")
        .font(.callout).foregroundStyle(.secondary)
      if SupportDiagnostics.phoneReport(for: device) == nil {
        Text(MacTransferL10n.text("mt_036"))
          .font(.caption).foregroundStyle(.orange)
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button(MacTransferL10n.text("mt_037")) { dismiss() }
        Button(MacTransferL10n.text("mt_038")) { compose() }
          .buttonStyle(.borderedProminent)
          .disabled(!valid)
      }
    }
    .padding(24)
    .frame(width: 560)
  }

  private func compose() {
    guard let service = NSSharingService(named: .composeEmail) else {
      errorMessage = MacTransferL10n.text("mt_039")
      return
    }
    do {
      let attachments = try SupportDiagnostics.mailAttachments(for: device)
      service.recipients = ["support@mochilog.ryuya-dev.net"]
      service.subject = "[MochiLog Mac] \(MacTransferL10n.text("mt_040"))"
      let body = """
      \(MacTransferL10n.text("mt_032")): \(nickname)
      \(MacTransferL10n.text("mt_033")): \(email)
      \(MacTransferL10n.text("mt_041")): \(device.model)

      \(MacTransferL10n.text("mt_034")):
      \(message)
      """
      service.perform(withItems: [body] + attachments)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
