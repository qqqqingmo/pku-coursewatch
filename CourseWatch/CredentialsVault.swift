import Foundation

struct LoginCredentials {
    let username: String
    let password: String
}

enum CredentialsVault {
    private struct Secret: Codable {
        var username: String
        var password: String
        var credentials: LoginCredentials { LoginCredentials(username: username, password: password) }
    }

    private struct Storage: Codable {
        var campus: Secret?
        var gradescope: Secret?
    }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CourseWatch", isDirectory: true)
    }
    private static var fileURL: URL { directory.appendingPathComponent("credentials.json") }

    static func load() -> LoginCredentials? { read().campus?.credentials }
    static func loadGradescope() -> LoginCredentials? { read().gradescope?.credentials }

    @discardableResult static func save(username: String, password: String) -> Bool {
        guard !username.isEmpty, !password.isEmpty else { return false }
        var storage = read()
        storage.campus = Secret(username: username, password: password)
        return write(storage)
    }

    @discardableResult static func saveGradescope(username: String, password: String) -> Bool {
        guard !username.isEmpty, !password.isEmpty else { return false }
        var storage = read()
        storage.gradescope = Secret(username: username, password: password)
        return write(storage)
    }

    static func delete() {
        var storage = read()
        storage.campus = nil
        _ = write(storage)
    }

    static func deleteGradescope() {
        var storage = read()
        storage.gradescope = nil
        _ = write(storage)
    }

    private static func read() -> Storage {
        guard let data = try? Data(contentsOf: fileURL),
              let storage = try? JSONDecoder().decode(Storage.self, from: data) else {
            return Storage()
        }
        return storage
    }

    private static func write(_ storage: Storage) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if storage.campus == nil && storage.gradescope == nil {
                try? manager.removeItem(at: fileURL)
                return true
            }
            let data = try JSONEncoder().encode(storage)
            let temporary = directory.appendingPathComponent(".credentials-\(UUID().uuidString)")
            guard manager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else { return false }
            guard rename(temporary.path, fileURL.path) == 0 else {
                try? manager.removeItem(at: temporary)
                return false
            }
            return true
        } catch { return false }
    }
}
