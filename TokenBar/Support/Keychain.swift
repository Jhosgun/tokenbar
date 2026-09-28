import Foundation
import OSLog
import Security

/// Wrapper mínimo sobre el llavero de macOS para los secretos de TokenBar.
///
/// Nunca lanza ni propaga errores: en caso de fallo devuelve `nil` y deja constancia
/// en el log. Los valores se guardan como `kSecClassGenericPassword` bajo el service
/// `com.local.tokenbar`, usando la llave lógica como `kSecAttrAccount`.
enum Keychain {
    /// Service compartido por todas las entradas de la app (ver CONTRACT.md §10).
    static let service = "com.local.tokenbar"

    private static let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "keychain")

    /// Guarda `value` bajo `key`. Pasar `nil` (o cadena vacía) borra la entrada.
    static func set(_ value: String?, forKey key: String) {
        guard let value, !value.isEmpty else {
            delete(forKey: key)
            return
        }
        guard let data = value.data(using: .utf8) else {
            log.error("valor no codificable en UTF-8 para \(key, privacy: .public)")
            return
        }

        let status = SecItemUpdate(query(forKey: key) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return

        case errSecItemNotFound:
            var item = query(forKey: key)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus != errSecSuccess {
                log.error("SecItemAdd falló para \(key, privacy: .public): \(addStatus)")
            }

        default:
            log.error("SecItemUpdate falló para \(key, privacy: .public): \(status)")
        }
    }

    /// Devuelve el valor guardado bajo `key`, o `nil` si no existe o hubo error.
    static func get(forKey key: String) -> String? {
        var item = query(forKey: key)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                log.error("SecItemCopyMatching falló para \(key, privacy: .public): \(status)")
            }
            return nil
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Lee una entrada de OTRA app (service distinto al nuestro), como las credenciales
    /// que Claude Code guarda bajo `Claude Code-credentials`.
    ///
    /// La primera vez macOS le pregunta al usuario si autoriza el acceso; si lo deniega,
    /// esto devuelve `nil` y el proveedor reporta "no configurado". Nunca bloquea al usuario.
    static func readForeign(service: String) -> String? {
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        item[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                log.debug("sin acceso a \(service, privacy: .public): \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(forKey key: String) {
        let status = SecItemDelete(query(forKey: key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("SecItemDelete falló para \(key, privacy: .public): \(status)")
        }
    }

    private static func query(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
