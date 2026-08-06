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
- ✏️ **Editable height** — click the readout, type an exact target (e.g. `100.1`), and press
  Return to move straight there.
- 🎚️ **Calibratable minimum** — set your desk's lowest height (default 68 cm) so the readout
  matches the physical panel.
- ⏰ **Posture reminders & tracking** — see today's sit/stand split and get nudged to switch on
  your own interval (optionally auto-switching the desk).
- 🎯 **Daily standing goal & 7-day history** — set a target and watch your standing trend at a
  glance, with a goal line on the chart.
- 🔀 **Desk switcher** — scan and pick between multiple desks by Bluetooth signal strength.
- 🏷️ **Nameable desks** — assign a local nickname to each desk; the switcher shows the number
  *and* your name (the advertised Bluetooth name is left untouched).
- 🔌 **Auto-connect & auto-reconnect** to your last desk on launch.
- 🐍 **Python prototype** for discovery, debugging, and scripting.

## Repo layout

```
.
├── DeskBar/            # The native Swift menu-bar app
│   ├── Sources/        #   DeskController (BLE), HotKeyManager, SwiftUI views
│   ├── Info.plist
│   └── build.sh        #   builds DeskBar.app with swiftc (no full Xcode needed)
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

Height decode from `99fa0021`: little-endian, `cm = raw / 100 + base`, where `base` is the
desk's mechanical minimum (configurable in the app; default 68 cm). The raw value is the
offset above that minimum, so `base` sets the absolute reading — calibrate it to match your
physical panel.

## Roadmap / ideas

- Launch at login (`SMAppService`).
- App icon + notarised release build.
- Standing-time export (CSV) & weekly summary.

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
