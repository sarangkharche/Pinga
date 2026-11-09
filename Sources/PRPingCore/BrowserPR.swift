import Foundation

public struct BrowserPR: Sendable, Equatable {
    public let repository: String
    public let number: Int
    public let url: URL

    public static func parse(_ url: URL, scope: WatchScope) -> BrowserPR? {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.port == nil,
              url.user == nil, url.password == nil else { return nil }
        let parts = url.pathComponents.dropFirst()
        guard parts.count >= 4 else { return nil }
        let path = Array(parts)
        guard path[2] == "pull", path[3].allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(path[3]), number > 0,
              let repository = SourceParser.repository("\(path[0])/\(path[1])"),
              scope.allows(repository: repository),
              let canonical = URL(string: "https://github.com/\(repository)/pull/\(number)") else { return nil }
        return BrowserPR(repository: repository, number: number, url: canonical)
    }
}
