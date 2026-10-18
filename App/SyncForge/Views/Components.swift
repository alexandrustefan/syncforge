import SwiftUI
import SyncForgeCore

extension TransportKind {
    var symbol: String {
        switch self {
        case .builtIn: return "laptopcomputer"
        case .usb: return "cable.connector"
        case .bluetooth, .bluetoothLE: return "dot.radiowaves.left.and.right"
        case .hdmi, .displayPort, .thunderbolt: return "display"
        case .airPlay: return "airplayaudio"
        case .aggregate: return "square.stack.3d.up"
        case .virtual: return "waveform.path"
        case .continuity: return "iphone"
        default: return "hifispeaker"
        }
    }
}

extension OutputState {
    var statusColor: Color {
        switch status {
        case .playing:
            if profile.calibration?.needsRecalibration == true { return .orange }
            return .green
        case .starting: return .yellow
        case .disabled: return .secondary
        case .unavailable: return .orange
        case .error: return .red
        }
    }

    /// Short synchronisation summary, e.g. "Calibrated ±0.2 ms · 3 h ago".
    var syncSummary: String {
        if profile.delayMode == .manual { return "Manual delay" }
        guard let cal = profile.calibration else {
            return timing?.latencySource == .driverEstimate ? "Driver estimate — not calibrated" : "Not calibrated"
        }
        if cal.needsRecalibration { return "Recalibration recommended" }
        let age = RelativeDateTimeFormatter().localizedString(for: cal.date, relativeTo: Date())
        return String(format: "Calibrated ±%.1f ms · ", max(cal.spreadMs / 2, 0.05)) + age
    }
}

func formatMs(_ v: Double, decimals: Int = 1) -> String {
    String(format: "%.\(decimals)f ms", v)
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// Peak-meter ballistics: fast rise, constant-rate fall, and a peak-hold marker. A reference type so
/// that per-frame updates don't invalidate any SwiftUI state (only the meter's canvas repaints).
final class MeterBallistics {
    private(set) var level: Float = -60
    private(set) var hold: Float = -60
    private var holdTime = Date.distantPast
    private var last = Date()
    var reportedSettled = false

    static let floor: Float = -60
    static let fallRate: Float = 24       // dB per second
    static let attackTime: Float = 0.025  // s
    static let holdSeconds = 1.2

    func advance(to target: Float, at now: Date) {
        let dt = Float(min(0.1, max(0, now.timeIntervalSince(last))))
        last = now
        let t = max(Self.floor, target)
        if t > level {
            level += (t - level) * min(1, dt / Self.attackTime)
        } else {
            level = max(t, level - Self.fallRate * dt)
        }
        if level >= hold {
            hold = level
            holdTime = now
        } else if now.timeIntervalSince(holdTime) > Self.holdSeconds {
            hold = max(level, hold - Self.fallRate * dt)
        }
    }

    /// Nothing left to animate for this target.
    func isSettled(for target: Float) -> Bool {
        let t = max(Self.floor, target)
        return abs(level - t) < 0.05 && hold - level < 0.05
    }
}

/// Horizontal peak meter (-60…0 dBFS). Values arrive ~10x per second; the meter interpolates
/// between them at display rate inside a small canvas, and pauses once it has settled.
struct LevelMeter: View {
    let db: Float
    var clipping = false
    var height: CGFloat = 5
    @State private var ballistics = MeterBallistics()
    /// Bumped once the animation settles, so the body re-evaluates and the timeline pauses.
    @State private var settleTick = 0

    var body: some View {
        let _ = settleTick
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: ballistics.isSettled(for: db))) { timeline in
            Canvas { ctx, size in
                ballistics.advance(to: db, at: timeline.date)
                if ballistics.isSettled(for: db) {
                    // Report each settle episode once; re-rendering must not trigger another report.
                    if !ballistics.reportedSettled {
                        ballistics.reportedSettled = true
                        DispatchQueue.main.async { settleTick &+= 1 }
                    }
                } else {
                    ballistics.reportedSettled = false
                }
                let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                ctx.fill(shape, with: .color(Color.primary.opacity(0.08)))
                ctx.clip(to: shape)
                func x(_ v: Float) -> CGFloat { size.width * CGFloat(max(0, min(1, (v + 60) / 60))) }
                let fill = Path(CGRect(x: 0, y: 0, width: x(ballistics.level), height: size.height))
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [.green, .green, .yellow, clipping ? .red : .orange]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                if ballistics.hold > MeterBallistics.floor + 1 {
                    let hx = x(ballistics.hold)
                    ctx.fill(Path(CGRect(x: max(0, hx - 2), y: 0, width: 2, height: size.height)),
                             with: .color(ballistics.hold > -3 ? .red : Color.primary.opacity(0.55)))
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Level")
        .accessibilityValue(String(format: "%.0f dB", db))
    }
}

/// A slider with a speaker icon and percentage.
struct VolumeSlider: View {
    @Environment(AppModel.self) private var model
    @Binding var value: Double
    var muted: Binding<Bool>?
    var showsPercent = true
    var accessibilityName = "Volume"
    @State private var editingPercent = false
    @State private var percentDraft = ""
    @State private var percentError: String?
    @State private var isDragging = false
    @FocusState private var percentFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 8) {
                if let muted {
                    Button {
                        muted.wrappedValue.toggle()
                    } label: {
                        Image(systemName: muted.wrappedValue ? "speaker.slash.fill" : volumeSymbol)
                            .frame(width: 18)
                            .foregroundStyle(muted.wrappedValue ? .red : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(muted.wrappedValue ? "Unmute" : "Mute")
                    .accessibilityLabel(muted.wrappedValue ? "Unmute \(accessibilityName)" : "Mute \(accessibilityName)")
                } else {
                    Image(systemName: volumeSymbol).frame(width: 18).foregroundStyle(.secondary)
                }
                Slider(value: $value, in: 0...1, onEditingChanged: { editing in
                    isDragging = editing
                    if editing { model.engine.beginUndoableChange(named: "Change \(accessibilityName)") }
                    else { model.engine.endUndoableChange() }
                })
                    .controlSize(.small)
                    .accessibilityLabel(accessibilityName)
                    .accessibilityValue("\(percentText) percent")
                if showsPercent {
                    if editingPercent {
                        TextField("0–100", text: $percentDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .focused($percentFocused)
                            .onSubmit { commitPercent() }
                            .onExitCommand { cancelPercent() }
                            .onChange(of: percentFocused) { _, focused in
                                if !focused && editingPercent { commitPercent(dismissing: true) }
                            }
                            .accessibilityLabel("\(accessibilityName) percentage")
                            .accessibilityHint("Enter a value from 0 to 100. Press Return to apply or Escape to cancel.")
                            .frame(width: 60)
                    } else {
                        Button {
                            percentDraft = percentText
                            percentError = nil
                            editingPercent = true
                            percentFocused = true
                        } label: {
                            Text("\(percentLabelText)%").frame(minWidth: 36, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Click to enter an exact volume percentage")
                        .accessibilityLabel("Edit \(accessibilityName) percentage")
                        .accessibilityValue("\(percentText) percent")
                    }
                }
            }
            if let percentError {
                Text(percentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear {
            if isDragging {
                model.engine.endUndoableChange()
                isDragging = false
            }
            cancelPercent()
        }
    }

    private var percentText: String {
        (value * 100).formatted(.number.precision(.fractionLength(0...6)))
    }

    private var percentLabelText: String {
        (value * 100).formatted(.number.precision(.fractionLength(0...1)))
    }

    private func commitPercent(dismissing: Bool = false) {
        var text = percentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("%") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = Locale.current.decimalSeparator, separator != "." {
            text = text.replacingOccurrences(of: separator, with: ".")
        }
        guard let percent = Double(text), percent.isFinite, (0...100).contains(percent) else {
            percentError = "Enter a percentage from 0 to 100."
            if dismissing {
                editingPercent = false
                percentDraft = ""
            } else { percentFocused = true }
            return
        }
        model.engine.performUndoableChange(named: "Change \(accessibilityName)") { value = percent / 100 }
        percentError = nil
        percentDraft = ""
        editingPercent = false
        percentFocused = false
    }

    private func cancelPercent() {
        editingPercent = false
        percentFocused = false
        percentError = nil
        percentDraft = ""
    }

    private var volumeSymbol: String {
        value < 0.01 ? "speaker.fill" : value < 0.4 ? "speaker.wave.1.fill" : value < 0.75 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// Coarse/fine millisecond adjuster with a text field.
struct DelayAdjuster: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var steps: [Double] = [-10, -1, -0.1, 0.1, 1, 10]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(steps.filter { $0 < 0 }, id: \.self) { s in stepButton(s) }
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .font(.body.monospacedDigit())
            Text("ms").foregroundStyle(.secondary)
            ForEach(steps.filter { $0 > 0 }, id: \.self) { s in stepButton(s) }
        }
        .controlSize(.small)
    }

    private func stepButton(_ s: Double) -> some View {
        Button(s > 0 ? "+\(label(s))" : label(s)) {
            value = min(max(value + s, range.lowerBound), range.upperBound)
        }
        .help("\(s > 0 ? "Add" : "Subtract") \(label(abs(s))) ms")
    }

    private func label(_ s: Double) -> String {
        abs(s) < 1 ? String(format: "%.1f", s) : String(format: "%.0f", s)
    }
}

/// A vertical slider for graphic EQ bands.
struct VerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height - 14
            let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let zeroT = (0 - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.1)).frame(width: 4)
                    .padding(.vertical, 7)
                // Fill from 0 dB to the value.
                let yValue = 7 + h * (1 - t), yZero = 7 + h * (1 - zeroT)
                Capsule().fill(Color.accentColor)
                    .frame(width: 4, height: max(2, abs(yValue - yZero)))
                    .offset(y: min(yValue, yZero))
                Circle()
                    .fill(.background)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .shadow(radius: 1)
                    .offset(y: h * (1 - t))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    onEditingChanged(true)
                    let frac = 1 - min(max((g.location.y - 7) / h, 0), 1)
                    let v = range.lowerBound + frac * (range.upperBound - range.lowerBound)
                    value = (v * 2).rounded() / 2
                }
                .onEnded { _ in onEditingChanged(false) })
            .onTapGesture(count: 2) { value = 0 }
        }
        .accessibilityElement()
        .accessibilityValue(String(format: "%.1f dB", value))
        .accessibilityAdjustableAction { dir in
            value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? 0.5 : -0.5)))
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Card container used throughout the main window.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }
}

/// Banner for problems that need the user's attention (no modal dialogs during playback).
struct Banner: View {
    enum Kind { case info, warning, error }
    let kind: Kind
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
    var stacksAction = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kind == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(kind == .error ? .red : kind == .warning ? .orange : .blue)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                if stacksAction, let actionTitle, let action {
                    Button(actionTitle, action: action).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            if !stacksAction, let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .font(.callout)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill((kind == .error ? Color.red : kind == .warning ? .orange : .blue).opacity(0.1)))
    }
}

/// Leaf views that read the 10 Hz meters, so only they refresh (not the whole page).
struct OutputLevelMeter: View {
    @Environment(AppModel.self) private var model
    let uid: String
    var height: CGFloat = 5

    var body: some View {
        let m = model.engine.meters[uid]
        LevelMeter(db: m?.peakDb ?? -120, clipping: m?.clipping ?? false, height: height)
    }
}

struct CaptureLevelMeter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LevelMeter(db: model.engine.captureLevelDb)
    }
}

extension View {
    /// Registers the view as a consumer of live meters while it is on screen.
    func showsLiveMeters(_ engine: SyncEngine) -> some View {
        onAppear { engine.meteringClients += 1 }
            .onDisappear { engine.meteringClients = max(0, engine.meteringClients - 1) }
    }
}
