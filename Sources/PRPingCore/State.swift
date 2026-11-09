import Foundation

// Keep the exact IDs visible in the last complete endpoint listing. Draft inline
// comments can become visible later with an old created_at timestamp, so a date
// watermark would lose them. Deleted events leave the next successful snapshot.
struct EventCursor: Codable, Sendable {
    var ids: Set<Int64> = []
}

struct PRState: Codable, Sendable {
    var updatedAt: Date
    var cursors: [String: EventCursor] = [:]
    var repository: String?
}

struct MonitorState: Codable, Sendable {
    var version = 2
    var login: String
    var monitorStart: Date
    var initialComplete = false
    var lastReconciliation: Date?
    var prs: [String: PRState] = [:]
    var outbox: [PREvent] = []
    var scope: WatchScope?
    var sourceStarts: [String: Date]?
}

struct StateFile {
    let url: URL

    func read() throws -> MonitorState? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            throw MonitorError.invalidState("Couldn't read the saved state. Your existing state hasn't been changed")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let state = try decoder.decode(MonitorState.self, from: data)
            guard (state.version == 2 || (state.version == 1 && state.scope == nil)), !state.login.isEmpty,
                  state.monitorStart.timeIntervalSince1970.isFinite,
                  state.scope.map({ $0.isCanonical && $0.login.caseInsensitiveCompare(state.login) == .orderedSame }) ?? true,
                  Set(state.outbox.map(\.id)).count == state.outbox.count,
                  state.outbox.allSatisfy({ $0.url.scheme == "https" && $0.url.host == "github.com" }) else {
                throw MonitorError.invalidState("The saved state is invalid")
            }
            return state
        } catch {
            throw MonitorError.invalidState("The saved state is damaged or from an unsupported version. It hasn't been changed")
        }
    }

    func write(_ state: MonitorState) throws {
        do {
            var state = state
            state.version = 2
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw MonitorError.persistence("Couldn't save Pinga state. This check will be retried")
        }
    }
}
