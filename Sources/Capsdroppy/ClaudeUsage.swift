//
//  ClaudeUsage.swift
//  Capsdroppy
//
//  Claude usage, from the Claude Code login already saved on this Mac. Opt-in:
//  nothing here runs until the user turns the switch on in settings.
//
//  What it does, per login and per refresh (never faster than once a minute):
//    1. reads the login from the macOS keychain (macOS asks the user first),
//    2. sends ONE request to https://api.anthropic.com/api/oauth/usage with it,
//    3. keeps the two percentages and forgets the login.
//  The login is never written to disk, never logged, never sent anywhere else,
//  and never refreshed by Caps: renewing it is Claude Code's job.
//
//  This is the user's own Claude Code login on their own Mac. It is not a
//  claude.ai web session, and Caps has no claude.ai sign-in of any kind.
//

import CryptoKit
import Foundation
import Security

// MARK: - Keychain

/// What the keychain said when asked for one login.
enum KeychainResult: Sendable, Equatable {
    case found(Data)
    case missing
    /// macOS did not allow it: the user pressed Deny, or the Mac is locked.
    case denied
}

protocol KeychainReading: Sendable {
    /// Service names of the Claude Code logins saved here. Names only: this
    /// never asks for a secret, so it never asks the user anything.
    func claudeServices() -> [String]
    /// The saved login for one service. This is the call macOS asks about.
    func credentials(service: String) -> KeychainResult
}

/// "Claude Code-credentials", plus "Claude Code-credentials-<hash>" for a
/// Claude Code that keeps its login in a custom config folder.
let claudeServicePrefix = "Claude Code-credentials"

struct SystemKeychain: KeychainReading {
    func claudeServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            // Attributes only. Asking for the data is what makes macOS prompt.
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        let names = items.compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0 == claudeServicePrefix || $0.hasPrefix(claudeServicePrefix + "-") }
        return Array(Set(names)).sorted()
    }

    func credentials(service: String) -> KeychainResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else { return .missing }
            return .found(data)
        case errSecItemNotFound:
            return .missing
        default:
            return .denied
        }
    }
}

/// Suggested names for the logins found: "Claude", "Claude 2", "Claude 3", the
/// plain service first and the hashed ones in a stable order after it.
func capsClaudeNames(_ services: [String]) -> [String: String] {
    let ordered = services.sorted { a, b in
        if (a == claudeServicePrefix) != (b == claudeServicePrefix) { return a == claudeServicePrefix }
        return a < b
    }
    var names: [String: String] = [:]
    for (i, s) in ordered.enumerated() { names[s] = i == 0 ? "Claude" : "Claude \(i + 1)" }
    return names
}

func capsClaudeAccountID(_ service: String) -> String { "claude:\(service)" }

/// Claude Code names a login's keychain item "Claude Code-credentials" for its
/// default folder (~/.claude) and "Claude Code-credentials-<8 hex>" for any other
/// config folder, where the 8 hex are the start of the SHA-256 of that folder's
/// absolute path. Checked against a real login on this Mac: "6c917058" is
/// sha256("/Users/lee/.claude-slide").
func capsClaudeSuffix(forFolder path: String) -> String {
    SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
}

/// The config folders worth hashing: every ".claude*" folder in the home folder,
/// the folders inside those (people keep one per account in a parent), and
/// CLAUDE_CONFIG_DIR.
func capsClaudeCandidateFolders(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
    let fm = FileManager.default
    func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
    var out: [String] = []
    for name in ((try? fm.contentsOfDirectory(atPath: home.path)) ?? []).sorted() where name.hasPrefix(".claude") {
        let path = home.appendingPathComponent(name).path
        guard isDir(path) else { continue }
        out.append(path)
        for child in ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted() where !child.hasPrefix(".") {
            let sub = path + "/" + child
            if isDir(sub) { out.append(sub) }
        }
    }
    if let env = environment["CLAUDE_CONFIG_DIR"], !env.isEmpty { out.append((env as NSString).expandingTildeInPath) }
    return out
}

/// The folder a keychain item belongs to, or nil when no candidate matches.
func capsClaudeFolder(service: String, candidates: [String], home: URL) -> String? {
    if service == claudeServicePrefix { return home.appendingPathComponent(".claude").path }
    let suffix = String(service.dropFirst(claudeServicePrefix.count + 1))
    return candidates.first { capsClaudeSuffix(forFolder: $0) == suffix }
}

// MARK: - Network

struct HTTPReply: Sendable {
    var status: Int
    var body: Data
    var retryAfter: TimeInterval?
}

protocol HTTPFetching: Sendable {
    func get(_ request: URLRequest) async throws -> HTTPReply
}

struct SystemHTTP: HTTPFetching {
    func get(_ request: URLRequest) async throws -> HTTPReply {
        // Ephemeral: no cookies, no cache, nothing kept on disk.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let retry = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
        return HTTPReply(status: http?.statusCode ?? 0, body: data, retryAfter: retry)
    }
}

// MARK: - Parsing

/// The saved login's JSON, reduced to what is needed to decide and ask.
struct ClaudeLogin {
    var accessToken: String
    var scopes: [String]?
    var expiresAt: Date?

    /// `{"claudeAiOauth": {"accessToken": ..., "scopes": [...], "expiresAt": <ms>}}`
    static func parse(_ data: Data) -> ClaudeLogin? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let scopes = (oauth["scopes"] as? [Any])?.compactMap { $0 as? String }
        var expires: Date?
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            expires = Date(timeIntervalSince1970: ms > 1e11 ? ms / 1000 : ms)
        }
        return ClaudeLogin(accessToken: token, scopes: scopes, expiresAt: expires)
    }

    /// A login with a scope list that leaves out `user:profile` cannot read usage.
    var canReadUsage: Bool { scopes?.contains("user:profile") ?? true }
}

/// The two windows Anthropic reports.
struct ClaudeUsage: Equatable {
    var fiveHour: Double?
    var sevenDay: Double?
    var fiveHourReset: Date?
    var sevenDayReset: Date?

    /// `five_hour` and `seven_day`, each with a utilization (older name:
    /// used_percentage) and a reset time. Both optional; neither present is nil.
    static func parse(_ data: Data) -> ClaudeUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> (Double?, Date?) {
            guard let w = root[key] as? [String: Any] else { return (nil, nil) }
            let pct = ((w["utilization"] ?? w["used_percentage"]) as? NSNumber)?.doubleValue
            return (pct, date(w["resets_at"]))
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five.0 != nil || seven.0 != nil else { return nil }
        return ClaudeUsage(fiveHour: five.0, sevenDay: seven.0, fiveHourReset: five.1, sevenDayReset: seven.1)
    }

    private static func date(_ raw: Any?) -> Date? {
        if let n = raw as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 1e11 ? v / 1000 : v)
        }
        guard let s = raw as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - The source

actor ClaudeKeychainSource: UsageSource {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// The fastest the network is asked, whatever the refresh setting says.
    static let minimumInterval: TimeInterval = 60

    private struct Entry {
        var account: CapsAccount
        var nextAllowed: Date
        var failures = 0
        var lastGood: Date?
    }

    private let keychain: any KeychainReading
    private let http: any HTTPFetching
    private let userAgent: String
    private var entries: [String: Entry] = [:]
    private var services: [String] = []
    private var interval: TimeInterval = ClaudeKeychainSource.minimumInterval

    init(keychain: any KeychainReading, http: any HTTPFetching, version: String) {
        self.keychain = keychain
        self.http = http
        // Honest about what is asking. Never a Claude Code user agent.
        self.userAgent = "Caps-Droppy/\(version)"
    }

    /// Which logins to read, and how often at most. Logins no longer listed
    /// are forgotten.
    func configure(services: [String], refresh: TimeInterval) {
        self.services = services
        self.interval = max(Self.minimumInterval, refresh)
        entries = entries.filter { services.contains($0.key) }
    }

    /// Forgets every reading (the switch was turned off).
    func reset() { entries = [:]; services = [] }

    func read(now: Date) async -> [CapsAccount] {
        let names = capsClaudeNames(services)
        var rows: [CapsAccount] = []
        for service in services {
            if let e = entries[service], now < e.nextAllowed.addingTimeInterval(-2) {
                rows.append(e.account)
                continue
            }
            let fresh = await fetch(service, name: names[service] ?? "Claude", now: now, previous: entries[service])
            entries[service] = fresh
            rows.append(fresh.account)
        }
        return rows
    }

    private func row(_ service: String, _ name: String, _ state: CapsAccountState) -> CapsAccount {
        CapsAccount(account: capsClaudeAccountID(service), available: true, sevenDayPct: nil, fiveHourPct: nil,
                    sevenDayReset: nil, fiveHourReset: nil, releaseDecision: nil,
                    kind: .claude, suggestedName: name, state: state)
    }

    private func fetch(_ service: String, name: String, now: Date, previous: Entry?) async -> Entry {
        let wait = interval
        func stop(_ state: CapsAccountState, retryIn: TimeInterval) -> Entry {
            Entry(account: row(service, name, state), nextAllowed: now.addingTimeInterval(retryIn))
        }
        // 1. The saved login. This is where macOS asks the user.
        let data: Data
        switch keychain.credentials(service: service) {
        case .found(let d): data = d
        // A "no" is not asked again for ten minutes, so a refusal never becomes a stream of prompts.
        case .denied: return stop(.accessDenied, retryIn: max(600, wait))
        case .missing: return stop(.loginExpired, retryIn: max(300, wait))
        }
        guard let login = ClaudeLogin.parse(data) else { return stop(.loginExpired, retryIn: max(300, wait)) }
        if !login.canReadUsage { return stop(.noUsageScope, retryIn: max(600, wait)) }
        if let expires = login.expiresAt, expires <= now { return stop(.loginExpired, retryIn: wait) }

        // 2. One request. The login is used here and goes out of scope below.
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let reply: HTTPReply
        do { reply = try await http.get(request) } catch {
            return failed(service, name, now: now, previous: previous, retryAfter: nil)
        }
        switch reply.status {
        case 200:
            guard let usage = ClaudeUsage.parse(reply.body) else {
                return failed(service, name, now: now, previous: previous, retryAfter: nil)
            }
            var account = row(service, name, .ok)
            account.sevenDayPct = usage.sevenDay
            account.fiveHourPct = usage.fiveHour
            account.sevenDayReset = usage.sevenDayReset.map(capsISO)
            account.fiveHourReset = usage.fiveHourReset.map(capsISO)
            account.seenAt = now
            return Entry(account: account, nextAllowed: now.addingTimeInterval(wait), failures: 0, lastGood: now)
        case 401: return stop(.loginExpired, retryIn: wait)
        // 403: this login's scopes leave out usage. Not a cap, not an outage.
        case 403: return stop(.noUsageScope, retryIn: max(600, wait))
        default: return failed(service, name, now: now, previous: previous, retryAfter: reply.retryAfter)
        }
    }

    /// 429, 5xx, no network: back off, and keep the last good numbers for a while.
    private func failed(_ service: String, _ name: String, now: Date, previous: Entry?, retryAfter: TimeInterval?) -> Entry {
        let failures = (previous?.failures ?? 0) + 1
        let delay = Self.backoff(failures: failures, retryAfter: retryAfter, floor: interval)
        var account = row(service, name, .unreachable)
        if let prev = previous, let good = prev.lastGood, now.timeIntervalSince(good) < 900 {
            account = prev.account
        }
        return Entry(account: account, nextAllowed: now.addingTimeInterval(delay), failures: failures, lastGood: previous?.lastGood)
    }

    /// Doubles from the refresh interval to a quarter hour, or obeys Retry-After.
    static func backoff(failures: Int, retryAfter: TimeInterval?, floor: TimeInterval) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return min(3600, max(floor, retryAfter)) }
        return min(900, max(floor, floor * pow(2, Double(max(0, failures - 1)))))
    }
}
