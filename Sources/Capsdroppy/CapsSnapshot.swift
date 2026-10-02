//
//  CapsSnapshot.swift
//  Capsdroppy
//
//  Reads and interprets /Users/lee/CC/Work/LFI/_ Operations/menubar-snapshot.json.
//
//  This is a direct port of the parsing and formatting rules in
//  /Users/lee/Sites/caps-raycast/src/snapshot.ts (parseSnapshot, buildReading,
//  formatTaper, formatReset, orderAccounts, displayName, formatPercentage),
//  per the brief's instruction to reuse that logic rather than invent new
//  rules. Behaviour is meant to match that file value for value, including
//  its date handling: `generated_at` in the snapshot carries no timezone
//  offset (e.g. "2026-09-28T16:05:06.669390") and is written in LOCAL time
//  (menubar_snapshot.py writes a naive local datetime). JavaScript's `Date`
//  reads an offset-free date-time as local too. `parseSnapshotTimestamp`
//  below does the same. It first shipped reading it as UTC, which put every
//  reading 7 hours in the future and showed "no reading" (Lee, 2026-09-29).
//
//  This file only reads a local file; the network lives in ClaudeUsage.swift.
//

import Foundation

// MARK: - Model

public struct CapsReleaseDecision: Sendable {
    public var ceilingPct: Double?
    public var hoursToReset: Double?
    public var released: Bool?
}

/// Where an account's numbers came from.
public enum CapsAccountKind: String, Sendable {
    /// A row from the optional snapshot file (Advanced setting).
    case snapshot
    /// A Claude Code login on this Mac, read through Anthropic's usage endpoint.
    case claude
    /// A Codex home folder, read from its session logs.
    case codex
}

/// Why an account has no numbers, when it has none. `ok` means it has them.
public enum CapsAccountState: String, Sendable {
    case ok
    /// Waiting for the first reading.
    case pending
    /// The saved login has no permission to report usage (Anthropic answered 403).
    case noUsageScope
    /// The saved login has expired; Claude Code renews it the next time it runs.
    case loginExpired
    /// macOS did not allow Caps to read the saved login.
    case accessDenied
    /// Anthropic could not be reached, or answered with an error. Retrying.
    case unreachable
    /// A Codex folder with no rate-limit line in its recent logs.
    case noActivity
}

public struct CapsAccount: Sendable, Identifiable {
    public var account: String
    public var available: Bool
    public var sevenDayPct: Double?
    public var fiveHourPct: Double?
    public var sevenDayReset: String?
    public var fiveHourReset: String?
    public var releaseDecision: CapsReleaseDecision?
    public var kind: CapsAccountKind = .snapshot
    /// The name the source suggests ("Claude 2", "Codex"). The user's own
    /// name for the account, if any, wins over it.
    public var suggestedName: String?
    public var state: CapsAccountState = .ok
    /// When the reading was taken (Codex: the log's own time).
    public var seenAt: Date?

    public var id: String { account }
    public var hasNumbers: Bool { sevenDayPct != nil || fiveHourPct != nil }
}

public struct CapsSnapshotFile: Sendable {
    public var generatedAt: Date
    public var accounts: [CapsAccount]
}

public struct CapsReading: Sendable {
    /// "42%" or "no reading".
    public var title: String
    public var accounts: [CapsAccount]
    public var hasReading: Bool
}

// MARK: - Staleness

/// Same threshold as caps-raycast/src/snapshot.ts: STALE_AFTER_MS.
private let capsStaleAfterSeconds: TimeInterval = 5 * 60

// MARK: - Parsing

public enum CapsSnapshotLoader {
    /// Parses the file only. Returns nil for missing, unreadable, or
    /// structurally malformed JSON — the caller treats nil exactly like
    /// `parseSnapshot` returning null in the TypeScript version: "no reading".
    public static func load(from path: String) -> CapsSnapshotFile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> CapsSnapshotFile? {
        guard
            let raw = try? JSONSerialization.jsonObject(with: data),
            let object = raw as? [String: Any],
            let generatedAtRaw = object["generated_at"] as? String,
            let generatedAt = parseSnapshotTimestamp(generatedAtRaw),
            let accountsRaw = object["accounts"] as? [Any]
        else { return nil }

        var accounts: [CapsAccount] = []
        accounts.reserveCapacity(accountsRaw.count)
        for entry in accountsRaw {
            guard let account = parseAccount(entry) else { return nil }
            accounts.append(account)
        }
        return CapsSnapshotFile(generatedAt: generatedAt, accounts: accounts)
    }

    private static func parseAccount(_ raw: Any) -> CapsAccount? {
        guard
            let object = raw as? [String: Any],
            let account = object["account"] as? String,
            let available = object["available"] as? Bool
        else { return nil }

        return CapsAccount(
            account: account,
            available: available,
            sevenDayPct: optionalNumber(object["seven_day_pct"]),
            fiveHourPct: optionalNumber(object["five_hour_pct"]),
            sevenDayReset: optionalString(object["seven_day_reset"]),
            fiveHourReset: optionalString(object["five_hour_reset"]),
            releaseDecision: parseDecision(object["release_decision"]),
            kind: (object["kind"] as? String).flatMap(CapsAccountKind.init(rawValue:)) ?? .snapshot,
            suggestedName: optionalString(object["name"]),
            state: (object["state"] as? String).flatMap(CapsAccountState.init(rawValue:)) ?? .ok
        )
    }

    private static func parseDecision(_ raw: Any?) -> CapsReleaseDecision? {
        guard let object = raw as? [String: Any] else { return nil }
        return CapsReleaseDecision(
            ceilingPct: optionalNumber(object["ceiling_pct"]),
            hoursToReset: optionalNumber(object["hours_to_reset"]),
            released: object["released"] as? Bool
        )
    }

    /// Mirrors `optionalNumber` in snapshot.ts: present-but-wrong-type values
    /// are dropped (become "no value") rather than invalidating the record.
    private static func optionalNumber(_ raw: Any?) -> Double? {
        guard let raw else { return nil }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func optionalString(_ raw: Any?) -> String? {
        raw as? String
    }

    /// Parses an ISO 8601 timestamp. If it carries an explicit offset or `Z`,
    /// that offset is honoured. If it carries none (the shape every
    /// `menubar-snapshot.json` write uses), it is read as local time, the
    /// same way the writer produced it.
    static func parseSnapshotTimestamp(_ raw: String) -> Date? {
        if raw.hasSuffix("Z") || raw.dropFirst(10).contains("+") || raw.dropFirst(10).contains("-") {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: raw) { return date }
            let isoNoFraction = ISO8601DateFormatter()
            isoNoFraction.formatOptions = [.withInternetDateTime]
            if let date = isoNoFraction.date(from: raw) { return date }
        }

        // No offset: split at "T", parse the date and time-of-day separately
        // so any fractional-second precision (snapshot.json writes to the
        // microsecond) is accepted without a fixed-width format string.
        let parts = raw.split(separator: "T", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let dateParts = parts[0].split(separator: "-")
        let timeParts = parts[1].split(separator: ":")
        guard dateParts.count == 3, timeParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]) else { return nil }
        let secondsComponent = timeParts[2].split(separator: ".")
        guard let whole = Int(secondsComponent.first ?? "") else { return nil }
        var fraction: Double = 0
        if secondsComponent.count > 1 {
            fraction = Double("0.\(secondsComponent[1])") ?? 0
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: whole)
        guard let date = calendar.date(from: components) else { return nil }
        return date.addingTimeInterval(fraction)
    }
}

// MARK: - Reading

/// The snapshot file's accounts, or none when the file is missing, malformed or
/// older than five minutes (a stale file is no reading, as in snapshot.ts).
public func capsSnapshotAccounts(_ snapshot: CapsSnapshotFile?, now: Date) -> [CapsAccount] {
    guard let snapshot else { return [] }
    let age = now.timeIntervalSince(snapshot.generatedAt)
    if age < 0 || age > capsStaleAfterSeconds { return [] }
    return snapshot.accounts
}

/// The average 7-day use that the ring and the header call the total.
///
/// Claude-family accounts (snapshot rows and Claude logins) make the total, with
/// `buildReading`'s rule from snapshot.ts: an unavailable account already at 100
/// counts as 100, and one with no number counts for nothing. Codex has its own
/// limits, so it stays out of the total whenever a Claude-family account has a
/// number; a Codex-only setup gets a total of its own.
public func capsTotal(_ accounts: [CapsAccount]) -> Double? {
    func contributions(_ list: [CapsAccount]) -> [Double] {
        list.compactMap { account in
            if !account.available, let pct = account.sevenDayPct, pct >= 100 { return 100 }
            guard let pct = account.sevenDayPct else { return nil }
            return min(100, pct)
        }
    }
    var values = contributions(accounts.filter { $0.kind != .codex })
    if values.isEmpty { values = contributions(accounts.filter { $0.kind == .codex }) }
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

/// Same rule applied to a whole reading, kept for the snapshot-only path.
public func capsBuildReading(_ snapshot: CapsSnapshotFile?, now: Date) -> CapsReading {
    capsBuildReading(accounts: capsSnapshotAccounts(snapshot, now: now))
}

public func capsBuildReading(accounts: [CapsAccount]) -> CapsReading {
    guard let total = capsTotal(accounts) else {
        return CapsReading(title: "no reading", accounts: accounts, hasReading: false)
    }
    return CapsReading(title: "\(Int(total.rounded()))%", accounts: accounts, hasReading: true)
}

// MARK: - Taper line

/// Reproduces `formatTaper` in snapshot.ts verbatim, including its exact
/// wording — the brief requires the same wording Caps and the Raycast
/// command already use.
public func capsFormatTaper(_ decision: CapsReleaseDecision?, _ now: Date) -> String {
    guard
        let decision,
        let ceilingPct = decision.ceilingPct,
        let hoursToReset = decision.hoursToReset,
        hoursToReset > 0
    else { return "no reading" }

    let ceiling = min(100, max(0, ceilingPct))
    if decision.released == true {
        return "Backlog can use up to \(capsFormatPct(ceiling)) now"
    }

    let reset = now.addingTimeInterval(hoursToReset * 60 * 60)
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    calendar.timeZone = .current

    let weekdayFormatter = DateFormatter()
    weekdayFormatter.locale = Locale(identifier: "en_US")
    weekdayFormatter.timeZone = .current
    weekdayFormatter.dateFormat = "EEE"
    let weekday = weekdayFormatter.string(from: reset)

    let hourFormatter = DateFormatter()
    hourFormatter.locale = Locale(identifier: "en_US")
    hourFormatter.timeZone = .current
    hourFormatter.dateFormat = "h"
    let hour = hourFormatter.string(from: reset)

    let dayPeriodFormatter = DateFormatter()
    dayPeriodFormatter.locale = Locale(identifier: "en_US")
    dayPeriodFormatter.timeZone = .current
    dayPeriodFormatter.dateFormat = "a"
    let dayPeriod = dayPeriodFormatter.string(from: reset).lowercased()

    return "Held for client work until about \(weekday) \(hour)\(dayPeriod)"
}

func capsFormatPct(_ value: Double) -> String {
    let rounded = value.rounded()
    if abs(rounded - value) < 0.05 {
        return "\(Int(rounded))%"
    }
    return String(format: "%.1f%%", value)
}

// MARK: - Reset formatting

/// Reproduces `formatReset` in snapshot.ts.
public func capsFormatReset(_ raw: String?, _ now: Date) -> String {
    guard let raw, let reset = CapsSnapshotLoader.parseSnapshotTimestamp(raw) ?? ISO8601DateFormatter().date(from: raw) else {
        return "reset unknown"
    }
    let seconds = Int(reset.timeIntervalSince(now))
    if seconds <= 0 { return "reset pending" }
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return "resets in \(days)d \(hours)h" }
    if hours > 0 { return "resets in \(hours)h \(minutes)m" }
    if minutes > 0 { return "resets in \(minutes)m" }
    return "resets in <1m"
}

// MARK: - Ordering and display

private let capsAccountOrder: [String: Int] = [
    "primary": 0,
    "secondary": 1,
    "backup": 2,
    "tertiary": 3,
    "quaternary": 4
]

/// Reproduces `orderAccounts` in snapshot.ts, with snapshot rows first, then
/// Claude logins, then Codex folders.
public func capsOrderAccounts(_ accounts: [CapsAccount]) -> [CapsAccount] {
    func group(_ k: CapsAccountKind) -> Int { k == .snapshot ? 0 : k == .claude ? 1 : 2 }
    return accounts.sorted { left, right in
        if group(left.kind) != group(right.kind) { return group(left.kind) < group(right.kind) }
        let leftRank = capsAccountOrder[left.account] ?? Int.max
        let rightRank = capsAccountOrder[right.account] ?? Int.max
        if leftRank != rightRank { return leftRank < rightRank }
        return left.account < right.account
    }
}

/// Reproduces `displayName` in snapshot.ts: "backup" reads as "Secondary" in
/// the UI (Caps' own naming for that slot), while every other identifier is
/// title-cased word by word.
public func capsDisplayName(_ account: String) -> String {
    if account == "backup" { return "Secondary" }
    return account
        .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        .map { word -> String in
            guard let first = word.first else { return "" }
            return first.uppercased() + word.dropFirst()
        }
        .joined(separator: " ")
}

/// Reproduces `formatPercentage` in snapshot.ts.
public func capsFormatPercentage(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "no reading" }
    return capsFormatPct(value)
}
