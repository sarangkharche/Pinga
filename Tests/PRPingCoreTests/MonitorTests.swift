import Foundation
import Testing
@testable import PRPingCore

private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date = epoch) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval = 61) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor FixtureTransport: HTTPTransport {
    struct Reply: Sendable {
        let path: String
        let queryContains: String?
        let response: HTTPResponse
        let token: String
        init(_ path: String, _ json: String, status: Int = 200, headers: [String: String] = [:], queryContains: String? = nil, token: String = "fixture-token") {
            self.path = path
            self.queryContains = queryContains
            self.token = token
            response = HTTPResponse(data: Data(json.utf8), status: status, headers: headers)
        }
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private var heldPath: String?
    private var held = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func append(_ replies: [Reply]) { self.replies += replies }
    func holdNext(_ path: String) { heldPath = path; held = false }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw MonitorError.api("Unexpected fixture request: \(request.url!.path)") }
        let reply = replies.removeFirst()
        #expect(request.url?.path == reply.path)
        if let query = reply.queryContains {
            #expect(request.url?.query?.removingPercentEncoding?.contains(query) == true)
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(reply.token)")
        #expect(request.httpMethod == "GET")
        if request.url?.path == heldPath {
            heldPath = nil
            held = true
            for waiter in holdWaiters { waiter.resume() }
            holdWaiters = []
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        return reply.response
    }
    var remaining: Int { replies.count }
}

private actor TokenProbe {
    private(set) var count = 0
    private var denied = false
    private var value = "fixture-token"
    func deny() { denied = true }
    func set(_ value: String) { self.value = value }
    func read() throws -> String {
        count += 1
        if denied { throw MonitorError.authentication("Offline fixture") }
        return value
    }
}

private typealias Reply = FixtureTransport.Reply

private func iso(_ offset: TimeInterval = 0) -> String {
    ISO8601DateFormatter().string(from: epoch.addingTimeInterval(offset))
}

private func pull(_ id: Int = 1, updated: TimeInterval = 0, repository: String = "owner/repo") -> String {
    """
    {"id":\(id),"number":\(id),"title":"Fix the thing","html_url":"https://github.com/\(repository)/pull/\(id)",
    "url":"https://api.github.com/repos/\(repository)/issues/\(id)","repository_url":"https://api.github.com/repos/\(repository)",
    "updated_at":"\(iso(updated))","pull_request":{"url":"https://api.github.com/repos/\(repository)/pulls/\(id)"}}
    """
}

private func search(_ pulls: [String] = [], total: Int? = nil, incomplete: Bool = false) -> String {
    "{\"total_count\":\(total ?? pulls.count),\"incomplete_results\":\(incomplete),\"items\":[\(pulls.joined(separator: ","))]}"
}

private func comment(_ id: Int, by login: String = "alice", at offset: TimeInterval = 1, repository: String = "owner/repo", body: String = "Please check this", replyingTo: Int? = nil) -> String {
    let parent = replyingTo.map { ",\"in_reply_to_id\":\($0)" } ?? ""
    let encodedBody = String(data: try! JSONEncoder().encode(body), encoding: .utf8)!
    return """
    {"id":\(id),"user":{"login":"\(login)"},"body":\(encodedBody),"html_url":"https://github.com/\(repository)/pull/1#issuecomment-\(id)","created_at":"\(iso(offset))"\(parent)}
    """
}

private func review(_ id: Int, by login: String = "alice", at offset: TimeInterval? = 1, state: String = "APPROVED") -> String {
    let submitted = offset.map { "\"\(iso($0))\"" } ?? "null"
    return """
    {"id":\(id),"user":{"login":"\(login)"},"body":"Looks good","html_url":"https://github.com/owner/repo/pull/1#pullrequestreview-\(id)","submitted_at":\(submitted),"state":"\(state)"}
    """
}

private func initial(_ pulls: [String] = [pull()], closed: [String] = []) -> [Reply] {
    [Reply("/user", "{\"login\":\"sarang\"}")] + searches(pulls, closed: closed)
}

private func replySearches(_ commented: [String] = [], closedCommented: [String] = [], reviewed: [String] = [], closedReviewed: [String] = []) -> [Reply] {
    [Reply("/search/issues", search(commented), queryContains: "commenter:sarang -author:sarang"),
     Reply("/search/issues", search(closedCommented), queryContains: "is:closed"),
     Reply("/search/issues", search(reviewed), queryContains: "reviewed-by:sarang -author:sarang"),
     Reply("/search/issues", search(closedReviewed), queryContains: "is:closed")]
}

private func searches(_ pulls: [String] = [pull()], closed: [String] = [], commented: [String] = [], closedCommented: [String] = [], reviewed: [String] = [], closedReviewed: [String] = []) -> [Reply] {
    [Reply("/search/issues", search(pulls), queryContains: "author:sarang"),
     Reply("/search/issues", search(closed), queryContains: "is:closed")]
        + replySearches(commented, closedCommented: closedCommented, reviewed: reviewed, closedReviewed: closedReviewed)
}

private func endpoints(_ id: Int = 1, issue: [String] = [], inline: [String] = [], reviews: [String] = [], repository: String = "owner/repo") -> [Reply] {
    [Reply("/repos/\(repository)/issues/\(id)/comments", "[\(issue.joined(separator: ","))]"),
     Reply("/repos/\(repository)/pulls/\(id)/comments", "[\(inline.joined(separator: ","))]"),
     Reply("/repos/\(repository)/pulls/\(id)/reviews", "[\(reviews.joined(separator: ","))]")]
}

private struct Harness {
    let directory: URL
    let stateURL: URL
    let clock: TestClock
    let transport: FixtureTransport
    let monitor: Monitor
    init(_ replies: [Reply], start: Date = epoch,
         scope: WatchScope? = WatchScope(mode: .repositories, sources: ["owner/repo"], login: "sarang", host: "github.com")) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prping-test-\(UUID().uuidString)")
        stateURL = directory.appendingPathComponent("state.json")
        if let scope {
            var seed = MonitorState(login: scope.login, monitorStart: Date(timeIntervalSince1970: floor(start.timeIntervalSince1970)))
            seed.scope = scope
            seed.sourceStarts = Dictionary(uniqueKeysWithValues: scope.sourceKeys.map { ($0, seed.monitorStart) })
            try! StateFile(url: stateURL).write(seed)
        }
        clock = TestClock(start)
        transport = FixtureTransport(replies)
        let clock = clock
        monitor = Monitor(stateURL: stateURL, transport: transport,
                          tokenProvider: { "fixture-token" }, now: { clock.now() })
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
}

@Test func baselineIsSilentAndUnchangedPRsSkipEndpoints() async throws {
    let h = Harness(initial() + endpoints(issue: [comment(1, at: -300)]))
    defer { h.clean() }
    let first = try await h.monitor.poll()
    #expect(first.events.isEmpty)
    #expect(first.login == "sarang")
    #expect(first.prCount == 1)
    #expect(first.nextDelay >= 60)
    h.clock.advance()
    await h.transport.append(searches())
    let second = try await h.monitor.poll()
    #expect(second.events.isEmpty)
    #expect(await h.transport.remaining == 0)
    #expect(await h.transport.requests.count == 16)
    let contents = try String(contentsOf: h.stateURL, encoding: .utf8)
    #expect(!contents.contains("fixture-token"))
    let attributes = try FileManager.default.attributesOfItem(atPath: h.stateURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func deduplicatesSelfEventsAndPendingReviews() async throws {
    let h = Harness(initial() + endpoints(issue: [comment(1, at: -300)]))
    defer { h.clean() }
    _ = try await h.monitor.poll()
    h.clock.advance()
    await h.transport.append(searches([pull(updated: 60)]) + endpoints(
        issue: [comment(1, at: -300), comment(2), comment(3, by: "SARANG")],
        inline: [comment(4)], reviews: [review(5), review(6, at: nil, state: "PENDING")]))
    let next = try await h.monitor.poll()
    #expect(Set(next.events.map(\.id)) == ["issue:2", "reviewComment:4", "review:5"])
    try await h.monitor.acknowledge(ids: next.events.map(\.id))
    h.clock.advance(901)
    await h.transport.append(searches([pull(updated: 60)]) + endpoints(
        issue: [comment(1, at: -300), comment(2), comment(3, by: "sarang")],
        inline: [comment(4)], reviews: [review(5), review(6, at: 900)]))
    let reconciled = try await h.monitor.poll()
    #expect(reconciled.events.map(\.id) == ["review:6"])
}

@Test func newlyDiscoveredPRIncludesEventsAfterMonitorStart() async throws {
    let h = Harness(initial([]), start: epoch.addingTimeInterval(0.9))
    defer { h.clean() }
    _ = try await h.monitor.poll()
    h.clock.advance()
    await h.transport.append(searches([pull(2, updated: 60)]) + endpoints(2, issue: [comment(1, at: -1), comment(2, at: 0), comment(3, at: 20)]))
    let next = try await h.monitor.poll()
    #expect(next.events.map(\.id) == ["issue:2", "issue:3"])
}

@Test func closedPRsAndCompletePaginationAreMonitored() async throws {
    let h = Harness(initial([], closed: [pull()]) + endpoints())
    defer { h.clean() }
    _ = try await h.monitor.poll()
    h.clock.advance()
    let link = "<https://api.github.com/repos/owner/repo/issues/1/comments?per_page=100&page=2>; rel=\"next\""
    await h.transport.append(searches([], closed: [pull(updated: 60)]) + [
        Reply("/repos/owner/repo/issues/1/comments", "[\(comment(1))]", headers: ["Link": link]),
        Reply("/repos/owner/repo/issues/1/comments", "[\(comment(2))]", queryContains: "page=2"),
        Reply("/repos/owner/repo/pulls/1/comments", "[]"), Reply("/repos/owner/repo/pulls/1/reviews", "[]")])
    let result = try await h.monitor.poll()
    #expect(Set(result.events.map(\.id)) == ["issue:1", "issue:2"])
}

@Test func failureMidEndpointDoesNotAdvanceState() async throws {
    let h = Harness(initial() + endpoints())
    defer { h.clean() }
    _ = try await h.monitor.poll()
    let before = try Data(contentsOf: h.stateURL)
    h.clock.advance()
    let link = "<https://api.github.com/repos/owner/repo/issues/1/comments?page=2>; rel=\"next\""
    await h.transport.append(searches([pull(updated: 60)]) + [
        Reply("/repos/owner/repo/issues/1/comments", "[\(comment(1))]", headers: ["link": link]),
        Reply("/repos/owner/repo/issues/1/comments", "{}", status: 500)])
    await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
    #expect(try Data(contentsOf: h.stateURL) == before)
    h.clock.advance()
    await h.transport.append(searches([pull(updated: 60)]) + endpoints(issue: [comment(1), comment(2)]))
    let retried = try await h.monitor.poll()
    #expect(Set(retried.events.map(\.id)) == ["issue:1", "issue:2"])
}

@Test func failureOnAnotherEndpointDoesNotDiscardCompletedComments() async throws {
    let h = Harness(initial() + endpoints())
    defer { h.clean() }
    _ = try await h.monitor.poll()
    let before = try Data(contentsOf: h.stateURL)
    h.clock.advance()
    await h.transport.append(searches([pull(updated: 60)]) + [
        Reply("/repos/owner/repo/issues/1/comments", "[\(comment(1))]"),
        Reply("/repos/owner/repo/pulls/1/comments", "{}", status: 500)])
    await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
    #expect(try Data(contentsOf: h.stateURL) == before)
    h.clock.advance()
    await h.transport.append(searches([pull(updated: 60)]) + endpoints(issue: [comment(1)]))
    #expect(try await h.monitor.poll().events.map(\.id) == ["issue:1"])
}

@Test func unacknowledgedEventsSurviveRestartAndAreRedelivered() async throws {
    let h = Harness(initial() + endpoints())
    defer { h.clean() }
    _ = try await h.monitor.poll()
    h.clock.advance()
    await h.transport.append(searches([pull(updated: 60)]) + endpoints(issue: [comment(1)]))
    let first = try await h.monitor.poll()
    let restartedTransport = FixtureTransport(initial([pull(updated: 60)]))
    let clock = h.clock
    let restarted = Monitor(stateURL: h.stateURL, transport: restartedTransport, tokenProvider: { "fixture-token" }, now: { clock.now() })
    let second = try await restarted.poll()
    #expect(second.events == first.events)
    try await restarted.acknowledge(ids: first.events.map(\.id))
    let anotherTransport = FixtureTransport(initial([pull(updated: 60)]))
    let another = Monitor(stateURL: h.stateURL, transport: anotherTransport, tokenProvider: { "fixture-token" }, now: { clock.now() })
    #expect(try await another.poll().events.isEmpty)
}

@Test func rateLimitHonorsCooldownWithoutMakingRequests() async throws {
    let h = Harness([Reply("/user", "{\"message\":\"secondary rate limit\"}", status: 429, headers: ["Retry-After": "180"])])
    defer { h.clean() }
    do {
        _ = try await h.monitor.poll()
        Issue.record("Expected rate limit")
    } catch MonitorError.retryAfter(let delay, _) { #expect(delay == 180) }
    #expect(await h.monitor.recommendedDelay == 180)
    await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
    #expect(await h.transport.requests.count == 1)
    #expect(try StateFile(url: h.stateURL).read()?.initialComplete == false)
    h.clock.advance(181)
    await h.transport.append(initial([]))
    #expect(try await h.monitor.poll().events.isEmpty)
}

@Test func primaryRateLimitUsesResetAndNormalBudgetsAdaptDelay() async throws {
    let reset = String(Int(epoch.timeIntervalSince1970 + 300))
    let limited = Harness([Reply("/user", "{}", status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": reset])])
    defer { limited.clean() }
    do {
        _ = try await limited.monitor.poll()
        Issue.record("Expected rate limit")
    } catch MonitorError.retryAfter(let delay, _) { #expect(delay == 302) }

    let adaptive = Harness([
        Reply("/user", "{\"login\":\"sarang\"}", headers: ["x-ratelimit-remaining": "26", "x-ratelimit-reset": reset])]
        + searches([]))
    defer { adaptive.clean() }
    #expect(try await adaptive.monitor.poll().nextDelay == 302)
}

@Test func corruptStateIsNeverSilentlyReset() async throws {
    let h = Harness([])
    defer { h.clean() }
    try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
    let original = Data("{broken state".utf8)
    try original.write(to: h.stateURL)
    await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
    #expect(try Data(contentsOf: h.stateURL) == original)
    #expect(await h.transport.requests.isEmpty)
}

@Test func accountSwitchDoesNotRewriteState() async throws {
    let h = Harness(initial([]))
    defer { h.clean() }
    _ = try await h.monitor.poll()
    let original = try Data(contentsOf: h.stateURL)
    let otherTransport = FixtureTransport([Reply("/user", "{\"login\":\"other\"}")])
    let other = Monitor(stateURL: h.stateURL, transport: otherTransport, tokenProvider: { "fixture-token" })
    await #expect(throws: MonitorError.self) { try await other.poll() }
    #expect(try Data(contentsOf: h.stateURL) == original)
}

@Test func searchLimitsAndIncompleteResultsFailWithoutBaseline() async throws {
    for json in [search([pull()], total: 1001), search([pull()], incomplete: true), search([pull()], total: 2)] {
        let h = Harness([Reply("/user", "{\"login\":\"sarang\"}"), Reply("/search/issues", json)])
        defer { h.clean() }
        await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
        #expect(try StateFile(url: h.stateURL).read()?.initialComplete == false)
    }
}

@Test func searchPaginationVisitsEveryPageBeforeBaseline() async throws {
    let link = "<https://api.github.com/search/issues?q=is%3Apr&page=2>; rel=\"next\""
    let h = Harness([
        Reply("/user", "{\"login\":\"sarang\"}"),
        Reply("/search/issues", search([pull()], total: 2), headers: ["link": link]),
        Reply("/search/issues", search([pull(2)], total: 2), queryContains: "page=2"),
        Reply("/search/issues", search())] + replySearches() + endpoints() + endpoints(2))
    defer { h.clean() }
    let result = try await h.monitor.poll()
    #expect(result.prCount == 2)
    #expect(result.openPRs.map(\.id) == [1, 2])
    #expect(await h.transport.remaining == 0)
    #expect(await h.transport.requests.count == 14)
}

@Test func openPRLinksExcludeClosedAndSortByLatestUpdateWithoutMoreRequests() async throws {
    let h = Harness(initial([pull(1, updated: 20), pull(3, updated: 30), pull(2, updated: 30), pull(4, updated: 40)],
                            closed: [pull(4, updated: 50)]) + endpoints(1) + endpoints(2) + endpoints(3) + endpoints(4))
    defer { h.clean() }
    let result = try await h.monitor.poll()
    #expect(result.prCount == 4)
    #expect(result.openPRs.map(\.id) == [2, 3, 1])
    #expect(result.openPRs.first?.number == 2)
    #expect(result.openPRs.first?.title == "Fix the thing")
    #expect(result.openPRs.first?.repository == "owner/repo")
    #expect(result.openPRs.first?.url == URL(string: "https://github.com/owner/repo/pull/2"))
    #expect(result.openPRs.first?.updatedAt == epoch.addingTimeInterval(30))
    #expect(await h.transport.requests.count == 19)
    #expect(await h.transport.remaining == 0)
}

@Test func foreignPaginationDoesNotLeakToken() async throws {
    let h = Harness(initial() + [Reply("/repos/owner/repo/issues/1/comments", "[]",
                                     headers: ["link": "<https://attacker.example/page>; rel=\"next\""])])
    defer { h.clean() }
    await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
    #expect(await h.transport.requests.allSatisfy { $0.url?.host == "api.github.com" })
    #expect(try StateFile(url: h.stateURL).read()?.initialComplete == false)
}

@Test func unchangedPRReceivesPeriodicFullReconciliation() async throws {
    let h = Harness(initial() + endpoints())
    defer { h.clean() }
    _ = try await h.monitor.poll()
    h.clock.advance(901)
    await h.transport.append(searches() + endpoints(inline: [comment(1, at: 600)]))
    #expect(try await h.monitor.poll().events.map(\.id) == ["reviewComment:1"])
}

@Test func forbiddenRepositoryResponseRefreshesAccountOnRetry() async throws {
    let h = Harness(initial() + endpoints())
    defer { h.clean() }
    _ = try await h.monitor.poll()
    let original = try Data(contentsOf: h.stateURL)
    h.clock.advance()
    await h.transport.append(searches([pull(updated: 60)]) + [
        Reply("/repos/owner/repo/issues/1/comments", "{\"message\":\"Resource not accessible\"}", status: 403)])
    await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
    #expect(try Data(contentsOf: h.stateURL) == original)
    h.clock.advance()
    // A fresh /user request proves the cached account was cleared, permitting
    // gh auth login to take effect without restarting the app.
    await h.transport.append(initial([pull(updated: 60)]) + endpoints(issue: [comment(1)]))
    #expect(try await h.monitor.poll().events.map(\.id) == ["issue:1"])
    #expect(await h.transport.remaining == 0)
}

@Test func failedInitialFetchDoesNotTurnRetryIntoHistoricalNotifications() async throws {
    let h = Harness(initial() + [Reply("/repos/owner/repo/issues/1/comments", "{}", status: 500)])
    defer { h.clean() }
    await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
    #expect(try StateFile(url: h.stateURL).read()?.initialComplete == false)
    h.clock.advance()
    await h.transport.append(searches([pull(updated: 60)]) + endpoints(issue: [comment(1, at: 1)]))
    #expect(try await h.monitor.poll().events.isEmpty)
}

@Test func latePublishedInlineCommentsAreNotLostToDateWatermarks() async throws {
    let h = Harness(initial() + endpoints(inline: [comment(1, at: -10)]))
    defer { h.clean() }
    _ = try await h.monitor.poll()
    h.clock.advance()
    await h.transport.append(searches([pull(updated: 60)]) + endpoints(inline: [comment(1, at: -10), comment(2, at: 20)]))
    let first = try await h.monitor.poll()
    #expect(first.events.map(\.id) == ["reviewComment:2"])
    try await h.monitor.acknowledge(ids: first.events.map(\.id))
    h.clock.advance()
    // A previously private draft was created before setup and another new
    // comment predates the most recently seen timestamp. Both are new IDs.
    await h.transport.append(searches([pull(updated: 120)]) + endpoints(inline: [
        comment(1, at: -10), comment(2, at: 20), comment(3, at: 1), comment(4, at: -30)]))
    let late = try await h.monitor.poll()
    #expect(Set(late.events.map(\.id)) == ["reviewComment:3", "reviewComment:4"])
}

@Test func sourceParsingCanonicalisesExactGitHubEntries() throws {
    #expect(try SourceParser.entries(mode: .repositories, values: [" Owner/Repo ", "https://github.com/OWNER/REPO/", "github.com/Other/Tools"]) == ["other/tools", "owner/repo"])
    #expect(try SourceParser.entries(mode: .organisations, values: ["Company", "https://github.com/orgs/COMPANY", "https://github.com/Other/"]) == ["company", "other"])
    let repo = WatchScope(mode: .repositories, sources: ["owner/repo"], login: "sarang", host: "github.com")
    #expect(repo.allows(repository: "OWNER/REPO"))
    #expect(!repo.allows(repository: "owner/repo-other"))
    #expect(!repo.allows(repository: "owner/repo/extra"))
    #expect(repo.allows(url: URL(string: "https://github.com/owner/repo/pull/1#issuecomment-1")!))
    #expect(!repo.allows(url: URL(string: "https://github.com/owner/repo-other/pull/1")!))
    #expect(!repo.allows(url: URL(string: "https://evil.example/owner/repo/pull/1")!))
    let org = WatchScope(mode: .organisations, sources: ["company"], login: "sarang", host: "github.com")
    #expect(org.allows(repository: "company/tools"))
    #expect(!org.allows(repository: "company-other/tools"))
    #expect(!org.allows(url: URL(string: "https://github.com/company-other/tools/pull/1")!))
}

@Test func invalidSourcesAreRejectedBeforeAuthenticationOrNetwork() async throws {
    let h = Harness([], scope: nil)
    defer { h.clean() }
    let token = TokenProbe()
    let monitor = Monitor(stateURL: h.stateURL, transport: h.transport, tokenProvider: { try await token.read() })
    for entry in ["owner/repo is:open", "https://github.com/owner/repo?x=1", "https://github.com/owner/repo#readme", "https://evil.example/owner/repo", "https://github.com/owner%2Frepo", "http://github.com/owner/repo", "owner/repo/extra", "owner/..", "https://user@github.com/owner/repo"] {
        await #expect(throws: MonitorError.self) { try await monitor.configure(mode: .repositories, entries: [entry]) }
    }
    await #expect(throws: MonitorError.self) {
        try await monitor.configure(mode: .repositories, entries: (1...11).map { "owner/repo\($0)" })
    }
    #expect(await token.count == 0)
    #expect(await h.transport.requests.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: h.stateURL.path))
}

@Test func missingSourcesAndLegacyStatePerformNoNetworkAndMigrateQuietly() async throws {
    let h = Harness([], scope: nil)
    defer { h.clean() }
    let token = TokenProbe()
    let clock = h.clock
    let monitor = Monitor(stateURL: h.stateURL, transport: h.transport, tokenProvider: { try await token.read() }, now: { clock.now() })
    await #expect(throws: MonitorError.self) { try await monitor.poll() }
    #expect(await token.count == 0)
    #expect(await h.transport.requests.isEmpty)
    var legacy = MonitorState(login: "sarang", monitorStart: epoch.addingTimeInterval(-1000))
    legacy.version = 1
    legacy.initialComplete = true
    legacy.prs["1"] = PRState(updatedAt: epoch)
    legacy.outbox = [PREvent(id: "issue:99", title: "Old", body: "Old", url: URL(string: "https://github.com/owner/repo/pull/1")!, date: epoch)]
    try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
    let legacyEncoder = JSONEncoder()
    legacyEncoder.dateEncodingStrategy = .millisecondsSince1970
    try legacyEncoder.encode(legacy).write(to: h.stateURL)
    // Use a fresh instance because the first one correctly cached the missing file.
    let migrated = Monitor(stateURL: h.stateURL, transport: h.transport, tokenProvider: { try await token.read() }, now: { clock.now() })
    #expect(try await migrated.sources() == nil)
    await #expect(throws: MonitorError.self) { try await migrated.poll() }
    #expect(await token.count == 0)
    await h.transport.append([Reply("/user", "{\"login\":\"sarang\"}"), Reply("/repos/owner/repo", "{\"full_name\":\"Owner/Repo\"}")])
    let scope = try await migrated.configure(mode: .repositories, entries: ["https://github.com/Owner/Repo"])
    #expect(scope.sources == ["owner/repo"])
    let reset = try #require(try StateFile(url: h.stateURL).read())
    #expect(reset.version == 2)
    #expect(reset.prs.isEmpty)
    #expect(reset.outbox.isEmpty)
    #expect(!reset.initialComplete)
    await h.transport.append(searches() + endpoints(issue: [comment(1, at: 1)]))
    #expect(try await migrated.poll().events.isEmpty)
    #expect(await token.count == 2)
}

@Test func removingAllSourcesWorksOfflineAndStaysPausedAfterRestart() async throws {
    let h = Harness([])
    defer { h.clean() }
    let token = TokenProbe()
    await token.deny()
    let monitor = Monitor(stateURL: h.stateURL, transport: h.transport, tokenProvider: { try await token.read() })
    let scope = try await monitor.configure(mode: .repositories, entries: [])
    #expect(scope.sources.isEmpty)
    #expect(scope.login == "sarang")
    #expect(try await monitor.poll().prCount == 0)
    let restarted = Monitor(stateURL: h.stateURL, transport: h.transport, tokenProvider: { try await token.read() })
    #expect(try await restarted.sources()?.sources.isEmpty == true)
    #expect(try await restarted.poll().events.isEmpty)
    #expect(await token.count == 0)
    #expect(await h.transport.requests.isEmpty)
}

@Test func failedPartialSourceValidationLeavesPreviousStateUntouched() async throws {
    let h = Harness([Reply("/user", "{\"login\":\"sarang\"}"),
                     Reply("/repos/owner/new", "{\"full_name\":\"owner/new\"}"),
                     Reply("/repos/owner/repo", "{}", status: 403, headers: ["x-github-sso": "required; url=https://github.com/orgs/owner/sso"])])
    defer { h.clean() }
    let before = try Data(contentsOf: h.stateURL)
    do {
        _ = try await h.monitor.configure(mode: .repositories, entries: ["owner/repo", "owner/new"])
        Issue.record("Expected permission failure")
    } catch { #expect(error.localizedDescription.contains("SSO")) }
    #expect(try Data(contentsOf: h.stateURL) == before)
    #expect(try await h.monitor.sources()?.sources == ["owner/repo"])
    #expect(await h.transport.remaining == 0)
}

@Test func scopeChangesRetainOnlyMatchingRepositoryRecordsAndOutbox() async throws {
    let h = Harness([Reply("/user", "{\"login\":\"sarang\"}"), Reply("/repos/owner/repo", "{\"full_name\":\"owner/repo\"}")],
                    scope: WatchScope(mode: .repositories, sources: ["owner/other", "owner/repo"], login: "sarang", host: "github.com"))
    defer { h.clean() }
    var saved = try #require(try StateFile(url: h.stateURL).read())
    saved.initialComplete = true
    saved.prs = ["1": PRState(updatedAt: epoch, repository: "owner/repo"), "2": PRState(updatedAt: epoch, repository: "owner/other"), "3": PRState(updatedAt: epoch)]
    saved.outbox = [PREvent(id: "issue:1", title: "Keep", body: "", url: URL(string: "https://github.com/owner/repo/pull/1")!, date: epoch),
                    PREvent(id: "issue:2", title: "Remove", body: "", url: URL(string: "https://github.com/owner/other/pull/2")!, date: epoch)]
    try StateFile(url: h.stateURL).write(saved)
    _ = try await h.monitor.configure(mode: .repositories, entries: ["owner/repo"])
    let changed = try #require(try StateFile(url: h.stateURL).read())
    #expect(Set(changed.prs.keys) == ["1"])
    #expect(changed.outbox.map(\.id) == ["issue:1"])
    #expect(changed.sourceStarts?.keys.sorted() == ["repositories:owner/repo"])
    #expect(changed.initialComplete)
}

@Test func addedSourcesIgnoreHistoryBeforeTheirConfigurationTime() async throws {
    let h = Harness(initial() + endpoints())
    defer { h.clean() }
    _ = try await h.monitor.poll()
    h.clock.advance(120)
    await h.transport.append([Reply("/user", "{\"login\":\"sarang\"}"),
                              Reply("/repos/owner/new", "{\"full_name\":\"owner/new\"}"),
                              Reply("/repos/owner/repo", "{\"full_name\":\"owner/repo\"}")])
    _ = try await h.monitor.configure(mode: .repositories, entries: ["owner/repo", "owner/new"])
    await h.transport.append([
        Reply("/search/issues", search([pull(2, updated: 121, repository: "owner/new")]), queryContains: "repo:owner/new"),
        Reply("/search/issues", search(), queryContains: "repo:owner/new")]
        + replySearches() + [
        Reply("/search/issues", search([pull()]), queryContains: "repo:owner/repo"),
        Reply("/search/issues", search(), queryContains: "repo:owner/repo")]
        + replySearches() + endpoints() + endpoints(2, issue: [comment(1, at: 60, repository: "owner/new"), comment(2, at: 121, repository: "owner/new")], repository: "owner/new"))
    #expect(try await h.monitor.poll().events.map(\.id) == ["issue:2"])
}

@Test func organisationSearchAndExactRepositoryAllowlistFilterUnexpectedResults() async throws {
    let h = Harness([Reply("/user", "{\"login\":\"sarang\"}"), Reply("/orgs/company", "{\"login\":\"Company\"}")], scope: nil)
    defer { h.clean() }
    _ = try await h.monitor.configure(mode: .organisations, entries: ["https://github.com/Company"])
    await h.transport.append([
        Reply("/search/issues", search([pull(1, repository: "company/tools"), pull(2, repository: "company-other/tools")]), queryContains: "org:company"),
        Reply("/search/issues", search(), queryContains: "org:company")]
        + replySearches() + endpoints(1, repository: "company/tools"))
    let result = try await h.monitor.poll()
    #expect(result.prCount == 1)
    #expect(result.openPRs.map(\.repository) == ["company/tools"])
    #expect(await h.transport.requests.allSatisfy { !$0.url!.path.contains("company-other") })
    #expect(await h.transport.remaining == 0)
}

@Test func repositoryIdentityCannotPointCommentRequestsOutsideTheScope() async throws {
    let forged = pull().replacingOccurrences(of: "repos/owner/repo/issues", with: "repos/other/repo/issues")
    let h = Harness(initial([forged]))
    defer { h.clean() }
    await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
    #expect(await h.transport.requests.count == 2)
    #expect(await h.transport.requests.allSatisfy { !$0.url!.path.contains("/comments") })
}

@Test func sourceChangeInvalidatesAnInFlightPollBeforeItCanCommitOrNotify() async throws {
    let h = Harness(initial() + endpoints())
    defer { h.clean() }
    _ = try await h.monitor.poll()
    h.clock.advance()
    await h.transport.append(searches([pull(updated: 60)]) + [Reply("/repos/owner/repo/issues/1/comments", "[\(comment(1))]")])
    await h.transport.holdNext("/repos/owner/repo/issues/1/comments")
    let running = Task { try await h.monitor.poll() }
    await h.transport.waitUntilHeld()
    await h.transport.append([Reply("/user", "{\"login\":\"sarang\"}"), Reply("/repos/owner/new", "{\"full_name\":\"owner/new\"}")])
    _ = try await h.monitor.configure(mode: .repositories, entries: ["owner/new"])
    // A new generation can finish even while the old HTTP response is suspended.
    await h.transport.append(searches([]))
    #expect(try await h.monitor.poll().events.isEmpty)
    let afterNewPoll = try Data(contentsOf: h.stateURL)
    await h.transport.release()
    await #expect(throws: MonitorError.self) { try await running.value }
    #expect(try Data(contentsOf: h.stateURL) == afterNewPoll)
    #expect(try await h.monitor.sources()?.sources == ["owner/new"])
    #expect(try StateFile(url: h.stateURL).read()?.outbox.isEmpty == true)
    #expect(await h.transport.remaining == 0)
}

@Test func everyPollRefreshesCLICredentialsWithoutExtraUserCallsForAnUnchangedToken() async throws {
    let h = Harness(initial([]) + searches([]))
    defer { h.clean() }
    let token = TokenProbe()
    let clock = h.clock
    let monitor = Monitor(stateURL: h.stateURL, transport: h.transport, tokenProvider: { try await token.read() }, now: { clock.now() })
    _ = try await monitor.poll()
    h.clock.advance()
    _ = try await monitor.poll()
    #expect(await token.count == 2)
    #expect(await h.transport.requests.filter { $0.url?.path == "/user" }.count == 1)
}

@Test func changedCredentialRequiresConfirmationBeforeMonitoringAnotherAccount() async throws {
    let h = Harness(initial([]))
    defer { h.clean() }
    let token = TokenProbe()
    let clock = h.clock
    let monitor = Monitor(stateURL: h.stateURL, transport: h.transport, tokenProvider: { try await token.read() }, now: { clock.now() })
    _ = try await monitor.poll()
    let before = try Data(contentsOf: h.stateURL)
    h.clock.advance()
    await token.set("fixture-second")
    await h.transport.append([Reply("/user", "{\"login\":\"other\"}", token: "fixture-second")])
    do {
        _ = try await monitor.poll()
        Issue.record("Expected source confirmation for a changed account")
    } catch MonitorError.sourcesRequired {}
    #expect(try Data(contentsOf: h.stateURL) == before)
    await h.transport.append([Reply("/user", "{\"login\":\"other\"}", token: "fixture-second"),
                              Reply("/repos/owner/repo", "{\"full_name\":\"owner/repo\"}", token: "fixture-second")])
    let confirmed = try await monitor.configure(mode: .repositories, entries: ["owner/repo"])
    #expect(confirmed.login == "other")
    let saved = try #require(try StateFile(url: h.stateURL).read())
    #expect(saved.login == "other")
    #expect(!saved.initialComplete)
    #expect(saved.outbox.isEmpty)
    #expect(await h.transport.remaining == 0)
}

private func responseEndpoints(_ id: Int = 1, issue: [String] = [], inline: [String] = [], repository: String = "owner/repo") -> [Reply] {
    Array(endpoints(id, issue: issue, inline: inline, repository: repository).prefix(2))
}

@Test func othersPRsOnlyNotifyRepliesInParticipatingThreadsAndExplicitMentions() async throws {
    let root = comment(1, by: "sarang", at: -20)
    let h = Harness(Array(initial([]).dropLast(4)) + replySearches([pull()]) + responseEndpoints(inline: [root]))
    defer { h.clean() }
    #expect(try await h.monitor.poll().events.isEmpty)
    h.clock.advance()
    await h.transport.append(searches([], commented: [pull(updated: 60)]) + responseEndpoints(
        issue: [comment(10), comment(11, body: "@sarang please check"), comment(12, body: "@sarang-extra please check"),
                comment(13, body: "email@sarang"), comment(14, by: "sarang", body: "@sarang"), comment(15, body: "Hi @SARANG!")],
        inline: [root, comment(2, replyingTo: 1), comment(3, by: "sarang", replyingTo: 1),
                 comment(4), comment(5, replyingTo: 4), comment(6, at: -30),
                 comment(7, by: "sarang", at: -10, replyingTo: 6), comment(8, replyingTo: 6),
                 comment(9, at: -20, replyingTo: 6)]))
    let result = try await h.monitor.poll()
    #expect(Set(result.events.map(\.id)) == ["issue:11", "issue:15", "reviewComment:2", "reviewComment:8"])
    #expect(result.events.filter { $0.id.hasPrefix("issue:") }.allSatisfy { $0.title.contains("mentioned you on") })
    #expect(result.events.filter { $0.id.hasPrefix("reviewComment:") }.allSatisfy { $0.title.contains("replied on") })
    #expect(result.openPRs.isEmpty)
    try await h.monitor.acknowledge(ids: result.events.map(\.id))
    h.clock.advance()
    await h.transport.append(searches([], commented: [pull(updated: 60)]))
    #expect(try await h.monitor.poll().events.isEmpty)
    #expect(await h.transport.remaining == 0)
}

@Test func reviewAndCommentDiscoveryDeduplicateWithoutChangingAuthoredAlerts() async throws {
    let other = pull(2)
    let ownRoot = comment(20, by: "sarang", at: -20)
    let h = Harness([Reply("/user", "{\"login\":\"sarang\"}")]
                    + searches([pull()], commented: [other, pull()], reviewed: [other])
                    + endpoints() + responseEndpoints(2, inline: [ownRoot]))
    defer { h.clean() }
    let baseline = try await h.monitor.poll()
    #expect(baseline.prCount == 2)
    #expect(baseline.openPRs.map(\.id) == [1])
    h.clock.advance()
    await h.transport.append(searches([pull(updated: 60)], closedCommented: [pull(2, updated: 60)], closedReviewed: [pull(2, updated: 60)])
        + endpoints(issue: [comment(1)], reviews: [review(2)])
        + responseEndpoints(2, inline: [ownRoot, comment(21, replyingTo: 20)]))
    let events = try await h.monitor.poll().events
    #expect(Set(events.map(\.id)) == ["issue:1", "review:2", "reviewComment:21"])
    #expect(await h.transport.requests.filter { $0.url?.path == "/repos/owner/repo/pulls/2/comments" }.count == 2)
    #expect(await h.transport.requests.filter { $0.url?.path == "/repos/owner/repo/pulls/2/reviews" }.isEmpty)
    #expect(await h.transport.remaining == 0)
}

@Test func completeInlinePaginationResolvesReplyAncestryAcrossPages() async throws {
    let root = comment(100, at: -30)
    let own = comment(101, by: "sarang", at: -20, replyingTo: 100)
    let h = Harness([Reply("/user", "{\"login\":\"sarang\"}")] + searches([], reviewed: [pull()])
                    + responseEndpoints(inline: [root, own]))
    defer { h.clean() }
    _ = try await h.monitor.poll()
    h.clock.advance()
    let link = "<https://api.github.com/repos/owner/repo/pulls/1/comments?per_page=100&page=2>; rel=\"next\""
    await h.transport.append(searches([], reviewed: [pull(updated: 60)]) + [
        Reply("/repos/owner/repo/issues/1/comments", "[]"),
        Reply("/repos/owner/repo/pulls/1/comments", "[\(root),\(own)]", headers: ["link": link]),
        Reply("/repos/owner/repo/pulls/1/comments", "[\(comment(102, replyingTo: 101)),\(comment(103, replyingTo: 102))]", queryContains: "page=2")])
    #expect(Set(try await h.monitor.poll().events.map(\.id)) == ["reviewComment:102", "reviewComment:103"])
    #expect(await h.transport.remaining == 0)
}

@Test func replyUpgradeEstablishesQuietBaselineAndPreservesAuthoredStateAndOutbox() async throws {
    let h = Harness([Reply("/user", "{\"login\":\"sarang\"}")]
                    + searches([pull(updated: 60)], commented: [pull(2, updated: 60)])
                    + endpoints(issue: [comment(2)])
                    + responseEndpoints(2, issue: [comment(4, body: "@sarang old mention")],
                                        inline: [comment(5, by: "sarang", at: -20), comment(6, replyingTo: 5)]))
    defer { h.clean() }
    var saved = try #require(try StateFile(url: h.stateURL).read())
    saved.initialComplete = true
    saved.prs["1"] = PRState(updatedAt: epoch, cursors: ["issue": EventCursor(ids: [1])], repository: "owner/repo")
    saved.outbox = [PREvent(id: "issue:77", title: "Waiting", body: "", url: URL(string: "https://github.com/owner/repo/pull/1")!, date: epoch)]
    try StateFile(url: h.stateURL).write(saved)
    let upgraded = try await h.monitor.poll()
    #expect(Set(upgraded.events.map(\.id)) == ["issue:2", "issue:77"])
    #expect(try StateFile(url: h.stateURL).read()?.replyMonitorStart != nil)
    try await h.monitor.acknowledge(ids: upgraded.events.map(\.id))
    h.clock.advance()
    await h.transport.append(searches([pull(updated: 60)], commented: [pull(2, updated: 120)])
        + responseEndpoints(2, inline: [comment(5, by: "sarang", at: -20), comment(6, replyingTo: 5), comment(7, at: 100, replyingTo: 5)]))
    #expect(try await h.monitor.poll().events.map(\.id) == ["reviewComment:7"])
}

@Test func failedReplyBaselineRetriesQuietlyAndDoesNotPersistPartialCursors() async throws {
    let h = Harness([Reply("/user", "{\"login\":\"sarang\"}")] + searches([], commented: [pull()]) + [
        Reply("/repos/owner/repo/issues/1/comments", "[]"),
        Reply("/repos/owner/repo/pulls/1/comments", "{}", status: 500)])
    defer { h.clean() }
    let before = try Data(contentsOf: h.stateURL)
    await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
    #expect(try Data(contentsOf: h.stateURL) == before)
    h.clock.advance()
    let own = comment(1, by: "sarang", at: -20)
    await h.transport.append(searches([], commented: [pull(updated: 60)]) + responseEndpoints(inline: [own, comment(2, replyingTo: 1)]))
    #expect(try await h.monitor.poll().events.isEmpty)
    h.clock.advance()
    await h.transport.append(searches([], commented: [pull(updated: 120)]) + responseEndpoints(inline: [own, comment(2, replyingTo: 1), comment(3, at: 100, replyingTo: 1)]))
    #expect(try await h.monitor.poll().events.map(\.id) == ["reviewComment:3"])
}

@Test func replyDiscoveryStaysScopedAndIncludesClosedReviewedPulls() async throws {
    let h = Harness([Reply("/user", "{\"login\":\"sarang\"}")]
                    + searches([], commented: [pull(2, repository: "other/private")], closedReviewed: [pull(3)])
                    + responseEndpoints(3))
    defer { h.clean() }
    #expect(try await h.monitor.poll().prCount == 1)
    let requests = await h.transport.requests
    #expect(requests.allSatisfy { !$0.url!.path.contains("other/private") })
    let queries = requests.filter { $0.url?.path == "/search/issues" }.map { $0.url!.query!.removingPercentEncoding! }
    #expect(queries.count == 6)
    #expect(queries.allSatisfy { $0.contains("repo:owner/repo") })
    #expect(queries.filter { $0.contains("is:closed") }.allSatisfy { $0.contains("updated:>=") })
    #expect(await h.transport.remaining == 0)
}

@Test func searchRatePauseResumesAtTheUnfinishedParticipationQuery() async throws {
    let h = Harness([Reply("/user", "{\"login\":\"sarang\"}"),
                     Reply("/search/issues", search()), Reply("/search/issues", search()),
                     Reply("/search/issues", "{\"message\":\"secondary rate limit\"}", status: 429, headers: ["Retry-After": "60"])])
    defer { h.clean() }
    let before = try Data(contentsOf: h.stateURL)
    await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
    #expect(try Data(contentsOf: h.stateURL) == before)
    h.clock.advance()
    await h.transport.append(replySearches())
    #expect(try await h.monitor.poll().events.isEmpty)
    #expect(await h.transport.requests.count == 8)
    #expect(await h.transport.remaining == 0)
    #expect(try StateFile(url: h.stateURL).read()?.initialComplete == true)
}

@Test func participationSearchPaginationRetriesTheUnfinishedPageAfterRateLimit() async throws {
    let link = "<https://api.github.com/search/issues?q=is%3Apr%20commenter%3Asarang%20repo%3Aowner%2Frepo&page=2>; rel=\"next\""
    let h = Harness([Reply("/user", "{\"login\":\"sarang\"}"),
                     Reply("/search/issues", search()), Reply("/search/issues", search()),
                     Reply("/search/issues", search([pull()], total: 2), headers: ["link": link]),
                     Reply("/search/issues", "{}", status: 429, headers: ["Retry-After": "60"], queryContains: "page=2")])
    defer { h.clean() }
    await #expect(throws: MonitorError.self) { try await h.monitor.poll() }
    #expect(try StateFile(url: h.stateURL).read()?.prs.isEmpty == true)
    h.clock.advance()
    await h.transport.append([Reply("/search/issues", search([pull(2)], total: 2), queryContains: "page=2")]
        + Array(replySearches().dropFirst()) + responseEndpoints() + responseEndpoints(2))
    let result = try await h.monitor.poll()
    #expect(result.prCount == 2)
    #expect(result.events.isEmpty)
    #expect(await h.transport.requests.filter { $0.url?.query?.contains("page=2") == true }.count == 2)
    #expect(await h.transport.remaining == 0)
}

@Test func newlyIndexedConversationsOnlyNotifyResponsesSinceMonitoringBegan() async throws {
    let h = Harness(initial([]))
    defer { h.clean() }
    _ = try await h.monitor.poll()
    h.clock.advance()
    await h.transport.append(searches([], reviewed: [pull(updated: 60)]) + responseEndpoints(inline: [
        comment(1, by: "sarang", at: -100), comment(2, at: -1, replyingTo: 1),
        comment(3, at: 0, replyingTo: 1), comment(4, at: 20, replyingTo: 1)]))
    #expect(Set(try await h.monitor.poll().events.map(\.id)) == ["reviewComment:3", "reviewComment:4"])
    #expect(await h.transport.remaining == 0)
}
