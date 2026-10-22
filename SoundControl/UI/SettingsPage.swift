import SwiftUI

/// Second page in the menu: login item, permission and all stored settings.
struct SettingsPage: View {
    let back: () -> Void
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var confirmReset = Runtime.isSnapshot && Runtime.arguments.contains("--confirm")

    var body: some View {
        let mixer = model.mixer
        let saved = mixer.settings.mapValues(\.applied).filter { !$0.value.isNeutral }.sorted { name($0.key).localizedStandardCompare(name($1.key)) == .orderedAscending }
        let gains = model.devices.outputs.compactMap { d in mixer.deviceGain[d.uid].map { (d, $0) } }

        VStack(spacing: 8) {
            HStack(spacing: 6) {
                RoundIconButton(symbol: "chevron.left", size: 24, help: "Back", action: back)
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 2)

            Module {
                HStack {
                    SettingLabel(symbol: "power", title: "Open at Login", tint: .green)
                    Spacer()
                    Toggle("Open at Login", isOn: Binding(get: { launchAtLogin }, set: { LoginItem.set($0); launchAtLogin = LoginItem.isEnabled }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Start Sound Control automatically when you log in")
                }
                SettingNote("Starts Sound Control automatically when you log in.")
                Divider()
                HStack {
                    SettingLabel(symbol: "lock.shield.fill", title: "System Audio Recording",
                                 tint: mixer.permission == .granted ? .blue : .orange)
                    Spacer()
                    if mixer.permission == .granted {
                        Text("Allowed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Allow") { mixer.requestPermission() }
                            .controlSize(.small)
                            .help("Ask macOS to let Sound Control hear and adjust app sound")
                    }
                }
                SettingNote("macOS only lets Sound Control change the volume of single apps with this permission.")
            }

            Module(spacing: 4) {
                HStack {
                    Text("Saved Settings").font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                SettingNote("Kept when the app, Sound Control or your Mac restarts.")
                    .padding(.bottom, 2)
                if saved.isEmpty {
                    Text(Features.appDetails ? "All apps play at 100% with no sound profile." : "All apps play at 100%.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(saved, id: \.key) { id, setting in
                                SavedRow(icon: AppIconCache.icon(for: -1, bundleID: id), title: name(id), detail: setting.summary) {
                                    withAnimation(.snappy) { mixer.reset(id) }
                                }
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !gains.isEmpty {
                    Divider().padding(.vertical, 3)
                    ForEach(gains, id: \.0.id) { device, gain in
                        SavedRow(symbol: model.symbol(device), title: model.name(device), detail: "Device boost \(percent(Double(gain)))") {
                            withAnimation(.snappy) { mixer.setDeviceGain(1, for: device.uid) }
                        }
                    }
                }
            }

            HStack {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                // Two-step so an accidental click deletes nothing.
                Button(confirmReset ? "Click Again to Reset" : "Reset All to Defaults") {
                    if confirmReset { resetEverything() } else {
                        withAnimation(.snappy) { confirmReset = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation(.snappy) { confirmReset = false } }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(confirmReset ? Color.red : Color.accentColor)
                .help(confirmReset ? "Click again within 3 seconds to confirm; this cannot be undone"
                                  : "Reset everything: all apps to 100%, no effects, automatic sample rates, all devices shown")
            }
            .padding(.horizontal, 4)
        }
    }

    private func resetEverything() {
        withAnimation(.snappy) {
            confirmReset = false
            Features.shared.reset()
            model.mixer.resetAll()
            model.devices.resetRates()
            model.devices.showAllDevices()
        }
    }

    private func name(_ id: String) -> String {
        model.mixer.names[id] ?? model.apps.first { $0.id == id }?.name ?? id
    }
}

struct SettingLabel: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title).font(.system(size: 12))
        }
    }
}

struct SavedRow: View {
    var icon: NSImage? = nil
    var symbol: String? = nil
    let title: String
    let detail: String
    let reset: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .background(.primary.opacity(0.08), in: Circle())
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            RoundIconButton(symbol: "arrow.counterclockwise", size: 20, help: "Reset", action: reset)
                .opacity(hover ? 1 : 0.5)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(hover ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hover = $0 }
    }
}
