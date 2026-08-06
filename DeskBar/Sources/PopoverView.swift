import SwiftUI

struct PopoverView: View {
    @ObservedObject var desk: DeskController
    @ObservedObject var shortcuts: ShortcutSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            presetButtons
            nudgeRow
            Divider()
            presetConfig
            Divider()
            deskSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(desk.isReady ? String(format: "%.1f cm", desk.heightCm) : "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(desk.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: desk.isStanding ? "figure.stand" : "chair.lounge")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
        }
    }

    private var presetButtons: some View {
        HStack(spacing: 10) {
            presetButton(title: "Sit", cm: desk.sitCm, symbol: "chair.lounge",
                         fill: .cyan, action: desk.goSit)
            presetButton(title: "Stand", cm: desk.standCm, symbol: "figure.stand",
                         fill: .green, action: desk.goStand)
        }
        .disabled(!desk.isReady)
    }

    private func presetButton(title: String, cm: Double, symbol: String,
                              fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.headline)
                Text("\(Int(cm)) cm").font(.caption2).opacity(0.9)
            }
            // Dark text/icon for legibility on the bright fill.
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .opacity(desk.isReady ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }

    private var nudgeRow: some View {
        HStack(spacing: 8) {
            Button { desk.nudge(-desk.nudgeCm) } label: {
                Label(nudgeLabel, systemImage: "minus").frame(maxWidth: .infinity)
            }
            Button { desk.stop() } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .tint(.red)
            Button { desk.nudge(desk.nudgeCm) } label: {
                Label(nudgeLabel, systemImage: "plus").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .disabled(!desk.isReady)
    }

    private var nudgeLabel: String {
        desk.nudgeCm == desk.nudgeCm.rounded()
            ? "\(Int(desk.nudgeCm)) cm"
            : String(format: "%.1f cm", desk.nudgeCm)
    }

    private var presetConfig: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save current height as").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Set Sit") { desk.setSitToCurrent() }
                    .frame(maxWidth: .infinity)
                Button("Set Stand") { desk.setStandToCurrent() }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!desk.isReady)

            HStack {
                Text("Nudge amount").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("", value: $desk.nudgeCm, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 40)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    // Binding(get:set:) here would rebuild identity every
                    // render and risk fighting in-progress typing — clamp on
                    // commit instead, via the direct binding.
                    .onSubmit { desk.setNudgeCm(desk.nudgeCm) }
                Text("cm").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var deskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Desk").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if desk.isPairing {
                    Button("Cancel") { desk.cancelPairing() }.controlSize(.small)
                } else {
                    Button("Switch…") { desk.beginPairing() }.controlSize(.small)
                }
            }

            if desk.isPairing {
                if desk.discovered.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Searching for nearby desks…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(desk.discovered) { d in
                        Button { desk.select(d) } label: {
                            HStack {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                Text(d.name)
                                Spacer()
                                Text(signalLabel(d.rssi))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("Tip: strongest signal is usually the one you're sitting at.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(desk.deskName.isEmpty ? "Not connected" : desk.deskName)
                    .font(.caption).foregroundStyle(.secondary)
                if !desk.deskID.isEmpty {
                    Text(desk.deskID)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func signalLabel(_ rssi: Int) -> String {
        let bars: String
        switch rssi {
        case ..<(-80): bars = "▁"
        case ..<(-70): bars = "▁▃"
        case ..<(-60): bars = "▁▃▅"
        default:       bars = "▁▃▅▇"
        }
        return "\(bars) \(rssi)"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Global shortcuts").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit…") {
                    openWindow(id: "shortcuts")
                    // Accessory (menu-bar-only) apps are never activated automatically,
                    // so the new window would open behind everything and never
                    // become key without this.
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
            }
            shortcutRow("\(shortcuts.stand.displayString) / \(shortcuts.sit.displayString)", "Stand / Sit")
            shortcutRow("\(shortcuts.nudgeUp.displayString) / \(shortcuts.nudgeDown.displayString)", "Nudge ±\(nudgeLabel)")
            shortcutRow(shortcuts.stop.displayString, "Stop")
            Divider().padding(.vertical, 2)
            Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                Label("Quit DeskBar", systemImage: "power").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        HStack {
            Text(keys).font(.system(.caption, design: .monospaced))
            Spacer()
            Text(desc).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        if desk.isMoving { return .orange }
        return desk.isReady ? .green : .secondary
    }
}
