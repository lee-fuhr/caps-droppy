//
//  CapsdroppyDroplet.swift
//  Capsdroppy
//
//  Caps: how much of your Claude and Codex limits you have used, on Droppy's
//  shelf and beside the notch.
//
//  Numbers come from up to three sources (see UsageSource.swift): Codex's own
//  session logs, Claude through the Claude Code login saved on this Mac (opt-in,
//  ClaudeUsage.swift), and an optional snapshot file (Advanced setting). The
//  droplet reads; it never writes outside Droppy's own preferences.
//

import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(CapsdroppyPrincipal)
public final class CapsdroppyPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { CapsdroppyDroplet() }
}

/// Preview only (the harness cannot see a real Mac's accounts). Each variable is
/// unset in Droppy, so none of these does anything there:
///   CAPS_PREVIEW_SNAPSHOT  a snapshot file to read, as the Advanced setting would
///   CAPS_PREVIEW_HOME      a folder to look for Codex homes in, instead of the real home
///   CAPS_PREVIEW_KEYCHAIN  comma-separated Claude keychain service names to list; the
///                          keychain is never touched and no request is sent
///   CAPS_PREVIEW_OPTIN=1   the Claude switch on
///   CAPS_PREVIEW_ONBOARDED=1  the welcome dismissed
///   CAPS_PREVIEW_ALERT=1   a sample banner
///   CAPS_PREVIEW_HOVER     an account id to render hovered
private let previewEnv = ProcessInfo.processInfo.environment

/// A keychain that lists the names it is told and holds a login that cannot
/// report usage, so a preview never touches the real keychain or the network.
private struct PreviewKeychain: KeychainReading {
    var services: [String]
    func claudeServices() -> [String] { services }
    func credentials(service: String) -> KeychainResult {
        .found(Data(#"{"claudeAiOauth":{"accessToken":"preview","scopes":["user:inference"]}}"#.utf8))
    }
}

private struct NoNetwork: HTTPFetching {
    func get(_ request: URLRequest) async throws -> HTTPReply { throw URLError(.notConnectedToInternet) }
}

/// Caps' usage readings, from every source the user has switched on.
@MainActor
public final class CapsdroppyDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "capsdroppy"

    private var host: DropletHost?
    private var ticker: AnyCancellable?
    private var alerts = CapsAlertTracker()
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)

    private var settingsSub: AnyCancellable?
    private var tickerSeconds: TimeInterval = 0
    private var fetchKey: CapsSettings.FetchKey?
    @Published private(set) var settings = CapsSettings()

    /// What the card draws: enabled accounts, ordered. `hasReading` means a total exists.
    @Published private(set) var reading: CapsReading = CapsReading(title: "no reading", accounts: [], hasReading: false)
    /// Found on this Mac, shown in settings whether or not they are switched on.
    @Published private(set) var codexHomes: [CodexHome] = []
    @Published private(set) var claudeServices: [String] = []
    /// True when any account carries a release_decision (a snapshot with budget holds).
    @Published private(set) var hasBudgetHolds = false

    private var snapshotAccounts: [CapsAccount] = []
    private var codexAccounts: [CapsAccount] = []
    private var claudeAccounts: [CapsAccount] = []
    private var knownIDs = Set<String>()
    private var lastDiscovery = Date.distantPast
    private var claudeTask: Task<Void, Never>?

    private let keychain: any KeychainReading
    private let claude: ClaudeKeychainSource
    private let homeDirectory: URL

    public override init() {
        let preview = previewEnv["CAPS_PREVIEW_KEYCHAIN"]
        let list = preview.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let keychain: any KeychainReading = list.map { PreviewKeychain(services: $0) } ?? SystemKeychain()
        let version = (Bundle(for: CapsdroppyPrincipal.self).infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1"
        self.keychain = keychain
        self.claude = ClaudeKeychainSource(keychain: keychain, http: preview == nil ? SystemHTTP() : NoNetwork(), version: version)
        self.homeDirectory = previewEnv["CAPS_PREVIEW_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        super.init()
    }

    public func activate(host: DropletHost) throws {
        self.host = host
        settings = loadSettings()
        fetchKey = settings.fetchKey
        refresh(discover: true)
        host.log.info("Caps activated: \(self.reading.title)")
        if previewEnv["CAPS_PREVIEW_ALERT"] == "1" {
            capsPresent([CapsAlert(kind: .full, title: "Claude is full", detail: "Back in 1d 14h")], on: host.hud)
        }

        // About once a minute by default; the refresh setting changes it.
        scheduleTicker()
        // A change from the settings pane (or anywhere else) applies at once.
        settingsSub = host.preferences.didChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsChanged() }
    }

    private func loadSettings() -> CapsSettings {
        var s = CapsSettings.load(from: host?.preferences)
        if previewEnv["CAPS_PREVIEW_OPTIN"] == "1" { s.claudeOptIn = true }
        if previewEnv["CAPS_PREVIEW_ONBOARDED"] == "1" { s.onboarded = true }
        if let path = previewEnv["CAPS_PREVIEW_SNAPSHOT"] { s.snapshotPath = path }
        return s
    }

    /// Writes one setting and applies it.
    func setSetting<V: Codable>(_ key: CapsSettings.Key, _ path: WritableKeyPath<CapsSettings, V>, _ value: V) {
        host?.preferences.setValue(value, forKey: key.rawValue)
        var next = settings
        next[keyPath: path] = value
        if next != settings { settings = next; settingsChanged() }
    }

    func setAccountEnabled(_ id: String, _ on: Bool) {
        var map = settings.accountEnabled
        map[id] = on
        setSetting(.accountEnabled, \.accountEnabled, map)
    }

    func setAccountName(_ id: String, _ name: String) {
        var map = settings.accountNames
        map[id] = name.isEmpty ? nil : name
        setSetting(.accountNames, \.accountNames, map)
    }

    /// Adds a Codex folder. Returns a sentence when it cannot, nil when it worked.
    @discardableResult
    func addCodexFolder(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let path = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL.path
        guard CodexReader.hasSessions(URL(fileURLWithPath: path)) else {
            return "That folder has no sessions folder in it, so it is not a Codex home."
        }
        if codexHomes.contains(where: { $0.path == path }) { return "Already in the list." }
        setSetting(.codexFolders, \.codexFolders, settings.codexFolders + [path])
        return nil
    }

    func removeCodexFolder(_ path: String) {
        setSetting(.codexFolders, \.codexFolders, settings.codexFolders.filter { $0 != path })
    }

    private func settingsChanged() {
        guard host != nil else { return }
        settings = loadSettings()
        scheduleTicker()
        let key = settings.fetchKey
        if key != fetchKey {
            // What is read changed: read again. Switching Claude off forgets its readings at once.
            let optInChanged = key.claudeOptIn != fetchKey?.claudeOptIn
            fetchKey = key
            refresh(discover: optInChanged)
        } else {
            // A name or an alert level: nothing to fetch, just redraw.
            rebuild()
        }
    }

    private func scheduleTicker() {
        let seconds = settings.effectiveRefresh
        guard ticker == nil || seconds != tickerSeconds else { return }
        tickerSeconds = seconds
        ticker = Timer.publish(every: seconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    public func deactivate() {
        ticker?.cancel()
        ticker = nil
        settingsSub?.cancel()
        settingsSub = nil
        claudeTask?.cancel()
        claudeTask = nil
        let claude = claude
        Task { await claude.reset() }
        activitySubject.send(nil)
        host = nil
    }

    // MARK: Reading

    /// One reading from every source. The file sources are read here; Claude's
    /// request runs off the main thread and lands in `rebuild()` when it returns.
    private func refresh(discover: Bool = false) {
        let now = Date()
        let s = settings
        codexHomes = CodexReader.homes(added: s.codexFolders, home: homeDirectory)
        snapshotAccounts = SnapshotFileSource(path: s.snapshotPath).readNow(now: now)
        let homes = s.showCodex ? codexHomes.filter { s.isEnabled($0.accountID) } : []
        codexAccounts = CodexLogSource(homes: homes).readNow(now: now)
        rebuild()
        refreshClaude(discover: discover || now.timeIntervalSince(lastDiscovery) > 300)
    }

    /// Lists the Claude Code logins (names only), and, when the user has opted
    /// in, reads usage for the enabled ones.
    private func refreshClaude(discover: Bool) {
        claudeTask?.cancel()
        let keychain = keychain, claude = claude
        let optIn = settings.claudeOptIn
        claudeTask = Task { [weak self] in
            if discover {
                let found = await Task.detached(priority: .utility) { keychain.claudeServices() }.value
                guard let self, !Task.isCancelled else { return }
                self.claudeServices = found
                self.lastDiscovery = Date()
            }
            guard let self, !Task.isCancelled else { return }
            guard optIn else {
                await claude.reset()
                if !self.claudeAccounts.isEmpty { self.claudeAccounts = []; self.rebuild() }
                return
            }
            let s = self.settings
            let services = self.claudeServices.filter { s.isEnabled(capsClaudeAccountID($0)) }
            await claude.configure(services: services, refresh: s.effectiveRefresh)
            let rows = await claude.read(now: Date())
            guard !Task.isCancelled else { return }
            self.claudeAccounts = rows
            self.rebuild()
        }
    }

    /// Puts the latest readings together: enabled accounts, in order, with the
    /// total. Cheap, so a rename can call it without fetching anything.
    private func rebuild() {
        let before = cardHeight
        let enabled = (snapshotAccounts + claudeAccounts + codexAccounts).filter { settings.isEnabled($0.account) }
        reading = capsBuildReading(accounts: capsOrderAccounts(enabled))
        hasBudgetHolds = reading.accounts.contains { $0.releaseDecision?.ceilingPct != nil }
        publishActivity()
        announceChanges()
        // An account coming or going changes the card's height.
        if cardHeight != before { host?.shelf.invalidateLayout(for: "fleet") }
    }

    /// One notch banner per real change (see CapsAlerts.swift). A missing
    /// reading is not a change: state is only compared between two readings.
    private func announceChanges() {
        guard let host else { return }
        let now = Date()
        let rows = reading.accounts.filter { $0.hasNumbers }.map { a in
            CapsAlertTracker.Snapshot(
                id: a.account, name: settings.name(for: a),
                sevenDay: a.sevenDayPct, fiveHour: a.fiveHourPct,
                released: a.releaseDecision?.released, ceiling: a.releaseDecision?.ceilingPct,
                reset7: capsUntil(a.sevenDayReset, now), reset5: capsUntil(a.fiveHourReset, now))
        }
        // An account that went away reads as new when it returns, so nothing stale fires.
        let ids = Set(rows.map(\.id))
        for gone in knownIDs.subtracting(ids) { alerts.forget(gone) }
        knownIDs = ids
        // The tracker records every change; settings only decide what is shown.
        let changes = settings.filter(
            alerts.update(rows, fiveHourThreshold: settings.fiveHourThreshold, rearm: settings.effectiveRearm))
        if !changes.isEmpty {
            capsPresent(changes, on: host.hud)
            host.log.info("Caps alert: \(changes.map(\.title).joined(separator: "; "))")
        }
    }

    /// The total as a fraction 0...1 for the ring, or nil when there is no total.
    var totalFraction: Double? {
        guard let total = capsTotal(reading.accounts) else { return nil }
        return min(1, max(0, total / 100))
    }

    /// Same 70/90 thresholds `accountSeverity` in snapshot.ts uses for a
    /// single account's severity: green under 70, amber 70..<90, red 90+.
    var totalTint: Color {
        guard let fraction = totalFraction else { return AdaptiveColors.notchSurfaceTertiaryText }
        let pct = fraction * 100
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }

    /// Codex has its own limits, so it is left out of the total whenever a
    /// Claude account has a number.
    var codexIsOutsideTotal: Bool {
        reading.accounts.contains { $0.kind != .codex && $0.sevenDayPct != nil }
    }
}

// MARK: - Shelf widget (one row per account, bars on one scale)

extension CapsdroppyDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                // The id stays "fleet": it is the key Droppy keeps a user's shelf layout under.
                id: "fleet",
                title: "Caps",
                systemImage: "gauge.with.dots.needle.67percent",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 300,
                    preferredPairedWidth: 150,
                    // Sized to the rows actually showing; see cardHeight.
                    contentHeight: .fixed(cardHeight)
                ),
                searchKeywords: ["claude", "quota", "usage", "caps", "codex", "limit"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(CapsShelfWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }

    /// Opens this droplet's settings, for the empty card's button.
    func openSettings() { _ = host?.workspace.openSettings() }

    /// Exact content height: 8pt host insets top and bottom, the 16pt header and
    /// 8pt under it, then the rows (or the empty state).
    var cardHeight: CGFloat {
        guard !reading.accounts.isEmpty else { return 8 + 16 + 8 + 12 + 8 + 22 + 8 }
        // Every row is 36 (28 of content, 4pt hover margin above and below),
        // and Codex steps 8 apart from the Claude rows above it.
        let kinds = Set(reading.accounts.map { $0.kind == .codex })
        let rows = CGFloat(reading.accounts.count) * 36 + (kinds.count == 2 ? 8 : 0)
        // Footer: a hairline with 6pt either side, then one 12pt line.
        return 8 + 16 + 8 + rows + 12.5 + 12 + 8
    }
}

// MARK: Card tokens

/// Droppy's own three text tones on the notch surface.
private let t1 = AdaptiveColors.notchSurfacePrimaryText
private let t2 = AdaptiveColors.notchSurfaceSecondaryText
private let t3 = AdaptiveColors.notchSurfaceTertiaryText

/// Use: green under 70, amber 70..<90, red 90+ (Caps' own thresholds).
private let calm = Color(red: 0.42, green: 0.84, blue: 0.62)
private let warm = Color(red: 1.00, green: 0.72, blue: 0.32)
private let hot = Color(red: 1.00, green: 0.42, blue: 0.38)
private func tone(_ p: Double) -> Color { p >= 90 ? hot : p >= 70 ? warm : calm }
private func fiveTone(_ p: Double) -> Color { p >= 90 ? hot : p >= 70 ? warm : t2 }

/// Three sizes only: 16 numbers, 12 names, 10 details.
private extension Font {
    static let capsNum = Font.system(size: 16, weight: .semibold)
    static let capsUnit = Font.system(size: 10, weight: .semibold)
    static let capsName = Font.system(size: 12, weight: .semibold)
    static let capsDetail = Font.system(size: 10)
}

func capsShortName(_ account: String) -> String {
    switch account {
    case "backup": return "Secondary"
    default: return capsDisplayName(account)
    }
}

/// "5d 8h", "14h", "13m": time until a reset, largest two units.
func capsUntil(_ raw: String?, _ now: Date) -> String {
    guard let raw, let date = CapsSnapshotLoader.parseSnapshotTimestamp(raw) ?? ISO8601DateFormatter().date(from: raw) else { return "–" }
    return capsUntil(date, now)
}

func capsUntil(_ date: Date, _ now: Date) -> String {
    let s = Int(max(0, date.timeIntervalSince(now)))
    let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
    if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}

private func capsAgo(_ date: Date, _ now: Date) -> String {
    let s = Int(max(0, now.timeIntervalSince(date)))
    if s < 3_600 { return "\(max(1, s / 60))m ago" }
    return s < 86_400 ? "\(s / 3_600)h ago" : "\(s / 86_400)d ago"
}

private func capsWhole(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))" } ?? "–" }

private func pair(_ label: String, _ value: String, _ valueColor: Color = t2) -> Text {
    Text(label).foregroundColor(t3) + Text(value).foregroundColor(valueColor)
}

// MARK: Card pieces

/// "92%": number at 16, sign at 10.
private struct CapsPercent: View {
    let value: String
    var dim = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(value).font(.capsNum).monospacedDigit().foregroundStyle(dim ? t2 : t1)
            Text("%").font(.capsUnit).foregroundStyle(t2)
        }
    }
}

/// The budget tick, drawn the same wherever it appears. Open (backlog may use
/// the account now): bright and 12pt, overhanging the bar. Held (saved for client
/// work): dim and 8pt, inside the bar. Shape and brightness both carry the state.
private struct CapsTick: View {
    let open: Bool
    var body: some View {
        Capsule().fill(open ? t1 : Color.white.opacity(0.6)).frame(width: 2, height: open ? 12 : 8)
    }
}

/// 7-day bar, full width, 8pt, with the budget tick cut into it. The cut is a
/// real gap in the bar, not black paint, so it reads on any background.
private struct CapsMeter: View {
    let pct: Double; let ceiling: Double?; let open: Bool
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12)).frame(height: 8)
                    if pct > 0 {
                        Capsule().fill(tone(pct)).frame(width: max(4, w * min(1, pct / 100)), height: 8)
                    }
                    if let c = ceiling, c > 0, c < 100 {
                        Rectangle().frame(width: 4, height: 8).offset(x: w * c / 100 - 2).blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
                if let c = ceiling, c > 0, c < 100 {
                    CapsTick(open: open).offset(x: w * c / 100 - 1)
                }
            }
        }
        .frame(height: 8)
    }
}

/// Short words for an account that has no numbers, in the row's small slot.
func capsStateShort(_ state: CapsAccountState) -> String? {
    switch state {
    case .ok: return nil
    case .pending: return "reading"
    case .noUsageScope: return "can't report usage"
    case .loginExpired: return "login expired"
    case .accessDenied: return "access not allowed"
    case .unreachable: return "retrying"
    case .noActivity: return "no recent use"
    }
}

/// The same, as a sentence, for the card's bottom line.
func capsStateLong(_ state: CapsAccountState, compact: Bool) -> String {
    switch state {
    case .ok: return ""
    case .pending: return "Reading…"
    case .noUsageScope: return compact ? "This login can't report usage" : "This login can't report usage. Sign in to Claude Code again."
    case .loginExpired: return compact ? "Login expired" : "Login expired. Claude Code renews it when you use it."
    case .accessDenied: return compact ? "macOS didn't allow access" : "macOS didn't allow access. Turn Claude off and on in settings to be asked again."
    case .unreachable: return compact ? "Can't reach Anthropic" : "Can't reach Anthropic. Trying again shortly."
    case .noActivity: return compact ? "No recent Codex use" : "No recent Codex use to read yet."
    }
}

/// One account row, 28pt: name, small gray slot and big 7-day number, then the
/// bar. Nothing on a row moves on hover; hovering only lights the row and puts
/// its details in the card's bottom line.
private struct CapsRow: View {
    let id: String
    let name: String; let pct: Double?; let fivePct: Double?
    let ceiling: Double?; let open: Bool
    var state: CapsAccountState = .ok
    var spentBack: String? = nil
    var readAge: String? = nil
    @Binding var hovered: String?
    var compact = false

    var body: some View {
        let lit = hovered == id
        // A window with only a 5-hour reading leads with that number.
        let big = pct ?? fivePct
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(name).font(.capsName).foregroundStyle(spentBack == nil && big != nil ? t1 : t2).lineLimit(1)
                Spacer(minLength: 8)
                small.font(.capsDetail).monospacedDigit().lineLimit(1).padding(.trailing, big == nil ? 0 : 8)
                // A fixed number column, so every small slot ends on one edge.
                if big != nil {
                    CapsPercent(value: capsWhole(big), dim: spentBack != nil)
                        .frame(width: compact ? nil : 44, alignment: .trailing)
                }
            }
            .frame(height: 16)
            if spentBack != nil {
                Capsule().fill(hot.opacity(0.55)).frame(height: 8)
            } else if let big {
                CapsMeter(pct: big, ceiling: ceiling, open: open)
            } else {
                Capsule().fill(Color.white.opacity(0.06)).frame(height: 8)
            }
        }
        // 4pt hover margin above and below, so moving down the list never
        // falls into a dead gap between rows.
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(lit ? 0.11 : 0))
                .padding(.horizontal, -4)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
        .animation(.easeOut(duration: 0.12), value: lit)
    }

    /// The same kind of fact on every row: why there is no number, or 5-hour
    /// use, or when a spent week comes back, or how old a Codex reading is.
    private var small: Text {
        if let word = capsStateShort(state) { return Text(word).foregroundColor(t3) }
        if let spentBack { return pair("back in ", spentBack) }
        if pct == nil, fivePct != nil { return Text("5-hour").foregroundColor(t3) }
        if let fivePct { return pair("5h ", "\(capsWhole(fivePct))%", fiveTone(fivePct)) }
        if let readAge { return pair("read ", readAge) }
        return Text("")
    }
}

private struct CapsShelfWidget: View {
    @ObservedObject var droplet: CapsdroppyDroplet
    let context: ShelfWidgetContext
    @State private var hovered: String?

    /// Preview only: CAPS_PREVIEW_HOVER=<account> renders with that row hovered,
    /// since the harness cannot hover. Unset in Droppy.
    private let previewHover = ProcessInfo.processInfo.environment["CAPS_PREVIEW_HOVER"]

    var body: some View {
        let now = Date()
        let accounts = droplet.reading.accounts
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 8)
            if accounts.isEmpty {
                emptyState
            } else {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, a in
                    let spent = (a.sevenDayPct ?? 0) >= 100
                    // Codex has its own limits, so it sits a step apart from the Claude rows.
                    let stepsApart = a.kind == .codex && index > 0 && accounts[index - 1].kind != .codex
                    CapsRow(
                        id: a.account, name: droplet.settings.name(for: a), pct: a.sevenDayPct,
                        fivePct: a.fiveHourPct, ceiling: a.releaseDecision?.ceilingPct,
                        open: a.releaseDecision?.released == true, state: a.state,
                        spentBack: spent ? capsUntil(a.sevenDayReset, now) : nil,
                        readAge: a.kind == .codex ? a.seenAt.map { capsAgo($0, now) } : nil,
                        hovered: $hovered, compact: context.isCompact
                    )
                    .padding(.top, stepsApart ? 8 : 0)
                }
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.top, 4).padding(.bottom, 8)
                footer(accounts: accounts, now: now)
            }
            Spacer(minLength: 0)
        }
        // The one padding every widget applies: the host's corner clearance.
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if let previewHover { hovered = previewHover } }
    }

    /// Nothing to show yet: say so and send the user to settings.
    private var emptyState: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Nothing to show yet").font(.capsDetail).foregroundStyle(t3).lineLimit(1)
            Spacer(minLength: 0)
            Button("Set up") { droplet.openSettings() }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .frame(height: 22)
        .padding(.top, 20)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(t2)
                .offset(x: -1).frame(width: 16, alignment: .leading)
            Text("Caps").font(.capsName).foregroundStyle(t2).padding(.leading, 4)
            Spacer(minLength: 8)
            if droplet.reading.hasReading {
                Text(context.isCompact ? "7d avg " : "7d total ").font(.capsDetail).foregroundStyle(t3)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(droplet.reading.title.replacingOccurrences(of: "%", with: ""))
                        .font(.capsName).monospacedDigit().foregroundStyle(t2)
                    Text("%").font(.capsUnit).foregroundStyle(t3)
                }
            }
        }
        .frame(height: 16)
    }

    /// The card's last line. At rest it is the key to the budget tick (only when
    /// some account has one) or a hint that rows have more; on hover it is that
    /// row's details. One fixed 12pt line (shorter wording in the narrow slot),
    /// so the card never moves.
    @ViewBuilder
    private func footer(accounts: [CapsAccount], now: Date) -> some View {
        let compact = context.isCompact
        let lit = hovered != nil
        HStack(alignment: .center, spacing: 4) {
            if let id = hovered, let a = accounts.first(where: { $0.account == id }) {
                detail(a, now: now, compact: compact)
            } else if droplet.hasBudgetHolds {
                // The key: both ticks exactly as they sit on a bar.
                specimen(open: true)
                Text("backlog open").foregroundStyle(t3)
                specimen(open: false).padding(.leading, 8)
                Text(compact ? "held" : "held for clients").foregroundStyle(t3)
                if !compact { Text("· hover a row").foregroundStyle(t3).padding(.leading, 4) }
            } else {
                Text(compact ? "Hover a row" : "Hover a row for reset times").foregroundStyle(t3)
            }
            Spacer(minLength: 0)
        }
        .font(.capsDetail)
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 12)
        .background(
            // The same wash as the hovered row, so the two read as one.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(lit ? 0.11 : 0))
                .padding(.horizontal, -4).padding(.vertical, -4)
        )
    }

    /// A 16pt piece of bar with its tick, for the key.
    private func specimen(open: Bool) -> some View {
        CapsMeter(pct: 0, ceiling: 50, open: open).frame(width: 16)
    }

    /// The head of every footer line: the tick on its 16pt piece of bar, or the
    /// same space left empty, so footer text always starts at one x.
    @ViewBuilder private func tickSlot(_ open: Bool?) -> some View {
        if let open { specimen(open: open) } else { Color.clear.frame(width: 16, height: 8) }
    }

    /// "  7d resets in 3d 4h · 5h in 2h", with whichever windows the account has.
    private func resetText(_ a: CapsAccount, now: Date, compact: Bool) -> Text {
        let seven = a.sevenDayReset != nil, five = a.fiveHourReset != nil
        if compact { return Text("  resets \(capsUntil(seven ? a.sevenDayReset : a.fiveHourReset, now))").foregroundColor(t3) }
        if seven && five { return Text("  7d resets in \(capsUntil(a.sevenDayReset, now)) · 5h in \(capsUntil(a.fiveHourReset, now))").foregroundColor(t3) }
        if seven { return Text("  7d resets in \(capsUntil(a.sevenDayReset, now))").foregroundColor(t3) }
        return Text("  5h resets in \(capsUntil(a.fiveHourReset, now))").foregroundColor(t3)
    }

    @ViewBuilder
    private func detail(_ a: CapsAccount, now: Date, compact: Bool) -> some View {
        let name = Text(compact ? "" : "\(droplet.settings.name(for: a)) · ").foregroundColor(t1)
        if a.state != .ok {
            tickSlot(nil)
            (name + Text(capsStateLong(a.state, compact: compact)).foregroundColor(t2))
        } else if (a.sevenDayPct ?? 0) >= 100 {
            tickSlot(nil)
            (name + Text("7d used up").foregroundColor(t2)
             + Text("  back in \(capsUntil(a.sevenDayReset, now))").foregroundColor(t3))
        } else {
            // Two groups, 2 spaces apart: what it is, then when each window resets.
            let times = resetText(a, now: now, compact: compact)
            if let d = a.releaseDecision, let c = d.ceilingPct, (d.hoursToReset ?? 0) > 0 {
                let cap = Int(min(100, max(0, c)).rounded())
                tickSlot(d.released == true)
                (name + Text("\(d.released == true ? "open" : "held") · cap \(cap)%").foregroundColor(t2)
                 + times)
            } else if a.kind == .snapshot {
                tickSlot(nil)
                (name + Text("no cap").foregroundColor(t2) + times)
            } else if a.kind == .codex, droplet.codexIsOutsideTotal {
                tickSlot(nil)
                (name + Text("not in the total").foregroundColor(t2) + times)
            } else {
                tickSlot(nil)
                (name + times)
            }
        }
    }
}


// MARK: - Live activity (the compact state: a small gauge and the total %)

extension CapsdroppyDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func makeCompactLeading() -> AnyView {
        AnyView(CapsProgressRing(fraction: totalFraction, tint: totalTint))
    }

    public func makeCompactTrailing() -> AnyView {
        AnyView(
            Text(reading.title)
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        )
    }

    /// Droppy does not mount a card for the compact activity (see the
    /// protocol's own doc comment on this requirement): return an empty view
    /// and put real controls in the shelf widget above.
    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(EmptyView())
    }

    private func publishActivity() {
        guard reading.hasReading, settings.showGauge else {
            // Gauge switched off in settings, or no guessing: withdraw the compact seat rather than showing a
            // gauge with nothing behind it. The shelf widget still shows the
            // words "no reading" explicitly; a two-glyph compact row has no
            // room to say that, so it says nothing instead.
            activitySubject.send(nil)
            return
        }
        activitySubject.send(
            LiveActivityState(
                priority: 120,
                accessibilityTitle: "Caps total usage \(reading.title)",
                isInteractive: false
            )
        )
    }
}

/// A small ring, `DroppyLiveActivityMetrics.progressRingSize` (20pt) across,
/// filled to the total fraction. Deliberately no percentage glyph inside it —
/// the trailing accessory already carries the number, and the ring at this
/// size has room for a fill, not a legible digit (the SDK reserves an 8pt
/// glyph slot here for something like a lock or a checkmark, too small for
/// two digits).
private struct CapsProgressRing: View {
    let fraction: Double?
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    AdaptiveColors.notchSurfaceTertiaryText.opacity(0.35),
                    lineWidth: DroppyLiveActivityMetrics.progressRingLineWidth
                )
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.03, min(1, fraction)))
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: DroppyLiveActivityMetrics.progressRingLineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: DroppyLiveActivityMetrics.progressRingSize, height: DroppyLiveActivityMetrics.progressRingSize)
    }
}
