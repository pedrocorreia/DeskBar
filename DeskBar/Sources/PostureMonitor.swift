import Foundation
import AppKit
import IOKit
import UserNotifications

/// Tracks how long you've spent sitting vs. standing today, and (optionally)
/// nudges you to switch posture on an interval.
///
/// Both jobs run off one low-frequency timer. Tracking is wall-clock based: the
/// desk only streams height while it's moving, so we can't count "samples seen
/// standing" — instead we read the current posture each tick and attribute the
/// elapsed wall time to it. Accounting pauses while the desk is disconnected or
/// the Mac has been idle for a while, so walking away doesn't inflate your
/// standing time or fire reminders at an empty desk. Totals reset daily.
@MainActor
final class PostureMonitor: NSObject, ObservableObject {
    // Same singleton rationale as DeskController.shared.
    static let shared = PostureMonitor()

    enum Posture { case sitting, standing }

    // MARK: - Settings (persisted)

    @Published var remindersEnabled: Bool {
        didSet {
            UserDefaults.standard.set(remindersEnabled, forKey: "remindersEnabled")
            if remindersEnabled {
                enableReminders()
                if present { nextRemindAt = Date().addingTimeInterval(intervalMin * 60) }
            }
            scheduleReminder()
        }
    }
    // Minutes to hold one posture before a nudge. Clamped on commit via
    // setIntervalMin(_:) rather than in didSet — the popover's TextField binds
    // $intervalMin directly and a re-entrant clamp fights live typing (see
    // DeskController.nudgeCm for the same reasoning).
    @Published var intervalMin: Double {
        didSet { UserDefaults.standard.set(intervalMin, forKey: "reminderIntervalMin") }
    }
    @Published var autoSwitch: Bool {
        didSet { UserDefaults.standard.set(autoSwitch, forKey: "reminderAutoSwitch") }
    }

    // MARK: - Tracking (persisted, reset daily)

    @Published private(set) var sitSeconds: Double
    @Published private(set) var standSeconds: Double
    private var trackingDay: String

    /// When the next reminder / auto-switch will fire, or nil when no countdown
    /// is active (reminders off, or paused because you're away/disconnected).
    /// The popover derives a live seconds countdown from this.
    @Published private(set) var nextSwitchAt: Date?

    /// Per-day archive of finished days (today lives in sit/standSeconds until it
    /// rolls over at midnight). Pruned to the last ~30 days.
    @Published private(set) var history: [String: DayStat]

    /// Daily standing-time goal, in minutes. Clamp on commit via setGoalMinutes.
    @Published var goalStandMinutes: Double {
        didSet { UserDefaults.standard.set(goalStandMinutes, forKey: "goalStandMinutes") }
    }

    struct DayStat: Codable, Identifiable {
        let day: String        // "yyyy-MM-dd"
        var stand: Double
        var sit: Double
        var id: String { day }
    }

    // MARK: - Runtime state

    private let desk = DeskController.shared
    private var timer: Timer?
    private var reminderTimer: Timer?
    private var present = false
    private var screenLocked = false
    private var activePosture: Posture?
    private var lastAccountAt = Date()
    private var postureRunStart = Date()
    private var nextRemindAt = Date.distantFuture

    private let tickInterval: TimeInterval = 30
    private let idleLimitSeconds: Double = 600   // 10 min away → pause

    // nonisolated: referenced from the (nonisolated) notification-delegate
    // callbacks; immutable Strings, so lifting them off the actor is safe.
    private nonisolated static let categoryID = "POSTURE_REMINDER"
    private nonisolated static let switchActionID = "POSTURE_SWITCH"

    override init() {
        let d = UserDefaults.standard
        remindersEnabled = d.bool(forKey: "remindersEnabled")                      // default false
        intervalMin = d.object(forKey: "reminderIntervalMin") as? Double ?? 45
        autoSwitch = d.bool(forKey: "reminderAutoSwitch")                          // default false
        goalStandMinutes = d.object(forKey: "goalStandMinutes") as? Double ?? 120  // 2 h
        sitSeconds = d.object(forKey: "sitSecondsToday") as? Double ?? 0
        standSeconds = d.object(forKey: "standSecondsToday") as? Double ?? 0
        trackingDay = d.string(forKey: "trackingDay") ?? Self.today()
        if let data = d.data(forKey: "postureHistory"),
           let decoded = try? JSONDecoder().decode([String: DayStat].self, from: data) {
            history = decoded
        } else {
            history = [:]
        }
        super.init()
        // A total stored on a previous day belongs to that day's archive, not today.
        if trackingDay != Self.today() { rolloverDay() }
    }

    // MARK: - Lifecycle

    func start() {
        UNUserNotificationCenter.current().delegate = self
        observeScreenLock()
        if remindersEnabled { enableReminders() }
        lastAccountAt = Date()
        tick()   // seed immediately so "Today" isn't blank until the first interval
        let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = tickInterval * 0.5   // coarse timer; let macOS coalesce wake-ups
        timer = t
    }

    func setIntervalMin(_ value: Double) {
        // No lower bound beyond a 1-minute safety floor (0 would make the
        // reminder timer fire in a tight loop).
        intervalMin = min(max(value.rounded(), 1), 180)
        // Re-arm relative to now so an edit takes effect without an extra wait.
        if present, remindersEnabled {
            nextRemindAt = Date().addingTimeInterval(intervalMin * 60)
            scheduleReminder()
        }
    }

    // MARK: - Core loop

    private func tick() {
        let now = Date()
        rolloverIfNeeded()

        let nowPresent = desk.isReady && !screenLocked
            && Self.systemIdleSeconds() < idleLimitSeconds

        guard nowPresent else {
            if present {
                account(upTo: now)      // flush the tail before pausing
                present = false
                scheduleReminder()      // present == false → clears the countdown
            }
            activePosture = nil
            lastAccountAt = now
            return
        }

        let posture: Posture = desk.isStanding ? .standing : .sitting

        guard present else {
            // Resuming after a pause (or the very first tick): start fresh —
            // don't bill the gap, and don't fire the instant you return.
            present = true
            activePosture = posture
            lastAccountAt = now
            postureRunStart = now
            nextRemindAt = now.addingTimeInterval(intervalMin * 60)
            scheduleReminder()
            return
        }

        account(upTo: now)

        // A posture change resets the countdown — switching *is* the movement we
        // were nudging toward. The reminder itself fires from its own precise
        // one-shot timer, not from this coarse (30 s) tracking tick.
        if posture != activePosture {
            activePosture = posture
            postureRunStart = now
            nextRemindAt = now.addingTimeInterval(intervalMin * 60)
            scheduleReminder()
        }

        persistTracking()
    }

    /// Attribute the wall time since the last accounting to the active posture.
    private func account(upTo now: Date) {
        guard let ap = activePosture else { lastAccountAt = now; return }
        let dt = now.timeIntervalSince(lastAccountAt)
        lastAccountAt = now
        guard dt > 0 else { return }
        switch ap {
        case .sitting:  sitSeconds += dt
        case .standing: standSeconds += dt
        }
    }

    // MARK: - Daily rollover

    private func rolloverIfNeeded() {
        if trackingDay != Self.today() { rolloverDay() }
    }

    /// Archive the finishing day, then zero the counters for the new day.
    private func rolloverDay() {
        archiveCurrentDay()
        sitSeconds = 0
        standSeconds = 0
        trackingDay = Self.today()
        persistTracking()
    }

    private func archiveCurrentDay() {
        guard standSeconds + sitSeconds >= 1 else { return }   // don't archive empty days
        history[trackingDay] = DayStat(day: trackingDay, stand: standSeconds, sit: sitSeconds)
        pruneHistory()
        persistHistory()
    }

    private func pruneHistory() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let cutoffKey = Self.dayKey(cutoff)
        history = history.filter { $0.key >= cutoffKey }   // "yyyy-MM-dd" sorts chronologically
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "postureHistory")
        }
    }

    private func persistTracking() {
        let d = UserDefaults.standard
        d.set(sitSeconds, forKey: "sitSecondsToday")
        d.set(standSeconds, forKey: "standSecondsToday")
        d.set(trackingDay, forKey: "trackingDay")
    }

    private static func today() -> String { dayKey(Date()) }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - Reminders

    private func enableReminders() {
        let center = UNUserNotificationCenter.current()
        let switchAction = UNNotificationAction(identifier: Self.switchActionID,
                                                title: "Switch now", options: [])
        let category = UNNotificationCategory(identifier: Self.categoryID,
                                              actions: [switchAction],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// (Re)arm the one-shot timer that fires the next reminder exactly at
    /// nextRemindAt, and publish that instant for the UI countdown. Clears both
    /// when no countdown should run (reminders off, or paused/away).
    private func scheduleReminder() {
        reminderTimer?.invalidate()
        reminderTimer = nil
        guard remindersEnabled, present else { nextSwitchAt = nil; return }
        nextSwitchAt = nextRemindAt
        let delay = max(nextRemindAt.timeIntervalSinceNow, 0)
        reminderTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reminderFired() }
        }
    }

    private func reminderFired() {
        guard remindersEnabled, present, let ap = activePosture else { return }
        fireReminder(currentlyStanding: ap == .standing,
                     heldFor: Date().timeIntervalSince(postureRunStart))
        nextRemindAt = Date().addingTimeInterval(intervalMin * 60)   // re-nudge each interval
        scheduleReminder()
    }

    private func fireReminder(currentlyStanding: Bool, heldFor: TimeInterval) {
        if autoSwitch { switchPosture() }

        let content = UNMutableNotificationContent()
        let held = Self.durationText(heldFor)
        if currentlyStanding {
            content.title = autoSwitch ? "Sitting you down" : "Time to sit"
            content.body = "You've been standing for \(held)."
        } else {
            content.title = autoSwitch ? "Standing you up" : "Time to stand"
            content.body = "You've been sitting for \(held)."
        }
        content.sound = .default
        if !autoSwitch { content.categoryIdentifier = Self.categoryID }   // no action button when we already moved

        let req = UNNotificationRequest(identifier: "posture-\(UUID().uuidString)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func switchPosture() {
        if desk.isStanding { desk.goSit() } else { desk.goStand() }
    }

    // MARK: - Formatting for the UI

    var standText: String { Self.durationText(standSeconds) }
    var sitText: String { Self.durationText(sitSeconds) }
    var goalText: String { Self.durationText(goalStandSeconds) }

    var goalStandSeconds: Double { goalStandMinutes * 60 }
    var metGoalToday: Bool { standSeconds >= goalStandSeconds }
    var hasData: Bool { sitSeconds + standSeconds >= 1 }

    func setGoalMinutes(_ value: Double) {
        goalStandMinutes = min(max(value.rounded(), 15), 600)
    }

    /// Standing/sitting totals for the last `n` days, oldest → newest (today
    /// last). Today comes from the live counters; earlier days from the archive
    /// (0 if the app wasn't running that day).
    func recentDays(_ n: Int) -> [DayStat] {
        let cal = Calendar.current
        return stride(from: n - 1, through: 0, by: -1).map { offset -> DayStat in
            let date = cal.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let key = Self.dayKey(date)
            if key == trackingDay {
                return DayStat(day: key, stand: standSeconds, sit: sitSeconds)
            }
            return history[key] ?? DayStat(day: key, stand: 0, sit: 0)
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    // MARK: - Presence: screen lock

    /// Pause the instant the screen locks (instead of waiting out the idle
    /// timeout) and resume on unlock, via the distributed notifications macOS
    /// posts for lock state.
    private func observeScreenLock() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLocked(true) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLocked(false) }
        }
    }

    private func setLocked(_ locked: Bool) {
        guard locked != screenLocked else { return }
        screenLocked = locked
        tick()   // re-evaluate presence now: flush + pause on lock, resume on unlock
    }

    // MARK: - Idle detection (permission-free, via IOHIDSystem)

    private static func systemIdleSeconds() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOHIDSystem"),
                                           &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any],
              let idleNs = props["HIDIdleTime"] as? UInt64 else { return 0 }
        return Double(idleNs) / 1_000_000_000
    }
}

extension PostureMonitor: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        // Accessory apps count as foreground — show the banner anyway.
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let switched = response.actionIdentifier == Self.switchActionID
        Task { @MainActor in if switched { self.switchPosture() } }
        completionHandler()
    }
}
