import Foundation
import Security

enum Keychain {
    private static let service = "com.nathanjiang.LectureNotes"

    #if DEBUG
    private static let isDebugHarness = CommandLine.arguments.contains { $0 == "--snapshot" || $0 == "--demo-busy" || $0 == "--whisper" }
    #endif

    static func get(_ account: String) -> String? {
        #if DEBUG
        if isDebugHarness { return nil }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        #if DEBUG
        if isDebugHarness { return }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
