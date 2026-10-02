//
//  CapsSettings.swift
//  Capsdroppy
//
//  Every setting the droplet has, with defaults equal to what 1.0.5 hard-coded.
//  Stored through the host's own droplet-scoped preferences, never UserDefaults.
//  Lee, live 2026-10-02 10:03am: 'I want to be able to easily toggle
//  notifications on/off at least.'
//
//  Pure values and pure rules, so they can be tested without a host.
//

import DroppyKit
import SwiftUI

struct CapsSettings: Equatable {
    /// Master switch: off means no notch banners at all.
    var notifications = true
    var alertFull = true
    var alertBack = true
    var alertOpened = true
    var alertFiveHour = true
    /// A 5-hour window at or past this fires its banner.
    var fiveHourThreshold = 90.0
    /// A 5-hour window must fall below this before it can fire again.
    var fiveHourRearm = 80.0
    /// Seconds between readings of the snapshot file.
    var refreshSeconds = 60.0
    var showCodex = true
    var showGauge = true

    static let refreshRange = 30.0...300.0
    static let thresholdRange = 50.0...100.0
    static let rearmFloor = 30.0

    /// The re-arm level actually used: never at or above the threshold, or a
    /// window hovering at the threshold would fire again and again.
    var effectiveRearm: Double { min(fiveHourRearm, fiveHourThreshold - 5) }
    var effectiveRefresh: TimeInterval { min(Self.refreshRange.upperBound, max(Self.refreshRange.lowerBound, refreshSeconds)) }

    func allows(_ kind: CapsAlert.Kind) -> Bool {
        guard notifications else { return false }
        switch kind {
        case .full: return alertFull
        case .back: return alertBack
        case .opened: return alertOpened
        case .fiveHour: return alertFiveHour
        }
    }

    /// Alerts the settings let through. The tracker has already recorded the
    /// change either way, so switching a kind back on never replays old ones.
    func filter(_ alerts: [CapsAlert]) -> [CapsAlert] { alerts.filter { allows($0.kind) } }

    enum Key: String {
        case notifications, alertFull, alertBack, alertOpened, alertFiveHour
        case fiveHourThreshold, fiveHourRearm, refreshSeconds, showCodex, showGauge
    }

    @MainActor
    static func load(from prefs: (any DropletPreferencesService)?) -> CapsSettings {
        var s = CapsSettings()
        guard let prefs else { return s }
        func bool(_ k: Key, _ d: Bool) -> Bool { prefs.value(forKey: k.rawValue, default: d) }
        func num(_ k: Key, _ d: Double) -> Double { prefs.value(forKey: k.rawValue, default: d) }
        s.notifications = bool(.notifications, s.notifications)
        s.alertFull = bool(.alertFull, s.alertFull)
        s.alertBack = bool(.alertBack, s.alertBack)
        s.alertOpened = bool(.alertOpened, s.alertOpened)
        s.alertFiveHour = bool(.alertFiveHour, s.alertFiveHour)
        s.fiveHourThreshold = num(.fiveHourThreshold, s.fiveHourThreshold)
        s.fiveHourRearm = num(.fiveHourRearm, s.fiveHourRearm)
        s.refreshSeconds = num(.refreshSeconds, s.refreshSeconds)
        s.showCodex = bool(.showCodex, s.showCodex)
        s.showGauge = bool(.showGauge, s.showGauge)
        return s
    }
}

// MARK: - Settings pane

extension CapsdroppyDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(CapsSettingsPane(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "Notifications", keywords: ["alerts", "banner", "notch", "caps"]),
            SettingsSearchEntry(title: "5-hour alert level", keywords: ["threshold", "percent", "caps"]),
            SettingsSearchEntry(title: "Refresh", keywords: ["interval", "minute", "caps"]),
            SettingsSearchEntry(title: "Show Codex", keywords: ["row", "caps"]),
            SettingsSearchEntry(title: "Show fleet gauge", keywords: ["ring", "notch", "caps"])
        ]
    }
}

private struct CapsSettingsPane: View {
    @ObservedObject var droplet: CapsdroppyDroplet

    private func bool(_ key: CapsSettings.Key, _ path: WritableKeyPath<CapsSettings, Bool>) -> Binding<Bool> {
        Binding(get: { droplet.settings[keyPath: path] }, set: { droplet.setSetting(key, path, $0) })
    }

    private func num(_ key: CapsSettings.Key, _ path: WritableKeyPath<CapsSettings, Double>) -> Binding<Double> {
        Binding(get: { droplet.settings[keyPath: path] }, set: { droplet.setSetting(key, path, $0) })
    }

    private var rearmBinding: Binding<Double> {
        Binding(get: { droplet.settings.effectiveRearm }, set: { droplet.setSetting(.fiveHourRearm, \.fiveHourRearm, $0) })
    }

    private func refreshText(_ s: Double) -> String {
        s < 60 ? "\(Int(s)) sec" : s.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(s / 60)) min" : "\(Int(s / 60)) min \(Int(s) % 60) sec"
    }

    var body: some View {
        let s = droplet.settings
        DropletSettingsPane {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Notifications",
                    subtitle: "Banners that drop from the notch when something changes. Off means none at all.",
                    isOn: bool(.notifications, \.notifications)
                )
            }

            DropletSettingsSection {
                settingsSectionHeader("Banners for")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(title: "An account runs out", isOn: bool(.alertFull, \.alertFull))
                    DropletToggleRow(title: "An account comes back", isOn: bool(.alertBack, \.alertBack))
                    DropletToggleRow(title: "A budget hold lifts", isOn: bool(.alertOpened, \.alertOpened))
                    DropletToggleRow(title: "A 5-hour window runs high", isOn: bool(.alertFiveHour, \.alertFiveHour))
                }
                .disabled(!s.notifications)
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("5-hour alert")
                    Text("When the 5-hour banner fires, and how far a window must fall before it can fire again.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } content: {
                DropletSettingsCard {
                    DropletSliderRow(
                        title: "Alert at",
                        value: "\(Int(s.fiveHourThreshold))%",
                        binding: num(.fiveHourThreshold, \.fiveHourThreshold),
                        range: CapsSettings.thresholdRange,
                        step: 5
                    )
                    DropletSliderRow(
                        title: "Re-arm below",
                        value: "\(Int(s.effectiveRearm))%",
                        binding: rearmBinding,
                        range: CapsSettings.rearmFloor...max(CapsSettings.rearmFloor + 5, s.fiveHourThreshold - 5),
                        step: 5
                    )
                }
                .disabled(!s.notifications || !s.alertFiveHour)
            }

            DropletSettingsSection {
                settingsSectionHeader("Display")
            } content: {
                DropletSettingsCard {
                    DropletSliderRow(
                        title: "Refresh",
                        value: refreshText(s.effectiveRefresh),
                        binding: num(.refreshSeconds, \.refreshSeconds),
                        range: CapsSettings.refreshRange,
                        step: 30
                    )
                    DropletToggleRow(
                        title: "Show Codex",
                        subtitle: "Codex's weekly use as a row under the accounts.",
                        isOn: bool(.showCodex, \.showCodex)
                    )
                    DropletToggleRow(
                        title: "Show fleet gauge",
                        subtitle: "The ring and percentage beside the notch.",
                        isOn: bool(.showGauge, \.showGauge)
                    )
                }
            }
        }
    }
}
