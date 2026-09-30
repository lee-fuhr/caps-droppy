//
//  CodexReading.swift
//  Capsdroppy
//
//  Codex's weekly limit, read from Codex's own session logs. Codex writes a
//  `rate_limits` object into ~/.codex/sessions/YYYY/MM/DD/*.jsonl on every
//  turn; the newest one is the reading. It only moves when Codex runs, so the
//  card shows how old it is.
//

import Foundation

struct CodexReading: Sendable, Equatable {
    /// Weekly window use, 0...100.
    var pct: Double
    var resetsAt: Date
    /// When the log line was written (the file's modification time).
    var seenAt: Date
}

enum CodexReader {
    static let sessionsRoot = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")

    private static let weekly = try! NSRegularExpression(
        pattern: #""primary":\{"used_percent":([0-9.]+),"window_minutes":10080,"resets_at":([0-9]+)"#
    )

    /// Newest weekly reading across the most recently written session logs,
    /// or nil when there is none. Reads only; never writes.
    static func load() -> CodexReading? {
        // Only the last few day folders: the whole tree is thousands of logs,
        // and this runs once a minute.
        let calendar = Calendar(identifier: .gregorian)
        var logs: [(URL, Date)] = []
        for back in 0..<4 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessionsRoot.appendingPathComponent(
                String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files where url.pathExtension == "jsonl" {
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    logs.append((url, date))
                }
            }
        }
        for (url, date) in logs.sorted(by: { $0.1 > $1.1 }).prefix(10) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = weekly.matches(in: text, range: range).last,
                  let pctRange = Range(match.range(at: 1), in: text),
                  let resetRange = Range(match.range(at: 2), in: text),
                  let pct = Double(text[pctRange]),
                  let reset = Double(text[resetRange])
            else { continue }
            return CodexReading(pct: pct, resetsAt: Date(timeIntervalSince1970: reset), seenAt: date)
        }
        return nil
    }
}
