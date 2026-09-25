import AppKit
import SwiftUI

struct MacTransferSupportView: View {
  @Environment(\.dismiss) private var dismiss
  let device: PairedDevice
  @State private var nickname = ""
  @State private var email = ""
  @State private var message = ""
  @State private var errorMessage: String?
  private var japanese: Bool { Locale.preferredLanguages.first?.hasPrefix("ja") == true }
  private var valid: Bool {
    [nickname, email, message].allSatisfy {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(japanese ? "Mac連携のサポート" : "Mac transfer support")
        .font(.title2.bold())
      Text(japanese
        ? "この機能はベータ版です。解決に時間がかかる場合があり、個別に返信できない場合もあります。"
        : "This feature is in beta. A fix may take time, and we may not be able to reply individually.")
        .foregroundStyle(.secondary)
      TextField(japanese ? "ニックネーム" : "Nickname", text: $nickname)
      TextField(japanese ? "返信先メールアドレス" : "Reply email", text: $email)
        .textContentType(.emailAddress)
      Text(japanese ? "発生した問題・再現手順" : "Problem and steps to reproduce")
      TextEditor(text: $message)
        .frame(height: 130)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
      Label(japanese
        ? "Macの診断情報と、このMacが最後に受け取ったiPhoneの診断情報を添付します。解析ログの本文やペアリングの秘密鍵は含めません。"
        : "The Mac report and the latest iPhone report received by this Mac are attached. Raw analytics logs and pairing secrets are excluded.",
        systemImage: "doc.text")
        .font(.callout).foregroundStyle(.secondary)
      if SupportDiagnostics.phoneReport(for: device) == nil {
        Text(japanese
          ? "iPhoneの診断情報はまだ届いていません。iPhoneでMochiLogを開いてMacに接続すると添付されます。"
          : "No iPhone diagnostics have arrived yet. Open MochiLog on the iPhone and connect to this Mac to include them.")
          .font(.caption).foregroundStyle(.orange)
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button(japanese ? "閉じる" : "Close") { dismiss() }
        Button(japanese ? "メールを作成" : "Compose email") { compose() }
          .buttonStyle(.borderedProminent)
          .disabled(!valid)
      }
    }
    .padding(24)
    .frame(width: 560)
  }

  private func compose() {
    guard let service = NSSharingService(named: .composeEmail) else {
      errorMessage = japanese ? "メール作成アプリを利用できません。" : "No email composer is available."
      return
    }
    do {
      let attachments = try SupportDiagnostics.mailAttachments(for: device)
      service.recipients = ["support@mochilog.ryuya-dev.net"]
      service.subject = "[MochiLog Mac] \(japanese ? "Mac連携ベータ" : "Mac transfer beta")"
      let body = """
      \(japanese ? "ニックネーム" : "Nickname"): \(nickname)
      \(japanese ? "返信先" : "Reply email"): \(email)
      \(japanese ? "機種" : "Device model"): \(device.model)

      \(japanese ? "問題・再現手順" : "Problem and steps to reproduce"):
      \(message)
      """
      service.perform(withItems: [body] + attachments)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
