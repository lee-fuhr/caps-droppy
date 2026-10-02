//
//  CapsSettings.swift
//  Capsdroppy
//
//  Every setting the droplet has. The 1.0.6 settings keep their keys and defaults
//  (which equal what 1.0.5 hard-coded); 1.1.0 adds the account switches, names,
//  the Claude opt-in, extra Codex folders and the Advanced snapshot file.
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

    static let refreshRange = 30.0...300.0
    static let thresholdRange = 50.0...100.0
    static let rearmFloor = 30.0
    static let legacySnapshotPath = "/Users/lee/CC/Work/LFI/_ Operations/menubar-snapshot.json"

    /// The re-arm level actually used: never at or above the threshold, or a
    /// window hovering at the threshold would fire again and again.
    var effectiveRearm: Double { min(fiveHourRearm, fiveHourThreshold - 5) }
    var effectiveRefresh: TimeInterval { min(Self.refreshRange.upperBound, max(Self.refreshRange.lowerBound, refreshSeconds)) }

    func isEnabled(_ id: String) -> Bool { accountEnabled[id] ?? true }

    /// The name the user gave an account, if any.
    func ownName(_ id: String) -> String? {
        let t = accountNames[id]?.trimmingCharacters(in: .whitespaces)
        return (t?.isEmpty ?? true) ? nil : t
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
        case claudeOptIn, accountEnabled, accountNames, codexFolders, snapshotPath
    }

    @MainActor
    static func load(
        from prefs: (any DropletPreferencesService)?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> CapsSettings {
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
        if prefs.hasValue(forKey: Key.snapshotPath.rawValue) {
            s.snapshotPath = prefs.value(forKey: Key.snapshotPath.rawValue, default: s.snapshotPath)
        } else if fileExists(Self.legacySnapshotPath) {
            s.snapshotPath = Self.legacySnapshotPath
        }
        return s
    }
}

// MARK: - Settings pane

extension CapsdroppyDroplet: SettingsPagesProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        if previewEnv["CAPS_PREVIEW_PAGE"] == "claude-details" { return AnyView(CapsClaudeDetailsPage()) }
        return AnyView(CapsSettingsPane(droplet: self))
    }

    public func makeSettingsPage(id: String, context: SettingsPaneContext) -> AnyView? {
        id == "claude-details" ? AnyView(CapsClaudeDetailsPage()) : nil
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "Show Claude usage", keywords: ["claude", "login", "keychain", "opt in", "caps"]),
            SettingsSearchEntry(title: "What Caps reads and sends", keywords: ["claude", "privacy", "disclosure", "caps"]),
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

private func capsNote(_ text: String) -> some View {
    Text(text).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

/// The full disclosure for the Claude switch, one step from the pane. Plain
/// paragraphs under headings: no boxes inside boxes.
private struct CapsClaudeDetailsPage: View {
    private func block(_ title: String, _ lines: [String]) -> some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(.primary)
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 8)
        } content: {
            EmptyView()
        }
    }

    var body: some View {
        DropletSettingsPage {
            block("What Caps reads", [
                "The Claude Code login that Claude Code already saved in this Mac's keychain, under the name \"Claude Code-credentials\". A Claude Code that keeps its login in another folder saves it under the same name with a suffix, and Caps lists those too.",
                "macOS asks you to allow this. Choose Always Allow and it stops asking."
            ])
            block("What Caps sends", [
                "One request to api.anthropic.com for each Claude login you leave on, once per refresh and never more than once a minute. It carries that login to sign in, and says it is Caps-Droppy.",
                "If Anthropic asks it to slow down, Caps waits."
            ])
            block("What Caps never does", [
                "Store the login, write it to a file, log it, or send it anywhere except that one request.",
                "Renew the login. Claude Code does that, so an expired login shows as expired until you use Claude Code.",
                "Use a claude.ai web sign-in. Caps has none, and Anthropic's terms do not allow one to be passed through a third-party tool."
            ])
            block("If a row says it can't report usage", [
                "Anthropic answered that this login is not allowed to read usage. That is not a cap. Signing in to Claude Code again usually fixes it."
            ])
            block("Turning it off", [
                "Switching off \"Show Claude usage\" stops every keychain read and every request at once, and forgets the readings."
            ])
        }
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

    /// One account, a real row, the same for Claude and Codex: the service's mark
    /// and the folder Caps found it in (its identity), a quiet nickname field
    /// beneath, and the switch. The nickname only changes what the card calls it.
    private func accountRow(id: String, kind: CapsAccountKind, primary: String, caption: String? = nil, removeFolder: String? = nil) -> some View {
        Toggle(isOn: enabled(id)) {
            HStack(alignment: .top, spacing: 8) {
                CapsServiceIcon(kind: kind, size: 16).foregroundStyle(.secondary).frame(width: 20).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(primary).lineLimit(1).truncationMode(.middle)
                    if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    TextField("", text: name(id), prompt: Text("Nickname (optional)"))
                        .labelsHidden().textFieldStyle(.roundedBorder).controlSize(.small).frame(maxWidth: 200)
                }
                if let removeFolder {
                    Spacer(minLength: 0)
                    Button { droplet.removeCodexFolder(removeFolder) } label: { Image(systemName: "minus") }
                        .buttonStyle(DroppyCircleButtonStyle(size: 22, destructive: true, solidFill: nil, foregroundColorOverride: nil))
                        .help("Stop reading this folder")
                }
            }
        }
        .toggleStyle(.switch)
    }

    private func tilde(_ path: String) -> String {
        // The home folder may be spelled with or without a /private prefix.
        for home in [droplet.homeDirectory.path, droplet.homeDirectory.standardizedFileURL.path] {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        return path
    }

    var body: some View {
        let s = droplet.settings
        let optedIn = s.claudeOptIn
        DropletSettingsPane {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Claude")
                    capsNote("Reads the Claude Code login saved on this Mac and sends one usage request to Anthropic per refresh. macOS asks first.")
                }
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Show Claude usage",
                        subtitle: "Off until you turn it on. Turning it off stops every request.",
                        isOn: bool(.claudeOptIn, \.claudeOptIn)
                    )
                    DropletSettingsPageLink("What Caps reads and sends", subtitle: "The full detail, including what it never does.", page: "claude-details") {
                        Image(systemName: "info.circle").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Claude Code logins")
                    capsNote("Found automatically on this Mac, in the keychain. Each shows the config folder it belongs to.")
                }
            } content: {
                DropletSettingsCard {
                    if droplet.claudeServices.isEmpty {
                        capsNote("No Claude Code login found on this Mac. Sign in to Claude Code and it will show up here.")
                    }
                    ForEach(droplet.claudeServices, id: \.self) { service in
                        let folder = droplet.claudeFolders[service]
                        accountRow(id: capsClaudeAccountID(service), kind: .claude,
                                   primary: folder.map(tilde) ?? "Claude Code login",
                                   caption: folder == nil ? "macOS keychain item \u{201C}\(service)\u{201D}; its config folder could not be worked out" : nil)
                            .disabled(!optedIn)
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Codex folders")
                    capsNote("Found automatically on this Mac (~/.codex and any ~/.codex-* beside it). Caps reads only their session logs; nothing is sent anywhere.")
                }
            } content: {
                DropletSettingsCard {
                    if droplet.codexHomes.isEmpty {
                        capsNote("No Codex folder found. Caps looks in ~/.codex. If you keep Codex somewhere else (CODEX_HOME) or use a second Codex login, add that folder below.")
                    }
                    ForEach(droplet.codexHomes, id: \.path) { home in
                        accountRow(id: home.accountID, kind: .codex, primary: tilde(home.path),
                                   caption: home.isAdded ? "Added by you" : nil,
                                   removeFolder: home.isAdded ? home.path : nil)
                    }
                    DropletControlRow(title: "Add a Codex folder", infoTip: "Pick the folder that holds Codex's sessions folder, such as one CODEX_HOME points to.") {
                        Button("Choose…") { folderMessage = droplet.chooseCodexFolder() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    DropletControlRow(title: "Or type its path") {
                        CapsCommitField(prompt: "~/.codex-work", value: "") { text in
                            folderMessage = droplet.addCodexFolder(text)
                        }
                        .frame(width: 200)
                    }
                    if let folderMessage { capsNote(folderMessage) }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Notifications")
                    capsNote("For every account together. Banners that drop from the notch when something changes.")
                }
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(title: "Show banners", isOn: bool(.notifications, \.notifications))
                    Group {
                        DropletToggleRow(title: "An account runs out", isOn: bool(.alertFull, \.alertFull))
                        DropletToggleRow(title: "An account comes back", isOn: bool(.alertBack, \.alertBack))
                        if droplet.hasBudgetHolds {
                            DropletToggleRow(title: "A budget hold lifts", isOn: bool(.alertOpened, \.alertOpened))
                        }
                        DropletToggleRow(title: "A 5-hour window runs high", isOn: bool(.alertFiveHour, \.alertFiveHour))
                    }
                    .disabled(!s.notifications)
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("5-hour alert")
                    capsNote("When the 5-hour banner fires, and how far a window must fall before it can fire again.")
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
                    capsNote("Optional. A JSON file of accounts that another tool keeps up to date. Leave it empty if you do not have one.")
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
}
