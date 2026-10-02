//
//  UsageSource.swift
//  Capsdroppy
//
//  Where numbers come from. Three sources, one shape:
//
//    CodexLogSource        Codex's own session logs (CodexReading.swift)
//    ClaudeKeychainSource  Anthropic's usage endpoint, opt-in (ClaudeUsage.swift)
//    SnapshotFileSource    an optional JSON file, the Advanced setting
//
//  Each returns rows the shelf card draws. A source never throws: a problem is
//  a row with a state ("login expired"), never a missing droplet.
//

import Foundation

protocol UsageSource: Sendable {
    func read(now: Date) async -> [CapsAccount]
}

/// ISO 8601 with a zone, the form `parseSnapshotTimestamp` reads back.
func capsISO(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

/// The Advanced snapshot file: a JSON file some other tool keeps current, with
/// one entry per account (seven_day_pct, five_hour_pct, resets and an optional
/// release_decision). Empty path means no snapshot source at all. Read-only.
struct SnapshotFileSource: UsageSource {
    var path: String

    func read(now: Date) async -> [CapsAccount] { readNow(now: now) }

    func readNow(now: Date) -> [CapsAccount] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return capsSnapshotAccounts(CapsSnapshotLoader.load(from: expanded), now: now)
    }
}
