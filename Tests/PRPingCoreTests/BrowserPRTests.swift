import Foundation
import Testing
@testable import PRPingCore

private let browserScope = WatchScope(mode: .repositories, sources: ["owner/repo"], login: "sarang", host: "github.com")

@Test func browserPRCanonicalisesAnAllowedPullRequest() throws {
    for address in ["https://github.com/Owner/Repo/pull/42", "https://github.com/owner/repo/pull/42/files?diff=split#discussion_r1",
                    "https://github.com/owner/repo/pull/42/commits"] {
        let parsed = try #require(BrowserPR.parse(URL(string: address)!, scope: browserScope))
        #expect(parsed.repository == "owner/repo")
        #expect(parsed.number == 42)
        #expect(parsed.url.absoluteString == "https://github.com/owner/repo/pull/42")
    }
    let organisation = WatchScope(mode: .organisations, sources: ["owner"], login: "sarang", host: "github.com")
    #expect(BrowserPR.parse(URL(string: "https://github.com/owner/tools/pull/1")!, scope: organisation) != nil)
}

@Test func browserPRRejectsUntrustedOrUnselectedURLs() {
    for address in ["http://github.com/owner/repo/pull/1", "https://github.com.evil.example/owner/repo/pull/1",
                    "https://evil.example/owner/repo/pull/1", "https://github.com:443/owner/repo/pull/1",
                    "https://user@github.com/owner/repo/pull/1", "https://github.com/owner/other/pull/1",
                    "https://github.com/owner/repo/issues/1", "https://github.com/owner/repo/pull",
                    "https://github.com/owner/repo/pull/0", "https://github.com/owner/repo/pull/-1",
                    "https://github.com/owner/repo/pull/1.0", "https://github.com/owner/repo/pull/999999999999999999999999",
                    "https://github.com/owner%2Frepo/other/pull/1"] {
        #expect(BrowserPR.parse(URL(string: address)!, scope: browserScope) == nil, "Accepted \(address)")
    }
}
