//
//  CodexReading.swift
//  Capsdroppy
//
//  Codex's limits, read from Codex's own session logs. Codex writes a
//  `rate_limits` object into <home>/sessions/YYYY/MM/DD/*.jsonl on every turn;
//  the newest one is the reading. It carries up to two windows, each with its
//  own length in minutes (300 is the 5-hour window, 10080 the 7-day one), so
//  they are told apart by `window_minutes`, never by position: on some plans
//  "primary" is the weekly window and "secondary" is empty.
//
//  Read-only. A home is a folder like ~/.codex, or any folder a user points
//  Codex at with CODEX_HOME.
//

import Foundation

/// One rate-limit window as Codex logged it.
struct CodexWindow: Equatable, Sendable {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date

    enum Slot { case fiveHour, sevenDay }

    /// 300 is the 5-hour window and 10080 the 7-day one. Anything else is put
    /// with the nearer of the two, so a plan that changes a length still shows.
    var slot: Slot { windowMinutes < 3_000 ? .fiveHour : .sevenDay }
}

/// A Codex folder with its newest reading.
struct CodexLimits: Equatable, Sendable {
    var fiveHour: CodexWindow?
    var sevenDay: CodexWindow?
    /// When the log line was written (the file's modification time).
    var seenAt: Date
}

/// A folder Codex keeps its sessions in.
struct CodexHome: Equatable, Sendable, Hashable {
    var url: URL
    /// Found on its own (~/.codex and its siblings), or added by the user.
    var isAdded: Bool

    var path: String { url.path }
    var accountID: String { "codex:\(path)" }

    /// ".codex" reads as "Codex", ".codex-work" as "Codex Work", "team-codex" as "Team Codex".
    var suggestedName: String {
        var name = url.lastPathComponent
        while name.hasPrefix(".") { name.removeFirst() }
        let shown = capsDisplayName(name)
        return shown.isEmpty ? "Codex" : shown
    }
}

enum CodexReader {
    /// Day folders to look back through, and logs to look into, per read. The
    /// whole tree is thousands of logs and this runs about once a minute.
    private static let daysBack = 4
    private static let logsPerHome = 10
    /// A log line is a few KB; the newest rate limit is near the end of the file.
    private static let tailBytes = 1_048_576

    // MARK: Finding homes

    /// ~/.codex, any ~/.codex-something beside it that has sessions, $CODEX_HOME,
    /// and the folders the user added. Each must be a folder with a `sessions`
    /// folder inside.
    static func homes(added: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> [CodexHome] {
        var found: [CodexHome] = []
        var seen = Set<String>()
        func add(_ url: URL, isAdded: Bool) {
            let url = url.standardizedFileURL
            guard hasSessions(url), seen.insert(url.path).inserted else { return }
            found.append(CodexHome(url: url, isAdded: isAdded))
        }
        add(home.appendingPathComponent(".codex"), isAdded: false)
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        for name in siblings.sorted() where name.hasPrefix(".codex") && name != ".codex" {
            add(home.appendingPathComponent(name), isAdded: false)
        }
        if let env = environment["CODEX_HOME"], !env.isEmpty {
            add(URL(fileURLWithPath: (env as NSString).expandingTildeInPath), isAdded: false)
        }
        for path in added where !path.isEmpty {
            add(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), isAdded: true)
        }
        return found
    }

    static func hasSessions(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("sessions").path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Reading

    /// The newest reading in this home, or nil when its recent logs hold none.
    static func latest(in home: CodexHome, now: Date = Date()) -> CodexLimits? {
        let sessions = home.url.appendingPathComponent("sessions")
        let calendar = Calendar(identifier: .gregorian)
        var logs: [(URL, Date)] = []
        for back in 0..<daysBack {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessions.appendingPathComponent(
                String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files where url.pathExtension == "jsonl" {
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    logs.append((url, date))
                }
            }
        }
        for (url, date) in logs.sorted(by: { $0.1 > $1.1 }).prefix(logsPerHome) {
            guard let tail = readTail(url) else { continue }
            if var limits = newestLimits(inLog: tail, seenAt: date) {
                // A window whose reset has passed is a window that has started over.
                limits.fiveHour = limits.fiveHour.map { renewed($0, now) }
                limits.sevenDay = limits.sevenDay.map { renewed($0, now) }
                return limits
            }
        }
        return nil
    }

    private static func renewed(_ w: CodexWindow, _ now: Date) -> CodexWindow {
        w.resetsAt > now ? w : CodexWindow(usedPercent: 0, windowMinutes: w.windowMinutes, resetsAt: w.resetsAt)
    }

    private static func readTail(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    /// The last line in a log that carries a usable `rate_limits`.
    static func newestLimits(inLog data: Data, seenAt: Date) -> CodexLimits? {
        let marker = Data("\"rate_limits\"".utf8)
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard line.range(of: marker) != nil, let windows = parseLine(Data(line)), !windows.isEmpty else { continue }
            var limits = CodexLimits(fiveHour: nil, sevenDay: nil, seenAt: seenAt)
            for w in windows {
                switch w.slot {
                case .fiveHour: if limits.fiveHour == nil { limits.fiveHour = w }
                case .sevenDay: if limits.sevenDay == nil { limits.sevenDay = w }
                }
            }
            return limits
        }
        return nil
    }

    /// The windows in one JSON log line, wherever `rate_limits` sits in it.
    static func parseLine(_ line: Data) -> [CodexWindow]? {
        guard let root = try? JSONSerialization.jsonObject(with: line),
              let limits = find("rate_limits", in: root) as? [String: Any]
        else { return nil }
        return ["primary", "secondary"].compactMap { key in
            guard let w = limits[key] as? [String: Any],
                  let used = (w["used_percent"] as? NSNumber)?.doubleValue,
                  let minutes = (w["window_minutes"] as? NSNumber)?.intValue,
                  let reset = (w["resets_at"] as? NSNumber)?.doubleValue
            else { return nil }
            return CodexWindow(usedPercent: used, windowMinutes: minutes, resetsAt: Date(timeIntervalSince1970: reset))
        }
    }

    private static func find(_ key: String, in node: Any, depth: Int = 0) -> Any? {
        guard depth < 4, let dict = node as? [String: Any] else { return nil }
        if let hit = dict[key], !(hit is NSNull) { return hit }
        for value in dict.values { if let hit = find(key, in: value, depth: depth + 1) { return hit } }
        return nil
    }
}

// MARK: - The source

struct CodexLogSource: UsageSource {
    var homes: [CodexHome]

    func read(now: Date) async -> [CapsAccount] { readNow(now: now) }

    func readNow(now: Date) -> [CapsAccount] {
        homes.map { home in
            let limits = CodexReader.latest(in: home, now: now)
            return CapsAccount(
                account: home.accountID, available: true,
                sevenDayPct: limits?.sevenDay?.usedPercent,
                fiveHourPct: limits?.fiveHour?.usedPercent,
                sevenDayReset: limits?.sevenDay.map { capsISO($0.resetsAt) },
                fiveHourReset: limits?.fiveHour.map { capsISO($0.resetsAt) },
                releaseDecision: nil, kind: .codex, suggestedName: home.suggestedName,
                state: limits == nil ? .noActivity : .ok, seenAt: limits?.seenAt)
        }
    }
}
