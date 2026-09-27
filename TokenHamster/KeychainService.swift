//
//  KeychainService.swift
//  TokenHamster
//
//  Created by Oscar Sun on 2026/7/16.
//
//  安全存储：使用 macOS Keychain 加密保管 API 配置 & Key
//  替代 UserDefaults / iCloud KVS 明文存储
//

import Foundation
import Security

final class KeychainService {

    static let shared = KeychainService()
    private init() {}

    // MARK: - 保存/读取/删除 JSON 数据

    /// 将 Codable 对象加密写入 Keychain
    func save<T: Codable>(_ value: T, forKey key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return saveData(data, forKey: key)
    }

    /// 从 Keychain 读取并解码为 Codable 对象
    func load<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = loadData(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// 从 Keychain 删除
    func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String:     kSecClassGenericPassword,
            kSecAttrService as String: "TokenHamster",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 清空所有 TokenHamster 条目
    func clearAll() {
        let query: [String: Any] = [
            kSecClass as String:     kSecClassGenericPassword,
            kSecAttrService as String: "TokenHamster",
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 底层 Security API

    private func saveData(_ data: Data, forKey key: String) -> Bool {
        // 先尝试删除旧的
        delete(forKey: key)

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "TokenHamster",
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func loadData(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "TokenHamster",
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}
