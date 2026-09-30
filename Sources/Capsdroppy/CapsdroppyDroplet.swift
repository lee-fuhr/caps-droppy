//
//  CapsdroppyDroplet.swift
//  Capsdroppy
//
//  Caps' fleet-quota reading, on Droppy's shelf and beside the notch.
//
//  Reads /Users/lee/CC/Work/LFI/_ Operations/menubar-snapshot.json and the
//  last few days of Codex session logs (~/.codex/sessions), on a 60-second
//  timer. No network, no writes. The parsing and
//  formatting rules live in CapsSnapshot.swift, a direct port of
//  /Users/lee/Sites/caps-raycast/src/snapshot.ts (see that file's header).
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

/// The path this droplet reads. Never written to, never anything else.
let capsSnapshotPath = "/Users/lee/CC/Work/LFI/_ Operations/menubar-snapshot.json"

/// Caps' fleet quota, read from the same snapshot file Caps and the Raycast
/// command already read.
@MainActor
public final class CapsdroppyDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "capsdroppy"

    private var host: DropletHost?
    private var ticker: AnyCancellable?
    private var alerts = CapsAlertTracker()
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)

    @Published private(set) var reading: CapsReading = CapsReading(title: "no reading", accounts: [], hasReading: false)
    @Published private(set) var codex: CodexReading?

    public func activate(host: DropletHost) throws {
        self.host = host
        refresh()
        host.log.info("Caps activated: \(self.reading.title)")
        // Preview only: CAPS_PREVIEW_ALERT=1 shows a sample banner so its look
        // can be checked in the harness. Unset in Droppy, so it never fires there.
        if ProcessInfo.processInfo.environment["CAPS_PREVIEW_ALERT"] == "1" {
            capsPresent([CapsAlert(kind: .full, title: "Secondary is full", detail: "Back in 1d 14h")], on: host.hud)
        }

        // Once a minute, matching the brief ("refresh about once a minute").
        // Caps' own snapshot writer runs on its own cadence; this droplet only
        // ever reads, never polls faster than it needs to.
        ticker = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    public func deactivate() {
        ticker?.cancel()
        ticker = nil
        activitySubject.send(nil)
        host = nil
    }

    private func refresh() {
        let before = cardHeight
        // Preview only: CAPS_PREVIEW_SNAPSHOT points the harness at a fixture so
        // review renders can show other account states. Unset in Droppy.
        let path = ProcessInfo.processInfo.environment["CAPS_PREVIEW_SNAPSHOT"] ?? capsSnapshotPath
        let snapshot = CapsSnapshotLoader.load(from: path)
        let next = capsBuildReading(snapshot, now: Date())
        reading = next
        codex = CodexReader.load()
        publishActivity()
        announceChanges()
        // An account coming back or running out changes the card's height.
        if cardHeight != before { host?.shelf.invalidateLayout(for: "fleet") }
    }

    /// One notch banner per real change (see CapsAlerts.swift). A missing
    /// reading is not a change: state is only compared between two readings.
    private func announceChanges() {
        guard reading.hasReading, let host else { return }
        let now = Date()
        var rows = reading.accounts.map { a in
            CapsAlertTracker.Snapshot(
                id: a.account, name: capsShortName(a.account),
                sevenDay: a.sevenDayPct, fiveHour: a.fiveHourPct,
                released: a.releaseDecision?.released, ceiling: a.releaseDecision?.ceilingPct,
                reset7: capsUntil(a.sevenDayReset, now), reset5: capsUntil(a.fiveHourReset, now))
        }
        if let c = codex {
            rows.append(CapsAlertTracker.Snapshot(
                id: "codex", name: "Codex", sevenDay: c.pct, fiveHour: nil,
                released: nil, ceiling: nil, reset7: capsUntil(c.resetsAt, now), reset5: "–"))
        }
        let changes = alerts.update(rows)
        if !changes.isEmpty {
            capsPresent(changes, on: host.hud)
            host.log.info("Caps alert: \(changes.map(\.title).joined(separator: "; "))")
        }
    }

    /// The fleet percentage as a fraction 0...1 for the ring, or nil when
    /// there is no reading to draw.
    var fleetFraction: Double? {
        guard reading.hasReading,
              let value = Double(reading.title.replacingOccurrences(of: "%", with: ""))
        else { return nil }
        return min(1, max(0, value / 100))
    }

    /// Same 70/90 thresholds `accountSeverity` in snapshot.ts uses for a
    /// single account's severity, applied here to the fleet average so the
    /// ring's color means the same thing Caps' own coloring does: green under
    /// 70, amber 70..<90, red 90+.
    var fleetTint: Color {
        guard let fraction = fleetFraction else { return AdaptiveColors.notchSurfaceTertiaryText }
        let pct = fraction * 100
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }
}

// MARK: - Shelf widget (one row per account, bars on one scale)

extension CapsdroppyDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "fleet",
                title: "Caps",
                systemImage: "gauge.with.dots.needle.67percent",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 300,
                    preferredPairedWidth: 150,
                    // Sized to the rows actually showing; see cardHeight.
                    contentHeight: .fixed(cardHeight)
                ),
                searchKeywords: ["claude", "quota", "usage", "caps", "codex"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(CapsShelfWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }

    /// Exact content height: 8pt host insets top and bottom, the 16pt header and
    /// 8pt under it, then the rows.
    var cardHeight: CGFloat {
        guard reading.hasReading else { return 64 }
        // Every row is 36 (28 of content, 4pt hover margin above and below),
        // Codex 8 more for its step apart.
        let rows = CGFloat(reading.accounts.count) * 36 + (codex != nil ? 44 : 0)
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

/// One account row, 28pt: name, small gray slot and big 7-day number, then the
/// bar. Nothing on a row moves on hover; hovering only lights the row and puts
/// its details in the card's bottom line.
private struct CapsRow: View {
    let id: String
    let name: String; let pct: Double; let fivePct: Double?
    let ceiling: Double?; let open: Bool
    var spentBack: String? = nil
    var readAge: String? = nil
    @Binding var hovered: String?
    var compact = false

    var body: some View {
        let lit = hovered == id
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(name).font(.capsName).foregroundStyle(spentBack == nil ? t1 : t2).lineLimit(1)
                Spacer(minLength: 8)
                small.font(.capsDetail).monospacedDigit().lineLimit(1).padding(.trailing, 8)
                // A fixed number column, so every small slot ends on one edge.
                CapsPercent(value: capsWhole(pct), dim: spentBack != nil)
                    .frame(width: compact ? nil : 44, alignment: .trailing)
            }
            .frame(height: 16)
            if spentBack != nil {
                Capsule().fill(hot.opacity(0.55)).frame(height: 8)
            } else {
                CapsMeter(pct: pct, ceiling: ceiling, open: open)
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

    /// The same kind of fact on every row: 5-hour use, or when a spent week
    /// comes back, or how old Codex's reading is.
    private var small: Text {
        if let spentBack { return pair("back in ", spentBack) }
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
        let accounts = capsOrderAccounts(droplet.reading.accounts)
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 8)
            if droplet.reading.hasReading {
                ForEach(accounts) { a in
                    let spent = (a.sevenDayPct ?? 0) >= 100
                    CapsRow(
                        id: a.account, name: capsShortName(a.account), pct: a.sevenDayPct ?? 0,
                        fivePct: a.fiveHourPct, ceiling: a.releaseDecision?.ceilingPct,
                        open: a.releaseDecision?.released == true,
                        spentBack: spent ? capsUntil(a.sevenDayReset, now) : nil,
                        hovered: $hovered, compact: context.isCompact
                    )
                }
                if let c = droplet.codex {
                    // Codex is not in the Claude average above, so it sits a step apart.
                    CapsRow(
                        id: "codex", name: "Codex", pct: c.pct, fivePct: nil, ceiling: nil, open: false,
                        readAge: capsAgo(c.seenAt, now), hovered: $hovered, compact: context.isCompact
                    )
                    .padding(.top, 8)
                }
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.top, 4).padding(.bottom, 8)
                footer(accounts: accounts, now: now)
            } else {
                Text("no reading").font(.capsDetail).foregroundStyle(t3)
            }
            Spacer(minLength: 0)
        }
        // The one padding every widget applies: the host's corner clearance.
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if let previewHover { hovered = previewHover } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(t2)
                .offset(x: -1).frame(width: 16, alignment: .leading)
            Text("Caps").font(.capsName).foregroundStyle(t2).padding(.leading, 4)
            Spacer(minLength: 8)
            if droplet.reading.hasReading {
                Text(context.isCompact ? "7d avg " : "7d, all accounts ").font(.capsDetail).foregroundStyle(t3)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(droplet.reading.title.replacingOccurrences(of: "%", with: ""))
                        .font(.capsName).monospacedDigit().foregroundStyle(t2)
                    Text("%").font(.capsUnit).foregroundStyle(t3)
                }
            }
        }
        .frame(height: 16)
    }

    /// The card's last line. At rest it is the key to the one mark with no
    /// words and says that rows have more; on hover it is that row's details.
    /// One fixed 12pt line (shorter wording in the narrow slot), so the card never moves.
    @ViewBuilder
    private func footer(accounts: [CapsAccount], now: Date) -> some View {
        let compact = context.isCompact
        let lit = hovered != nil
        return HStack(alignment: .center, spacing: 4) {
            if let id = hovered, id == "codex", let c = droplet.codex {
                tickSlot(nil)
                (Text(compact ? "" : "Codex · ").foregroundColor(t1)
                 + Text("not in the average").foregroundColor(t2)
                 + Text("  7d resets in \(capsUntil(c.resetsAt, now))").foregroundColor(t3))
            } else if let id = hovered, let a = accounts.first(where: { $0.account == id }) {
                detail(a, now: now, compact: compact)
            } else {
                // The key: both ticks exactly as they sit on a bar.
                specimen(open: true)
                Text("backlog open").foregroundStyle(t3)
                specimen(open: false).padding(.leading, 8)
                Text(compact ? "held" : "held for clients").foregroundStyle(t3)
                if !compact { Text("· hover a row").foregroundStyle(t3).padding(.leading, 4) }
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

    @ViewBuilder
    private func detail(_ a: CapsAccount, now: Date, compact: Bool) -> some View {
        let name = Text(compact ? "" : "\(capsShortName(a.account)) · ").foregroundColor(t1)
        if (a.sevenDayPct ?? 0) >= 100 {
            tickSlot(nil)
            (name + Text("7d used up").foregroundColor(t2)
             + Text("  back in \(capsUntil(a.sevenDayReset, now))").foregroundColor(t3))
        } else {
            // Two groups, 2 spaces apart: the budget, then when each window resets.
            let times = compact
                ? Text("  resets \(capsUntil(a.sevenDayReset, now))").foregroundColor(t3)
                : Text("  7d resets in \(capsUntil(a.sevenDayReset, now)) · 5h in \(capsUntil(a.fiveHourReset, now))").foregroundColor(t3)
            if let d = a.releaseDecision, let c = d.ceilingPct, (d.hoursToReset ?? 0) > 0 {
                let cap = Int(min(100, max(0, c)).rounded())
                tickSlot(d.released == true)
                (name + Text("\(d.released == true ? "open" : "held") · cap \(cap)%").foregroundColor(t2)
                 + times)
            } else {
                tickSlot(nil)
                (name + Text("no cap").foregroundColor(t2) + times)
            }
        }
    }
}


// MARK: - Live activity (the compact state: a small gauge and the fleet %)

extension CapsdroppyDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func makeCompactLeading() -> AnyView {
        AnyView(CapsProgressRing(fraction: fleetFraction, tint: fleetTint))
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
        guard reading.hasReading else {
            // No guessing: withdraw the compact seat rather than showing a
            // gauge with nothing behind it. The shelf widget still shows the
            // words "no reading" explicitly; a two-glyph compact row has no
            // room to say that, so it says nothing instead.
            activitySubject.send(nil)
            return
        }
        activitySubject.send(
            LiveActivityState(
                priority: 120,
                accessibilityTitle: "Caps fleet usage \(reading.title)",
                isInteractive: false
            )
        )
    }
}

/// A small ring, `DroppyLiveActivityMetrics.progressRingSize` (20pt) across,
/// filled to the fleet fraction. Deliberately no percentage glyph inside it —
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
