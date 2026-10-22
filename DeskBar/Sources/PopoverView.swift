import SwiftUI

struct PopoverView: View {
    @ObservedObject var desk: DeskController
    @ObservedObject var shortcuts: ShortcutSettings
    @ObservedObject var posture: PostureMonitor
    @Environment(\.openWindow) private var openWindow
    @FocusState private var intervalFocused: Bool
    @FocusState private var goalFocused: Bool
    @State private var deskListHeight: CGFloat = 0
    @State private var expandedDeskID: UUID?
    @State private var deskSearch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            presetButtons
            nudgeRow
            randomizeButton
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

    private var randomizeButton: some View {
        Button { desk.randomize() } label: {
            Label("Randomize", systemImage: "dice").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!desk.isReady)
        .help("Move each connected desk to a random height within its range")
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
                if posture.notificationsDenied {
                    Label("Notifications denied — enable in System Settings", systemImage: "bell.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
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
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.calendar = Calendar(identifier: .gregorian)
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: dayKey) else { return "" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.calendar = Calendar(identifier: .gregorian)
        out.setLocalizedDateFormatFromTemplate("EEEEE")
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
                Text(desk.desks.count > 1 ? "Desks — all move together" : "Desk")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if desk.isPairing {
                    Button("Done") { desk.cancelPairing() }.controlSize(.small)
                } else {
                    Button("Add…") { desk.beginPairing() }.controlSize(.small)
                }
            }

            if desk.desks.isEmpty && desk.pendingIDs.isEmpty && !desk.isPairing {
                Text("No desk connected — tap Add… to find one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(desk.desks) { conn in
                ConnectedDeskRow(desk: desk, conn: conn,
                                 expanded: expandedDeskID == conn.id) {
                    expandedDeskID = expandedDeskID == conn.id ? nil : conn.id
                }
            }
            // Saved desks Bluetooth hasn't found yet — removable so a desk that's
            // gone for good doesn't keep the background scan running forever.
            ForEach(desk.pendingIDs, id: \.self) { id in
                HStack(spacing: 6) {
                    Circle().fill(Color.secondary).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(desk.nickname(for: id.uuidString) ?? "Saved desk").font(.caption)
                        Text("Not found yet — searching…").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { desk.remove(id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Forget this desk")
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
                    let visible = desk.discovered.filter(matchesDeskSearch)
                    let named = visible
                        .filter { desk.nickname(for: $0.id.uuidString) != nil }
                        .sorted { (desk.nickname(for: $0.id.uuidString) ?? "")
                            .localizedCaseInsensitiveCompare(desk.nickname(for: $1.id.uuidString) ?? "")
                            == .orderedAscending }
                    let others = visible
                        .filter { desk.nickname(for: $0.id.uuidString) == nil }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                    deskSearchField

                    if visible.isEmpty {
                        Text("No nearby desks match “\(deskSearch.trimmingCharacters(in: .whitespaces))”.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
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
                    }

                    Text("Tap a desk to add it; every added desk moves together. Bars show signal strength.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        // A query left over from the last pairing session would hide desks the
        // next time the picker opens, so each session starts unfiltered.
        .onChange(of: desk.isPairing) { _ in deskSearch = "" }
    }

    private var deskSearchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search by name or number", text: $deskSearch)
                .textFieldStyle(.plain)
            if !deskSearch.isEmpty {
                Button { deskSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }

    /// Matches the nickname or the advertised name (e.g. "DESK 4821"), ignoring
    /// case and diacritics, so typing the number on the desk's sticker finds it.
    private func matchesDeskSearch(_ d: DiscoveredDesk) -> Bool {
        let query = deskSearch.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return true }
        let nick = desk.nickname(for: d.id.uuidString) ?? ""
        return d.name.localizedStandardContains(query) || nick.localizedStandardContains(query)
    }

    private func deskRow(_ d: DiscoveredDesk) -> some View {
        Button { desk.add(d) } label: {
            HStack {
                Image(systemName: "plus.circle")
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
            Button("About DeskBar…") {
                openWindow(id: "about")
                // Accessory (menu-bar-only) apps are never activated automatically,
                // so the new window would open behind everything and never
                // become key without this.
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .controlSize(.small)
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

    /// Live value shown when not editing. Number-less "—" while the primary desk
    /// is disconnected (its heightCm is then stale), even if other desks are up.
    private var display: String {
        desk.isPrimaryReady ? String(format: "%.1f cm", desk.heightCm) : "—"
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(minWidth: 130, alignment: .leading)   // reserve stable width; .fixedSize() shifts layout as digits change
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
        if let target = parseCm(text) {
            desk.moveTo(cm: target)
        }
        editing = false
    }
}

/// Parse a typed height, tolerating a "cm" suffix, spaces, or a decimal comma.
private func parseCm(_ text: String) -> Double? {
    Double(text
        .replacingOccurrences(of: "cm", with: "")
        .replacingOccurrences(of: ",", with: ".")
        .trimmingCharacters(in: .whitespaces))
}

/// One added desk: live status + height, expandable to its per-desk settings
/// (nickname, calibrated minimum, a height for just this desk) and a Remove button.
private struct ConnectedDeskRow: View {
    @ObservedObject var desk: DeskController
    @ObservedObject var conn: DeskConnection
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conn.displayName).font(.caption)
                        if desk.nickname(for: conn.id.uuidString) != nil || !conn.isReady {
                            Text(conn.isReady ? conn.advertisedName : conn.statusText)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if conn.isReady {
                        Text(String(format: "%.1f cm", conn.heightCm))
                            .font(.caption).monospacedDigit()
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    DeskNicknameField(desk: desk, id: conn.id.uuidString)
                    HStack {
                        Text("Min height").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        TextField("", value: $conn.minCm,
                                  format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 44)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            // Clamp + refresh the readout on commit, not per keystroke —
                            // see setMinCm / the nudge field's binding note.
                            .onSubmit { conn.setMinCm(conn.minCm) }
                        Text("cm").font(.caption).foregroundStyle(.secondary)
                    }
                    DeskHeightField(desk: desk, conn: conn)
                    Button(role: .destructive) { desk.remove(conn.id) } label: {
                        Label("Remove desk", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 13)
            }
        }
    }

    private var color: Color {
        if conn.isMoving { return .orange }
        return conn.isReady ? .green : .secondary
    }
}

/// Moves just this one desk (the header readout and Sit/Stand move all of them).
/// A plain draft, not bound to the live height: the row above already shows
/// that, and a draft that tracked it would fight typing while the desk moves.
private struct DeskHeightField: View {
    let desk: DeskController
    @ObservedObject var conn: DeskConnection
    @State private var draft = ""

    var body: some View {
        HStack {
            Text("Height").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if conn.isMoving {
                Button { conn.stop() } label: { Image(systemName: "stop.fill") }
                    .controlSize(.small)
                    .tint(.red)
                    .help("Stop this desk")
            }
            TextField(String(format: "%.0f", conn.heightCm), text: $draft)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(commit)
            Text("cm").font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!conn.isReady)
        .help("Type a height and press Return to move only this desk")
    }

    private func commit() {
        if let target = parseCm(draft) { desk.move(conn, to: target) }   // clamps to this desk's range
        draft = ""
    }
}

/// A local, free-text nickname for a desk (e.g. "My desk"), stored keyed by its
/// Bluetooth id — it never changes the desk's advertised name. Buffered in a
/// local draft and committed on Return or blur.
private struct DeskNicknameField: View {
    @ObservedObject var desk: DeskController
    let id: String
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
                .onAppear { draft = desk.nickname(for: id) ?? "" }
        }
    }

    private func commit() { desk.setNickname(draft, for: id) }
}

/// Measures the desk list's natural content height so it can size to fit when
/// short and cap (then scroll) when long.
private struct DeskListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
