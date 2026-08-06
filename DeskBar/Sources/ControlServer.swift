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

    /// `~/Library/Application Support/DeskBar/control.sock`. The directory is
    /// created 0700 so the socket node underneath it is never world-reachable.
    static var socketPath: String {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/DeskBar")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return (dir as NSString).appendingPathComponent("control.sock")
    }

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
        // Create the socket node with 0600 from the start — chmod-after-bind
        // would leave a brief window at the directory umask. Restore the mask
        // immediately after.
        let savedMask = umask(0o177)
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        umask(savedMask)
        guard bindRC == 0 else {
            NSLog("DeskBar control: bind() failed errno=\(errno)"); close(fd); return
        }
        guard listen(fd, 8) == 0 else {
            NSLog("DeskBar control: listen() failed errno=\(errno)"); close(fd); return
        }
        NSLog("DeskBar control: listening on \(path)")

        // Accept on a background thread.
        DispatchQueue.global(qos: .userInitiated).async {
            Self.acceptLoop(fd: fd)
        }
    }

    // MARK: - Socket plumbing (background threads, no actor state touched)

    private static func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                NSLog("DeskBar control: accept() failed errno=\(errno)")
                break
            }
            // Don't let a write to a peer that closed first raise SIGPIPE and
            // take down the whole app — the very crash class this server exists
            // to avoid. Per-socket SO_NOSIGPIPE turns that into a normal EPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Handled serially — a single desk does one thing at a time, and the
            // assistant driving this is itself blocked awaiting a move, so there's
            // no concurrent request to service. Keeps the server simple.
            handleClient(client)
        }
    }

    private static func handleClient(_ client: Int32) {
        defer { close(client) }
        guard let line = readLine(client) else { return }
        var out = process(requestLine: line)
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

    /// Holds a value being handed between the socket thread and a `@MainActor`
    /// task. Only ever written on one side of a semaphore and read on the other,
    /// so the access is serialized — `@unchecked Sendable` documents that.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private static func process(requestLine: Data) -> Data {
        let obj = (try? JSONSerialization.jsonObject(with: requestLine)) as? [String: Any]
        guard let cmd = obj?["cmd"] as? String else {
            return encode(["ok": false, "error": "Malformed request (expected JSON with a \"cmd\")."])
        }
        // Decode into Sendable primitives on this thread so nothing non-Sendable
        // crosses into the main-actor task below.
        let heightArg = number(obj?["height_cm"])
        let deltaArg = number(obj?["delta_cm"])

        // Bridge into the main actor (where DeskController and all CoreBluetooth
        // work live) and wait for the result. The handler itself yields with
        // `await Task.sleep` while a move is in flight, so the main thread stays
        // free to service BLE height notifications — only THIS worker thread
        // blocks on the semaphore. The reply comes back as `Data` (Sendable).
        let box = Box<Data>(encode(["ok": false, "error": "No result"]))
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let dict = await DeskBridge.handle(cmd: cmd, heightArg: heightArg, deltaArg: deltaArg)
            box.value = encode(dict)
            sem.signal()
        }
        sem.wait()
        return box.value
    }

    private static func encode(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{\"ok\":false}".utf8)
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}

/// The main-actor side: translates a decoded command into DeskController calls
/// and reports the resulting desk state.
@MainActor
private enum DeskBridge {
    private static let moveTimeout: TimeInterval = 45

    static func handle(cmd: String, heightArg: Double?, deltaArg: Double?) async -> [String: Any] {
        let desk = DeskController.shared
        switch cmd {
        case "status":
            return snapshot(ok: true)

        case "set_height":
            guard let cm = heightArg else {
                return snapshot(ok: false, error: "set_height needs a numeric \"height_cm\".")
            }
            return await move { desk.moveTo(cm: cm) }

        case "sit":
            return await move { desk.goSit() }

        case "stand":
            return await move { desk.goStand() }

        case "nudge":
            guard let delta = deltaArg else {
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
    /// Reports `ok:false` when the desk stalled/was stopped short of the target
    /// rather than silently claiming success.
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
        if !desk.lastMoveReachedTarget {
            return snapshot(ok: false, error: "Desk stopped short of the target (obstruction or travel limit).")
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
}
