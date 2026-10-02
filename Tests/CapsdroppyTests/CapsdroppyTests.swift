import Foundation
import XCTest
@testable import Capsdroppy

final class AlertTrackerTests: XCTestCase {
    private func row(_ id: String, seven: Double, five: Double? = nil, released: Bool? = nil) -> CapsAlertTracker.Snapshot {
        .init(id: id, name: id, sevenDay: seven, fiveHour: five, released: released, ceiling: 60, reset7: "1d", reset5: "1h")
    }

    func testFirstReadingOnlyRecords() {
        var t = CapsAlertTracker()
        XCTAssertTrue(t.update([row("a", seven: 100)]).isEmpty)
    }

    func testRunsOutThenComesBack() {
        var t = CapsAlertTracker()
        _ = t.update([row("a", seven: 50)])
        XCTAssertEqual(t.update([row("a", seven: 100)]).map(\.kind), [.full])
        XCTAssertTrue(t.update([row("a", seven: 100)]).isEmpty)
        XCTAssertEqual(t.update([row("a", seven: 0)]).map(\.kind), [.back])
    }

    func testHoldLiftsOnlyWhenReleaseDecisionExists() {
        var t = CapsAlertTracker()
        _ = t.update([row("a", seven: 10, released: false)])
        XCTAssertEqual(t.update([row("a", seven: 10, released: true)]).map(\.kind), [.opened])
        var none = CapsAlertTracker()
        _ = none.update([row("b", seven: 10)])
        XCTAssertTrue(none.update([row("b", seven: 10)]).isEmpty)
    }

    func testFiveHourFiresOnceAndRearms() {
        var t = CapsAlertTracker()
        _ = t.update([row("a", seven: 10, five: 10)])
        XCTAssertEqual(t.update([row("a", seven: 10, five: 95)]).map(\.kind), [.fiveHour])
        XCTAssertTrue(t.update([row("a", seven: 10, five: 96)]).isEmpty)
        XCTAssertTrue(t.update([row("a", seven: 10, five: 85)]).isEmpty)   // not below 80 yet
        _ = t.update([row("a", seven: 10, five: 70)])
        XCTAssertEqual(t.update([row("a", seven: 10, five: 92)]).map(\.kind), [.fiveHour])
    }
}

final class CodexParseTests: XCTestCase {
    private func line(_ rl: String) -> Data { Data(#"{"type":"event_msg","payload":{"rate_limits":\#(rl)}}"#.utf8) }

    func testBothWindowsByLengthNotPosition() {
        let l = line(#"{"primary":{"used_percent":12.5,"window_minutes":300,"resets_at":2000000000},"secondary":{"used_percent":40,"window_minutes":10080,"resets_at":2000500000}}"#)
        let limits = CodexReader.newestLimits(inLog: l, seenAt: Date())
        XCTAssertEqual(limits?.fiveHour?.usedPercent, 12.5)
        XCTAssertEqual(limits?.sevenDay?.usedPercent, 40)
    }

    func testWeeklyInPrimaryAndEmptySecondary() {
        let l = line(#"{"primary":{"used_percent":98,"window_minutes":10080,"resets_at":2000000000},"secondary":null}"#)
        let limits = CodexReader.newestLimits(inLog: l, seenAt: Date())
        XCTAssertNil(limits?.fiveHour)
        XCTAssertEqual(limits?.sevenDay?.usedPercent, 98)
    }

    func testNewestLineWinsAndNullIsSkipped() {
        var d = line(#"{"primary":{"used_percent":1,"window_minutes":10080,"resets_at":2000000000}}"#)
        d.append(0x0A); d.append(line(#"{"primary":{"used_percent":2,"window_minutes":10080,"resets_at":2000000000}}"#))
        d.append(0x0A); d.append(line("null"))
        XCTAssertEqual(CodexReader.newestLimits(inLog: d, seenAt: Date())?.sevenDay?.usedPercent, 2)
    }
}

final class ClaudeParseTests: XCTestCase {
    func testUsageBothNames() {
        let a = ClaudeUsage.parse(Data(#"{"five_hour":{"utilization":23.0,"resets_at":"2026-10-02T20:00:00.000000+00:00"},"seven_day":{"used_percentage":61,"resets_at":"2026-10-07T01:00:00Z"}}"#.utf8))
        XCTAssertEqual(a?.fiveHour, 23)
        XCTAssertEqual(a?.sevenDay, 61)
        XCTAssertNotNil(a?.sevenDayReset)
    }

    func testLoginScopes() {
        let ok = ClaudeLogin.parse(Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:inference","user:profile"],"expiresAt":1999999999000}}"#.utf8))
        XCTAssertEqual(ok?.canReadUsage, true)
        let no = ClaudeLogin.parse(Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:inference"]}}"#.utf8))
        XCTAssertEqual(no?.canReadUsage, false)
    }

    func testNames() {
        let n = capsClaudeNames(["Claude Code-credentials-zz", "Claude Code-credentials", "Claude Code-credentials-aa"])
        XCTAssertEqual(n["Claude Code-credentials"], "Claude")
        XCTAssertEqual(n["Claude Code-credentials-aa"], "Claude 2")
        XCTAssertEqual(n["Claude Code-credentials-zz"], "Claude 3")
    }

    func testBackoff() {
        XCTAssertEqual(ClaudeKeychainSource.backoff(failures: 1, retryAfter: nil, floor: 60), 60)
        XCTAssertEqual(ClaudeKeychainSource.backoff(failures: 3, retryAfter: nil, floor: 60), 240)
        XCTAssertEqual(ClaudeKeychainSource.backoff(failures: 9, retryAfter: nil, floor: 60), 900)
        XCTAssertEqual(ClaudeKeychainSource.backoff(failures: 1, retryAfter: 300, floor: 60), 300)
    }
}

private struct FakeKeychain: KeychainReading {
    var result: KeychainResult
    func claudeServices() -> [String] { ["Claude Code-credentials"] }
    func credentials(service: String) -> KeychainResult { result }
}

private final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    var reply: HTTPReply
    var requests: [URLRequest] = []
    init(_ reply: HTTPReply) { self.reply = reply }
    func get(_ request: URLRequest) async throws -> HTTPReply { requests.append(request); return reply }
}

final class ClaudeSourceTests: XCTestCase {
    private func login(scopes: String = #"["user:profile"]"#) -> KeychainResult {
        .found(Data(#"{"claudeAiOauth":{"accessToken":"SECRET","scopes":\#(scopes)}}"#.utf8))
    }

    func testSuccessAndHonestHeaders() async {
        let http = FakeHTTP(HTTPReply(status: 200, body: Data(#"{"five_hour":{"utilization":10,"resets_at":"2026-10-02T20:00:00Z"},"seven_day":{"utilization":55,"resets_at":"2026-10-07T01:00:00Z"}}"#.utf8), retryAfter: nil))
        let src = ClaudeKeychainSource(keychain: FakeKeychain(result: login()), http: http, version: "1.1.0")
        await src.configure(services: ["Claude Code-credentials"], refresh: 60)
        let rows = await src.read(now: Date())
        XCTAssertEqual(rows.first?.sevenDayPct, 55)
        XCTAssertEqual(rows.first?.fiveHourPct, 10)
        XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "User-Agent"), "Caps-Droppy/1.1.0")
        XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        // A second read inside the interval sends nothing.
        _ = await src.read(now: Date().addingTimeInterval(10))
        XCTAssertEqual(http.requests.count, 1)
    }

    func testMissingScopeMakesNoRequest() async {
        let http = FakeHTTP(HTTPReply(status: 200, body: Data(), retryAfter: nil))
        let src = ClaudeKeychainSource(keychain: FakeKeychain(result: login(scopes: #"["user:inference"]"#)), http: http, version: "1.1.0")
        await src.configure(services: ["Claude Code-credentials"], refresh: 60)
        let rows = await src.read(now: Date())
        XCTAssertEqual(rows.first?.state, .noUsageScope)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testStatuses() async {
        for (status, state): (Int, CapsAccountState) in [(403, .noUsageScope), (401, .loginExpired), (429, .unreachable), (503, .unreachable)] {
            let http = FakeHTTP(HTTPReply(status: status, body: Data(), retryAfter: nil))
            let src = ClaudeKeychainSource(keychain: FakeKeychain(result: login()), http: http, version: "1.1.0")
            await src.configure(services: ["Claude Code-credentials"], refresh: 60)
            let rows = await src.read(now: Date())
            XCTAssertEqual(rows.first?.state, state, "status \(status)")
        }
    }

    func testDeniedKeychain() async {
        let http = FakeHTTP(HTTPReply(status: 200, body: Data(), retryAfter: nil))
        let src = ClaudeKeychainSource(keychain: FakeKeychain(result: .denied), http: http, version: "1.1.0")
        await src.configure(services: ["Claude Code-credentials"], refresh: 60)
        let rows = await src.read(now: Date())
        XCTAssertEqual(rows.first?.state, .accessDenied)
        XCTAssertTrue(http.requests.isEmpty)
    }
}

final class TotalTests: XCTestCase {
    private func acct(_ id: String, _ kind: CapsAccountKind, _ seven: Double?) -> CapsAccount {
        CapsAccount(account: id, available: true, sevenDayPct: seven, fiveHourPct: nil, sevenDayReset: nil,
                    fiveHourReset: nil, releaseDecision: nil, kind: kind)
    }

    func testCodexStaysOutWhenClaudePresent() {
        XCTAssertEqual(capsTotal([acct("a", .claude, 40), acct("b", .snapshot, 60), acct("c", .codex, 100)]), 50)
    }

    func testCodexOnlyGetsItsOwnTotal() {
        XCTAssertEqual(capsTotal([acct("c", .codex, 30), acct("d", .codex, 50)]), 40)
    }

    func testNoNumbersNoTotal() { XCTAssertNil(capsTotal([acct("a", .claude, nil)])) }

    func testSnapshotShapeStillParses() {
        let json = #"{"generated_at":"2026-10-02T10:00:00","accounts":[{"account":"backup","available":true,"seven_day_pct":50,"release_decision":{"ceiling_pct":60,"hours_to_reset":10,"released":false}}]}"#
        let s = CapsSnapshotLoader.parse(Data(json.utf8))
        XCTAssertEqual(s?.accounts.first?.releaseDecision?.released, false)
        XCTAssertEqual(s?.accounts.first?.kind, .snapshot)
    }
}

/// Opt-in checks against this Mac. Skipped unless the variable is set.
final class RealPathTests: XCTestCase {
    func testRealCodexHome() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAPS_REAL_CODEX"] == "1")
        let homes = CodexReader.homes(added: [])
        let rows = CodexLogSource(homes: homes).readNow(now: Date())
        for r in rows { print("CODEX \(r.suggestedName ?? "?") state=\(r.state) 7d=\(r.sevenDayPct.map { "\($0)" } ?? "nil") 5h=\(r.fiveHourPct.map { "\($0)" } ?? "nil")") }
        XCTAssertFalse(rows.isEmpty)
    }

    /// One real request. The token comes in through the environment of this one
    /// process and only the two percentages are printed.
    func testOneLiveClaudeRequest() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["CAPS_LIVE_TOKEN"] else { throw XCTSkip("no token given") }
        let json = Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","scopes":["user:profile"]}}"#.utf8)
        let src = ClaudeKeychainSource(keychain: FakeKeychain(result: .found(json)), http: SystemHTTP(), version: "1.1.0")
        await src.configure(services: ["Claude Code-credentials"], refresh: 60)
        let rows = await src.read(now: Date())
        print("CLAUDE state=\(rows.first?.state.rawValue ?? "none") 5h=\(rows.first?.fiveHourPct.map { "\($0)" } ?? "nil") 7d=\(rows.first?.sevenDayPct.map { "\($0)" } ?? "nil")")
        // ok with two numbers, or noUsageScope for a login that cannot report usage.
        XCTAssertNotNil(rows.first)
    }
}

final class PaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    /// A window whose reset is `left` seconds away: it has run for 7 days minus `left`.
    private func pace(used: Double, left: TimeInterval) -> CapsPace? {
        capsPace(used: used, resetsAt: now.addingTimeInterval(left), now: now)
    }

    func testMissingOrPastResetHasNoPace() {
        XCTAssertNil(capsPace(used: 50, resetsAt: nil, now: now))
        XCTAssertNil(capsPace(used: 50, resetsAt: now.addingTimeInterval(-60), now: now))
        XCTAssertNil(capsPace(used: 50, resetsAt: now, now: now))
    }

    func testWindowBoundaries() {
        // Reset a full week away: the window has just started.
        let start = pace(used: 10, left: 7 * day)
        XCTAssertEqual(start?.elapsed ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(start?.tooEarly, true)
        XCTAssertEqual(start?.isAhead, false)
        // Reset a second away: the window is over.
        XCTAssertEqual(pace(used: 10, left: 1)?.elapsed ?? 0, 1, accuracy: 1e-5)
        // A reset more than a week away (clock skew) clamps to the start.
        XCTAssertEqual(pace(used: 10, left: 9 * day)?.elapsed, 0)
    }

    func testAheadOfPaceProjectsRunOut() {
        let p = pace(used: 80, left: 3.5 * day)!      // half through, 80% used
        XCTAssertEqual(p.tickPct, 50, accuracy: 1e-9)
        XCTAssertTrue(p.isAhead)
        // 80% in 3.5 days reaches 100% at 4.375 days, 2.625 days before the reset.
        XCTAssertEqual(p.resetsAt.timeIntervalSince(p.runsOutAt!), 2.625 * day, accuracy: 1)
    }

    func testBehindAndExactlyOnPaceAreNotAhead() {
        XCTAssertFalse(pace(used: 30, left: 3.5 * day)!.isAhead)
        XCTAssertNil(pace(used: 30, left: 3.5 * day)!.runsOutAt)
        XCTAssertFalse(pace(used: 50, left: 3.5 * day)!.isAhead)   // a steady pace lands exactly on the reset
    }

    func testZeroAndFullBars() {
        let zero = pace(used: 0, left: 3 * day)!
        XCTAssertFalse(zero.isAhead)
        XCTAssertNil(zero.runsOutAt)
        let full = pace(used: 100, left: 3 * day)!
        XCTAssertTrue(full.isSpent)
        XCTAssertFalse(full.isAhead)
        XCTAssertEqual(capsPaceSentence(full, compact: false), "")
        XCTAssertEqual(pace(used: 140, left: 3 * day)?.used, 100)   // clamped
    }

    func testTooEarlyNeverProjects() {
        let p = pace(used: 50, left: 7 * day - 5 * 3_600)!   // five hours in, half used
        XCTAssertTrue(p.tooEarly)
        XCTAssertFalse(p.isAhead)
        XCTAssertNil(p.runsOutAt)
    }

    func testSentences() {
        XCTAssertTrue(capsPaceSentence(pace(used: 80, left: 3.5 * day)!, compact: false).hasPrefix("ahead of pace, runs out ~"))
        XCTAssertTrue(capsPaceSentence(pace(used: 30, left: 3.5 * day)!, compact: false).hasPrefix("on pace, resets "))
    }
}

final class ClaudeFolderTests: XCTestCase {
    func testSuffixIsTheStartOfTheFolderPathHash() {
        // Measured on a real Claude Code login: its keychain item ends 6c917058.
        XCTAssertEqual(capsClaudeSuffix(forFolder: "/Users/lee/.claude-slide"), "6c917058")
    }

    func testMapsAServiceToItsFolder() {
        let home = URL(fileURLWithPath: "/Users/lee")
        let candidates = ["/Users/lee/.claude", "/Users/lee/.claude-slide", "/Users/lee/.claude-work"]
        XCTAssertEqual(capsClaudeFolder(service: "Claude Code-credentials", candidates: candidates, home: home), "/Users/lee/.claude")
        XCTAssertEqual(capsClaudeFolder(service: "Claude Code-credentials-6c917058", candidates: candidates, home: home), "/Users/lee/.claude-slide")
        XCTAssertNil(capsClaudeFolder(service: "Claude Code-credentials-deadbeef", candidates: candidates, home: home))
    }
}
