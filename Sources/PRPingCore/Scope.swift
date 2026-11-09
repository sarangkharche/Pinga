import Foundation

public enum SourceMode: String, Codable, CaseIterable, Sendable {
    case repositories
    case organisations
}

public struct WatchScope: Codable, Equatable, Sendable {
    public let mode: SourceMode
    public let sources: [String]
    public let login: String
    public let host: String

    public init(mode: SourceMode, sources: [String], login: String, host: String) {
        self.mode = mode
        self.sources = sources
        self.login = login
        self.host = host
    }

    public func allows(repository: String) -> Bool {
        guard host == "github.com", let repository = SourceParser.repository(repository) else { return false }
        let source = mode == .repositories ? repository : String(repository.split(separator: "/")[0])
        return sources.contains(source)
    }

    public func allows(url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.port == nil,
              url.user == nil, url.password == nil else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { return false }
        return allows(repository: "\(parts[1])/\(parts[2])")
    }

    var isCanonical: Bool {
        guard host == "github.com", SourceParser.owner(login) != nil,
              sources.count <= 10, sources == sources.sorted(), Set(sources).count == sources.count else { return false }
        return sources.allSatisfy { entry in
            let canonical = mode == .repositories ? SourceParser.repository(entry) : SourceParser.owner(entry)
            return canonical == entry
        }
    }

    func sourceKey(for repository: String) -> String {
        let entry = mode == .repositories ? repository.lowercased() : String(repository.split(separator: "/")[0]).lowercased()
        return "\(mode.rawValue):\(entry)"
    }

    var sourceKeys: [String] { sources.map { "\(mode.rawValue):\($0)" } }
}

enum SourceParser {
    static func entries(mode: SourceMode, values: [String]) throws -> [String] {
        var result: Set<String> = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let path: String
            if trimmed.contains("://") || trimmed.lowercased().hasPrefix("github.com/") {
                let raw = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
                guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
                      components.host?.lowercased() == "github.com", components.port == nil,
                      components.user == nil, components.password == nil, components.query == nil,
                      components.fragment == nil, !components.percentEncodedPath.contains("%") else {
                    throw invalid(mode)
                }
                var urlPath = components.path
                if urlPath.hasSuffix("/") { urlPath.removeLast() }
                guard urlPath.hasPrefix("/") else { throw invalid(mode) }
                path = String(urlPath.dropFirst())
            } else {
                path = trimmed
            }
            let canonical: String?
            if mode == .repositories {
                canonical = repository(path)
            } else {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                let name = parts.count == 2 && parts[0].lowercased() == "orgs" ? String(parts[1]) : path
                canonical = owner(name)
            }
            guard let canonical else { throw invalid(mode) }
            result.insert(canonical)
        }
        guard result.count <= 10 else {
            throw MonitorError.api("Choose up to 10 repositories or organisations so checks can finish within GitHub's API limits")
        }
        return result.sorted()
    }

    static func owner(_ input: String) -> String? {
        let value = input.lowercased()
        guard value.range(of: "^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?$", options: .regularExpression) != nil else { return nil }
        return value
    }

    static func repository(_ input: String) -> String? {
        let parts = input.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let owner = owner(String(parts[0])) else { return nil }
        let name = String(parts[1]).lowercased()
        guard name != ".", name != "..",
              name.range(of: "^[a-z0-9._-]{1,100}$", options: .regularExpression) != nil else { return nil }
        return "\(owner)/\(name)"
    }

    private static func invalid(_ mode: SourceMode) -> MonitorError {
        .api(mode == .repositories
             ? "Use an owner/repository name or an exact https://github.com/owner/repository URL"
             : "Use an organisation name or an exact https://github.com/organisation URL")
    }
}
