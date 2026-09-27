import SwiftUI

private enum LicenseDocument: String, CaseIterable, Identifiable {
  case mochiLog, collector, sparkle, pythonRuntime, python, notices

  var id: String { rawValue }

  var titleKey: String {
    switch self {
    case .mochiLog: "mt_l_01"
    case .collector: "mt_l_02"
    case .sparkle: "mt_l_03"
    case .pythonRuntime: "mt_l_04"
    case .python: "mt_l_04"
    case .notices: "mt_l_05"
    }
  }

  var title: String {
    self == .pythonRuntime ? "Python 3.13" : MacTransferL10n.text(titleKey)
  }

  var resource: (String, String) {
    switch self {
    case .mochiLog: ("LICENSE-MochiLog", "txt")
    case .collector: ("LICENSE-pymobiledevice3", "txt")
    case .sparkle: ("LICENSE-Sparkle", "txt")
    case .pythonRuntime: ("LICENSE-Python-Runtime", "txt")
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
  @State private var selection = LicenseDocument.mochiLog.rawValue

  private var pythonLicenses: [URL] {
    guard let root = Bundle.main.resourceURL?.appendingPathComponent("PythonLicenses"),
      let urls = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil) else { return [] }
    return urls.filter { $0.pathExtension == "txt" }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
  }

  private var selectedContents: String {
    if let document = LicenseDocument(rawValue: selection) { return document.contents }
    guard let url = pythonLicenses.first(where: { $0.path == selection }),
      let text = try? String(contentsOf: url, encoding: .utf8) else {
      return MacTransferL10n.text("mt_l_06")
    }
    return text
  }

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
            Text(document.title).tag(document.rawValue)
          }
          Section(MacTransferL10n.text("mt_l_04")) {
            ForEach(pythonLicenses, id: \.path) { url in
              Text(url.deletingPathExtension().lastPathComponent).tag(url.path)
            }
          }
        }
        .listStyle(.sidebar)
        .frame(width: 210)
        ScrollView {
          Text(selectedContents)
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
