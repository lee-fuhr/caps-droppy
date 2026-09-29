//
//  CapsdroppyDroplet.swift
//  Capsdroppy
//
//  Caps' fleet-quota reading, on Droppy's shelf and beside the notch.
//
//  Reads only /Users/lee/CC/Work/LFI/_ Operations/menubar-snapshot.json, on a
//  60-second timer. No network, no writes, no other files. The parsing and
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
        let snapshot = CapsSnapshotLoader.load(from: capsSnapshotPath)
        let next = capsBuildReading(snapshot, now: Date())
        reading = next
        publishActivity()
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

// MARK: - Shelf widget (the expanded/shelf state: one row per account)

extension CapsdroppyDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "fleet",
                title: "Caps",
                systemImage: "gauge.with.dots.needle.67percent",
                layoutTraits: ShelfWidgetLayoutTraits(
                    // A header plus at most four one-line account rows (7-day %
                    // only, Lee 2026-09-29). Sized to the content, not a stock
                    // card height — the last floating gauge this fleet shipped
                    // was "bigger than it needs to be".
                    preferredSoloWidth: 300,
                    preferredPairedWidth: 150,
                    // Measured against the offscreen preview render at this
                    // width: header plus four rows ends at 117pt with 8pt
                    // insets; 120 leaves a small buffer.
                    contentHeight: .fixed(120)
                ),
                searchKeywords: ["claude", "quota", "usage", "caps"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(CapsShelfWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

/// The shelf widget: full account table when solo, just the fleet number
/// when paired (grouped rows are always compact — see `ShelfWidgetContext`).
private struct CapsShelfWidget: View {
    @ObservedObject var droplet: CapsdroppyDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if context.isCompact {
                Spacer(minLength: 0)
                Text(droplet.reading.title)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Spacer(minLength: 0)
            } else if !droplet.reading.hasReading {
                Spacer(minLength: 0)
                Text("no reading")
                    .font(.system(size: 13))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                Spacer(minLength: 0)
            } else {
                accountRows
                Spacer(minLength: 0)
            }
        }
        // The one padding every widget applies: the host's own corner
        // clearance for this slot. See ShelfWidgetContext.contentInsets.
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12, weight: .medium))
            Text("Caps")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Text(droplet.reading.title)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    // Lee, live 2026-09-29 12:26pm: "My OVERALL % is a little useful, just as is an
    // overview of the 7d on all available accts". So one line per account whose week
    // is not spent (7d under 100), showing only its 7-day %. Spent accounts still
    // count in the header's overall number; they just leave the list.
    private var accountRows: some View {
        let accounts = capsOrderAccounts(droplet.reading.accounts).filter { account in
            guard let pct = account.sevenDayPct else { return false }
            return pct < 100
        }
        return VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            ForEach(accounts) { account in
                HStack(spacing: DroppySpacing.xsm) {
                    Text(capsDisplayName(account.account))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                    Spacer(minLength: DroppySpacing.xs)
                    Text("7d \(capsFormatPercentage(account.sevenDayPct))")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
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
