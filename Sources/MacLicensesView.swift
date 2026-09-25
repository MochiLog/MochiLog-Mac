import SwiftUI

private enum LicenseDocument: String, CaseIterable, Identifiable {
  case mochiLog, collector, sparkle, python, notices

  var id: String { rawValue }

  var titleKey: String {
    switch self {
    case .mochiLog: "mt_l_01"
    case .collector: "mt_l_02"
    case .sparkle: "mt_l_03"
    case .python: "mt_l_04"
    case .notices: "mt_l_05"
    }
  }

  var resource: (String, String) {
    switch self {
    case .mochiLog: ("LICENSE-MochiLog", "txt")
    case .collector: ("LICENSE-pymobiledevice3", "txt")
    case .sparkle: ("LICENSE-Sparkle", "txt")
    case .python: ("LICENSE-Python-Dependencies", "txt")
    case .notices: ("THIRD_PARTY", "md")
    }
  }

  var contents: String {
    let (name, ext) = resource
    guard let url = Bundle.main.url(forResource: name, withExtension: ext),
      let text = try? String(contentsOf: url, encoding: .utf8) else {
      return MacTransferL10n.text("mt_l_06")
    }
    return text
  }
}

struct MacLicensesView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selection = LicenseDocument.mochiLog

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label(MacTransferL10n.text("mt_l_00"), systemImage: "doc.text")
          .font(.title2.bold())
        Spacer()
        Button(MacTransferL10n.text("mt_037")) { dismiss() }
      }
      HStack(alignment: .top, spacing: 16) {
        List(selection: $selection) {
          ForEach(LicenseDocument.allCases) { document in
            Text(MacTransferL10n.text(document.titleKey)).tag(document)
          }
        }
        .listStyle(.sidebar)
        .frame(width: 210)
        ScrollView {
          Text(selection.contents)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
      }
      .frame(maxHeight: .infinity)
    }
    .padding(24)
    .frame(minWidth: 850, minHeight: 540)
  }
}
