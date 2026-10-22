import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = Runtime.arguments.contains("--settings")

    var body: some View {
        VStack(spacing: 8) {
            if showSettings {
                SettingsPage { withAnimation(.snappy(duration: 0.25)) { showSettings = false } }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 8) {
                    OutputModule()
                    InputModule()
                    AppsModule()
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            FooterBar(showSettings: $showSettings)
        }
        .padding(10)
        .frame(width: 380)
        .onAppear {
            model.devices.readVolumes()
            model.monitor.refresh()
            model.mixer.refreshPermission()
        }
    }
}

// MARK: Building blocks

/// Switch for settings. Snapshots run in an app that is never active, where AppKit draws a switch that is on in its grey
/// inactive look; there a drawn copy of the active switch covers it, so the images show the switch as it looks in the open menu.
struct SettingSwitchStyle: ToggleStyle {
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .overlay(alignment: .trailing) {
                if Runtime.isSnapshot && configuration.isOn {
                    let mini = controlSize == .mini
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: mini ? 32 : 44, height: mini ? 15 : 20)
                        .overlay(alignment: .trailing) {
                            Capsule().fill(.white).frame(width: mini ? 19 : 27, height: mini ? 11 : 16).padding(.trailing, 2)
                        }
                }
            }
    }
}

extension ToggleStyle where Self == SettingSwitchStyle {
    static var setting: SettingSwitchStyle { SettingSwitchStyle() }
}

/// Snapshot mode only: where controls sit in the rendered menu, in points from its top left. Written next to the images as
/// <base>-targets.json, so the README animations (scripts/compose.swift --scene) can point the cursor at them.
@MainActor
enum DemoTargets {
    static var frames: [String: CGRect] = [:]
    static func write(to path: String) {
        let json = frames.mapValues { [$0.minX, $0.minY, $0.width, $0.height].map { ($0 * 10).rounded() / 10 } }
        try? JSONEncoder().encode(json).write(to: URL(fileURLWithPath: path))
    }
}

extension View {
    /// Records this view's frame for the README animations (snapshots only, see `DemoTargets`).
    func demoTarget(_ id: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if Runtime.isSnapshot { DemoTargets.frames[id] = frame }
        }
    }
}

/// Explanation under a setting or status: secondary, wraps to as many lines as it needs and is never truncated.
/// `fixedSize(vertical:)` makes the menu panel measure the full height; without it the panel cuts the text off.
struct SettingNote: View {
    let text: String
    var tint: Color? = nil
    init(_ text: String, tint: Color? = nil) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tile in the style of the Control Center modules.
struct Module<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(scheme == .dark ? 0.06 : 0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(scheme == .dark ? 0.08 : 0.05), lineWidth: 0.5)
            )
    }
}

/// Small round button with a symbol (mute, gear, reset …).
struct RoundIconButton: View {
    let symbol: String
    var size: CGFloat = 22
    var active = false
    var activeColor: Color = .accentColor
    var help = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(active ? Color.white : (hover ? Color.primary : Color.secondary))
                .frame(width: size, height: size)
                .background(active ? AnyShapeStyle(activeColor.gradient) : AnyShapeStyle(.primary.opacity(hover ? 0.12 : 0.07)), in: Circle())
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct DeviceBadge: View {
    let symbol: String
    var size: CGFloat = 24
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: Circle())
    }
}

func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

func rateLabel(_ rate: Double) -> String {
    let khz = rate / 1000
    return khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
}

// MARK: Output

struct OutputModule: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = Runtime.arguments.contains("--devices")

    var body: some View {
        @Bindable var m = model
        let dm = model.devices
        let level = model.outputLevel
        let muted = dm.outputMuted
        Module {
            DeviceHeader(title: "Output", device: dm.currentOutput, fallback: "speaker.wave.2.fill",
                         value: muted ? "Muted" : percent(level), boosted: model.outputBoosted && !muted,
                         expanded: $expanded)
                .demoTarget("output")
            HStack(spacing: 6) {
                CapsuleSlider(
                    value: $m.outputLevel,
                    range: 0...Double(AppMixer.maxVolume),
                    symbol: muted || level < 0.001 ? "speaker.slash.fill" : "speaker.wave.3.fill",
                    symbolValue: min(level, 1),
                    dimmed: muted,
                    detent: 1,
                    boostFrom: 1
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded { model.outputLevel = 1 })
                .help("Volume of your speakers or headphones; double-click to reset to 100%")
                RoundIconButton(symbol: muted ? "speaker.slash.fill" : "speaker.fill", size: 24, active: muted,
                                activeColor: .red, help: muted ? "Unmute" : "Mute") {
                    dm.setMuted(!muted, .output)
                }
            }
            if expanded {
                DeviceList(direction: .output) { withAnimation(.snappy(duration: 0.25)) { expanded = false } }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct InputModule: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = Runtime.isSnapshot && Runtime.arguments.contains("--inputs")

    var body: some View {
        let dm = model.devices
        let muted = dm.inputMuted
        Module {
            DeviceHeader(title: "Input", device: dm.currentInput, fallback: "mic.fill",
                         value: muted ? "Muted" : (dm.inputHasVolume ? percent(Double(dm.inputVolume)) : nil),
                         boosted: false, expanded: $expanded)
            if dm.inputHasVolume || expanded {
                HStack(spacing: 6) {
                    CapsuleSlider(
                        value: Binding(get: { Double(dm.inputVolume) }, set: { dm.setVolume(Float($0), .input) }),
                        symbol: muted ? "mic.slash.fill" : "mic.fill",
                        dimmed: muted || !dm.inputHasVolume
                    )
                    .disabled(!dm.inputHasVolume)
                    .help(dm.inputHasVolume ? "How loudly the microphone picks up sound" : "This microphone has no volume control")
                    RoundIconButton(symbol: muted ? "mic.slash.fill" : "mic.fill", size: 24, active: muted,
                                    activeColor: .red, help: muted ? "Unmute Microphone" : "Mute Microphone") {
                        dm.setMuted(!muted, .input)
                    }
                }
            }
            if expanded {
                DeviceList(direction: .input) { withAnimation(.snappy(duration: 0.25)) { expanded = false } }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct DeviceHeader: View {
    let title: String
    let device: AudioDevice?
    let fallback: String
    let value: String?
    let boosted: Bool
    @Binding var expanded: Bool
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                DeviceBadge(symbol: device.map(model.symbol) ?? fallback)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(device.map(model.name) ?? "No Device")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let value {
                    Text(value)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(boosted ? Color.orange : Color.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hover ? .secondary : .tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(expanded ? "Hide Devices" : "Choose Device")
    }
}

struct DeviceList: View {
    let direction: AudioDirection
    let done: () -> Void
    @Environment(AppModel.self) private var model
    @State private var showHidden = false

    var body: some View {
        let dm = model.devices
        let devices = direction == .output ? dm.outputs : dm.inputs
        let current = direction == .output ? dm.currentOutput : dm.currentInput
        // The active device always stays visible, even if it is hidden.
        let visible = devices.filter { !dm.isHidden($0) || $0.id == current?.id }
        let hidden = devices.filter { dm.isHidden($0) && $0.id != current?.id }
        VStack(spacing: 1) {
            Divider().padding(.bottom, 3)
            ForEach(visible) { device in
                DeviceRow(name: model.name(device), symbol: model.symbol(device), selected: device.id == current?.id, hidden: dm.isHidden(device),
                          toggleHidden: { withAnimation(.snappy) { dm.setHidden(!dm.isHidden(device), device) } }) {
                    dm.select(device)
                    done()
                }
            }
            if !hidden.isEmpty {
                ListActionRow(symbol: showHidden ? "chevron.down" : "chevron.right", title: "Hidden (\(hidden.count))",
                              help: showHidden ? "Collapse hidden devices" : "Show hidden devices", secondary: true) {
                    withAnimation(.snappy(duration: 0.25)) { showHidden.toggle() }
                }
                if showHidden {
                    ForEach(hidden) { device in
                        DeviceRow(name: model.name(device), symbol: model.symbol(device), selected: false, hidden: true,
                                  toggleHidden: { withAnimation(.snappy) { dm.setHidden(false, device) } }) {
                            dm.select(device)
                            done()
                        }
                        .opacity(0.7)
                    }
                    .transition(.opacity)
                }
            }
            if Features.sampleRate {
                SampleRateRow(direction: direction)
                    .padding(.top, 3)
            }
        }
        .onAppear {
            showHidden = Runtime.isSnapshot && Runtime.arguments.contains("--hidden")
            // AirPlay room names: the first search happens only when the user expands the list (macOS then asks once for "Local Network").
            if direction == .output { model.airPlay.start() }
        }
    }
}

/// Row without a device in the device list (Hidden).
struct ListActionRow: View {
    let symbol: String
    let title: String
    let help: String
    var secondary = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(secondary ? .secondary : .primary)
                    .frame(width: 22, height: 22)
                    .background(secondary ? AnyShapeStyle(.clear) : AnyShapeStyle(.primary.opacity(0.08)), in: Circle())
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary ? .secondary : .primary)
                Spacer()
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(hover ? AnyShapeStyle(.primary.opacity(0.07)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct SampleRateRow: View {
    let direction: AudioDirection
    @Environment(AppModel.self) private var model

    var body: some View {
        let dm = model.devices
        let rates = direction == .output ? dm.outputRates : dm.inputRates
        let current = direction == .output ? dm.outputRate : dm.inputRate
        let preferred = dm.preferredRate(direction)
        if rates.count > 1 {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text("Sample Rate")
                    .font(.system(size: 12))
                Spacer()
                Menu {
                    Button {
                        dm.setPreferredRate(nil, direction)
                    } label: {
                        if preferred == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
                    }
                    Divider()
                    ForEach(rates, id: \.self) { rate in
                        Button {
                            dm.setPreferredRate(rate, direction)
                            if direction == .output { model.mixer.rebuildAll() }
                        } label: {
                            if preferred == rate { Label(rateLabel(rate), systemImage: "checkmark") } else { Text(rateLabel(rate)) }
                        }
                    }
                } label: {
                    Text(preferred == nil ? "Automatic · \(rateLabel(current))" : rateLabel(current))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 5)
            .help("How many times per second audio is sampled. Automatic lets macOS and your apps choose; a fixed rate is remembered per device.")
        }
    }
}

struct DeviceRow: View {
    let name: String
    let symbol: String
    let selected: Bool
    var hidden = false
    var toggleHidden: (() -> Void)? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        // The eye is a separate button next to (not inside) the row: clicking it must never also trigger "select device",
        // which collapsed the list.
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? .white : .primary)
                        .frame(width: 22, height: 22)
                        .background(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.primary.opacity(0.08)), in: Circle())
                    Text(name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 5)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(selected ? "This device is currently in use" : "Use this device")
            .demoTarget("device-\(name)")
            if let toggleHidden {
                // Hide button only visible on hover so the list stays calm; hidden devices show "Show".
                // Always present instead of `if hover`: every structural change makes macOS reset the pointer –
                // with a customized accessibility pointer ~40–60 ms each time (measured).
                RoundIconButton(symbol: hidden ? "eye" : "eye.slash", size: 20,
                                help: hidden ? "Show in List" : "Hide from List", action: toggleHidden)
                    .opacity(hover || hidden ? 1 : 0)
            }
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.trailing, 5)
        .background(hover ? AnyShapeStyle(.primary.opacity(0.07)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hover = $0 }
        .contextMenu {
            if let toggleHidden { Button(hidden ? "Show in List" : "Hide from List", action: toggleHidden) }
        }
    }
}

// MARK: Apps

struct AppsModule: View {
    @Environment(AppModel.self) private var model
    @State private var expandedApp: String? = Runtime.isDemo && Features.appDetails ? "com.apple.Music" : nil
    @State private var showOthers = Runtime.isSnapshot && Runtime.arguments.contains("--others")
    @State private var contentHeight: CGFloat = 0
    /// Which apps were at the top when opened: while the menu is open, no app jumps while adjusting
    /// between the top and "More Apps" (they would otherwise move around during adjustment).
    @State private var frozenTop: Set<String>?
    @State private var frozenKnown: Set<String> = []

    /// Up to this number all apps are in one list; above it, quiet apps are collapsed.
    private static let groupThreshold = 6

    private var allApps: [AudioApp] {
        model.apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func isActive(_ app: AudioApp) -> Bool {
        model.recentlyPlaying.contains(app.id) || app.isPlaying || !model.mixer.applied(for: app.id).isNeutral || expandedApp == app.id
    }

    private func freeze() {
        let all = allApps
        frozenTop = Set(all.filter(isActive).map(\.id))
        frozenKnown = Set(all.map(\.id))
    }

    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return min(max(screen - 380, 200), 470)
    }

    var body: some View {
        let mixer = model.mixer
        // Always alphabetical; nothing is re-sorted by volume or playback.
        let all = allApps
        let grouped = all.count > Self.groupThreshold
        let liveTop = Set(all.filter(isActive).map(\.id))
        // Newly added apps may appear at the top, known ones keep their place.
        let top = frozenTop.map { $0.union(liveTop.subtracting(frozenKnown)) } ?? liveTop
        let active = grouped ? all.filter { top.contains($0.id) } : all
        let others = grouped ? all.filter { !top.contains($0.id) } : []
        let anyChanged = all.contains { !mixer.setting(for: $0.id).volumeIsNeutral }

        Module(spacing: 6) {
            HStack(spacing: 6) {
                Text("Apps").font(.system(size: 12, weight: .semibold))
                if !all.isEmpty {
                    Text("\(all.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.primary.opacity(0.07), in: Capsule())
                }
                Spacer()
                if anyChanged {
                    Button("All to 100%") {
                        withAnimation(.snappy) { all.forEach { mixer.resetVolume($0.id) } }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .help("Set the volume of every app back to 100%")
                }
            }

            if mixer.permission != .granted && !Runtime.isDemo {
                PermissionBanner()
            }

            if all.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "speaker.zzz")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text("No app is using audio right now.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(active) { app in row(app) }
                        if !others.isEmpty {
                            OthersToggle(count: others.count, open: showOthers || active.isEmpty) {
                                withAnimation(.snappy(duration: 0.25)) { showOthers.toggle() }
                            }
                            .disabled(active.isEmpty)
                            if showOthers || active.isEmpty {
                                ForEach(others) { app in row(app) }
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.automatic)
                .frame(height: min(max(contentHeight, 1), maxListHeight))
                .mask(ScrollFade(active: contentHeight > maxListHeight))
            }
        }
        .animation(.snappy(duration: 0.25), value: active.map(\.id))
        .onChange(of: Features.shared.advanced) { _, on in if !on { expandedApp = nil } }
        .onAppear(perform: freeze)
        .onChange(of: model.menuOpenCount) { freeze() }
    }

    private func row(_ app: AudioApp) -> some View {
        AppRow(app: app, expanded: expandedApp == app.id) {
            withAnimation(.snappy(duration: 0.25)) { expandedApp = expandedApp == app.id ? nil : app.id }
        }
    }
}

/// Soft edge at the bottom when the list scrolls.
struct ScrollFade: View {
    let active: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
            if active {
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 14)
            }
        }
    }
}

struct OthersToggle: View {
    let count: Int
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("More Apps")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .foregroundStyle(hover ? .primary : .secondary)
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(open ? "Hide the apps that are not playing sound" : "Show the apps that are not playing sound")
    }
}

struct AppRow: View {
    let app: AudioApp
    let expanded: Bool
    let toggleDetail: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        let mixer = model.mixer
        let s = mixer.applied(for: app.id)
        let shown = s.muted ? 0 : Double(s.volume)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon)   // pre-rendered at 24 pt
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(app.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        if app.isPlaying {
                            Image(systemName: "waveform")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .symbolEffect(.variableColor.iterative, options: .repeating)
                        }
                        if s.profile != .flat {
                            Image(systemName: s.profile.symbol)
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .help(s.profile.title)
                        }
                        if let failure = mixer.failures[app.id] {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help(failure)
                        }
                        Spacer(minLength: 2)
                        Text(s.muted ? "Muted" : percent(shown))
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(s.muted ? Color.secondary : (shown > 1.005 ? Color.orange : (s.volumeIsNeutral ? Color.secondary : Color.accentColor)))
                    }
                    CapsuleSlider(
                        value: Binding(get: { shown }, set: { mixer.setVolume(Float($0), for: app.id) }),
                        range: 0...Double(AppMixer.maxVolume),
                        height: 12,
                        tint: .accentColor,
                        dimmed: s.muted,
                        detent: 1,
                        boostFrom: 1
                    )
                    .simultaneousGesture(TapGesture(count: 2).onEnded { mixer.resetVolume(app.id) })
                    .help("Volume of \(app.name); double-click to reset to 100%")
                    .demoTarget("slider-\(app.name)")
                }
                HStack(spacing: 4) {
                    RoundIconButton(symbol: s.muted ? "speaker.slash.fill" : "speaker.fill", size: 22, active: s.muted,
                                    activeColor: .red, help: s.muted ? "Unmute" : "Mute") {
                        mixer.toggleMute(for: app.id)
                    }
                    if Features.appDetails {
                        RoundIconButton(symbol: "gearshape.fill", size: 22, active: expanded || !s.effectsAreNeutral,
                                        help: "Sound, balance and output for \(app.name)", action: toggleDetail)
                            .opacity(hover || expanded || !s.effectsAreNeutral ? 1 : 0.35)
                    }
                }
            }
            if expanded && Features.appDetails {
                AppDetail(app: app)
                    // Cross-fade only: CoreGraphics stores text at intermediate sizes as separate glyph bitmaps per size
                    // that are never released – hence no `.numericText()` either.
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(expanded ? AnyShapeStyle(.primary.opacity(0.05)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { h in hover = h }   // no animation: otherwise every mouse movement redraws several frames
    }
}

/// Fine settings of an app: sound profile, balance, mono, own output device.
struct AppDetail: View {
    let app: AudioApp
    @Environment(AppModel.self) private var model

    var body: some View {
        let mixer = model.mixer
        let s = mixer.setting(for: app.id)
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(SoundProfile.allCases) { p in
                    ProfileChip(profile: p, selected: s.profile == p) {
                        withAnimation(.snappy(duration: 0.2)) { mixer.setProfile(p, for: app.id) }
                    }
                }
            }
            if s.profile != .flat {
                SettingNote(s.profile.detail)
                    .padding(.leading, 2)
            }

            HStack(spacing: 8) {
                Text("L").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                CapsuleSlider(
                    value: Binding(get: { Double(s.balance) }, set: { mixer.setBalance(Float($0), for: app.id) }),
                    range: -1...1, height: 12, tint: .accentColor, detent: 0, origin: 0
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded { mixer.setBalance(0, for: app.id) })
                Text("R").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .help("Balance – double-click to center")

            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { s.mono }, set: { mixer.setMono($0, for: app.id) })) {
                    Text("Mono").font(.system(size: 11))
                }
                .toggleStyle(.setting)
                .controlSize(.mini)
                .help("Play the left and right sound as one, so both sides sound the same")
                Spacer()
                OutputPicker(app: app, selected: s.outputUID)
            }

            HStack {
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.2)) { mixer.reset(app.id) }
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(s.isNeutral ? Color.secondary.opacity(0.5) : Color.accentColor)
                .disabled(s.isNeutral)
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 2)
        .padding(.bottom, 2)
    }
}

struct ProfileChip: View {
    let profile: SoundProfile
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: profile.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(height: 13)
                Text(profile.title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Color.white : (hover ? Color.primary : Color.secondary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.primary.opacity(hover ? 0.1 : 0.06)),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(profile.detail)
    }
}

struct OutputPicker: View {
    let app: AudioApp
    let selected: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        let outputs = model.devices.outputs
        let name = selected.flatMap { uid in outputs.first { $0.uid == uid }.map(model.name) } ?? (selected == nil ? "System Output" : "Not Connected")
        Menu {
            Button {
                model.mixer.setOutput(nil, for: app.id)
            } label: {
                if selected == nil { Label("System Output", systemImage: "checkmark") } else { Text("System Output") }
            }
            Divider()
            ForEach(outputs) { d in
                Button {
                    model.mixer.setOutput(d.uid, for: app.id)
                } label: {
                    if selected == d.uid { Label(model.name(d), systemImage: "checkmark") } else { Text(model.name(d)) }
                }
            }
        } label: {
            Label(name, systemImage: "hifispeaker")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .medium))
        .controlSize(.small)
        .fixedSize()
        .help("Output device for \(app.name)")
    }
}

struct PermissionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text("To control app volume, boost and sound, Sound Control needs permission for “System Audio Recording”.")
                    .font(.system(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Allow") { model.mixer.requestPermission() }
                        .help("Ask macOS to let Sound Control hear and adjust app sound")
                    Button("Open Settings") { CapturePermission.openSettings() }
                        .help("Open System Settings, where you can turn on System Audio Recording")
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Footer

struct FooterBar: View {
    @Binding var showSettings: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            let advanced = Features.shared.advanced
            RoundIconButton(symbol: "slider.horizontal.3", size: 16, active: advanced,
                            help: advanced ? "Hide advanced controls" : "Show advanced controls (sound, balance, output per app, sample rate)") {
                withAnimation(.snappy(duration: 0.25)) { Features.shared.toggle() }
            }
            .opacity(advanced ? 1 : 0.6)
            Text("Sound Control")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            // Only way to Apple's sound settings (one central button instead of one in every list).
            RoundIconButton(symbol: "speaker.wave.2.fill", size: 24, help: "macOS Sound Settings") {
                SystemSettings.openSound()
            }
            RoundIconButton(symbol: "gearshape.fill", size: 24, active: showSettings, help: "Settings") {
                withAnimation(.snappy(duration: 0.25)) { showSettings.toggle() }
            }
            RoundIconButton(symbol: "power", size: 24, help: "Quit Sound Control") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 4)
    }
}
