import Foundation

enum MacTransferL10n {
  static func text(_ key: String) -> String {
    NSLocalizedString(key, tableName: "MacTransfer", bundle: .main, value: key, comment: "")
  }
}
