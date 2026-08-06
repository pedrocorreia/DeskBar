# DeskBar — contributor & agent guide

macOS menu-bar app that controls a **LINAK DPG1C** Bluetooth standing desk, plus a Python
prototype and an MCP server. This file is the fast on-ramp for humans and AI assistants
working in the repo. For user-facing docs see [README.md](README.md); for history see
[CHANGELOG.md](CHANGELOG.md).

## Repo layout

```
DeskBar/                 # The native macOS menu-bar app (Swift)
  Sources/
    DeskBarApp.swift     # @main App: MenuBarExtra, single-instance guard, hotkey wiring
    DeskController.swift  # CoreBluetooth: connect/scan, the LINAK protocol, move logic
    HotKeyManager.swift   # Carbon global hotkeys + KeyCombo + ShortcutSettings model
    PopoverView.swift     # The menu-bar popover UI
    ShortcutSettingsView.swift  # The "Shortcuts…" recorder window
  Info.plist             # LSUIElement (no Dock), Bluetooth usage string, version
  AppIcon.icns           # Generated app icon (see tools/)
  build.sh               # Builds DeskBar.app with swiftc; `--install` copies to ~/Applications
  tools/
    make_icon.swift      # Renders the 1024px icon with CoreGraphics
    make_icns.sh         # Renders all sizes → AppIcon.icns
prototype/               # Python/bleak tools that reverse-engineered the protocol
  desk.py                # scan / info / monitor / up / down / to / diag
  test_idasen.py         # minimal move test via the idasen library
mcp/                     # MCP server so an AI assistant can drive the desk
  desk_mcp.py            # stdio MCP server (tools: get_status, stand, sit, set_height, nudge, list_desks)
```

## Prerequisites

- **macOS 13+** and Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is
  not required — the app builds with `swiftc`.
- **Python 3** for `prototype/` and `mcp/` (a shared `.venv/` at the repo root is used in
  development; it is gitignored).

## Build & run the app

```bash
cd DeskBar
./build.sh                 # → DeskBar.app (ad-hoc signed)
open DeskBar.app
# or: ./build.sh --install  → installs to ~/Applications (Spotlight-visible)
```

First launch prompts for **Bluetooth permission** — allow it. The app auto-connects to the
last desk (or the known default) and shows live height in the menu bar.

## Run the Python prototype

```bash
python3 -m venv .venv
./.venv/bin/python -m pip install -r prototype/requirements.txt
./.venv/bin/python prototype/desk.py scan      # find your desk's CoreBluetooth UUID
```

## Run the MCP server

```bash
./.venv/bin/python -m pip install -r mcp/requirements.txt
DESK_ADDRESS="<your-desk-uuid>" ./.venv/bin/python mcp/desk_mcp.py
```

Register it with an MCP client (Claude Code example):

```bash
claude mcp add deskbar -- /absolute/path/.venv/bin/python /absolute/path/mcp/desk_mcp.py
```

The server reads Sit/Stand/nudge presets from the app's preferences (`com.pedro.deskbar`), so
they stay in sync with the app.

## The LINAK DPG1C protocol (the crucial knowledge)

The DPG1C **ignores all movement commands until it receives a DPG "wakeup" handshake** — this
was the single biggest gotcha. Characteristics share the base
`…-338a-1024-8a49-009c0215f78a`:

| Short UUID | Purpose |
|---|---|
| `99fa0002` | command (up `47 00` / down `46 00` / stop `FF 00` / wakeup `FE 00`) |
| `99fa0021` | height + speed (notify/read) |
| `99fa0031` | reference input (move-to target) |
| `99fa0011` | DPG (wakeup handshake) |

Move sequence: **(1)** DPG handshake — `7f 86 00` then `7f 86 80 01…11` to `99fa0011`, then
`FE 00` to command; **(2)** prime with `FE 00` + `FF 00`; **(3)** spam the target to `99fa0031`
(~every 0.1 s) until reached. Height: little-endian, `cm = raw/100 + 62.0` (range ~62–127 cm).
The Swift app reimplements this in `DeskController.swift`; the Python side gets it from `idasen`.

## House style / conventions

- **No third-party Swift dependencies.** Only system frameworks (SwiftUI, AppKit,
  CoreBluetooth, Carbon). Keep it that way — the app must build with a bare `swiftc`.
- **Comments explain *why*, not *what*** — especially the non-obvious platform workarounds
  (MenuBarExtra template flattening, `@StateObject` singletons, DPG handshake, Carbon hotkeys
  vs Accessibility). Match that density.
- **`@MainActor`** on the BLE/UI classes; CoreBluetooth delegate callbacks hop back to the
  main actor via `Task { @MainActor in … }`.
- Shared singletons (`DeskController.shared` etc.) exist to dodge a real `@StateObject`
  init-order bug — see the comment on `DeskController.shared` before "simplifying" them away.

## Common gotchas

- **The menu bar shows an SF Symbol, not `AppIcon.icns`.** The app is `LSUIElement` (no Dock
  icon); `AppIcon.icns` is what Finder/Spotlight show.
- **Single-instance guard:** a second launch just focuses the running instance and exits — so
  after rebuilding, **quit the running copy first**, or you won't see changes.
- **Renamed the repo folder?** The `.venv` `pip` script's shebang goes stale — use
  `./.venv/bin/python -m pip …` instead of `./.venv/bin/pip`.
- **Distribution:** builds are only ad-hoc signed (not notarized); downloaders must clear
  quarantine (`xattr -dr com.apple.quarantine DeskBar.app`).

## Regenerate the app icon

Edit `DeskBar/tools/make_icon.swift`, then:

```bash
cd DeskBar && ./tools/make_icns.sh   # rewrites AppIcon.icns
./build.sh
```

## Release process

1. Update [CHANGELOG.md](CHANGELOG.md) (Keep a Changelog format).
2. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `DeskBar/Info.plist`.
3. Commit, then `git tag -a vX.Y.Z` and push the tag.
4. `gh release create vX.Y.Z --title "…" --notes-file notes.md`.

Semver: additive features → minor; fixes only → patch.

## Testing

There are no automated tests — the app is GUI + live Bluetooth + physical hardware, so
verification is manual with a desk in range (and best done watching the physical desk with a
hand near its controller). The pure, testable islands if you want coverage: `KeyCombo`
encode/decode and `HotKeyManager.applyBindings` duplicate detection. **Never** commit changes
to movement logic without testing against a real desk.
