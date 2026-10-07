// WifiPasswords.swift. Wi-Fi passwords the phone dashboard may switch with. CoreWLAN can't use
// the passwords macOS already saved (associating without one fails with kCWInvalidParameterErr),
// so Sleepless keeps its own copy, one login-keychain item per network, for the networks you
// choose. Items are tied to Sleepless's signature, so reading them never prompts as long as the
// app is signed by the same certificate (see build.sh). Reads still happen off the main thread:
// if a re-signed build does trigger a keychain prompt, only that switch waits on it.
import Foundation
import Security

enum WifiPasswords {
    private static let service = "com.aboudjem.Sleepless.wifi"

    static func read(ssid: String) -> String? {
        var query = baseQuery(ssid: ssid)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(ssid: String, password: String) -> Bool {
        remove(ssid: ssid)
        var attributes = baseQuery(ssid: ssid)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrLabel as String] = "Sleepless Wi-Fi: \(ssid)"
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func remove(ssid: String) {
        SecItemDelete(baseQuery(ssid: ssid) as CFDictionary)
    }

    static func savedSSIDs() -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return Set(list.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    private static func baseQuery(ssid: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: ssid]
    }
}
