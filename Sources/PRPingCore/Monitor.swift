import Foundation

public actor Monitor {
    private let stateFile: StateFile
    private let transport: any HTTPTransport
    private let tokenProvider: @Sendable () async throws -> String
    private let now: @Sendable () -> Date
    private var state: MonitorState?
    private var loadedState = false
    private var token: String?
    private var account: String?
    private var polling: UInt64?
    private var configuring = false
    private var generation: UInt64 = 0
    private var nextAllowedPoll = Date.distantPast
    private var failures = 0
    private var budgets: [String: RateBudget] = [:]
    private var requestCounts: [String: Int] = [:]

    public init(stateURL: URL, transport: any HTTPTransport = URLSessionTransport(),
                tokenProvider: @escaping @Sendable () async throws -> String = { try await GitHubCLI.token() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        stateFile = StateFile(url: stateURL)
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.now = now
    }

    public var recommendedDelay: TimeInterval { max(60, nextAllowedPoll.timeIntervalSince(now())) }

    public func sources() throws -> WatchScope? {
        try loadState()
        return state?.scope
    }

    public func configure(mode: SourceMode, entries: [String]) async throws -> WatchScope {
        let entries = try SourceParser.entries(mode: mode, values: entries)
        try loadState()
        guard !configuring else { throw MonitorError.api("Source validation is already running") }
        configuring = true
        generation &+= 1
        let operation = generation
        defer { configuring = false }
        let login: String
        if entries.isEmpty, let saved = state {
            // Removing all sources is a local privacy action and must work offline.
            login = saved.login
        } else {
            login = try await refreshIdentity(generation: operation, force: true)
        }
        try checkGeneration(operation)
        for entry in entries {
            let path = mode == .repositories ? "repos/\(entry)" : "orgs/\(entry)"
            let response = try await request(URL(string: "https://api.github.com/\(path)")!, generation: operation)
            try checkGeneration(operation)
            if mode == .repositories {
                let repository: RepositoryReference = try decode(response.data)
                guard SourceParser.repository(repository.fullName) == entry else {
                    throw MonitorError.api("That repository has moved. Paste its current GitHub repository URL")
                }
            } else {
                let organisation: GitHubUser = try decode(response.data)
                guard SourceParser.owner(organisation.login) == entry else {
                    throw MonitorError.api("That organisation has moved. Paste its current GitHub organisation URL")
                }
            }
        }
        try checkGeneration(operation)
        let scope = WatchScope(mode: mode, sources: entries, login: login, host: "github.com")
        let configuredAt = Date(timeIntervalSince1970: floor(now().timeIntervalSince1970))
        var candidate: MonitorState
        if let saved = state, saved.scope != nil, saved.login.caseInsensitiveCompare(login) == .orderedSame {
            candidate = saved
            candidate.prs = candidate.prs.filter { _, record in
                record.repository.map { scope.allows(repository: $0) } ?? false
            }
            candidate.outbox.removeAll { !scope.allows(url: $0.url) }
        } else {
            // State predating source selection has no reliable repository identity.
            // Establish a quiet baseline instead of carrying its old notification queue.
            candidate = MonitorState(login: login, monitorStart: configuredAt)
        }
        let previousStarts = candidate.sourceStarts ?? [:]
        candidate.sourceStarts = Dictionary(uniqueKeysWithValues: scope.sourceKeys.map { ($0, previousStarts[$0] ?? configuredAt) })
        candidate.scope = scope
        candidate.login = login
        candidate.lastReconciliation = nil
        try checkGeneration(operation)
        try stateFile.write(candidate)
        state = candidate
        failures = 0
        nextAllowedPoll = .distantPast
        return scope
    }

    public func poll() async throws -> PollResult {
        try loadState()
        guard let scope = state?.scope else { throw MonitorError.sourcesRequired }
        guard !configuring else { throw MonitorError.retryAfter(60, "Waiting for source validation to finish") }
        if scope.sources.isEmpty {
            return PollResult(events: [], login: scope.login, prCount: 0, nextDelay: 60)
        }
        guard polling != generation else { throw MonitorError.retryAfter(60, "A GitHub check is already running") }
        let delay = nextAllowedPoll.timeIntervalSince(now())
        guard delay <= 0 else { throw MonitorError.retryAfter(delay, "Waiting before the next GitHub check") }
        let operation = generation
        polling = operation
        requestCounts = [:]
        defer { if polling == operation { polling = nil } }
        do {
            let login = try await refreshIdentity(generation: operation, force: false)
            try checkGeneration(operation)
            guard scope.login.caseInsensitiveCompare(login) == .orderedSame else { throw MonitorError.sourcesRequired }
            let started = now()
            let monitorStart = Date(timeIntervalSince1970: floor(started.timeIntervalSince1970))
            var candidate = state ?? MonitorState(login: login, monitorStart: monitorStart)
            let discovery = try await authoredPulls(login: login, at: started, scope: scope, generation: operation)
            try checkGeneration(operation)
            let pulls = discovery.monitored
            let reconcile = candidate.lastReconciliation.map { started.timeIntervalSince($0) >= 900 } ?? true
            var events: [PREvent] = []
            for pull in pulls {
                try checkGeneration(operation)
                guard scope.allows(repository: pull.repository) else { continue }
                let key = String(pull.id)
                let saved = candidate.prs[key]
                if let saved, saved.repository == pull.repository, saved.updatedAt == pull.updatedAt, !reconcile { continue }
                var record = saved ?? PRState(updatedAt: pull.updatedAt, repository: pull.repository)
                let sourceStart = candidate.sourceStarts?[scope.sourceKey(for: pull.repository)] ?? candidate.monitorStart
                for kind in EventKind.allCases {
                    let fetched = try await eventsForPull(pull, kind: kind, generation: operation)
                    try checkGeneration(operation)
                    let previous = record.cursors[kind.rawValue]
                    var cursor = EventCursor()
                    for event in fetched {
                        if candidate.initialComplete,
                           (previous != nil || event.date >= sourceStart),
                           previous?.ids.contains(event.id) != true,
                           event.login.caseInsensitiveCompare(login) != .orderedSame {
                            events.append(event.notification(pull: pull, kind: kind))
                        }
                        cursor.ids.insert(event.id)
                    }
                    record.cursors[kind.rawValue] = cursor
                }
                record.updatedAt = pull.updatedAt
                record.repository = pull.repository
                candidate.prs[key] = record
            }
            try checkGeneration(operation)
            candidate.initialComplete = true
            if reconcile { candidate.lastReconciliation = started }
            // Acknowledge can run while a network request is suspended. Use the
            // current outbox so this transaction never resurrects an acknowledged event.
            let existing = (state?.outbox ?? []).filter { scope.allows(url: $0.url) }
            var known = Set(existing.map(\.id))
            candidate.outbox = existing
            for event in events.sorted(by: { ($0.date, $0.id) < ($1.date, $1.id) })
                where scope.allows(url: event.url) && known.insert(event.id).inserted {
                candidate.outbox.append(event)
            }
            guard candidate.outbox.count <= 10_000 else {
                throw MonitorError.api("There are too many waiting notifications. Enable notifications before checking again")
            }
            try checkGeneration(operation)
            try stateFile.write(candidate)
            state = candidate
            failures = 0
            let nextDelay = adaptiveDelay()
            nextAllowedPoll = now().addingTimeInterval(nextDelay)
            return PollResult(events: candidate.outbox, login: login, prCount: pulls.count, nextDelay: nextDelay,
                              openPRs: discovery.open)
        } catch {
            if operation != generation { throw MonitorError.api("Sources changed. Check again with your current selection") }
            failures = min(failures + 1, 5)
            var delay = min(900, 60 * pow(2, Double(failures - 1)))
            if case MonitorError.retryAfter(let requested, _) = error { delay = max(60, requested) }
            nextAllowedPoll = now().addingTimeInterval(delay)
            throw error
        }
    }

    public func acknowledge(ids: [String]) throws {
        try loadState()
        guard var candidate = state, !ids.isEmpty else { return }
        let acknowledged = Set(ids)
        candidate.outbox.removeAll { acknowledged.contains($0.id) }
        try stateFile.write(candidate)
        state = candidate
    }

    private func loadState() throws {
        guard !loadedState else { return }
        state = try stateFile.read()
        loadedState = true
    }

    private func checkGeneration(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw MonitorError.api("Sources changed. Check again with your current selection") }
    }

    private func refreshIdentity(generation: UInt64, force: Bool) async throws -> String {
        let refreshed = try await tokenProvider()
        try checkGeneration(generation)
        guard !refreshed.isEmpty, !refreshed.contains("\n"), !refreshed.contains("\r") else {
            throw MonitorError.authentication("Sign in with gh auth login for github.com")
        }
        if refreshed != token {
            token = refreshed
            account = nil
            budgets = [:]
        }
        if force { account = nil }
        let login = try await currentLogin(generation: generation)
        try checkGeneration(generation)
        return login
    }

    private func currentLogin(generation: UInt64) async throws -> String {
        if let account { return account }
        let response = try await request(URL(string: "https://api.github.com/user")!, generation: generation)
        try checkGeneration(generation)
        let user: GitHubUser = try decode(response.data)
        guard !user.login.isEmpty, user.login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw MonitorError.api("GitHub returned an invalid account name")
        }
        account = user.login
        return user.login
    }

    private func authoredPulls(login: String, at date: Date, scope: WatchScope, generation: UInt64) async throws -> (monitored: [GitHubPull], open: [OpenPR]) {
        let since = String(ISO8601DateFormatter().string(from: date.addingTimeInterval(-7 * 86_400)).prefix(10))
        let qualifier = scope.mode == .repositories ? "repo" : "org"
        let queries = scope.sources.flatMap { source in
            ["is:pr author:\(login) \(qualifier):\(source) is:open",
             "is:pr author:\(login) \(qualifier):\(source) is:closed updated:>=\(since)"]
        }
        var pulls: [Int64: GitHubPull] = [:]
        var openIDs: Set<Int64> = []
        for (index, query) in queries.enumerated() {
            var components = URLComponents(string: "https://api.github.com/search/issues")!
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "per_page", value: "100"),
                                     URLQueryItem(name: "sort", value: "updated"), URLQueryItem(name: "order", value: "desc")]
            var next = components.url
            var visited: Set<URL> = []
            var count = 0
            while let url = next {
                guard visited.insert(url).inserted, visited.count <= 10 else {
                    throw MonitorError.api("GitHub search pagination was incomplete. Saved state hasn't advanced")
                }
                let response = try await request(url, generation: generation)
                try checkGeneration(generation)
                let page: SearchPage = try decode(response.data)
                guard !page.incompleteResults, page.totalCount <= 1_000 else {
                    throw MonitorError.api("GitHub couldn't return every authored PR. Saved state hasn't advanced")
                }
                count += page.items.count
                for pull in page.items {
                    guard scope.allows(repository: pull.repository) else { continue }
                    try validatePullURLs(pull)
                    pulls[pull.id] = pull
                    if index.isMultiple(of: 2) { openIDs.insert(pull.id) }
                    else { openIDs.remove(pull.id) }
                }
                next = try nextPage(response.headers, matching: components.url!)
                if next == nil, count < page.totalCount {
                    throw MonitorError.api("GitHub search pagination ended early. Saved state hasn't advanced")
                }
            }
        }
        let open = openIDs.compactMap { pulls[$0] }.map {
            OpenPR(id: $0.id, number: $0.number, title: $0.title, url: $0.htmlURL,
                   repository: $0.repository, updatedAt: $0.updatedAt)
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        return (monitored: pulls.values.sorted { $0.id < $1.id }, open: open)
    }

    private func validatePullURLs(_ pull: GitHubPull) throws {
        let repository = pull.repository.lowercased()
        let urls = [(pull.repositoryURL, "api.github.com", "/repos/\(repository)"),
                    (pull.url, "api.github.com", "/repos/\(repository)/issues/\(pull.number)"),
                    (pull.pullRequest.url, "api.github.com", "/repos/\(repository)/pulls/\(pull.number)"),
                    (pull.htmlURL, "github.com", "/\(repository)/pull/\(pull.number)")]
        guard urls.allSatisfy({ url, host, path in
            url.scheme == "https" && url.host == host && url.port == nil && url.user == nil && url.password == nil &&
            url.query == nil && url.fragment == nil && url.path.lowercased() == path
        }) else { throw MonitorError.api("GitHub returned a PR URL outside its expected repository") }
    }

    private func eventsForPull(_ pull: GitHubPull, kind: EventKind, generation: UInt64) async throws -> [GitHubEvent] {
        let base = kind == .issue ? pull.url : pull.pullRequest.url
        let endpoint = kind == .review ? "reviews" : "comments"
        var components = URLComponents(url: base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        var next = components.url
        var visited: Set<URL> = []
        var events: [GitHubEvent] = []
        while let url = next {
            guard visited.insert(url).inserted, visited.count <= 10_000 else {
                throw MonitorError.api("GitHub comment pagination didn't finish. Saved state hasn't advanced")
            }
            let response = try await request(url, generation: generation)
            try checkGeneration(generation)
            if kind == .review {
                let reviews: [GitHubReview] = try decode(response.data)
                for review in reviews where review.state.uppercased() != "PENDING" {
                    guard let date = review.submittedAt else { continue }
                    events.append(GitHubEvent(id: review.id, login: review.user?.login ?? "ghost", body: review.body ?? "",
                                              url: review.htmlURL, date: date, reviewState: review.state))
                }
            } else {
                let comments: [GitHubComment] = try decode(response.data)
                events += comments.map { GitHubEvent(id: $0.id, login: $0.user?.login ?? "ghost", body: $0.body ?? "",
                                                     url: $0.htmlURL, date: $0.createdAt, reviewState: nil) }
            }
            next = try nextPage(response.headers, matching: components.url!)
        }
        return events
    }

    private func request(_ url: URL, generation: UInt64) async throws -> HTTPResponse {
        try checkGeneration(generation)
        guard url.scheme == "https", url.host == "api.github.com", url.user == nil, url.password == nil else {
            throw MonitorError.api("GitHub returned an unexpected API URL")
        }
        let resource = url.path == "/search/issues" ? "search" : "core"
        if let budget = budgets[resource], budget.remaining <= 1, budget.reset > now() {
            throw MonitorError.retryAfter(max(60, budget.reset.timeIntervalSince(now()) + 2), "Waiting for GitHub's API limit to reset")
        }
        guard let token else { throw MonitorError.authentication("Sign in with gh auth login for github.com") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PRPing", forHTTPHeaderField: "User-Agent")
        requestCounts[resource, default: 0] += 1
        let response: HTTPResponse
        do { response = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try checkGeneration(generation)
            throw MonitorError.api("Couldn't reach GitHub. Pinga will retry")
        }
        try checkGeneration(generation)
        let headers = Dictionary(response.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, latest in latest })
        if let remaining = headers["x-ratelimit-remaining"].flatMap(Int.init),
           let reset = headers["x-ratelimit-reset"].flatMap(Double.init) {
            budgets[headers["x-ratelimit-resource"] ?? resource] = RateBudget(remaining: remaining, reset: Date(timeIntervalSince1970: reset))
        }
        if response.status == 401 {
            self.token = nil
            account = nil
            throw MonitorError.authentication("GitHub sign in expired. Run gh auth login for github.com")
        }
        if response.status == 429 || (response.status == 403 &&
            (headers["retry-after"] != nil || headers["x-ratelimit-remaining"] == "0" || isRateLimit(response.data))) {
            let wait = retryDelay(headers)
            throw MonitorError.retryAfter(wait, "GitHub asked Pinga to wait before checking again")
        }
        guard (200..<300).contains(response.status) else {
            if response.status == 403 {
                self.token = nil
                account = nil
                if headers["x-github-sso"]?.lowercased().contains("required") == true {
                    throw MonitorError.api("GitHub requires organisation SSO approval. Authorise GitHub CLI for that organisation then save your sources again")
                }
                throw MonitorError.api("GitHub denied access. Check repository permissions, organisation SSO approval and GitHub CLI sign in")
            }
            if response.status == 404 {
                throw MonitorError.api("GitHub couldn't access that source. Check its name, repository permissions and organisation SSO approval")
            }
            throw MonitorError.api("GitHub returned HTTP \(response.status). Pinga will retry")
        }
        guard response.data.count <= 10 * 1_024 * 1_024 else {
            throw MonitorError.api("GitHub returned a page that was too large to process")
        }
        return HTTPResponse(data: response.data, status: response.status, headers: headers)
    }

    private func nextPage(_ headers: [String: String], matching original: URL) throws -> URL? {
        guard let link = headers["link"] else { return nil }
        for entry in link.components(separatedBy: ",") {
            let parts = entry.components(separatedBy: ";")
            guard parts.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces) == "rel=\"next\"" }) else { continue }
            let raw = parts[0].trimmingCharacters(in: .whitespaces)
            guard raw.hasPrefix("<"), raw.hasSuffix(">"), let url = URL(string: String(raw.dropFirst().dropLast())),
                  url.scheme == "https", url.host == "api.github.com", url.port == nil,
                  url.user == nil, url.password == nil, url.path == original.path else {
                throw MonitorError.api("GitHub returned an invalid pagination link")
            }
            return url
        }
        return nil
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: data) }
        catch { throw MonitorError.api("GitHub returned data Pinga couldn't read. Saved state hasn't advanced") }
    }

    private func isRateLimit(_ data: Data) -> Bool {
        let message = (try? JSONDecoder().decode(APIMessage.self, from: data).message.lowercased()) ?? ""
        return message.contains("rate limit") || message.contains("secondary rate") || message.contains("abuse detection")
    }

    private func retryDelay(_ headers: [String: String]) -> TimeInterval {
        if let raw = headers["retry-after"] {
            if let seconds = Double(raw), seconds.isFinite { return max(60, seconds) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: raw) { return max(60, date.timeIntervalSince(now()) + 2) }
        }
        if let reset = headers["x-ratelimit-reset"].flatMap(Double.init), reset.isFinite {
            return max(60, reset - now().timeIntervalSince1970 + 2)
        }
        return 60
    }

    private func adaptiveDelay() -> TimeInterval {
        var delay: TimeInterval = 60
        for (resource, budget) in budgets where budget.reset > now() {
            let reserve = resource == "search" ? 2 : 25
            let available = budget.remaining - reserve
            let requests = max(resource == "search" ? 2 : 1, requestCounts[resource] ?? 1)
            let untilReset = budget.reset.timeIntervalSince(now()) + 2
            delay = max(delay, available > 0 ? untilReset * Double(requests) / Double(available) : untilReset)
        }
        return delay
    }
}

private struct RateBudget: Sendable { let remaining: Int; let reset: Date }
private struct APIMessage: Decodable { let message: String }
private struct RepositoryReference: Decodable {
    let fullName: String
    enum CodingKeys: String, CodingKey { case fullName = "full_name" }
}
private struct GitHubUser: Decodable { let login: String }
private struct SearchPage: Decodable {
    let totalCount: Int
    let incompleteResults: Bool
    let items: [GitHubPull]
    enum CodingKeys: String, CodingKey { case totalCount = "total_count", incompleteResults = "incomplete_results", items }
}
private struct GitHubPull: Decodable {
    let id: Int64
    let number: Int
    let title: String
    let htmlURL: URL
    let url: URL
    let repositoryURL: URL
    let updatedAt: Date
    let pullRequest: PullReference
    struct PullReference: Decodable { let url: URL }
    enum CodingKeys: String, CodingKey {
        case id, number, title, url, htmlURL = "html_url", repositoryURL = "repository_url",
             updatedAt = "updated_at", pullRequest = "pull_request"
    }
    var repository: String { repositoryURL.pathComponents.suffix(2).joined(separator: "/").lowercased() }
    var label: String { "\(repository)#\(number)" }
}
private struct GitHubComment: Decodable {
    let id: Int64
    let user: GitHubUser?
    let body: String?
    let htmlURL: URL
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case id, user, body, htmlURL = "html_url", createdAt = "created_at" }
}
private struct GitHubReview: Decodable {
    let id: Int64
    let user: GitHubUser?
    let body: String?
    let htmlURL: URL
    let submittedAt: Date?
    let state: String
    enum CodingKeys: String, CodingKey { case id, user, body, state, htmlURL = "html_url", submittedAt = "submitted_at" }
}
private enum EventKind: String, CaseIterable {
    case issue, reviewComment, review
}
private struct GitHubEvent {
    let id: Int64
    let login: String
    let body: String
    let url: URL
    let date: Date
    let reviewState: String?

    func notification(pull: GitHubPull, kind: EventKind) -> PREvent {
        let verb: String
        switch reviewState?.uppercased() {
        case "APPROVED": verb = "approved"
        case "CHANGES_REQUESTED": verb = "requested changes on"
        case "DISMISSED": verb = "had a review dismissed on"
        default: verb = kind == .review ? "reviewed" : "commented on"
        }
        let snippet = String(body.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(180))
        let summary = snippet.isEmpty ? pull.title : "\(pull.title)\n\(snippet)"
        let safeURL = url.scheme == "https" && url.host == "github.com" ? url : pull.htmlURL
        return PREvent(id: "\(kind.rawValue):\(id)", title: "\(login) \(verb) \(pull.label)", body: summary, url: safeURL, date: date)
    }
}
