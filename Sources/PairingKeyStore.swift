import Foundation
import Security

enum PairingKeyStore {
  private static let service = "net.ryuya-dev.MochiLog.mac-pairing"

  #if TRANSFER_TESTING
  private static var testKeys: [UUID: Data] = [:]
  #endif

  static func load(for id: UUID) -> Data? {
    #if TRANSFER_TESTING
    return testKeys[id]
    #else
    var query = baseQuery(for: id)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let key = item as? Data, key.count == 32 else { return nil }
    return key
    #endif
  }

  static func save(_ key: Data, for id: UUID) throws {
    guard key.count == 32 else { throw CollectorError.failed("Invalid pairing key") }
    #if TRANSFER_TESTING
    testKeys[id] = key
    #else
    let query = baseQuery(for: id)
    let update = [kSecValueData as String: key]
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var insertion = query
      insertion[kSecValueData as String] = key
      guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
        throw CollectorError.failed("Could not save pairing key in Keychain")
      }
    } else if status != errSecSuccess {
      throw CollectorError.failed("Could not update pairing key in Keychain")
    }
    #endif
  }

  private static func baseQuery(for id: UUID) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id.uuidString]
  }
}
