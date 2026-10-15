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

// LINAK desks report height as an offset above their mechanical minimum, so
// converting the raw BLE value into an absolute cm reading means adding that
// minimum back. The minimum varies by model (and by any display offset set on
// the physical panel), so it's user-calibratable per desk — see minCm.
// The usable travel above the minimum is a fixed hardware span.
private let kTravelCm = 65.0   // was kMaxCm(127) − kMinCm(62)

/// One desk's live BLE link: its characteristics, height readout, and move loop.
///
/// Each desk runs its own handshake and move loop, so several desks driven to
/// the same target travel independently — they arrive at slightly different
/// times and each detects its own stall/limit. The shared CBCentralManager (and
/// so connect/disconnect events) lives in DeskController, which routes them here
/// by peripheral id; this object is the peripheral's delegate directly.
@MainActor
final class DeskConnection: NSObject, ObservableObject, Identifiable {
    let id: UUID
    private(set) var peripheral: CBPeripheral
    private weak var owner: DeskController?

    // Every published change re-derives DeskController's aggregate state (menu-bar
    // height, "any moving", status line) — didSet rather than Combine so the
    // aggregate is already current by the time anything reads it.
    @Published var heightCm: Double = 0     { didSet { owner?.refresh() } }
    @Published var speed: Int = 0
    @Published var isReady = false           { didSet { owner?.refresh() } }
    @Published var statusText = "Connecting…" { didSet { owner?.refresh() } }
    @Published var isMoving = false          { didSet { owner?.refresh() } }
    @Published var advertisedName: String    { didSet { owner?.refresh() } }

    // Whether this desk's last movement actually arrived at its target (vs.
    // stalled, hit a travel limit, or was stopped). Read via DeskController by
    // ControlServer.move() so the MCP client isn't told a short move succeeded.
    private(set) var lastMoveReachedTarget = true

    // Calibration: this desk's absolute height at its lowest position. Per desk
    // because two desks of different models (or panel display offsets) won't
    // share a baseline — and with one global value, "move all to 100 cm" would
    // leave them at visibly different heights. Persisted keyed by peripheral id;
    // falls back to the pre-multi-desk global "minCm". Deliberately not clamped
    // in didSet (the popover's TextField binds to $minCm and a re-entrant clamp
    // fights live typing) — clamp on commit via setMinCm(_:).
    @Published var minCm: Double {
        didSet {
            var all = UserDefaults.standard.dictionary(forKey: Self.minCmKey) as? [String: Double] ?? [:]
            all[id.uuidString] = minCm
            UserDefaults.standard.set(all, forKey: Self.minCmKey)
        }
    }
    static let minCmKey = "deskMinCm"

    /// Usable maximum height = calibrated minimum + fixed travel span.
    var maxCm: Double { minCm + kTravelCm }

    // Most recent raw height sample (0.1 mm units above the minimum). Retained
    // so recalibrating minCm can refresh the readout immediately rather than
    // waiting for the next BLE notification (the desk is silent when idle).
    private var lastRawHeight: UInt16 = 0

    func setMinCm(_ value: Double) {
        minCm = min(max(value, 40.0), 100.0)
        if isReady { heightCm = Double(lastRawHeight) / 100.0 + minCm }
    }

    private var chars: [CBUUID: CBCharacteristic] = [:]

    // Movement loop
    private var targetCm: Double?
    private var moveTimer: Timer?
    private var moveStart = Date()
    private var lastProgressHeight = 0.0
    private var lastProgressTime = Date()

    // CoreBluetooth's connect() has no timeout: if the target peripheral isn't
    // actually advertising (BLE-asleep, out of range, stale discovery), it hangs
    // on "Connecting…" forever. This timer hands any stuck connect attempt back
    // to the owner, which falls back to an active re-scan.
    private var connectTimeoutTimer: Timer?

    init(peripheral: CBPeripheral, name: String, owner: DeskController) {
        id = peripheral.identifier
        self.peripheral = peripheral
        self.owner = owner
        advertisedName = name
        let perDesk = UserDefaults.standard.dictionary(forKey: Self.minCmKey) as? [String: Double]
        minCm = perDesk?[peripheral.identifier.uuidString]
            ?? UserDefaults.standard.object(forKey: "minCm") as? Double
            ?? 68.0
        super.init()
        peripheral.delegate = self
    }

    var displayName: String {
        owner?.nickname(for: id.uuidString) ?? (advertisedName.isEmpty ? "Desk" : advertisedName)
    }

    // MARK: - Connection lifecycle (driven by DeskController's central delegate)

    func connect(using central: CBCentralManager) {
        statusText = "Connecting…"
        central.connect(peripheral)
        scheduleConnectTimeout(central)
    }

    /// Swap in a freshly discovered CBPeripheral for the same id (a re-scan can
    /// hand back a new object after the old one went stale).
    func adopt(_ p: CBPeripheral) {
        guard p.identifier == id, p !== peripheral else { return }
        peripheral = p
        p.delegate = self
    }

    func didConnect() {
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = nil
        if let n = peripheral.name, !n.isEmpty { advertisedName = n }
        statusText = "Discovering…"
        peripheral.discoverServices(nil)
    }

    func didDisconnect(central: CBCentralManager) {
        abortMove()
        isReady = false
        chars = [:]
        statusText = "Disconnected — reconnecting…"
        connect(using: central)   // fast path: works if the desk is already advertising
    }

    func didFailToConnect() {
        // The timer armed by the failed attempt is now moot — the owner's
        // re-scan takes over, and a late fire would redundantly cancel it.
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = nil
        statusText = "Connection failed — retrying…"
    }

    /// Tear down before the owner forgets this desk.
    func disconnect(central: CBCentralManager) {
        stop()
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = nil
        owner = nil   // no more aggregate refreshes from a removed desk
        central.cancelPeripheralConnection(peripheral)
    }

    private func scheduleConnectTimeout(_ central: CBCentralManager) {
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isReady, let owner = self.owner else { return }
                central.cancelPeripheralConnection(self.peripheral)
                self.statusText = "Desk not responding — scanning…"
                owner.connectionTimedOut(self)
            }
        }
    }

    // MARK: - Movement

    func moveTo(cm: Double) {
        guard isReady else { return }
        let target = min(max(cm, minCm + 0.5), maxCm - 0.5)
        targetCm = target
        isMoving = true
        lastMoveReachedTarget = false   // set true only if we actually arrive
        statusText = String(format: "Moving to %.0f cm…", target)

        // 1) DPG handshake, 2) prime with wakeup+stop.
        write(Cmd.dpg1, to: DeskUUID.dpg, .withResponse)
        write(Cmd.dpg2, to: DeskUUID.dpg, .withResponse)
        write(Cmd.wakeup, to: DeskUUID.command, .withResponse)
        write(Cmd.stop, to: DeskUUID.command, .withResponse)

        moveStart = Date()
        lastProgressHeight = heightCm
        lastProgressTime = Date()
        moveTimer?.invalidate()
        moveTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.moveTick() }
        }
    }

    func stop() {
        abortMove()
        write(Cmd.stop, to: DeskUUID.command, .withResponse)
        write(Cmd.refStop, to: DeskUUID.referenceInput, .withResponse)
        statusText = isReady ? "Connected" : statusText
    }

    /// Kill the local move loop without talking to the desk (e.g. it just dropped).
    private func abortMove() {
        moveTimer?.invalidate()
        moveTimer = nil
        targetCm = nil
        isMoving = false
    }

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
        lastMoveReachedTarget = reached
        stop()
        statusText = reached ? "Connected" : "Stopped"
    }

    // MARK: - Encoding

    private func encodeTargetCm(_ cm: Double) -> Data {
        let raw = Int(((cm - minCm) / 100.0 * 10000.0).rounded())
        let clamped = UInt16(min(max(raw, 0), 65535))
        return Data([UInt8(clamped & 0xFF), UInt8(clamped >> 8)])
    }

    private func decodeHeightSpeed(_ data: Data) {
        guard data.count >= 2 else { return }
        let rawH = UInt16(data[0]) | (UInt16(data[1]) << 8)
        lastRawHeight = rawH
        heightCm = Double(rawH) / 100.0 + minCm
        if data.count >= 4 {
            let rawS = UInt16(data[2]) | (UInt16(data[3]) << 8)
            speed = Int(Int16(bitPattern: rawS))
        }
    }

    private func write(_ data: Data, to uuid: CBUUID, _ type: CBCharacteristicWriteType) {
        guard let ch = chars[uuid] else { return }
        peripheral.writeValue(data, for: ch, type: type)
    }
}

extension DeskConnection: CBPeripheralDelegate {
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
