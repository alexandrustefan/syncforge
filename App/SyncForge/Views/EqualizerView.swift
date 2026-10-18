import SwiftUI
import SyncForgeCore

/// What the equalizer screen is editing.
enum EQTarget: Hashable {
    case system
    case output(String)
}

let systemEQTag = "__system__"

struct EqualizerView: View {
    @Environment(AppModel.self) private var model
    @State private var showSavePreset = false
    @State private var presetName = ""
    @State private var selectedBand: UUID?
    @State private var isEditingEQ = false

    private var engine: SyncEngine { model.engine }

    private var candidates: [OutputState] {
        engine.outputs.sorted { ($0.profile.enabled ? 0 : 1, $0.name.localizedLowercase, $0.uid) < ($1.profile.enabled ? 0 : 1, $1.name.localizedLowercase, $1.uid) }
    }

    private var target: EQTarget {
        if model.equalizerUID == systemEQTag || model.equalizerUID == nil { return .system }
        if let u = model.equalizerUID, engine.outputs.contains(where: { $0.uid == u }) { return .output(u) }
        return .system
    }

    private var targetOutput: OutputState? {
        if case .output(let uid) = target { return engine.outputs.first { $0.uid == uid } }
        return nil
    }

    // MARK: Reading / writing the edited settings

    private func dsp(_ t: EQTarget) -> DSPSettings {
        switch t {
        case .system: return engine.store.settings.systemDSP
        case .output(let uid): return engine.store.profile(uid: uid)?.dsp ?? .flat
        }
    }

    private func updateDSP(_ t: EQTarget, markCustom: Bool = true, named actionName: String = "Edit Equalizer", _ mutate: @escaping (inout DSPSettings) -> Void) {
        engine.performUndoableChange(named: actionName) {
            switch t {
            case .system:
                engine.updateSettings { s in
                    mutate(&s.systemDSP)
                    if markCustom { s.systemDSP.presetName = "Custom" }
                }
            case .output(let uid):
                engine.updateProfile(uid) { p in
                    mutate(&p.dsp)
                    if markCustom { p.dsp.presetName = "Custom" }
                }
            }
        }
    }

    private func eqEditingChanged(_ editing: Bool) {
        guard editing != isEditingEQ else { return }
        isEditingEQ = editing
        if editing { engine.beginUndoableChange(named: "Edit Equalizer") }
        else { engine.endUndoableChange() }
    }

    private func dspBinding<T>(_ kp: WritableKeyPath<DSPSettings, T>, markCustom: Bool = true) -> Binding<T> {
        let t = target
        return Binding(get: { dsp(t)[keyPath: kp] }, set: { v in updateDSP(t, markCustom: markCustom) { $0[keyPath: kp] = v } })
    }

    private var sampleRate: Double { targetOutput?.device?.nominalSampleRate ?? 48000 }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Equalizer",
                              subtitle: "The system EQ shapes the sound of every output. Each output also has its own EQ, filters and limiter on top, for correcting that speaker.")
                toolbar.disabled(model.calibration.isRunning)
                editor.disabled(model.calibration.isRunning)
            }
            .padding(20)
        }
        .sheet(isPresented: $showSavePreset) { savePresetSheet }
        .onDisappear { eqEditingChanged(false) }
        .onChange(of: model.equalizerUID) { _, _ in eqEditingChanged(false) }
    }

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Preset").font(.headline)
            TextField("Preset name", text: $presetName).frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { showSavePreset = false }
                Button("Save") {
                    let name = presetName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        var d = dsp(target)
                        d.presetName = name
                        engine.performUndoableChange(named: "Save EQ Preset") {
                            engine.store.saveCustomPreset(name: name, settings: d)
                            updateDSP(target, markCustom: false) { $0.presetName = name }
                        }
                    }
                    showSavePreset = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private var toolbar: some View {
        let current = dsp(target)
        return Card {
            HStack(spacing: 12) {
                Picker("Edit", selection: Binding(get: {
                    if case .output(let u) = target { return u }
                    return systemEQTag
                }, set: { model.equalizerUID = $0 })) {
                    Label("All Outputs (System EQ)", systemImage: "hifispeaker.2").tag(systemEQTag)
                    Divider()
                    ForEach(candidates) { o in
                        Label(o.name, systemImage: o.transport.symbol).tag(o.uid)
                    }
                }
                .frame(maxWidth: 320)
                Toggle("Enabled", isOn: dspBinding(\.enabled, markCustom: false))
                    .toggleStyle(.switch)
                    .fixedSize()
                Spacer()
            }
            HStack(spacing: 12) {
                Menu {
                    ForEach(engine.store.allPresets) { preset in
                        Button(preset.name + (preset.isBuiltIn ? "" : " (custom)")) {
                            updateDSP(target, markCustom: false, named: "Apply EQ Preset") { d in
                                var s = preset.settings
                                s.enabled = true
                                // The system EQ has no limiter of its own; keep the output's limiter settings.
                                s.limiterEnabled = d.limiterEnabled
                                s.limiterCeilingDb = d.limiterCeilingDb
                                d = s
                            }
                        }
                        .help(preset.summary ?? preset.name)
                    }
                    if !engine.store.customPresets.isEmpty {
                        Divider()
                        Menu("Delete Custom Preset") {
                            ForEach(engine.store.customPresets) { preset in
                                Button(preset.name) {
                                    engine.performUndoableChange(named: "Delete EQ Preset") {
                                        engine.store.customPresets.removeAll { $0.name == preset.name }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Preset: \(current.presetName)", systemImage: "list.bullet")
                }
                .frame(width: 210)
                Button("Save Preset…") {
                    presetName = current.presetName == "Custom" ? "" : current.presetName
                    showSavePreset = true
                }
                Button("Reset") { updateDSP(target, markCustom: false, named: "Reset Equalizer") { $0 = .flat } }
                    .help("Neutral: all bands at 0 dB, filters off")
            }
            if let summary = engine.store.allPresets.first(where: { $0.name == current.presetName })?.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            if let o = targetOutput {
                HStack {
                    Toggle("Apply the system EQ to this output", isOn: engine.profileBinding(o.uid, \.useSystemEQ, fallback: true))
                    Text(o.profile.useSystemEQ ? "System EQ “\(engine.store.settings.systemDSP.presetName)” is applied first; the dashed curve shows the combined result."
                                                 : "This output ignores the system EQ.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                let excluded = engine.outputs.filter { $0.profile.enabled && !$0.profile.useSystemEQ }.map(\.name)
                Text(excluded.isEmpty ? "Applied to every output. Per-output EQs are applied on top."
                                      : "Applied to every output except: \(excluded.joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var editor: some View {
        let d = dsp(target)
        let rate = sampleRate
        let settings = engine.store.settings
        let combined: [Biquad]? = {
            if let o = targetOutput {
                let sys = o.profile.useSystemEQ ? settings.systemDSP : nil
                let room = o.profile.useSystemEQ && settings.roomCorrectionEnabled ? settings.roomCorrection : []
                let corr = o.profile.correctionEnabled ? o.profile.correction : []
                guard (sys.map { $0.enabled && !$0.isNeutral } ?? false) || !room.isEmpty || !corr.isEmpty else { return nil }
                return BiquadDesign.chain(system: sys, device: d, sampleRate: rate, roomCorrection: room, deviceCorrection: corr).cascade
            }
            guard settings.roomCorrectionEnabled, !settings.roomCorrection.isEmpty else { return nil }
            return BiquadDesign.chain(system: d, device: .flat, sampleRate: rate, roomCorrection: settings.roomCorrection).cascade
        }()
        Card {
            ResponseGraph(settings: d, sampleRate: rate, effective: combined, measured: targetOutput?.profile.calibration?.responseDb,
                          selected: $selectedBand, onEditingChanged: eqEditingChanged) { id, freq, gain in
                updateDSP(target) { s in
                    guard let i = s.bands.firstIndex(where: { $0.id == id }) else { return }
                    s.bands[i].frequency = freq
                    if s.bands[i].type.usesGain { s.bands[i].gainDb = gain }
                }
            }
            .frame(height: 230)
            .opacity(d.enabled ? 1 : 0.45)
            HStack {
                let boost = BiquadDesign.maxBoostDb(d, sampleRate: rate)
                Text(String(format: "Peak boost %.1f dB · effective preamp %.1f dB", boost, BiquadDesign.effectivePreampDb(d, sampleRate: rate)))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let o = targetOutput { OutputLevelMeter(uid: o.uid).frame(width: 140) }
            }
        }

        correctionCard

        Card {
            Text("Bands").font(.headline)
            graphicSliders(d)
            Divider()
            bandTable(d)
        }

        Card {
            Text(targetOutput == nil ? "Filters & Gain" : "Filters, Gain & Limiter").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Preamp").foregroundStyle(.secondary)
                    HStack {
                        Slider(value: dspBinding(\.preampDb, markCustom: false), in: -24...12, onEditingChanged: eqEditingChanged).frame(width: 220)
                        Text(String(format: "%+.1f dB", d.preampDb)).monospacedDigit().frame(width: 64, alignment: .trailing)
                        Toggle("Automatic headroom", isOn: dspBinding(\.autoHeadroom, markCustom: false))
                            .help("Lower the preamp by the largest EQ boost so boosts cannot clip")
                    }
                }
                passFilterRow("High-pass", d: d, kp: \.highPass, range: 20...1000)
                passFilterRow("Low-pass", d: d, kp: \.lowPass, range: 1000...20000)
                if targetOutput != nil {
                    GridRow {
                        Text("Limiter").foregroundStyle(.secondary)
                        HStack {
                            Toggle("Prevent clipping", isOn: dspBinding(\.limiterEnabled, markCustom: false))
                            Slider(value: dspBinding(\.limiterCeilingDb, markCustom: false), in: -12...0, onEditingChanged: eqEditingChanged)
                                .frame(width: 160)
                                .disabled(!d.limiterEnabled)
                            Text(String(format: "ceiling %.1f dBFS", d.limiterCeilingDb)).font(.caption).monospacedDigit()
                        }
                    }
                }
            }
            Text(targetOutput == nil
                 ? "Each output keeps its own limiter, which also protects against boosts from the system EQ."
                 : "Filters are minimum-phase IIR sections: they add no buffering, and only a small frequency-dependent group delay (largest near steep low cut-offs).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Calibration-derived corrections: per-output tone matching, or room resonances for the system.
    @ViewBuilder private var correctionCard: some View {
        let settings = engine.store.settings
        let bands: [EQBand] = targetOutput?.profile.correction ?? settings.roomCorrection
        let enabled = targetOutput?.profile.correctionEnabled ?? settings.roomCorrectionEnabled
        Card {
            HStack {
                Text(targetOutput == nil ? "Room Correction (from calibration)" : "Speaker Correction (from calibration)").font(.headline)
                Spacer()
                if !bands.isEmpty {
                    Toggle("Enabled", isOn: Binding(get: { enabled }, set: { on in
                        engine.performUndoableChange(named: "Change Calibration Correction") {
                            if let o = targetOutput { engine.updateProfile(o.uid) { $0.correctionEnabled = on } }
                            else { engine.updateSettings { $0.roomCorrectionEnabled = on } }
                        }
                    }))
                    .toggleStyle(.switch)
                    Button("Clear") {
                        engine.performUndoableChange(named: "Clear Calibration Correction") {
                            if let o = targetOutput { engine.updateProfile(o.uid) { $0.correction = [] } }
                            else { engine.updateSettings { $0.roomCorrection = [] } }
                        }
                    }
                    .controlSize(.small)
                }
            }
            if bands.isEmpty {
                Text(targetOutput == nil
                     ? "No room resonances measured. Run Calibration with auto-EQ on and all outputs enabled."
                     : "No correction yet. Calibrate with auto-EQ on to match this speaker's tone to the others.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(bands.map { String(format: "%@ %@ Hz %+.1f dB", $0.type.displayName, frequencyLabel($0.frequency), $0.gainDb) }.joined(separator: " · "))
                    .font(.callout.monospacedDigit())
                Text(targetOutput == nil
                     ? "Gentle cuts of bass peaks your room adds at the microphone position. Applied to every output that uses the system EQ."
                     : "Brings this speaker's tone closer to the average of your speakers (the microphone's own colouring cancels out). The grey curve is what the microphone measured.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func passFilterRow(_ title: String, d: DSPSettings, kp: WritableKeyPath<DSPSettings, PassFilter>,
                               range: ClosedRange<Double>) -> some View {
        let f = d[keyPath: kp]
        let t = target
        return GridRow {
            Text(title).foregroundStyle(.secondary)
            HStack {
                Toggle("", isOn: dspBinding(kp.appending(path: \.enabled))).labelsHidden()
                Slider(value: Binding(
                    get: { log10(f.frequency) },
                    set: { v in updateDSP(t) { $0[keyPath: kp].frequency = pow(10, v).rounded() } }),
                       in: log10(range.lowerBound)...log10(range.upperBound), onEditingChanged: eqEditingChanged)
                    .frame(width: 220)
                    .disabled(!f.enabled)
                Text(frequencyLabel(f.frequency)).monospacedDigit().frame(width: 64, alignment: .trailing)
                Picker("", selection: dspBinding(kp.appending(path: \.slope))) {
                    ForEach(FilterSlope.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                .disabled(!f.enabled)
            }
        }
    }

    private func graphicSliders(_ d: DSPSettings) -> some View {
        let t = target
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(d.bands) { band in
                VStack(spacing: 4) {
                    Text(String(format: "%+.1f", band.gainDb)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    VerticalSlider(value: Binding(
                        get: { band.gainDb },
                        set: { v in updateDSP(t) { s in
                            if let i = s.bands.firstIndex(where: { $0.id == band.id }) { s.bands[i].gainDb = v }
                        } }), range: -18...18, onEditingChanged: eqEditingChanged)
                        .frame(height: 140)
                        .opacity(band.enabled && band.type.usesGain ? 1 : 0.35)
                    Text(frequencyLabel(band.frequency)).font(.caption2).foregroundStyle(selectedBand == band.id ? Color.accentColor : .secondary)
                }
                .frame(maxWidth: .infinity)
                .onTapGesture { selectedBand = band.id }
            }
        }
        .padding(.vertical, 4)
    }

    private func bandTable(_ d: DSPSettings) -> some View {
        let t = target
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Parametric").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    updateDSP(t) { $0.bands.append(EQBand(frequency: 1000)) }
                } label: { Label("Add Band", systemImage: "plus") }
                .controlSize(.small)
                .disabled(d.bands.count >= 24)
            }
            ForEach(d.bands) { band in
                BandRow(band: band, highlighted: selectedBand == band.id) { updated in
                    updateDSP(t) { s in
                        if let i = s.bands.firstIndex(where: { $0.id == band.id }) { s.bands[i] = updated }
                    }
                } onDelete: {
                    updateDSP(t) { s in s.bands.removeAll { $0.id == band.id } }
                }
            }
        }
    }
}

private struct BandRow: View {
    let band: EQBand
    let highlighted: Bool
    let onChange: (EQBand) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { band.enabled }, set: { var b = band; b.enabled = $0; onChange(b) })).labelsHidden()
            Picker("", selection: Binding(get: { band.type }, set: { var b = band; b.type = $0; onChange(b) })) {
                ForEach(FilterType.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            field("Hz", value: band.frequency, range: 20...20000, width: 70) { var b = band; b.frequency = $0; onChange(b) }
            field("dB", value: band.gainDb, range: -24...24, width: 56) { var b = band; b.gainDb = $0; onChange(b) }
                .disabled(!band.type.usesGain)
            field("Q", value: band.q, range: 0.1...20, width: 52) { var b = band; b.q = $0; onChange(b) }
            Spacer()
            Button(role: .destructive, action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove band")
        }
        .controlSize(.small)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor.opacity(0.1) : .clear))
    }

    private func field(_ unit: String, value: Double, range: ClosedRange<Double>, width: CGFloat, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 3) {
            TextField("", value: Binding(get: { value }, set: { set(min(max($0, range.lowerBound), range.upperBound)) }),
                      format: .number.precision(.fractionLength(unit == "Hz" ? 0 : 1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary).font(.caption)
        }
    }
}

func frequencyLabel(_ f: Double) -> String {
    f >= 1000 ? String(format: f >= 10000 ? "%.0fk" : "%.1fk", f / 1000).replacingOccurrences(of: ".0k", with: "k") : String(format: "%.0f", f)
}

/// Frequency-response plot with draggable band handles.
struct ResponseGraph: View {
    let settings: DSPSettings
    let sampleRate: Double
    /// Optional combined cascade (e.g. system + output EQ), drawn dashed.
    var effective: [Biquad]? = nil
    /// Optional measured response on AutoEQ.grid (dB, normalised), drawn grey.
    var measured: [Double?]? = nil
    @Binding var selected: UUID?
    var onEditingChanged: (Bool) -> Void = { _ in }
    let onDrag: (UUID, Double, Double) -> Void

    private let minF = 20.0, maxF = 20000.0, range = 18.0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, size in
                    drawGrid(ctx, size)
                    drawCurve(ctx, size)
                }
                ForEach(settings.bands.filter { $0.enabled }) { band in
                    let gain = band.type.usesGain ? band.gainDb : 0
                    Circle()
                        .fill(selected == band.id ? Color.accentColor : Color.accentColor.opacity(0.65))
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                        .frame(width: 12, height: 12)
                        .position(x: x(band.frequency, size.width), y: y(gain, size.height))
                        .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                            onEditingChanged(true)
                            selected = band.id
                            let f = frequency(atX: g.location.x, size.width)
                            let db = max(-range, min(range, ((size.height / 2 - g.location.y) / (size.height / 2)) * range))
                            onDrag(band.id, f.rounded(), (db * 2).rounded() / 2)
                        }.onEnded { _ in onEditingChanged(false) })
                        .help("\(band.type.displayName) \(frequencyLabel(band.frequency)) Hz \(String(format: "%+.1f dB", band.gainDb)) Q \(String(format: "%.2f", band.q))")
                }
            }
        }
    }

    private func x(_ f: Double, _ w: CGFloat) -> CGFloat {
        CGFloat(log10(f / minF) / log10(maxF / minF)) * w
    }

    private func frequency(atX px: CGFloat, _ w: CGFloat) -> Double {
        min(maxF, max(minF, minF * pow(maxF / minF, Double(px / w))))
    }

    private func y(_ db: Double, _ h: CGFloat) -> CGFloat {
        h / 2 - CGFloat(max(-range, min(range, db)) / range) * h / 2
    }

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        let line = Color.primary.opacity(0.08)
        for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
            var p = Path()
            p.move(to: CGPoint(x: x(f, size.width), y: 0))
            p.addLine(to: CGPoint(x: x(f, size.width), y: size.height))
            ctx.stroke(p, with: .color(line))
            ctx.draw(Text(frequencyLabel(f)).font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: x(f, size.width) + 2, y: size.height - 7), anchor: .leading)
        }
        for db in [-12.0, -6, 0, 6, 12] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y(db, size.height)))
            p.addLine(to: CGPoint(x: size.width, y: y(db, size.height)))
            ctx.stroke(p, with: .color(db == 0 ? Color.primary.opacity(0.2) : line))
            ctx.draw(Text(String(format: "%+.0f", db)).font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: 4, y: y(db, size.height) - 7), anchor: .leading)
        }
    }

    private func drawCurve(_ ctx: GraphicsContext, _ size: CGSize) {
        let cascade = BiquadDesign.cascade(settings, sampleRate: sampleRate)
        let preamp = settings.enabled ? BiquadDesign.effectivePreampDb(settings, sampleRate: sampleRate) : 0
        let top = min(maxF, sampleRate * 0.49)
        let n = 240
        var curve = Path()
        var withPreamp = Path()
        for i in 0..<n {
            let f = minF * pow(top / minF, Double(i) / Double(n - 1))
            let db = BiquadDesign.responseDb(cascade, frequency: f, sampleRate: sampleRate)
            let pt = CGPoint(x: x(f, size.width), y: y(db, size.height))
            let pt2 = CGPoint(x: pt.x, y: y(db + preamp, size.height))
            if i == 0 { curve.move(to: pt); withPreamp.move(to: pt2) } else { curve.addLine(to: pt); withPreamp.addLine(to: pt2) }
        }
        var fill = curve
        fill.addLine(to: CGPoint(x: x(top, size.width), y: size.height / 2))
        fill.addLine(to: CGPoint(x: 0, y: size.height / 2))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(Color.accentColor.opacity(0.12)))
        ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2)
        if abs(preamp) > 0.05 {
            ctx.stroke(withPreamp, with: .color(Color.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        if let measured {
            var m = Path()
            var started = false
            for (i, v) in measured.enumerated() where i < AutoEQ.grid.count {
                guard let v else { started = false; continue }
                let pt = CGPoint(x: x(AutoEQ.grid[i], size.width), y: y(v, size.height))
                if started { m.addLine(to: pt) } else { m.move(to: pt); started = true }
            }
            ctx.stroke(m, with: .color(Color.secondary.opacity(0.7)), lineWidth: 1.5)
        }
        if let effective {
            var eff = Path()
            for i in 0..<n {
                let f = minF * pow(top / minF, Double(i) / Double(n - 1))
                let pt = CGPoint(x: x(f, size.width), y: y(BiquadDesign.responseDb(effective, frequency: f, sampleRate: sampleRate), size.height))
                if i == 0 { eff.move(to: pt) } else { eff.addLine(to: pt) }
            }
            ctx.stroke(eff, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
    }
}
