import Foundation

/// Local control endpoint so external tools — notably the `deskbar` MCP server —
/// can drive the desk through THIS app instead of doing Bluetooth themselves.
///
/// Why it exists: macOS attributes a CoreBluetooth request to the *responsible*
/// process. When the MCP server's Python is spawned by the `claude` CLI, that CLI
/// is the responsible process and has no `NSBluetoothAlwaysUsageDescription`, so
/// TCC hard-aborts the process (SIGABRT) the instant it touches BLE. DeskBar.app,
/// by contrast, is a properly signed bundle with the usage string and a granted
/// Bluetooth permission. Routing all BLE through here means the MCP server never
/// links CoreBluetooth at all — it just speaks a tiny line-delimited JSON protocol
/// over a Unix-domain socket.
///
/// Protocol: one JSON object per line in, one JSON object per line out.
///   → {"cmd":"set_height","height_cm":77}
///   ← {"ok":true,"ready":true,"height_cm":77.0,"posture":"sitting","moving":false,
///      "sit_cm":74,"stand_cm":110,"nudge_cm":2,"name":"Desk","desk_id":"…"}
final class ControlServer {
    static let shared = ControlServer()

    /// `~/Library/Application Support/DeskBar/control.sock`. Created lazily.
    static var socketPath: String {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/DeskBar")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("control.sock")
    }

    private var listenFD: Int32 = -1

    // MARK: - Lifecycle

    func start() {
        let path = Self.socketPath
        // AF_UNIX paths cap at 104 bytes on macOS; guard so a long $HOME can't
        // silently truncate into the wrong socket.
        guard path.utf8.count < 104 else {
            NSLog("DeskBar control: socket path too long (\(path.utf8.count) bytes) — not starting")
            return
        }
        unlink(path)   // clear a stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("DeskBar control: socket() failed errno=\(errno)"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                path.withCString { src in _ = strncpy(dst, src, 103) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bindRC == 0 else {
            NSLog("DeskBar control: bind() failed errno=\(errno)"); close(fd); return
        }
        chmod(path, 0o600)   // this user only
        guard listen(fd, 8) == 0 else {
            NSLog("DeskBar control: listen() failed errno=\(errno)"); close(fd); return
        }
        listenFD = fd
        NSLog("DeskBar control: listening on \(path)")

        // Accept on a background thread; each connection is handled inline
        // (requests are short and serialized, which suits a single desk fine).
        DispatchQueue.global(qos: .userInitiated).async { [fd] in
            Self.acceptLoop(fd: fd)
        }
    }

    // MARK: - Socket plumbing (background thread, no actor state touched)

    private static func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                NSLog("DeskBar control: accept() failed errno=\(errno)")
                break
            }
            handleClient(client)
        }
    }

    private static func handleClient(_ client: Int32) {
        defer { close(client) }
        guard let line = readLine(client) else { return }
        let reply = process(requestLine: line)
        var out = reply
        out.append(0x0A)
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < out.count {
                let n = write(client, base + off, out.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    /// Read a single 0x0A-terminated line (bounded, so a rogue client can't grow
    /// memory unbounded). Returns the bytes without the newline.
    private static func readLine(_ client: Int32, limit: Int = 64 * 1024) -> Data? {
        var buf = Data()
        var byte: UInt8 = 0
        while buf.count < limit {
            let n = read(client, &byte, 1)
            if n <= 0 { return buf.isEmpty ? nil : buf }
            if byte == 0x0A { return buf }
            buf.append(byte)
        }
        return buf
    }

    // MARK: - Request handling

    private static func process(requestLine: Data) -> Data {
        let obj = (try? JSONSerialization.jsonObject(with: requestLine)) as? [String: Any]
        guard let cmd = obj?["cmd"] as? String else {
            return encode(["ok": false, "error": "Malformed request (expected JSON with a \"cmd\")."])
        }

        // Bridge into the main actor (where DeskController and all CoreBluetooth
        // work live) and wait for the result. The handler itself yields with
        // `await Task.sleep` while a move is in flight, so the main thread stays
        // free to service BLE height notifications — only THIS background socket
        // thread blocks on the semaphore.
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = ["ok": false, "error": "No result"]
        Task { @MainActor in
            result = await DeskBridge.handle(cmd: cmd, args: obj ?? [:])
            sem.signal()
        }
        sem.wait()
        return encode(result)
    }

    private static func encode(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{\"ok\":false}".utf8)
    }
}

/// The main-actor side: translates a decoded command into DeskController calls
/// and reports the resulting desk state.
@MainActor
private enum DeskBridge {
    private static let moveTimeout: TimeInterval = 45

    static func handle(cmd: String, args: [String: Any]) async -> [String: Any] {
        let desk = DeskController.shared
        switch cmd {
        case "status":
            return snapshot(ok: true)

        case "set_height":
            guard let cm = number(args["height_cm"]) else {
                return snapshot(ok: false, error: "set_height needs a numeric \"height_cm\".")
            }
            return await move { desk.moveTo(cm: cm) }

        case "sit":
            return await move { desk.goSit() }

        case "stand":
            return await move { desk.goStand() }

        case "nudge":
            guard let delta = number(args["delta_cm"]) else {
                return snapshot(ok: false, error: "nudge needs a numeric \"delta_cm\".")
            }
            return await move { desk.nudge(delta) }

        case "stop":
            desk.stop()
            return snapshot(ok: true)

        case "scan":
            return await scan()

        default:
            return snapshot(ok: false, error: "Unknown command \"\(cmd)\".")
        }
    }

    /// Issue a movement and wait (yielding) until the desk stops or we time out.
    private static func move(_ action: () -> Void) async -> [String: Any] {
        let desk = DeskController.shared
        guard desk.isReady else {
            return snapshot(ok: false, error: "Desk isn't connected yet — DeskBar is still finding it.")
        }
        action()
        // Let isMoving latch true before we start watching for it to clear.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        while desk.isMoving && Date().timeIntervalSince(start) < moveTimeout {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        if desk.isMoving {
            desk.stop()
            return snapshot(ok: false, error: "Desk didn't reach the target in time; stopped.")
        }
        return snapshot(ok: true)
    }

    private static func scan() async -> [String: Any] {
        let desk = DeskController.shared
        let wasPairing = desk.isPairing
        desk.beginPairing()
        try? await Task.sleep(nanoseconds: 5_000_000_000)   // collect for ~5s
        let desks = desk.discovered.map { ["name": $0.name, "id": $0.id.uuidString, "rssi": $0.rssi] }
        if !wasPairing { desk.cancelPairing() }
        var out = snapshot(ok: true)
        out["desks"] = desks
        return out
    }

    /// Current desk state as a response dictionary.
    private static func snapshot(ok: Bool, error: String? = nil) -> [String: Any] {
        let desk = DeskController.shared
        var d: [String: Any] = [
            "ok": ok,
            "ready": desk.isReady,
            "height_cm": desk.heightCm,
            "posture": desk.isStanding ? "standing" : "sitting",
            "moving": desk.isMoving,
            "sit_cm": desk.sitCm,
            "stand_cm": desk.standCm,
            "nudge_cm": desk.nudgeCm,
            "name": desk.deskName,
            "desk_id": desk.deskID,
        ]
        if let error { d["error"] = error }
        return d
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
