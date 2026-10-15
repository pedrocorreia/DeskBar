import Foundation
@preconcurrency import CoreBluetooth

struct DiscoveredDesk: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

/// Owns the CoreBluetooth central and the set of connected desks, and fans every
/// command out to all of them — "Stand" or "100 cm" moves every connected desk.
///
/// The single-desk-shaped API (heightCm, isReady, moveTo, goSit, …) is kept as an
/// aggregate so hotkeys, PostureMonitor and ControlServer drive all desks without
/// knowing there's more than one. Reads like heightCm/isStanding come from the
/// *primary* desk: the first connected one in the list.
@MainActor
final class DeskController: NSObject, ObservableObject {
    // `_desk.wrappedValue` in DeskBarApp.init() reads a @StateObject before
    // SwiftUI has installed its storage, which hands back a throwaway instance
    // from the autoclosure rather than the one the UI actually uses — hotkeys
    // wired to that throwaway silently read stale state (e.g. nudgeCm frozen
    // at its launch-time value). Backing the @StateObject with a shared
    // singleton means "a new instance" always resolves to the same object.
    static let shared = DeskController()

    /// Connected (or reconnecting) desks, in the order they were added.
    @Published private(set) var desks: [DeskConnection] = []

    // Aggregate UI state, re-derived from `desks` by refresh(). Only assigned
    // when the value actually changes, so subscribers (PostureMonitor watches
    // $heightCm) aren't spammed by one desk's updates echoing through.
    @Published private(set) var heightCm: Double = 0
    @Published private(set) var isReady = false          // at least one desk ready
    @Published private(set) var statusText = "Starting…"
    @Published private(set) var isMoving = false         // any desk moving
    @Published private(set) var deskName = ""

    // Bluetooth-level problem (off / denied), which trumps per-desk status.
    private var centralStatus: String?

    // Desks the last moveTo was sent to. lastMoveReachedTarget is true only if
    // every one of them arrived — ControlServer reports a partial move as a failure.
    private var lastMoveDesks: [DeskConnection] = []
    var lastMoveReachedTarget: Bool { lastMoveDesks.allSatisfy(\.lastMoveReachedTarget) }
    /// Desks from the last move that stopped short, for error reporting.
    var desksShortOfTarget: [DeskConnection] { lastMoveDesks.filter { !$0.lastMoveReachedTarget } }

    // Desk-picker ("pairing") state
    @Published var isPairing = false
    @Published var discovered: [DiscoveredDesk] = []
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    // User presets (persisted). Shared by all desks — the point is to bring
    // every desk to the same sit/stand height.
    @Published var sitCm: Double  { didSet { UserDefaults.standard.set(sitCm, forKey: "sitCm") } }
    @Published var standCm: Double { didSet { UserDefaults.standard.set(standCm, forKey: "standCm") } }

    // Local, user-assigned desk nicknames, keyed by CoreBluetooth peripheral
    // UUID. Purely local — it never touches the desk's advertised BLE name.
    @Published private var nicknames: [String: String] {
        didSet { UserDefaults.standard.set(nicknames, forKey: "deskNicknames") }
    }

    /// The user's nickname for a desk id, or nil if none (blank counts as none).
    func nickname(for id: String) -> String? {
        guard !id.isEmpty, let n = nicknames[id], !n.isEmpty else { return nil }
        return n
    }

    func setNickname(_ name: String?, for id: String) {
        guard !id.isEmpty else { return }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { nicknames.removeValue(forKey: id) }
        else { nicknames[id] = trimmed }
        refresh()   // deskName may be the nickname
    }

    // Nudge step, user-configurable (persisted). Clamped to a sane physical
    // range via setNudgeCm(_:) rather than by re-assigning nudgeCm from its
    // own didSet — the popover's TextField binds directly to $nudgeCm, and a
    // re-entrant didSet there fights the live typing (clamps mid-keystroke,
    // can trip SwiftUI's "modifying state during view update" warning).
    @Published var nudgeCm: Double {
        didSet { UserDefaults.standard.set(nudgeCm, forKey: "nudgeCm") }
    }

    func setNudgeCm(_ value: Double) {
        nudgeCm = min(max(value, 0.5), 20.0)
    }

    private var central: CBCentralManager!

    // Known desk identifier (from the prototype scan), tried on a fresh install.
    private let defaultUUID = "A6EB36A7-8AB4-E267-D74C-B9E8D1EC8195"
    private static let savedDesksKey = "deskUUIDs"

    // Only a fresh install (nothing ever saved) auto-adopts the first desk a
    // scan finds. Once the user has managed the list — even removing every
    // desk — an empty list must stay empty rather than grab a neighbour's desk.
    private lazy var autoAdopt: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: Self.savedDesksKey) == nil && d.object(forKey: "deskUUID") == nil
    }()

    override init() {
        let d = UserDefaults.standard
        sitCm = d.object(forKey: "sitCm") as? Double ?? 74.0
        standCm = d.object(forKey: "standCm") as? Double ?? 110.0
        nudgeCm = d.object(forKey: "nudgeCm") as? Double ?? 2.0
        nicknames = (d.dictionary(forKey: "deskNicknames") as? [String: String]) ?? [:]
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// The desk whose height the menu bar and header show: first ready, else first.
    var primary: DeskConnection? { desks.first(where: \.isReady) ?? desks.first }
    var readyDesks: [DeskConnection] { desks.filter(\.isReady) }

    var isStanding: Bool { heightCm >= (sitCm + standCm) / 2 }

    /// CoreBluetooth UUID of the primary desk (macOS-specific, not the hardware
    /// MAC — same identifier `desk.py scan` prints).
    var deskID: String { primary?.id.uuidString ?? "" }

    // MARK: - Public actions (all desks)

    func goSit()   { moveTo(cm: sitCm) }
    func goStand() { moveTo(cm: standCm) }
    func setSitToCurrent()   { sitCm = heightCm.rounded() }
    func setStandToCurrent() { standCm = heightCm.rounded() }

    func moveTo(cm: Double) {
        lastMoveDesks = readyDesks
        for d in lastMoveDesks { d.moveTo(cm: cm) }
    }

    /// Relative to each desk's own height, so desks at different heights keep
    /// their offset rather than snapping together.
    func nudge(_ delta: Double) {
        lastMoveDesks = readyDesks
        for d in lastMoveDesks { d.moveTo(cm: d.heightCm + delta) }
    }

    /// Send each desk to its own random height within its calibrated range.
    /// Inset by the same 0.5 cm DeskConnection.moveTo clamps to, so the pick is
    /// never silently pulled back onto a travel limit.
    func randomize() {
        lastMoveDesks = readyDesks
        for d in lastMoveDesks {
            d.moveTo(cm: Double.random(in: (d.minCm + 0.5)...(d.maxCm - 0.5)).rounded())
        }
    }

    func stop() {
        for d in desks { d.stop() }
    }

    // MARK: - Desk picker

    /// Start scanning and collecting nearby desks to add. Existing connections stay up.
    func beginPairing() {
        // Clear first, before the power-state guard — otherwise a scan attempted
        // while Bluetooth is off leaves the previous session's results in place,
        // and callers (e.g. ControlServer.scan) report them as freshly found.
        discovered = []
        discoveredPeripherals = [:]
        guard central.state == .poweredOn else { return }
        isPairing = true
        central.stopScan()
        central.scanForPeripherals(withServices: nil)   // catch non-advertising units too
        refresh()
    }

    func cancelPairing() {
        isPairing = false
        refresh()   // also winds the scan down to whatever reconnects still need
    }

    /// Add a chosen desk alongside the existing ones. Pairing stays open so
    /// several desks can be picked in a row; the picker hides ones already added.
    func add(_ desk: DiscoveredDesk) {
        guard !desks.contains(where: { $0.id == desk.id }) else { return }
        guard let p = discoveredPeripherals[desk.id]
            ?? central.retrievePeripherals(withIdentifiers: [desk.id]).first else { return }
        attach(p, name: desk.name)
    }

    /// Disconnect a desk and stop reconnecting to it on launch.
    func remove(_ id: UUID) {
        guard let idx = desks.firstIndex(where: { $0.id == id }) else { return }
        let d = desks.remove(at: idx)
        d.disconnect(central: central)
        lastMoveDesks.removeAll { $0.id == id }
        saveDesks()
        refresh()
    }

    private func attach(_ p: CBPeripheral, name: String) {
        autoAdopt = false
        let conn = DeskConnection(peripheral: p, name: name, owner: self)
        desks.append(conn)
        saveDesks()
        conn.connect(using: central)
        refresh()
    }

    private func saveDesks() {
        UserDefaults.standard.set(desks.map(\.id.uuidString), forKey: Self.savedDesksKey)
    }

    /// Saved desk ids, migrating the single-desk "deskUUID" key from older versions.
    private func savedDeskIDs() -> [UUID] {
        let d = UserDefaults.standard
        let strings = d.stringArray(forKey: Self.savedDesksKey)
            ?? [d.string(forKey: "deskUUID") ?? defaultUUID]
        return strings.compactMap(UUID.init(uuidString:))
    }

    // MARK: - Aggregate state

    /// Re-derive the aggregate published state from the per-desk connections.
    func refresh() {
        let p = primary
        setIfChanged(\.heightCm, p?.heightCm ?? 0)
        setIfChanged(\.isReady, desks.contains(where: \.isReady))
        setIfChanged(\.isMoving, desks.contains(where: \.isMoving))
        setIfChanged(\.deskName, p?.displayName ?? "")
        setIfChanged(\.statusText, aggregateStatus())
        updateScanning()   // e.g. stop the reconnect scan once the last desk is ready
    }

    private func setIfChanged<T: Equatable>(_ kp: ReferenceWritableKeyPath<DeskController, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    private func aggregateStatus() -> String {
        if let centralStatus { return centralStatus }
        if isPairing { return "Searching for desks…" }
        if desks.isEmpty { return "No desk — add one below" }
        if let moving = desks.first(where: \.isMoving) { return moving.statusText }
        if desks.count == 1 { return desks[0].statusText }
        let ready = desks.filter(\.isReady).count
        return ready == desks.count ? "\(ready) desks connected" : "\(ready) of \(desks.count) desks connected"
    }

    // MARK: - Connection

    fileprivate func connectSavedOrScan() {
        if desks.isEmpty {
            let ids = savedDeskIDs()
            let known = central.retrievePeripherals(withIdentifiers: ids)
            // Keep the saved order, not whatever order CoreBluetooth returns.
            for id in ids {
                if let p = known.first(where: { $0.identifier == id }) { attach(p, name: p.name ?? "") }
            }
        } else {
            for d in desks where !d.isReady { d.connect(using: central) }
        }
        updateScanning()
    }

    /// A desk's connect attempt stalled: it was cancelled, so actively scan for
    /// it (didDiscover reconnects any saved desk it sees) and re-arm a connect.
    func connectionTimedOut(_ conn: DeskConnection) {
        guard desks.contains(where: { $0 === conn }) else { return }
        conn.connect(using: central)
        updateScanning()
    }

    /// Keep a background scan running while pairing, while any saved desk is
    /// still unreachable, or (fresh install) to auto-adopt the first desk found.
    /// Stop it once every desk is connected — scanning costs radio time.
    private func updateScanning() {
        guard central.state == .poweredOn else { return }
        if isPairing { return }   // pairing already runs a broad scan
        let needScan = (desks.isEmpty && autoAdopt) || desks.contains(where: { !$0.isReady })
        if needScan && !central.isScanning {
            central.scanForPeripherals(withServices: nil)
        } else if !needScan && central.isScanning {
            central.stopScan()
        }
    }
}

extension DeskController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: centralStatus = nil; connectSavedOrScan()
            case .unauthorized: centralStatus = "Bluetooth permission denied"
            case .poweredOff: centralStatus = "Bluetooth is off"
            default: centralStatus = "Bluetooth unavailable"
            }
            refresh()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let looksLikeDesk = name.uppercased().contains("DESK") || name.uppercased().contains("LINAK")
        let hasService = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .contains(DeskUUID.controlService) ?? false
        guard looksLikeDesk || hasService else { return }
        let deskName = name.isEmpty ? "Desk" : name
        Task { @MainActor in
            // A saved desk we're waiting on just showed up: reconnect it.
            if let conn = self.desks.first(where: { $0.id == peripheral.identifier }) {
                if !conn.isReady && peripheral.state == .disconnected {
                    conn.adopt(peripheral)
                    conn.connect(using: central)
                }
                if !self.isPairing { return }
            }
            // Pairing mode: collect desks not yet added for the picker.
            if self.isPairing {
                guard !self.desks.contains(where: { $0.id == peripheral.identifier }) else { return }
                self.discoveredPeripherals[peripheral.identifier] = peripheral
                let entry = DiscoveredDesk(id: peripheral.identifier, name: deskName, rssi: RSSI.intValue)
                if let idx = self.discovered.firstIndex(where: { $0.id == entry.id }) {
                    self.discovered[idx] = entry   // refresh RSSI in place; ordering is the view's job
                } else {
                    self.discovered.append(entry)
                }
                return
            }
            // Fresh install: adopt the first desk we see.
            if self.desks.isEmpty && self.autoAdopt {
                self.attach(peripheral, name: deskName)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.desks.first(where: { $0.id == peripheral.identifier })?.didConnect()
            self.updateScanning()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            // Removed desks are already gone from `desks`, so their disconnect is ignored.
            self.desks.first(where: { $0.id == peripheral.identifier })?.didDisconnect(central: central)
            self.updateScanning()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            guard let conn = self.desks.first(where: { $0.id == peripheral.identifier }) else { return }
            conn.didFailToConnect()
            self.updateScanning()   // didDiscover reconnects it when it next advertises
        }
    }
}
