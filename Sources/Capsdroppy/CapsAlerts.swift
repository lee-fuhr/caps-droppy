//
//  CapsAlerts.swift
//  Capsdroppy
//
//  One notch banner per change, never on a timer and never repeated while the
//  condition holds. Lee, live 2026-09-30 11:47am, picked all four:
//  an account runs out, an account comes back, a budget hold lifts, and a
//  5-hour window passes 90%.
//

import DroppyKit
import SwiftUI

/// What changed between two readings, in the order a banner shows them.
struct CapsAlert: Equatable {
    enum Kind: Equatable { case full, back, opened, fiveHour }
    var kind: Kind
    var title: String
    var detail: String
}

/// Remembers the last reading and turns the next one into alerts.
/// Pure logic, no UI, so the rules can be tested on their own.
struct CapsAlertTracker {
    private var spent: [String: Bool] = [:]
    private var released: [String: Bool] = [:]
    /// Armed once a 5-hour window fires; re-armed only after it drops below the re-arm level (80% by default),
    /// so a window hovering around 90% does not fire again and again.
    private var fiveFired: [String: Bool] = [:]
    private var primed = false

    /// Accounts are (id, display name, 7-day %, 5-hour %, released?, 7-day reset, 5-hour reset, cap %).
    struct Snapshot {
        var id: String; var name: String
        var sevenDay: Double?; var fiveHour: Double?
        var released: Bool?; var ceiling: Double?
        var reset7: String; var reset5: String
    }

    /// Drops everything remembered about one account, so it reads as new when it
    /// returns (a hidden Codex row, switched back on, fires nothing stale).
    mutating func forget(_ id: String) {
        spent[id] = nil; released[id] = nil; fiveFired[id] = nil
    }

    /// Alerts for this reading. The first reading after launch only records
    /// state: starting Droppy is not an event. A 5-hour window fires at
    /// `fiveHourThreshold` and re-arms below `rearm` (defaults 90 and 80).
    /// Settings filter what is shown; state is recorded for every kind either way.
    mutating func update(_ accounts: [Snapshot], fiveHourThreshold: Double = 90, rearm: Double = 80) -> [CapsAlert] {
        var alerts: [CapsAlert] = []
        for a in accounts {
            guard let seven = a.sevenDay else { continue }
            let isSpent = seven >= 100
            if primed, let was = spent[a.id], was != isSpent {
                alerts.append(isSpent
                    ? CapsAlert(kind: .full, title: "\(a.name) is full", detail: "Back in \(a.reset7)")
                    : CapsAlert(kind: .back, title: "\(a.name) is back", detail: "A fresh week to use"))
            }
            spent[a.id] = isSpent

            if let r = a.released {
                if primed, released[a.id] == false, r == true {
                    let cap = a.ceiling.map { "up to \(Int($0.rounded()))% of the week" } ?? "it again"
                    alerts.append(CapsAlert(kind: .opened, title: "\(a.name) hold lifted", detail: "Backlog may use \(cap)"))
                }
                released[a.id] = r
            }

            if let five = a.fiveHour {
                let fired = fiveFired[a.id] ?? false
                if five >= fiveHourThreshold, !fired, !isSpent {
                    if primed {
                        alerts.append(CapsAlert(kind: .fiveHour, title: "\(a.name) 5-hour at \(Int(five.rounded()))%",
                                                detail: "Resets in \(a.reset5)"))
                    }
                    fiveFired[a.id] = true
                } else if five < rearm {
                    fiveFired[a.id] = false
                }
            }
        }
        primed = true
        return alerts
    }
}

extension CapsAlert {
    var tint: Color {
        switch kind {
        case .full: return Color(red: 1.00, green: 0.42, blue: 0.38)
        case .back, .opened: return Color(red: 0.42, green: 0.84, blue: 0.62)
        case .fiveHour: return Color(red: 1.00, green: 0.72, blue: 0.32)
        }
    }
}

/// The banner: the gauge in the alert's color on the strip, and the sentence on
/// the card it grows into. Several changes at once share one banner.
@MainActor
func capsPresent(_ alerts: [CapsAlert], on hud: any DropletHUDService) {
    guard let first = alerts.first else { return }
    let title = alerts.count == 1 ? first.title : alerts.map(\.title).joined(separator: " · ")
    let detail = alerts.count == 1 ? first.detail : "\(alerts.count) changes"
    let tint = first.tint
    hud.present(
        DropletHUDRequest(
            id: "caps.alert",
            duration: 5,
            priority: .normal,
            accessibilityLabel: "Caps: \(title). \(detail)",
            isExpanded: true,
            expandedContentHeight: 40
        ) {
            HStack(spacing: 0) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
        } expanded: {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText).lineLimit(1)
                    Text(detail).font(.system(size: 10))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    )
}
