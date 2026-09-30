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
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)

    @Published private(set) var reading: CapsReading = CapsReading(title: "no reading", accounts: [], hasReading: false)
    @Published private(set) var codex: CodexReading?

    public func activate(host: DropletHost) throws {
        self.host = host
        refresh()
        host.log.info("Caps activated: \(self.reading.title)")

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
        let snapshot = CapsSnapshotLoader.load(from: capsSnapshotPath)
        let next = capsBuildReading(snapshot, now: Date())
        reading = next
        codex = CodexReader.load()
        publishActivity()
        // An account coming back or running out changes the card's height.
        if cardHeight != before { host?.shelf.invalidateLayout(for: "fleet") }
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

    /// Exact content height: 8pt host insets top and bottom, the 16pt header,
    /// 12pt under it, then each row and 12pt between rows. A live account is
    /// 44 (name 16, bar 8, detail 12, two 4pt gaps), Codex 28 (no detail
    /// line), a spent account 16. Nothing is padded, so no empty shelf.
    var cardHeight: CGFloat {
        guard reading.hasReading else { return 64 }
        var rows: [CGFloat] = reading.accounts.map { ($0.sevenDayPct ?? 0) >= 100 ? 16 : 44 }
        if codex != nil { rows.append(28) }
        let body = rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * 12
        return 8 + 16 + 12 + body + 8
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

private func capsShortName(_ account: String) -> String {
    switch account {
    case "backup": return "Secondary"
    default: return capsDisplayName(account)
    }
}

/// "5d 8h", "14h", "13m": time until a reset, largest two units.
private func capsUntil(_ raw: String?, _ now: Date) -> String {
    guard let raw, let date = CapsSnapshotLoader.parseSnapshotTimestamp(raw) ?? ISO8601DateFormatter().date(from: raw) else { return "–" }
    return capsUntil(date, now)
}

private func capsUntil(_ date: Date, _ now: Date) -> String {
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

/// "cap 32%, open" (backlog may use up to 32% of the week now) or
/// "cap 49%, held" (held for client work). Nil when there is no decision.
private func capsBudget(_ d: CapsReleaseDecision?) -> String? {
    guard let d, let c = d.ceilingPct, (d.hoursToReset ?? 0) > 0 else { return nil }
    return "cap \(Int(min(100, max(0, c)).rounded()))%, " + (d.released == true ? "open" : "held")
}

private func capsBudgetColor(_ d: CapsReleaseDecision?) -> Color { d?.released == true ? t1 : warm }

private func pair(_ label: String, _ value: String, _ valueColor: Color = t2) -> Text {
    Text(label).foregroundColor(t3) + Text(value).foregroundColor(valueColor)
}

// MARK: Card pieces

/// "92%": number at 16, sign at 10.
private struct CapsPercent: View {
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(.capsNum).monospacedDigit().foregroundStyle(t1)
            Text("%").font(.capsUnit).foregroundStyle(t2)
        }
    }
}

/// "5d 8h" built the same way as "92%": numbers at 16, unit letters at 10.
private struct CapsDuration: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ForEach(Array(text.split(separator: " ").enumerated()), id: \.offset) { _, part in
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(part.prefix { $0.isNumber })).font(.capsNum).monospacedDigit().foregroundStyle(t1)
                    Text(String(part.drop { $0.isNumber })).font(.capsUnit).foregroundStyle(t2)
                }
            }
        }
    }
}

/// The budget mark. Drawn the same on the bar and at the head of its sentence.
private struct CapsNotch: View {
    let color: Color
    var body: some View { Capsule().fill(color).frame(width: 2, height: 12) }
}

/// 7-day bar, full width, 8pt. The notch cuts through it and overhangs 2pt.
private struct CapsMeter: View {
    let pct: Double; let ceiling: Double?; let mark: Color
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 8)
                if pct > 0 {
                    Capsule().fill(tone(pct)).frame(width: max(4, w * min(1, pct / 100)), height: 8)
                }
                if let c = ceiling, c > 0, c < 100 {
                    Rectangle().fill(Color.black).frame(width: 4, height: 12).offset(x: w * c / 100 - 2)
                    CapsNotch(color: mark).offset(x: w * c / 100 - 1)
                }
            }
        }
        .frame(height: 8)
    }
}

/// One live account. Rest: name and 7-day %, bar, budget and 5-hour %.
/// Hover: every number becomes the time until its window resets, in place.
private struct CapsRow: View {
    let name: String; let pct: Double; let fivePct: Double?
    let ceiling: Double?; let mark: Color; let budget: String?
    let reset7: String; let reset5: String?; let age: String?
    let hover: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(name).font(.capsName).foregroundStyle(t1).lineLimit(1)
                if let age, !hover { Text(" · \(age)").font(.capsDetail).foregroundStyle(t3) }
                Spacer(minLength: 8)
                if hover { CapsDuration(text: reset7) } else { CapsPercent(value: capsWhole(pct)) }
            }
            .frame(height: 16)
            CapsMeter(pct: pct, ceiling: ceiling, mark: mark)
            if fivePct != nil || budget != nil {
                HStack(alignment: .center, spacing: 0) {
                    if let budget {
                        HStack(alignment: .center, spacing: 4) {
                            CapsNotch(color: mark)
                            Text(budget).font(.capsDetail).foregroundStyle(mark)
                        }
                    }
                    Spacer(minLength: 8)
                    if let fivePct {
                        // One shape in both states: "5h · 30%" at rest, "5h · 14m" on hover.
                        hover ? pair("5h · ", reset5 ?? "–") : pair("5h · ", "\(capsWhole(fivePct))%", fiveTone(fivePct))
                    }
                }
                .font(.capsDetail).monospacedDigit().lineLimit(1)
                .frame(height: 12, alignment: .center)
            }
        }
    }
}

/// A spent account keeps its place: name dimmed, when it comes back.
private struct CapsSpentRow: View {
    let name: String; let back: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(name).font(.capsName).foregroundStyle(t3).lineLimit(1)
            Spacer(minLength: 8)
            pair("back ", back).font(.capsDetail).monospacedDigit().lineLimit(1)
            Text("0").font(.capsNum).hidden().frame(width: 0)   // share the 16pt baseline
        }
        .frame(height: 16)
    }
}

private struct CapsShelfWidget: View {
    @ObservedObject var droplet: CapsdroppyDroplet
    let context: ShelfWidgetContext
    @State private var hover = false

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 12)
            if droplet.reading.hasReading {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(capsOrderAccounts(droplet.reading.accounts)) { a in
                        if (a.sevenDayPct ?? 0) >= 100 {
                            CapsSpentRow(name: capsShortName(a.account), back: capsUntil(a.sevenDayReset, now))
                        } else {
                            CapsRow(
                                name: capsShortName(a.account), pct: a.sevenDayPct ?? 0, fivePct: a.fiveHourPct,
                                ceiling: a.releaseDecision?.ceilingPct, mark: capsBudgetColor(a.releaseDecision),
                                budget: capsBudget(a.releaseDecision),
                                reset7: capsUntil(a.sevenDayReset, now), reset5: capsUntil(a.fiveHourReset, now),
                                age: nil, hover: hover
                            )
                        }
                    }
                    if let c = droplet.codex {
                        CapsRow(
                            name: "Codex", pct: c.pct, fivePct: nil, ceiling: nil, mark: .clear, budget: nil,
                            reset7: capsUntil(c.resetsAt, now), reset5: nil, age: capsAgo(c.seenAt, now), hover: hover
                        )
                    }
                }
            } else {
                Text("no reading").font(.capsDetail).foregroundStyle(t3)
            }
            Spacer(minLength: 0)
        }
        // The one padding every widget applies: the host's corner clearance.
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(t2)
                .offset(x: -1).frame(width: 16, alignment: .leading)
            Text("Caps").font(.capsName).foregroundStyle(t2).padding(.leading, 4)
            Spacer(minLength: 8)
            if hover {
                // Names the mode every number below has switched into.
                Text("reset times").font(.capsDetail).foregroundStyle(t3)
                Text("0").font(.capsNum).hidden().frame(width: 0)
            } else if droplet.reading.hasReading {
                Text("avg 7d").font(.capsDetail).foregroundStyle(t3).padding(.trailing, 4)
                CapsPercent(value: droplet.reading.title.replacingOccurrences(of: "%", with: ""))
            }
        }
        .frame(height: 16)
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
