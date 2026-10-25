import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

enum OpenCodeGoCLICredentialsError: LocalizedError, Sendable, Equatable {
    case expired
    case unreadable
    case malformed
    case ambiguous

    var errorDescription: String? {
        switch self {
        case .expired:
            "The OpenCode CLI login has expired. Sign in again with OpenCode."
        case .unreadable:
            "The OpenCode CLI credentials could not be read."
        case .malformed:
            "The OpenCode CLI credentials have an unsupported or invalid format."
        case .ambiguous:
            "Multiple OpenCode CLI accounts are active. Select one account in OpenCode."
        }
    }
}

struct OpenCodeGoCLICredentialsReader: Sendable {
    private let databaseURL: URL?
    private let authURL: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
    {
        let dataHome = environment["XDG_DATA_HOME"].flatMap { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
        } ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
        // Provider-specific by design: Go credentials share the OpenCode CLI data directory.
        let directory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        self.authURL = directory.appendingPathComponent("auth.json")
        let filename = environment["OPENCODE_DB"] ?? "opencode.db"
        if filename == ":memory:" {
            self.databaseURL = nil
        } else if filename.hasPrefix("/") {
            self.databaseURL = URL(fileURLWithPath: filename)
        } else {
            self.databaseURL = directory.appendingPathComponent(filename).standardizedFileURL
        }
    }

    func load(now: Date = Date()) throws -> String? {
        guard let databaseURL = self.databaseURL?.resolvingSymlinksInPath() else { return nil }
        if try Self.fileExists(at: databaseURL),
           let credentials = try self.readDatabase(at: databaseURL)
        {
            return try Self.select(credentials, now: now)
        }
        return try self.readLegacyAuth()
    }

    private func readDatabase(at url: URL) throws -> [Credential]? {
        do {
            return try self.readDatabase(at: url, immutable: false)
        } catch let failure as SQLiteReadFailure {
            guard failure.code == SQLITE_CANTOPEN,
                  try !Self.fileExists(at: URL(fileURLWithPath: url.path + "-wal")),
                  try !Self.fileExists(at: URL(fileURLWithPath: url.path + "-shm"))
            else { throw OpenCodeGoCLICredentialsError.unreadable }
            // A clean WAL shutdown can remove sidecars while the main file stays in WAL mode.
            do {
                return try self.readDatabase(at: url, immutable: true)
            } catch is SQLiteReadFailure {
                throw OpenCodeGoCLICredentialsError.unreadable
            }
        }
    }

    private func readDatabase(at url: URL, immutable: Bool) throws -> [Credential]? {
        var database: OpaquePointer?
        let filename = immutable ? "\(url.absoluteURL.absoluteString)?immutable=1" : url.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let result = sqlite3_open_v2(filename, &database, flags, nil)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK else { throw SQLiteReadFailure(code: result) }
        sqlite3_busy_timeout(database, 100)

        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'credential'",
            -1,
            &schema,
            nil) == SQLITE_OK
        else { throw SQLiteReadFailure(code: sqlite3_errcode(database)) }
        defer { sqlite3_finalize(schema) }
        switch sqlite3_step(schema) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW: break
        default: throw SQLiteReadFailure(code: sqlite3_errcode(database))
        }

        var statement: OpaquePointer?
        // Three rows suffice to detect ambiguity after giving the specific Go integration precedence.
        let sql = """
        SELECT integration_id, value FROM credential
        WHERE active = 1 AND integration_id IN ('opencode-go', 'opencode')
        ORDER BY CASE integration_id WHEN 'opencode-go' THEN 0 ELSE 1 END
        LIMIT 3
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteReadFailure(code: sqlite3_errcode(database))
        }
        defer { sqlite3_finalize(statement) }
        var credentials: [Credential] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let integration = sqlite3_column_text(statement, 0) else {
                throw OpenCodeGoCLICredentialsError.malformed
            }
            let data: Data? = if sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                                 let bytes = sqlite3_column_blob(statement, 1)
            {
                Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            } else {
                nil
            }
            credentials.append(Credential(integration: String(cString: integration), data: data))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw SQLiteReadFailure(code: step) }
        return credentials
    }

    private static func select(_ credentials: [Credential], now: Date) throws -> String? {
        let specific = credentials.filter { $0.integration == "opencode-go" }
        let selected = specific.isEmpty ? credentials : specific
        guard selected.count <= 1 else { throw OpenCodeGoCLICredentialsError.ambiguous }
        guard let credential = selected.first else { return nil }
        guard let data = credential.data else { throw OpenCodeGoCLICredentialsError.malformed }
        let value = try Self.decode(data)
        // Provider-specific by design: Go accepts the shared OpenCode login only when it is OAuth.
        if credential.integration == "opencode", value.type != "oauth" { return nil }
        switch value.type {
        case "key", "api":
            return try Self.token(value.key)
        case "oauth":
            let access = try Self.token(value.access)
            guard let expires = value.expires, expires.isFinite, expires >= 0,
                  expires.rounded(.towardZero) == expires
            else {
                throw OpenCodeGoCLICredentialsError.malformed
            }
            guard expires / 1000 > now.timeIntervalSince1970 else {
                throw OpenCodeGoCLICredentialsError.expired
            }
            return access
        default:
            throw OpenCodeGoCLICredentialsError.malformed
        }
    }

    private func readLegacyAuth() throws -> String? {
        guard try Self.fileExists(at: self.authURL) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: self.authURL)
        } catch {
            throw OpenCodeGoCLICredentialsError.unreadable
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OpenCodeGoCLICredentialsError.malformed
        }
        guard let entry = object["opencode-go"] else { return nil }
        guard let value = entry as? [String: Any] else { throw OpenCodeGoCLICredentialsError.malformed }
        guard value["type"] as? String == "api" else { return nil }
        return try Self.token(value["key"] as? String)
    }

    private static func fileExists(at url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        } catch {
            throw OpenCodeGoCLICredentialsError.unreadable
        }
    }

    private static func decode(_ data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw OpenCodeGoCLICredentialsError.malformed
        }
    }

    private static func token(_ value: String?) throws -> String {
        guard let value, !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { throw OpenCodeGoCLICredentialsError.malformed }
        return value
    }

    private struct Credential {
        let integration: String
        let data: Data?
    }

    private struct SQLiteReadFailure: Error {
        let code: Int32
    }

    private struct Value: Decodable {
        let type: String
        let key: String?
        let access: String?
        let expires: Double?
    }
}
