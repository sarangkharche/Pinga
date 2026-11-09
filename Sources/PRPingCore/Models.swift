import Foundation
import Darwin

public struct PREvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public let url: URL
    public let date: Date

    public init(id: String, title: String, body: String, url: URL, date: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.url = url
        self.date = date
    }
}

public struct OpenPR: Codable, Sendable, Equatable, Identifiable {
    public let id: Int64
    public let number: Int
    public let title: String
    public let url: URL
    public let repository: String
    public let updatedAt: Date

    public init(id: Int64, number: Int, title: String, url: URL, repository: String, updatedAt: Date) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repository = repository
        self.updatedAt = updatedAt
    }
}

public struct PollResult: Sendable {
    public let events: [PREvent]
    public let login: String
    public let prCount: Int
    public let nextDelay: TimeInterval
    public let openPRs: [OpenPR]

    public init(events: [PREvent], login: String, prCount: Int, nextDelay: TimeInterval, openPRs: [OpenPR] = []) {
        self.events = events
        self.login = login
        self.prCount = prCount
        self.nextDelay = nextDelay
        self.openPRs = openPRs
    }
}

public enum MonitorError: Error, LocalizedError, Sendable {
    case sourcesRequired
    case retryAfter(TimeInterval, String)
    case authentication(String)
    case invalidState(String)
    case api(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .sourcesRequired:
            return "Choose your repositories or organisations in Manage sources before monitoring"
        case .retryAfter(_, let message), .authentication(let message), .invalidState(let message),
             .api(let message), .persistence(let message):
            return message
        }
    }
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let headers: [String: String]

    public init(data: Data, status: Int = 200, headers: [String: String] = [:]) {
        self.data = data
        self.status = status
        self.headers = headers
    }
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config, delegate: GitHubRedirectGuard(), delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MonitorError.api("GitHub returned an unexpected response")
        }
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return HTTPResponse(data: data, status: response.statusCode, headers: headers)
    }
}

private final class GitHubRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = request.url?.scheme == "https" && request.url?.host == "api.github.com"
        completionHandler(allowed ? request : nil)
    }
}

public enum GitHubCLI {
    public static func token() async throws -> String {
        try await Task.detached(priority: .utility) {
            let locations = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            guard let executable = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw MonitorError.authentication("Install GitHub CLI and run gh auth login for github.com")
            }
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["auth", "token", "--hostname", "github.com"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw MonitorError.authentication("Couldn't run GitHub CLI. Run gh auth login for github.com")
            }
            let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timeout.schedule(deadline: .now() + 15)
            timeout.setEventHandler {
                if process.isRunning { process.terminate() }
            }
            timeout.resume()
            let hardTimeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            hardTimeout.schedule(deadline: .now() + 18)
            hardTimeout.setEventHandler {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            hardTimeout.resume()
            defer { timeout.cancel(); hardTimeout.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard process.terminationStatus == 0, !token.isEmpty, !token.contains("\n") else {
                throw MonitorError.authentication("Sign in with gh auth login for github.com")
            }
            return token
        }.value
    }
}
