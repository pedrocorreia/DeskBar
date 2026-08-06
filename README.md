# DeskBar

A tiny macOS **menu-bar app** to control a **LINAK Bluetooth standing desk** — Sit/Stand
presets, live height, and **global keyboard shortcuts** — plus the Python prototype used to
reverse-engineer the protocol.

Built and tested on an Apple Silicon Mac (M3 Pro, macOS 26) against a **LINAK DPG1C**
controller (a desk advertising as `DESK ####`).

> ⚠️ **Safety:** this moves a real motorised desk. Keep the area clear, don't leave cables,
> monitors, or fingers in the way, and keep the physical controller reachable. Use at your own
> risk — see the MIT warranty disclaimer.

---

## Features

- 🪑 **Sit / Stand presets** — one click (or one shortcut) to your saved heights.
- ⌨️ **Global keyboard shortcuts** (system-wide, no Accessibility permission required):
  | Shortcut | Action |
  |---|---|
  | `⌃⌥↑` / `⌃⌥↓` | Stand / Sit |
  | `⌃⌥⇧↑` / `⌃⌥⇧↓` | Nudge ±2 cm |
  | `⌃⌥Space` | Stop |
- 📏 **Live height** shown right in the menu bar.
- 🔀 **Desk switcher** — scan and pick between multiple desks by Bluetooth signal strength.
- 🔌 **Auto-connect & auto-reconnect** to your last desk on launch.
- 🤖 **AI control (MCP)** — drive the desk from Claude or any MCP client in natural language.
- 🐍 **Python prototype** for discovery, debugging, and scripting.

## Control it with AI (MCP)

DeskBar ships an [MCP](https://modelcontextprotocol.io) server (`mcp/desk_mcp.py`) that exposes
the desk as tools — `get_status`, `stand`, `sit`, `set_height`, `nudge`, `list_desks` — so an AI
assistant can move it for you: *"put my desk in standing mode for the next hour."*

**The DeskBar app must be running.** The MCP server does **not** talk Bluetooth itself — it
relays commands over a local Unix-domain socket
(`~/Library/Application Support/DeskBar/control.sock`) to the DeskBar app, which owns the
Bluetooth permission and holds the live desk connection. Launch DeskBar.app first; if it isn't
running, the tools say so.

<details>
<summary>Why this indirection (the crash it avoids)</summary>

macOS attributes a CoreBluetooth request to the **responsible process**. When an MCP client
such as Claude Code spawns the server, that client is the responsible process — and if it has
no `NSBluetoothAlwaysUsageDescription`, the OS **hard-aborts** the server with `SIGABRT` the
instant it touches BLE. The client just sees the connection drop (`-32000: Connection closed`).
Routing all Bluetooth through the signed, Bluetooth-granted app sidesteps this entirely: the
MCP server never links CoreBluetooth.
</details>

Setup:

```bash
./.venv/bin/python -m pip install -r mcp/requirements.txt

# Register with Claude Code (use absolute paths):
claude mcp add deskbar -- /abs/path/.venv/bin/python /abs/path/mcp/desk_mcp.py
```

No `DESK_ADDRESS` or Bluetooth setup is needed for the MCP server — the app handles the desk
(pick it once via **Desk → Switch…**) and stays the single source of truth for your presets.

> **Heads-up:** MCP servers are long-lived — a client loads `desk_mcp.py` once, when it
> connects. After first registering it (or editing the server), **restart / reconnect the MCP
> client** so it picks up the current code.

## Repo layout

```
.
├── DeskBar/            # The native Swift menu-bar app
│   ├── Sources/        #   DeskController (BLE), ControlServer (MCP socket),
│   │                   #   HotKeyManager, SwiftUI views
│   ├── Info.plist
│   └── build.sh        #   builds DeskBar.app with swiftc (no full Xcode needed)
├── mcp/                # MCP server exposing the desk as AI tools
│   ├── desk_mcp.py     #   talks to the app's control socket (no Bluetooth here)
│   ├── test_client.py  #   spawns the server over stdio and calls a tool
│   └── requirements.txt
└── prototype/          # Python tools used to crack the protocol
    ├── desk.py         #   scan / info / monitor / up / down / to / diag
    ├── test_idasen.py  #   minimal move test via the `idasen` library
    └── requirements.txt
```

## Quick start — the app

Requires macOS 13+ and the Xcode **Command Line Tools** (`xcode-select --install`). No full
Xcode needed.

```bash
cd DeskBar
./build.sh
open DeskBar.app
```

On first launch, macOS asks for **Bluetooth permission** — click Allow. A chair icon appears
in the menu bar; click it for Sit/Stand, nudge, stop, and the desk switcher.

**Want it in Spotlight?** A build left in a dev folder is indexed by Spotlight's raw metadata
DB but filtered out of the search UI, which only shows apps from `~/Applications`,
`/Applications`, or `/System/Applications`. Run `./build.sh --install` instead to install to
`~/Applications` and register it with Launch Services.

**Pairing / switching desks:** open the panel → **Desk → Switch…** → pick the desk with the
strongest signal (that's the one you're sitting at). Your choice is remembered.

## Quick start — the Python prototype

```bash
python3 -m venv .venv
./.venv/bin/pip install -r prototype/requirements.txt

# find your desk (wake it by tapping the physical controller first)
./.venv/bin/python prototype/desk.py scan

# confirm the protocol and read height (use the address from scan)
./.venv/bin/python prototype/desk.py info    --address <UUID>
./.venv/bin/python prototype/desk.py monitor --address <UUID>
./.venv/bin/python prototype/desk.py to      --address <UUID> --cm 110
```

On macOS the `--address` is a CoreBluetooth UUID (not a MAC), printed by `scan`.

## How the LINAK DPG1C protocol works

All characteristics share the base UUID `…-338a-1024-8a49-009c0215f78a`:

| Short UUID | Purpose |
|---|---|
| `99fa0002` | Command (up / down / stop / wakeup) |
| `99fa0021` | Height + speed (notify / read) |
| `99fa0031` | Reference input (move-to target) |
| `99fa0011` | DPG (wakeup handshake) |

The key gotcha: **the DPG1C ignores every movement command until it receives a "DPG wakeup"
handshake.** The working sequence is:

1. **Wake:** write `7f 86 00` to `99fa0011`, then `7f 86 80 01 02 … 11` (20 bytes), then
   `fe 00` to the command char.
2. **Prime:** `fe 00` (wakeup) then `ff 00` (stop) to the command char.
3. **Move:** repeatedly (~every 0.1 s) write the target to `99fa0031` until reached.
   Encoding: `raw = round((metres − 0.62) × 10000)` as little-endian `uint16`.
4. **Stop:** `ff 00` to the command char, `01 80` to reference input.

Height decode from `99fa0021`: little-endian, `cm = raw / 100 + 62.0` (range 62–127 cm).

## Roadmap / ideas

- Launch at login (`SMAppService`).
- User-customisable shortcuts in the UI.
- App icon + notarised release build.
- Sit/stand reminders.

Contributions welcome — issues and PRs appreciated, especially test reports from other LINAK
controller variants.

## Acknowledgements

Protocol understanding stands on the shoulders of prior reverse-engineering work:

- [`idasen`](https://github.com/newAM/idasen) — Python library for IKEA IDÅSEN / LINAK desks
  (used directly by the prototype).
- [`linak-controller`](https://github.com/rhyst/linak-controller) — documented the DPG1C
  wakeup handshake.

## License

[MIT](LICENSE) © 2026 Pedro Correia
