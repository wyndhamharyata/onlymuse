import CommonCrypto
import Foundation
import Security
import SQLite3

// The youtube.com cookies of the Helium browser. Google refuses a sign-in inside an app's own web page, so
// onlymuse uses the sign-in Helium already has. Helium is Chromium, which encrypts each cookie with AES-128 and a
// key made from a password it keeps in the Keychain. macOS asks the person once before the helper reads it.
enum HeliumCookies {
  struct Cookie {
    let host: String
    let name: String
    let value: String
    let path: String
    let isSecure: Bool
    let isHTTPOnly: Bool
  }

  private static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/net.imput.helium/Default/Cookies")
  private static let keychainService = "Helium Storage Key"
  private static let keychainAccount = "Helium"
  // Chromium's own values for macOS, in os_crypt.
  private static let salt = "saltysalt"
  private static let keyRounds: UInt32 = 1003
  private static let keyLength = 16
  private static let encryptedPrefix = "v10"
  // From database version 24, Chromium puts the SHA-256 of the cookie's host before its value.
  private static let hostHashVersion = 24
  private static let hostHashLength = 32

  enum Failure: Error {
    case noDatabase
    case noKey
  }

  // Blocks while macOS asks for the Keychain, so it runs off the main thread.
  static func readYouTubeCookies() -> Result<[Cookie], Failure> {
    guard let password = readKeychainPassword() else { return .failure(.noKey) }
    guard let rows = readRows() else { return .failure(.noDatabase) }

    let key = toKey(password: password)
    let cookies = rows.cookies.compactMap { row -> Cookie? in
      guard let value = decrypt(row.encrypted, key: key, hasHostHash: rows.version >= hostHashVersion) else { return nil }

      return Cookie(host: row.host, name: row.name, value: value, path: row.path, isSecure: row.isSecure, isHTTPOnly: row.isHTTPOnly)
    }

    return .success(cookies)
  }

  private static func readKeychainPassword() -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
    ]
    var result: CFTypeRef?

    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }

    return result as? Data
  }

  private struct Row {
    let host: String
    let name: String
    let encrypted: Data
    let path: String
    let isSecure: Bool
    let isHTTPOnly: Bool
  }

  // Helium writes the file while it runs, so the helper reads a copy.
  private static func readRows() -> (version: Int, cookies: [Row])? {
    let copyURL = FileManager.default.temporaryDirectory.appending(path: "onlymuse-helium-cookies.sqlite")

    try? FileManager.default.removeItem(at: copyURL)
    guard (try? FileManager.default.copyItem(at: databaseURL, to: copyURL)) != nil else { return nil }
    defer { try? FileManager.default.removeItem(at: copyURL) }

    var database: OpaquePointer?

    guard sqlite3_open_v2(copyURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_close(database) }

    let version = Int(readText(database, "select value from meta where key = 'version'").first?.first ?? "") ?? 0
    var statement: OpaquePointer?
    let sql = "select host_key, name, encrypted_value, path, is_secure, is_httponly from cookies where host_key = 'youtube.com' or host_key like '%.youtube.com'"

    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }

    var rows: [Row] = []

    while sqlite3_step(statement) == SQLITE_ROW {
      let bytes = sqlite3_column_blob(statement, 2)
      let count = Int(sqlite3_column_bytes(statement, 2))
      let encrypted = bytes.map { Data(bytes: $0, count: count) } ?? Data()

      rows.append(Row(
        host: String(cString: sqlite3_column_text(statement, 0)),
        name: String(cString: sqlite3_column_text(statement, 1)),
        encrypted: encrypted,
        path: String(cString: sqlite3_column_text(statement, 3)),
        isSecure: sqlite3_column_int(statement, 4) != 0,
        isHTTPOnly: sqlite3_column_int(statement, 5) != 0
      ))
    }

    return (version, rows)
  }

  private static func readText(_ database: OpaquePointer?, _ sql: String) -> [[String]] {
    var statement: OpaquePointer?

    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }

    var rows: [[String]] = []

    while sqlite3_step(statement) == SQLITE_ROW {
      rows.append([sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""])
    }

    return rows
  }

  // PBKDF2 with SHA-1, as Chromium makes its cookie key on macOS.
  private static func toKey(password: Data) -> Data {
    var key = Data(count: keyLength)
    let saltBytes = Array(salt.utf8)

    key.withUnsafeMutableBytes { keyBuffer in
      password.withUnsafeBytes { passwordBuffer in
        _ = CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2),
          passwordBuffer.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
          saltBytes, saltBytes.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), keyRounds,
          keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength
        )
      }
    }

    return key
  }

  // AES-128-CBC, with 16 spaces as the IV, after the "v10" mark.
  private static func decrypt(_ encrypted: Data, key: Data, hasHostHash: Bool) -> String? {
    guard encrypted.starts(with: Data(encryptedPrefix.utf8)) else { return nil }

    let body = encrypted.dropFirst(encryptedPrefix.count)
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var plain = Data(count: body.count + kCCBlockSizeAES128)
    var plainLength = 0
    let plainCapacity = plain.count

    let status = plain.withUnsafeMutableBytes { plainBuffer in
      body.withUnsafeBytes { bodyBuffer in
        key.withUnsafeBytes { keyBuffer in
          iv.withUnsafeBytes { ivBuffer in
            CCCrypt(
              CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
              keyBuffer.baseAddress, key.count, ivBuffer.baseAddress,
              bodyBuffer.baseAddress, body.count,
              plainBuffer.baseAddress, plainCapacity, &plainLength
            )
          }
        }
      }
    }

    guard status == kCCSuccess else { return nil }

    var value = plain.prefix(plainLength)
    if hasHostHash { value = value.dropFirst(hostHashLength) }

    return String(data: value, encoding: .utf8)
  }
}
