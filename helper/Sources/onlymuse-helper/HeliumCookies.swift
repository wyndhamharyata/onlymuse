import CommonCrypto
import Foundation
import Security
import SQLite3

// Google refuses a sign-in inside a web view, so onlymuse reads Helium's youtube.com cookies.
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
  private static let keyByteCount = 16
  private static let encryptedPrefix = "v10"
  // From database version 24, Chromium puts the SHA-256 of the cookie's host before its value.
  private static let hostHashVersion = 24
  private static let hostHashByteCount = 32

  enum Failure: Error {
    case noDatabase
    case noKey
  }

  static func readYouTubeCookies() -> Result<[Cookie], Failure> {
    guard let password = readKeychainPassword() else { return .failure(.noKey) }
    guard let cookies = readRows(key: toKey(password: password)) else { return .failure(.noDatabase) }

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

  // Helium writes the file while it runs, so the helper reads a copy.
  private static func readRows(key: Data) -> [Cookie]? {
    let copyURL = FileManager.default.temporaryDirectory.appending(path: "onlymuse-helium-cookies.sqlite")

    try? FileManager.default.removeItem(at: copyURL)
    guard (try? FileManager.default.copyItem(at: databaseURL, to: copyURL)) != nil else { return nil }
    defer { try? FileManager.default.removeItem(at: copyURL) }

    var database: OpaquePointer?

    guard sqlite3_open_v2(copyURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_close(database) }

    let version = Int(readFirstText(database, "select value from meta where key = 'version'") ?? "") ?? 0
    var statement: OpaquePointer?
    let sql = "select host_key, name, encrypted_value, path, is_secure, is_httponly from cookies where host_key = 'youtube.com' or host_key like '%.youtube.com'"

    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }

    var cookies: [Cookie] = []

    while sqlite3_step(statement) == SQLITE_ROW {
      let bytes = sqlite3_column_blob(statement, 2)
      let count = Int(sqlite3_column_bytes(statement, 2))
      let encrypted = bytes.map { Data(bytes: $0, count: count) } ?? Data()

      guard let value = decrypt(encrypted, key: key, hasHostHash: version >= hostHashVersion) else { continue }

      cookies.append(Cookie(
        host: String(cString: sqlite3_column_text(statement, 0)),
        name: String(cString: sqlite3_column_text(statement, 1)),
        value: value,
        path: String(cString: sqlite3_column_text(statement, 3)),
        isSecure: sqlite3_column_int(statement, 4) != 0,
        isHTTPOnly: sqlite3_column_int(statement, 5) != 0
      ))
    }

    return cookies
  }

  private static func readFirstText(_ database: OpaquePointer?, _ sql: String) -> String? {
    var statement: OpaquePointer?

    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

    return sqlite3_column_text(statement, 0).map { String(cString: $0) }
  }

  private static func toKey(password: Data) -> Data {
    var key = Data(count: keyByteCount)
    let saltBytes = Array(salt.utf8)

    key.withUnsafeMutableBytes { keyBuffer in
      password.withUnsafeBytes { passwordBuffer in
        _ = CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2),
          passwordBuffer.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
          saltBytes, saltBytes.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), keyRounds,
          keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), keyByteCount
        )
      }
    }

    return key
  }

  // AES-128-CBC, with 16 spaces as the IV, after the "v10" mark.
  private static func decrypt(_ encrypted: Data, key: Data, hasHostHash: Bool) -> String? {
    guard encrypted.starts(with: Data(encryptedPrefix.utf8)) else { return nil }

    let body = encrypted.dropFirst(encryptedPrefix.count)
    let initializationVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var plain = Data(count: body.count + kCCBlockSizeAES128)
    var plainLength = 0
    let plainCapacity = plain.count

    let status = plain.withUnsafeMutableBytes { plainBuffer in
      body.withUnsafeBytes { bodyBuffer in
        key.withUnsafeBytes { keyBuffer in
          initializationVector.withUnsafeBytes { vectorBuffer in
            CCCrypt(
              CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
              keyBuffer.baseAddress, key.count, vectorBuffer.baseAddress,
              bodyBuffer.baseAddress, body.count,
              plainBuffer.baseAddress, plainCapacity, &plainLength
            )
          }
        }
      }
    }

    guard status == kCCSuccess else { return nil }

    var value = plain.prefix(plainLength)

    if hasHostHash { value = value.dropFirst(hostHashByteCount) }

    return String(data: value, encoding: .utf8)
  }
}
