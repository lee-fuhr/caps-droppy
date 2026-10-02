//
//  Pace.swift
//  Capsdroppy
//
//  The one question a 7-day bar answers: am I on pace to run out before it
//  resets? The window is 7 days and ends at the reset, so it started at
//  reset minus 7 days. A steady pace has used (elapsed share of the window) of
//  the allowance by now; use more and the straight line from the start through
//  today reaches 100% before the reset. Pure, so it can be tested without a UI.
//

import Foundation

struct CapsPace: Equatable {
    /// How far through the 7-day window it is, 0...1. The pace tick sits here.
    var elapsed: Double
    /// Used share, 0...100.
    var used: Double
    /// When a straight-line projection hits 100%, if that is before the reset.
    var runsOutAt: Date?
    var resetsAt: Date
    /// Too early in the window (under 6 hours in) to project anything honestly.
    var tooEarly: Bool

    var isSpent: Bool { used >= 100 }
    /// Using more than a steady pace allows, and enough of the window has passed to say so.
    var isAhead: Bool { !tooEarly && !isSpent && runsOutAt != nil }
    /// Where the pace tick sits, as a percentage of the bar.
    var tickPct: Double { elapsed * 100 }

    static let window: TimeInterval = 7 * 86_400
    static let minimumElapsed: TimeInterval = 6 * 3_600
}

/// Pace for one 7-day reading, or nil without a usable reset (missing, or already past).
func capsPace(used: Double, resetsAt: Date?, now: Date) -> CapsPace? {
    guard let resetsAt, resetsAt > now else { return nil }
    let start = resetsAt.addingTimeInterval(-CapsPace.window)
    let sinceStart = min(CapsPace.window, max(0, now.timeIntervalSince(start)))
    let used = min(100, max(0, used))
    let tooEarly = sinceStart < CapsPace.minimumElapsed
    var runsOut: Date?
    if !tooEarly, used > 0, used < 100 {
        // used / sinceStart is the rate; 100 / rate is how long the whole allowance lasts.
        let t = start.addingTimeInterval(sinceStart * (100 / used))
        if t < resetsAt { runsOut = t }
    }
    return CapsPace(elapsed: sinceStart / CapsPace.window, used: used, runsOutAt: runsOut, resetsAt: resetsAt, tooEarly: tooEarly)
}

/// "Tue 4pm", in the user's time zone.
func capsDayHour(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "EEE h a"
    return f.string(from: date).replacingOccurrences(of: " AM", with: "am").replacingOccurrences(of: " PM", with: "pm")
}

/// The footer's sentence about pace.
func capsPaceSentence(_ p: CapsPace, compact: Bool) -> String {
    if p.isSpent { return "" }
    if let out = p.runsOutAt { return compact ? "ahead · out ~\(capsDayHour(out))" : "ahead of pace, runs out ~\(capsDayHour(out))" }
    if p.tooEarly { return compact ? "resets \(capsDayHour(p.resetsAt))" : "early in the week, resets \(capsDayHour(p.resetsAt))" }
    return compact ? "on pace · \(capsDayHour(p.resetsAt))" : "on pace, resets \(capsDayHour(p.resetsAt))"
}
