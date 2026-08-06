import SwiftUI

struct PopoverView: View {
    @ObservedObject var desk: DeskController
    @ObservedObject var shortcuts: ShortcutSettings
    @ObservedObject var posture: PostureMonitor
    @Environment(\.openWindow) private var openWindow
    @FocusState private var intervalFocused: Bool
    @FocusState private var goalFocused: Bool
    @State private var deskListHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            presetButtons
            nudgeRow
            Divider()
            presetConfig
            Divider()
            postureSection
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
                EditableHeight(desk: desk)
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

    private var postureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Today").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if posture.hasData {
                    legendValue(.green, posture.standText)   // standing
                    legendValue(.cyan, posture.sitText)      // sitting
                    if posture.metGoalToday {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2).foregroundStyle(.green)
                    }
                } else {
                    Text("No data yet").font(.caption).foregroundStyle(.secondary)
                }
            }
            historyChart
            HStack {
                Text("Daily goal").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("", value: $posture.goalStandMinutes,
                          format: .number.precision(.fractionLength(0)))
                    .frame(width: 40)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($goalFocused)
                    .onSubmit { posture.setGoalMinutes(posture.goalStandMinutes) }
                Text("min").font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: goalFocused) { focused in
                if !focused { posture.setGoalMinutes(posture.goalStandMinutes) }
            }
            Toggle(isOn: $posture.remindersEnabled) {
                Text("Remind me to switch posture").font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            if posture.remindersEnabled {
                HStack(spacing: 6) {
                    Text("Every").font(.caption).foregroundStyle(.secondary)
                    TextField("", value: $posture.intervalMin,
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 34)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .focused($intervalFocused)
                        .onSubmit { posture.setIntervalMin(posture.intervalMin) }
                    Text("min").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle(isOn: $posture.autoSwitch) {
                        Text("Auto-switch").font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
                // Commit on unfocus too, not only on Return.
                .onChange(of: intervalFocused) { focused in
                    if !focused { posture.setIntervalMin(posture.intervalMin) }
                }
                if let target = posture.nextSwitchAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, target.timeIntervalSince(context.date))
                        HStack(spacing: 4) {
                            Image(systemName: posture.autoSwitch ? "timer" : "bell")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("\(posture.autoSwitch ? "Auto-switch" : "Next reminder") in \(countdownText(remaining))")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Last 7 days as a mini stacked bar chart — standing (green) below, sitting
    /// (cyan) above — with an orange standing-goal line. A day whose standing
    /// reached the goal is solid green; today is highlighted.
    private var historyChart: some View {
        let days = posture.recentDays(7)
        let goalSec = posture.goalStandSeconds
        let maxTotal = days.map { $0.stand + $0.sit }.max() ?? 0
        // 20% headroom so the goal line never sits on the very top edge (where it
        // previously bled into the row above).
        let top = max(goalSec, maxTotal, 1) * 1.2
        let todayKey = days.last?.day
        return VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(days) { d in
                            let isToday = d.day == todayKey
                            VStack(spacing: 0) {
                                Rectangle().fill(sitColor(isToday: isToday))
                                    .frame(height: geo.size.height * CGFloat(d.sit / top))
                                Rectangle().fill(standColor(d.stand, goalSec: goalSec, isToday: isToday))
                                    .frame(height: geo.size.height * CGFloat(d.stand / top))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .frame(maxWidth: .infinity)
                        }
                    }
                    Rectangle().fill(Color.orange.opacity(0.7))
                        .frame(height: 1)
                        .offset(y: -geo.size.height * CGFloat(goalSec / top))
                }
            }
            .frame(height: 34)
            .clipped()
            HStack(spacing: 3) {
                ForEach(days) { d in
                    Text(weekdayLetter(d.day))
                        .font(.system(size: 8))
                        .foregroundStyle(d.day == todayKey ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 10) {
                legendKey(.green, "Standing")
                legendKey(.cyan, "Sitting")
                legendLine(.orange, "Goal")
                Spacer()
            }
        }
    }

    private func standColor(_ stand: Double, goalSec: Double, isToday: Bool) -> Color {
        if goalSec > 0 && stand >= goalSec { return .green }
        return .green.opacity(isToday ? 0.55 : 0.35)
    }

    private func sitColor(isToday: Bool) -> Color {
        .cyan.opacity(isToday ? 0.5 : 0.3)
    }

    /// A colored dot + duration, used in the "Today" row as both a total and a
    /// legend for the chart's stacked colors.
    private func legendValue(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    /// Chart legend: a color swatch + label.
    private func legendKey(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Legend entry drawn as a line (for the goal marker).
    private func legendLine(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Rectangle().fill(color).frame(width: 8, height: 2)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func weekdayLetter(_ dayKey: String) -> String {
        let parse = DateFormatter(); parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: dayKey) else { return "" }
        let out = DateFormatter(); out.setLocalizedDateFormatFromTemplate("EEEEE")
        return out.string(from: date)
    }

    /// Seconds → "M:SS" (minutes uncapped, e.g. "45:00").
    private func countdownText(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
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
                    let named = desk.discovered
                        .filter { desk.nickname(for: $0.id.uuidString) != nil }
                        .sorted { (desk.nickname(for: $0.id.uuidString) ?? "")
                            .localizedCaseInsensitiveCompare(desk.nickname(for: $1.id.uuidString) ?? "")
                            == .orderedAscending }
                    let others = desk.discovered
                        .filter { desk.nickname(for: $0.id.uuidString) == nil }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                    // Cap the list at a fixed height and scroll past it, so a
                    // roomful of desks can't stretch the popover off-screen. It
                    // still shrinks to fit when only a few are found.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if !named.isEmpty {
                                Text("Saved").font(.caption2).foregroundStyle(.secondary)
                                ForEach(named) { deskRow($0) }
                            }
                            if !others.isEmpty {
                                if !named.isEmpty {
                                    Text("Other desks").font(.caption2).foregroundStyle(.secondary)
                                        .padding(.top, 2)
                                }
                                ForEach(others) { deskRow($0) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: DeskListHeightKey.self, value: g.size.height)
                        })
                    }
                    .frame(height: min(deskListHeight, 220))
                    .onPreferenceChange(DeskListHeightKey.self) { deskListHeight = $0 }

                    Text("Tip: name a desk to pin it to the top; the bars show signal strength.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                if let nick = desk.nickname(for: desk.deskID) {
                    Text(nick).font(.caption).foregroundStyle(.primary)
                    Text(desk.deskName.isEmpty ? "Not connected" : desk.deskName)
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(desk.deskName.isEmpty ? "Not connected" : desk.deskName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !desk.deskID.isEmpty {
                    DeskNicknameField(desk: desk)
                }
                HStack {
                    Text("Min height").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("", value: $desk.minCm,
                              format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        // Clamp + refresh the readout on commit, not per keystroke —
                        // see setMinCm / the nudge field's binding note.
                        .onSubmit { desk.setMinCm(desk.minCm) }
                    Text("cm").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
    }

    private func deskRow(_ d: DiscoveredDesk) -> some View {
        Button { desk.select(d) } label: {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right")
                VStack(alignment: .leading, spacing: 1) {
                    if let nick = desk.nickname(for: d.id.uuidString) {
                        Text(nick)
                        Text(d.name).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(d.name)
                    }
                }
                Spacer()
                Text(signalLabel(d.rssi)).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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

/// The big height readout, now editable: type a target height and press Return
/// to drive the desk there (moveTo(cm:) clamps to the desk's physical range).
///
/// It binds to a local buffer rather than $desk.heightCm directly. The buffer
/// mirrors the live height whenever the user hasn't diverged from it — including
/// while the field is focused, so a desk moving under you keeps the readout
/// current. Only once you type a different value does it freeze, so the stream
/// of incoming BLE height updates can't overwrite your keystrokes; it reverts to
/// the live height if you blur without pressing Return.
private struct EditableHeight: View {
    @ObservedObject var desk: DeskController
    @State private var text = ""
    // The value we last pushed in from the live height. While focused, if `text`
    // still equals it the user hasn't typed anything, so it's safe to keep
    // syncing; once they diverge we stop until they commit or blur.
    @State private var lastSynced = ""
    @FocusState private var editing: Bool

    /// Live value shown when not editing. Number-less "—" until connected.
    private var display: String {
        desk.isReady ? String(format: "%.1f cm", desk.heightCm) : "—"
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .fixedSize()
            .focused($editing)
            .disabled(!desk.isReady)
            .onSubmit(commit)
            // Single-parameter onChange: the two-parameter form is macOS 14+,
            // but this app deploys to macOS 13.
            .onChange(of: display) { newValue in
                // Keep mirroring the live height unless the user has started
                // typing a different value (text has diverged from lastSynced).
                if !editing || text == lastSynced { sync(to: newValue) }
            }
            .onChange(of: editing) { isEditing in
                if !isEditing { sync(to: display) }   // discard uncommitted edits on blur
            }
            .onAppear { sync(to: display) }
    }

    /// Push a live-height string into the field and remember it as the baseline
    /// for detecting whether the user has since typed anything.
    private func sync(to value: String) {
        text = value
        lastSynced = value
    }

    /// Parse the typed value (tolerating a "cm" suffix, spaces, or a decimal
    /// comma) and move the desk there. Then resign focus; the onChange above
    /// resyncs the field to the live height.
    private func commit() {
        let cleaned = text
            .replacingOccurrences(of: "cm", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if let target = Double(cleaned) {
            desk.moveTo(cm: target)
        }
        editing = false
    }
}

/// A local, free-text nickname for the connected desk (e.g. "My desk"), stored
/// keyed by its Bluetooth id — it never changes the desk's advertised name.
/// Buffered in a local draft and committed on Return or blur; resyncs if the
/// connected desk changes.
private struct DeskNicknameField: View {
    @ObservedObject var desk: DeskController
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text("Name").font(.caption).foregroundStyle(.secondary)
            Spacer()
            TextField("e.g. My desk", text: $draft)
                .frame(width: 150)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { isFocused in if !isFocused { commit() } }
                .onAppear { draft = desk.nickname(for: desk.deskID) ?? "" }
                .onChange(of: desk.deskID) { _ in draft = desk.nickname(for: desk.deskID) ?? "" }
        }
        .padding(.top, 2)
    }

    private func commit() { desk.setNickname(draft, for: desk.deskID) }
}

/// Measures the desk list's natural content height so it can size to fit when
/// short and cap (then scroll) when long.
private struct DeskListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
