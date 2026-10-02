//
//  CapsSettings.swift
//  Capsdroppy
//
//  Every setting the droplet has. The 1.0.6 settings keep their keys and defaults
//  (which equal what 1.0.5 hard-coded); 1.1.0 adds the account switches, names,
//  the Claude opt-in, extra Codex folders, the Advanced snapshot file and the
//  first-run flag.
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
    /// Seconds between readings. Claude's usage is never asked for faster than every 60.
    var refreshSeconds = 60.0
    var showCodex = true
    var showGauge = true
    /// Claude usage through the Claude Code login saved on this Mac. Off until
    /// the user turns it on, after reading what it does.
    var claudeOptIn = false
    /// Per-account switch, by account id. An account never mentioned is on.
    var accountEnabled: [String: Bool] = [:]
    /// The user's own name for an account, by account id.
    var accountNames: [String: String] = [:]
    /// Codex folders the user added, beside the ones found on their own.
    var codexFolders: [String] = []
    /// Advanced: a snapshot file to read. Empty means none.
    var snapshotPath = ""
    /// The first-run welcome has been dismissed.
    var onboarded = false

    static let refreshRange = 30.0...300.0
    static let thresholdRange = 50.0...100.0
    static let rearmFloor = 30.0

    /// The re-arm level actually used: never at or above the threshold, or a
    /// window hovering at the threshold would fire again and again.
    var effectiveRearm: Double { min(fiveHourRearm, fiveHourThreshold - 5) }
    var effectiveRefresh: TimeInterval { min(Self.refreshRange.upperBound, max(Self.refreshRange.lowerBound, refreshSeconds)) }

    func isEnabled(_ id: String) -> Bool { accountEnabled[id] ?? true }

    /// What the card calls an account: the user's name for it, else the
    /// source's suggestion ("Claude 2", "Codex"). A snapshot row keeps the
    /// names Caps has always shown ("backup" reads "Secondary").
    func name(for account: CapsAccount) -> String {
        if let own = accountNames[account.account]?.trimmingCharacters(in: .whitespaces), !own.isEmpty { return own }
        if account.kind == .snapshot { return capsShortName(account.account) }
        return account.suggestedName ?? capsDisplayName(account.account)
    }

    /// Everything that decides WHAT is read. A change here needs a fresh
    /// reading; a change to a name or an alert level does not.
    struct FetchKey: Equatable {
        var claudeOptIn: Bool
        var accountEnabled: [String: Bool]
        var codexFolders: [String]
        var snapshotPath: String
        var showCodex: Bool
        var refresh: TimeInterval
    }
    var fetchKey: FetchKey {
        FetchKey(claudeOptIn: claudeOptIn, accountEnabled: accountEnabled, codexFolders: codexFolders,
                 snapshotPath: snapshotPath, showCodex: showCodex, refresh: effectiveRefresh)
    }

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
        case claudeOptIn, accountEnabled, accountNames, codexFolders, snapshotPath, onboarded
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
        s.claudeOptIn = bool(.claudeOptIn, s.claudeOptIn)
        s.accountEnabled = prefs.value(forKey: Key.accountEnabled.rawValue, default: s.accountEnabled)
        s.accountNames = prefs.value(forKey: Key.accountNames.rawValue, default: s.accountNames)
        s.codexFolders = prefs.value(forKey: Key.codexFolders.rawValue, default: s.codexFolders)
        s.snapshotPath = prefs.value(forKey: Key.snapshotPath.rawValue, default: s.snapshotPath)
        s.onboarded = bool(.onboarded, s.onboarded)
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
            SettingsSearchEntry(title: "Show Claude usage", keywords: ["claude", "login", "keychain", "opt in", "caps"]),
            SettingsSearchEntry(title: "Codex folders", keywords: ["codex", "home", "add", "account", "caps"]),
            SettingsSearchEntry(title: "Notifications", keywords: ["alerts", "banner", "notch", "caps"]),
            SettingsSearchEntry(title: "5-hour alert level", keywords: ["threshold", "percent", "caps"]),
            SettingsSearchEntry(title: "Refresh", keywords: ["interval", "minute", "caps"]),
            SettingsSearchEntry(title: "Show Codex", keywords: ["row", "caps"]),
            SettingsSearchEntry(title: "Show total gauge", keywords: ["ring", "notch", "caps"]),
            SettingsSearchEntry(title: "Snapshot file", keywords: ["advanced", "json", "caps"])
        ]
    }
}

/// A text field that commits when the user presses Return or leaves it, so
/// typing a path does not re-read anything on every keystroke.
private struct CapsCommitField: View {
    let prompt: String
    let value: String
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { onCommit(text) }
            .onChange(of: focused) { _, now in if !now { onCommit(text) } }
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
    }
}

private struct CapsSettingsPane: View {
    @ObservedObject var droplet: CapsdroppyDroplet
    @State private var folderMessage: String?

    private func bool(_ key: CapsSettings.Key, _ path: WritableKeyPath<CapsSettings, Bool>) -> Binding<Bool> {
        Binding(get: { droplet.settings[keyPath: path] }, set: { droplet.setSetting(key, path, $0) })
    }

    private func num(_ key: CapsSettings.Key, _ path: WritableKeyPath<CapsSettings, Double>) -> Binding<Double> {
        Binding(get: { droplet.settings[keyPath: path] }, set: { droplet.setSetting(key, path, $0) })
    }

    private var rearmBinding: Binding<Double> {
        Binding(get: { droplet.settings.effectiveRearm }, set: { droplet.setSetting(.fiveHourRearm, \.fiveHourRearm, $0) })
    }

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(get: { droplet.settings.isEnabled(id) }, set: { droplet.setAccountEnabled(id, $0) })
    }

    private func name(_ id: String) -> Binding<String> {
        Binding(get: { droplet.settings.accountNames[id] ?? "" }, set: { droplet.setAccountName(id, $0) })
    }

    private func refreshText(_ s: Double) -> String {
        s < 60 ? "\(Int(s)) sec" : s.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(s / 60)) min" : "\(Int(s / 60)) min \(Int(s) % 60) sec"
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// One account: its switch (titled with the name the card shows) and the
    /// name the user can change.
    @ViewBuilder
    private func accountRows(id: String, suggested: String, detail: String, removeFolder: String? = nil) -> some View {
        let shown = droplet.settings.accountNames[id].flatMap { $0.isEmpty ? nil : $0 } ?? suggested
        DropletToggleRow(title: shown, subtitle: detail, isOn: enabled(id))
        DropletControlRow(title: "Name") {
            HStack(spacing: 8) {
                TextField("", text: name(id), prompt: Text(suggested)).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 170)
                if let removeFolder {
                    Button { droplet.removeCodexFolder(removeFolder) } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 24, destructive: true, solidFill: nil, foregroundColorOverride: nil))
                    .help("Stop reading this folder")
                }
            }
        }
        .disabled(!droplet.settings.isEnabled(id))
    }

    var body: some View {
        let s = droplet.settings
        let optedIn = s.claudeOptIn
        DropletSettingsPane {
            if !s.onboarded { welcome }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Codex")
                    note("Read from Codex's own session logs on this Mac. Nothing is sent anywhere.")
                }
            } content: {
                DropletSettingsCard {
                    if droplet.codexHomes.isEmpty {
                        DropletControlRow(title: "No Codex folder found") { DropletValuePill(text: "none") }
                    }
                    ForEach(droplet.codexHomes, id: \.path) { home in
                        accountRows(id: home.accountID, suggested: home.suggestedName, detail: home.path,
                                    removeFolder: home.isAdded ? home.path : nil)
                    }
                    DropletControlRow(title: "Add a Codex folder", infoTip: "A folder that holds Codex's sessions, such as one CODEX_HOME points to.") {
                        HStack(spacing: 8) {
                            CapsCommitField(prompt: "~/work/.codex", value: "") { text in
                                folderMessage = droplet.addCodexFolder(text)
                            }
                            .frame(width: 190)
                        }
                    }
                    if let folderMessage {
                        DropletControlRow(title: folderMessage) { EmptyView() }
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 6) {
                    settingsSectionHeader("Claude")
                    note("Caps can show your exact Claude usage. It reads the Claude Code login already saved on this Mac, and only that.")
                    note("Reads: the Claude Code login in your Mac's keychain. macOS will ask you to allow this.")
                    note("Sends: one usage request to Anthropic for each refresh, from this Mac.")
                    note("Never: stores the login, logs it, or sends it anywhere else.")
                    note("This is not a claude.ai web sign-in. Claude Code keeps the login fresh; Caps never renews it.")
                }
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Show Claude usage",
                        subtitle: "Off until you turn it on. Turning it off stops every request.",
                        isOn: bool(.claudeOptIn, \.claudeOptIn)
                    )
                    if droplet.claudeServices.isEmpty {
                        DropletControlRow(title: "No Claude Code login found") { DropletValuePill(text: "none") }
                    }
                    let names = capsClaudeNames(droplet.claudeServices)
                    ForEach(droplet.claudeServices, id: \.self) { service in
                        Group {
                            accountRows(id: capsClaudeAccountID(service), suggested: names[service] ?? "Claude",
                                        detail: "Claude Code login, keychain item \"\(service)\"")
                        }
                        .disabled(!optedIn)
                    }
                }
            }

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
                    if droplet.hasBudgetHolds {
                        DropletToggleRow(title: "A budget hold lifts", isOn: bool(.alertOpened, \.alertOpened))
                    }
                    DropletToggleRow(title: "A 5-hour window runs high", isOn: bool(.alertFiveHour, \.alertFiveHour))
                }
                .disabled(!s.notifications)
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("5-hour alert")
                    note("When the 5-hour banner fires, and how far a window must fall before it can fire again.")
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
                        subtitle: "Codex's use as rows under the Claude accounts.",
                        isOn: bool(.showCodex, \.showCodex)
                    )
                    DropletToggleRow(
                        title: "Show total gauge",
                        subtitle: "The ring and percentage beside the notch.",
                        isOn: bool(.showGauge, \.showGauge)
                    )
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Advanced")
                    note("Optional. A JSON file of accounts that another tool keeps up to date. Leave it empty if you do not have one.")
                }
            } content: {
                DropletSettingsCard {
                    DropletStackedRow(title: "Snapshot file") {
                        CapsCommitField(prompt: "Path to a snapshot file", value: s.snapshotPath) { text in
                            droplet.setSetting(.snapshotPath, \.snapshotPath, text.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                }
            }
        }
    }

    /// First run: what Caps found on this Mac, before anything is read.
    private var welcome: some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Welcome")
                note("Caps shows how much of your Claude and Codex limits you have used. This is what it found on this Mac. Nothing has been sent anywhere.")
            }
        } content: {
            DropletSettingsCard {
                DropletControlRow(title: "Codex folders found") { DropletValuePill(text: "\(droplet.codexHomes.count)") }
                DropletControlRow(title: "Claude Code logins found") { DropletValuePill(text: "\(droplet.claudeServices.count)") }
                DropletControlRow(title: "Claude is off until you turn it on below") {
                    Button("Got it") { droplet.setSetting(.onboarded, \.onboarded, true) }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                }
            }
        }
    }
}
