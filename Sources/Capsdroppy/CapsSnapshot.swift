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
//  offset (e.g. "2026-09-28T16:05:06.669390"), and JavaScript's `Date`
//  constructor interprets a date-time string with no offset as UTC — verified
//  with `node -e 'new Date("2026-09-28T16:05:06.669390").toISOString()'`,
//  which returns the same instant unshifted. `parseUTCTimestamp` below does
//  the same: it never applies the local (Pacific) offset.
//
//  No network. This droplet only ever reads this one local file.
//

import Foundation

// MARK: - Model

public struct CapsReleaseDecision: Sendable {
    public var ceilingPct: Double?
    public var hoursToReset: Double?
    public var released: Bool?
}

public struct CapsAccount: Sendable, Identifiable {
    public var account: String
    public var available: Bool
    public var sevenDayPct: Double?
    public var fiveHourPct: Double?
    public var sevenDayReset: String?
    public var fiveHourReset: String?
    public var releaseDecision: CapsReleaseDecision?

    public var id: String { account }
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
            let generatedAt = parseUTCTimestamp(generatedAtRaw),
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
            releaseDecision: parseDecision(object["release_decision"])
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
    /// `menubar-snapshot.json` write uses), it is read as UTC — matching
    /// JavaScript's `Date` constructor, verified against this exact
    /// millisecond-plus-microsecond shape.
    static func parseUTCTimestamp(_ raw: String) -> Date? {
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
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        guard let dayStart = dateFormatter.date(from: String(parts[0])) else { return nil }

        let timeOfDay = String(parts[1])
        let timeParts = timeOfDay.split(separator: ":")
        guard timeParts.count == 3,
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]) else { return nil }
        let secondsComponent = timeParts[2].split(separator: ".")
        guard let whole = Int(secondsComponent.first ?? "") else { return nil }
        var fraction: Double = 0
        if secondsComponent.count > 1 {
            let fracString = "0.\(secondsComponent[1])"
            fraction = Double(fracString) ?? 0
        }

        let seconds = Double(hour * 3600 + minute * 60 + whole) + fraction
        return dayStart.addingTimeInterval(seconds)
    }
}

// MARK: - Reading

/// Reproduces `buildReading` in snapshot.ts, including the "blocked account
/// at 100%" rule the brief states explicitly: an unavailable account whose
/// `seven_day_pct` is already >= 100 contributes 100 to the average; any
/// other unavailable account with no usable number contributes nothing (not
/// zero — it is excluded, same as a missing number for an available account).
public func capsBuildReading(_ snapshot: CapsSnapshotFile?, now: Date) -> CapsReading {
    guard let snapshot else {
        return CapsReading(title: "no reading", accounts: [], hasReading: false)
    }

    let age = now.timeIntervalSince(snapshot.generatedAt)
    if age < 0 || age > capsStaleAfterSeconds {
        return CapsReading(title: "no reading", accounts: [], hasReading: false)
    }

    let contributions: [Double] = snapshot.accounts.compactMap { account in
        if !account.available, let pct = account.sevenDayPct, pct >= 100 { return 100 }
        guard let pct = account.sevenDayPct else { return nil }
        return min(100, pct)
    }
    guard !contributions.isEmpty else {
        return CapsReading(title: "no reading", accounts: snapshot.accounts, hasReading: false)
    }

    let usedPct = contributions.reduce(0, +) / Double(contributions.count)
    return CapsReading(title: "\(Int(usedPct.rounded()))%", accounts: snapshot.accounts, hasReading: true)
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
    guard let raw, let reset = CapsSnapshotLoader.parseUTCTimestamp(raw) ?? ISO8601DateFormatter().date(from: raw) else {
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

/// Reproduces `orderAccounts` in snapshot.ts.
public func capsOrderAccounts(_ accounts: [CapsAccount]) -> [CapsAccount] {
    accounts.sorted { left, right in
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
