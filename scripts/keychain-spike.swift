import Foundation
import Security
import LocalAuthentication

// Explicit, opt-in experiment: only a random temporary item in the data-protection
// keychain. No default-keychain lookup, access-list edits, prompts or real profiles.
@main struct KeychainSpike {
    static func main() throws {
        let service = "net.nebula.gui.spike." + UUID().uuidString
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "Spike", code: 1)
        }
        let secret = Data(bytes)
        let context = LAContext(); context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "temporary-spike-item",
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        var add = query; add[kSecValueData as String] = secret
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        var result: [String: Any] = ["schema": 1, "kind": "adhoc_data_protection_keychain_spike", "addStatus": status]
        if status == errSecSuccess {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let read = SecItemCopyMatching(query as CFDictionary, &value)
            result["readStatus"] = read
            result["roundTripMatches"] = read == errSecSuccess && (value as? Data) == secret
            query.removeValue(forKey: kSecReturnData as String)
            query.removeValue(forKey: kSecMatchLimit as String)
            result["deleteStatus"] = SecItemDelete(query as CFDictionary)
        }
        // Never emit item identifiers, keychain contents or random credential bytes.
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]))
        print("")
        if status == errSecSuccess, result["deleteStatus"] as? OSStatus != errSecSuccess {
            throw NSError(domain: "SpikeCleanup", code: 2)
        }
    }
}
