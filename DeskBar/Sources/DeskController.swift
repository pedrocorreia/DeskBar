import Foundation
@preconcurrency import CoreBluetooth

// LINAK DPG1C BLE protocol. See prototype/ and the project memory for how this
// was reverse-engineered. Char UUIDs all share the …-338a-1024-8a49-009c0215f78a base.
enum DeskUUID {
    static let command        = CBUUID(string: "99fa0002-338a-1024-8a49-009c0215f78a")
    static let heightSpeed    = CBUUID(string: "99fa0021-338a-1024-8a49-009c0215f78a")
    static let referenceInput = CBUUID(string: "99fa0031-338a-1024-8a49-009c0215f78a")
    static let dpg            = CBUUID(string: "99fa0011-338a-1024-8a49-009c0215f78a")
    static let controlService = CBUUID(string: "99fa0001-338a-1024-8a49-009c0215f78a")
}

private enum Cmd {
    static let up      = Data([0x47, 0x00])
    static let down    = Data([0x46, 0x00])
    static let stop    = Data([0xFF, 0x00])
    static let wakeup  = Data([0xFE, 0x00])
    static let refStop = Data([0x01, 0x80])
    // DPG "wakeup" handshake — the DPG1C ignores movement without this.
    static let dpg1 = Data([0x7F, 0x86, 0x00])
    static let dpg2 = Data([0x7F, 0x86, 0x80, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
                            0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
                            0x10, 0x11])
}

// Physical limits (metres) for LINAK desks.
private let kMinCm = 62.0
private let kMaxCm = 127.0

struct DiscoveredDesk: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

@MainActor
final class DeskController: NSObject, ObservableObject {
    // `_desk.wrappedValue` in DeskBarApp.init() reads a @StateObject before
    // SwiftUI has installed its storage, which hands back a throwaway instance
    // from the autoclosure rather than the one the UI actually uses — hotkeys
    // wired to that throwaway silently read stale state (e.g. nudgeCm frozen
    // at its launch-time value). Backing the @StateObject with a shared
    // singleton means "a new instance" always resolves to the same object.
    static let shared = DeskController()

    // Published UI state
    @Published var heightCm: Double = 0
    @Published var speed: Int = 0
    @Published var isReady = false          // connected + characteristics discovered
    @Published var statusText = "Starting…"
    @Published var isMoving = false
    @Published var deskName = ""

    // Desk-picker ("pairing") state
    @Published var isPairing = false
    @Published var discovered: [DiscoveredDesk] = []
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    // User presets (persisted)
    @Published var sitCm: Double  { didSet { UserDefaults.standard.set(sitCm, forKey: "sitCm") } }
    @Published var standCm: Double { didSet { UserDefaults.standard.set(standCm, forKey: "standCm") } }

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
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]

    // Movement loop
    private var targetCm: Double?
    private var moveTimer: Timer?
    private var moveStart = Date()
    private var lastProgressHeight = 0.0
    private var lastProgressTime = Date()

    // CoreBluetooth's connect() has no timeout: if the target peripheral isn't
    // actually advertising (BLE-asleep, out of range, stale discovery), it hangs
    // on "Connecting…" forever. This timer promotes any stuck connect attempt to
    // an active re-scan after a grace period.
    private var connectTimeoutTimer: Timer?

    // Known desk identifier (from the prototype scan). Falls back to scanning.
    private let defaultUUID = "A6EB36A7-8AB4-E267-D74C-B9E8D1EC8195"

    override init() {
        let d = UserDefaults.standard
        sitCm = d.object(forKey: "sitCm") as? Double ?? 74.0
        standCm = d.object(forKey: "standCm") as? Double ?? 110.0
        nudgeCm = d.object(forKey: "nudgeCm") as? Double ?? 2.0
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isStanding: Bool { heightCm >= (sitCm + standCm) / 2 }

    /// CoreBluetooth UUID of the currently connected/selected desk (macOS-specific,
    /// not the hardware MAC — same identifier `desk.py scan` prints).
    var deskID: String { peripheral?.identifier.uuidString ?? "" }

    // MARK: - Public actions

    func goSit()   { moveTo(cm: sitCm) }
    func goStand() { moveTo(cm: standCm) }
    func nudge(_ delta: Double) { moveTo(cm: heightCm + delta) }
    func setSitToCurrent()   { sitCm = heightCm.rounded() }
    func setStandToCurrent() { standCm = heightCm.rounded() }

    // MARK: - Desk picker

    /// Start scanning and collecting nearby desks instead of auto-connecting.
    func beginPairing() {
        guard central.state == .poweredOn else { return }
        isPairing = true
        discovered = []
        discoveredPeripherals = [:]
        central.stopScan()
        central.scanForPeripherals(withServices: nil)   // catch non-advertising units too
        statusText = "Searching for desks…"
    }

    func cancelPairing() {
        isPairing = false
        central.stopScan()
        statusText = isReady ? "Connected" : "Not connected"
    }

    /// Switch to a chosen desk: remember it, drop the old connection, connect the new one.
    func select(_ desk: DiscoveredDesk) {
        isPairing = false
        central.stopScan()
        UserDefaults.standard.set(desk.id.uuidString, forKey: "deskUUID")

        let old = peripheral
        let newP = discoveredPeripherals[desk.id]
            ?? central.retrievePeripherals(withIdentifiers: [desk.id]).first
        // Point at the new target first so didDisconnect ignores the old one.
        peripheral = newP
        deskName = desk.name
        isReady = false
        chars = [:]
        if let old, old.identifier != newP?.identifier {
            central.cancelPeripheralConnection(old)
        }
        if let newP {
            newP.delegate = self
            statusText = "Connecting…"
            central.connect(newP)
            scheduleConnectTimeout(for: newP)
        }
    }

    func moveTo(cm: Double) {
        guard isReady, let p = peripheral else { return }
        let target = min(max(cm, kMinCm + 0.5), kMaxCm - 0.5)
        targetCm = target
        isMoving = true
        statusText = String(format: "Moving to %.0f cm…", target)

        // 1) DPG handshake, 2) prime with wakeup+stop.
        write(Cmd.dpg1, to: DeskUUID.dpg, .withResponse)
        write(Cmd.dpg2, to: DeskUUID.dpg, .withResponse)
        write(Cmd.wakeup, to: DeskUUID.command, .withResponse)
        write(Cmd.stop, to: DeskUUID.command, .withResponse)
        _ = p // keep reference

        moveStart = Date()
        lastProgressHeight = heightCm
        lastProgressTime = Date()
        moveTimer?.invalidate()
        moveTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.moveTick() }
        }
    }

    func stop() {
        moveTimer?.invalidate()
        moveTimer = nil
        targetCm = nil
        isMoving = false
        write(Cmd.stop, to: DeskUUID.command, .withResponse)
        write(Cmd.refStop, to: DeskUUID.referenceInput, .withResponse)
        statusText = isReady ? "Connected" : statusText
    }

    // MARK: - Movement loop

    private func moveTick() {
        guard let target = targetCm else { return }
        let diff = abs(heightCm - target)
        if diff <= 0.6 { finishMove(reached: true); return }
        if Date().timeIntervalSince(moveStart) > 40 { finishMove(reached: false); return }

        // Stall detection: if height hasn't progressed for >1.2s (after a grace
        // period), the desk hit a limit or is blocked.
        if abs(heightCm - lastProgressHeight) > 0.2 {
            lastProgressHeight = heightCm
            lastProgressTime = Date()
        } else if Date().timeIntervalSince(moveStart) > 1.5,
                  Date().timeIntervalSince(lastProgressTime) > 1.2 {
            finishMove(reached: false)
            return
        }

        write(encodeTargetCm(target), to: DeskUUID.referenceInput, .withoutResponse)
    }

    private func finishMove(reached: Bool) {
        stop()
        statusText = reached ? "Connected" : "Stopped"
    }

    // MARK: - Encoding

    private func encodeTargetCm(_ cm: Double) -> Data {
        let raw = Int(((cm - kMinCm) / 100.0 * 10000.0).rounded())
        let clamped = UInt16(min(max(raw, 0), 65535))
        return Data([UInt8(clamped & 0xFF), UInt8(clamped >> 8)])
    }

    private func decodeHeightSpeed(_ data: Data) {
        guard data.count >= 2 else { return }
        let rawH = UInt16(data[0]) | (UInt16(data[1]) << 8)
        heightCm = Double(rawH) / 100.0 + kMinCm
        if data.count >= 4 {
            let rawS = UInt16(data[2]) | (UInt16(data[3]) << 8)
            speed = Int(Int16(bitPattern: rawS))
        }
    }

    // MARK: - BLE write helper

    private func write(_ data: Data, to uuid: CBUUID, _ type: CBCharacteristicWriteType) {
        guard let p = peripheral, let ch = chars[uuid] else { return }
        p.writeValue(data, for: ch, type: type)
    }

    // MARK: - Connection

    fileprivate func connectKnownOrScan() {
        if let uuid = UUID(uuidString: UserDefaults.standard.string(forKey: "deskUUID") ?? defaultUUID) {
            let known = central.retrievePeripherals(withIdentifiers: [uuid])
            if let p = known.first {
                statusText = "Connecting…"
                peripheral = p
                p.delegate = self
                central.connect(p)
                scheduleConnectTimeout(for: p)
                return
            }
        }
        statusText = "Scanning…"
        central.scanForPeripherals(withServices: [DeskUUID.controlService])
        // Some units don't advertise the service; broaden after a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !self.isReady, self.peripheral == nil else { return }
            self.central.scanForPeripherals(withServices: nil)
        }
    }
}

extension DeskController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: connectKnownOrScan()
            case .unauthorized: statusText = "Bluetooth permission denied"
            case .poweredOff: statusText = "Bluetooth is off"
            default: statusText = "Bluetooth unavailable"
            }
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
            // Pairing mode: collect all desks for the picker; don't auto-connect.
            if self.isPairing {
                self.discoveredPeripherals[peripheral.identifier] = peripheral
                let entry = DiscoveredDesk(id: peripheral.identifier, name: deskName, rssi: RSSI.intValue)
                if let idx = self.discovered.firstIndex(where: { $0.id == entry.id }) {
                    self.discovered[idx] = entry
                } else {
                    self.discovered.append(entry)
                }
                self.discovered.sort { $0.rssi > $1.rssi }
                return
            }
            central.stopScan()
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "deskUUID")
            self.peripheral = peripheral
            self.deskName = deskName
            peripheral.delegate = self
            self.statusText = "Connecting…"
            central.connect(peripheral)
            self.scheduleConnectTimeout(for: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectTimeoutTimer?.invalidate()
            self.connectTimeoutTimer = nil
            if let n = peripheral.name, !n.isEmpty { self.deskName = n }
            self.statusText = "Discovering…"
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            // Ignore disconnects from a desk we've already switched away from.
            guard peripheral.identifier == self.peripheral?.identifier else { return }
            self.isReady = false
            self.chars = [:]
            self.statusText = "Disconnected — reconnecting…"
            self.central.connect(peripheral)   // fast path: works if the desk is already advertising
            self.scheduleConnectTimeout(for: peripheral)
        }
    }

    /// After a grace period, if a connect() call above hasn't landed, cancel it and
    /// fall back to an active scan. CoreBluetooth's connect() has no built-in
    /// timeout, so without this a stale/out-of-range/BLE-asleep peripheral leaves
    /// the UI stuck on "Connecting…" forever.
    private func scheduleConnectTimeout(for peripheral: CBPeripheral) {
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.peripheral?.identifier == peripheral.identifier, !self.isReady else { return }
                self.central.cancelPeripheralConnection(peripheral)
                self.statusText = "Desk not responding — scanning…"
                self.connectKnownOrScan()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            // The timer armed by the failed connect attempt is now moot — if
            // connectKnownOrScan() below takes the scan branch (not the
            // known-peripheral branch), nothing else invalidates it, and it
            // can fire later and redundantly cancel/restart an active scan.
            self.connectTimeoutTimer?.invalidate()
            self.connectTimeoutTimer = nil
            self.statusText = "Connection failed — retrying…"
            self.connectKnownOrScan()
        }
    }
}

extension DeskController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            for ch in service.characteristics ?? [] {
                self.chars[ch.uuid] = ch
                if ch.uuid == DeskUUID.heightSpeed {
                    peripheral.setNotifyValue(true, for: ch)
                    peripheral.readValue(for: ch)
                }
            }
            if self.chars[DeskUUID.command] != nil,
               self.chars[DeskUUID.referenceInput] != nil,
               self.chars[DeskUUID.heightSpeed] != nil {
                self.isReady = true
                self.statusText = "Connected"
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard characteristic.uuid == DeskUUID.heightSpeed, let data = characteristic.value else { return }
        Task { @MainActor in self.decodeHeightSpeed(data) }
    }
}
