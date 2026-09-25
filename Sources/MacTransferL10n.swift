import Foundation

enum MacTransferL10n {
  static func text(_ key: String) -> String {
    NSLocalizedString(key, tableName: "MacTransfer", bundle: .main, value: key, comment: "")
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: .current, arguments: arguments)
  }
}
