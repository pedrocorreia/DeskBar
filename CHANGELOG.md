# Changelog

All notable changes to DeskBar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed
- The connected desk's raw CoreBluetooth UUID no longer clutters the popover — the name/nickname
  identifies the desk, and the UUID was only ever there for troubleshooting.

### Added
- **Editable height readout.** Click the large height in the popover, type a target
  (e.g. `100.1`), and press Return to drive the desk straight to that height. Tolerates a
  `cm` suffix and a decimal comma; the value is clamped to the desk's physical range. The
  readout keeps tracking the live height even while focused, and only freezes once you type a
  different value, so a moving desk stays current but your keystrokes aren't overwritten; it
  reverts to the live height if you blur without pressing Return.
- **Nameable desks.** Give each desk a local nickname (e.g. "My desk") from the Desk section
  once connected — saved locally against the desk's Bluetooth id, never touching the advertised
  name. Named desks are grouped in a **Saved** section at the top of the switcher (showing your
  name and the `DESK ####` number), and the list no longer reshuffles as the Bluetooth signal
  fluctuates — it's sorted by name, with signal strength still shown per row.
- **Standing-time history & daily goal.** Set a daily standing goal (default 2 h); the popover
  shows today's standing *and* sitting totals (with a checkmark once you hit the goal) and a
  7-day stacked bar chart — standing in green, sitting in cyan — with a goal line, today
  highlighted. Both standing and sitting are archived per day (last 30 days kept).
- **Posture reminders + standing-time tracking.** DeskBar tracks how long you've spent sitting
  vs. standing today — shown in the popover as a split bar and totals — and can nudge you to
  switch on an interval you choose (default 45 min). Reminders arrive as a macOS notification
  with a **Switch now** button, or can move the desk for you (**Auto-switch**). A live
  countdown to the next switch is shown while reminders are on. Tracking and reminders pause
  while the desk is disconnected, the screen is locked, or you've been idle >10 min, so an
  empty desk is neither counted nor nagged; totals reset daily.
- **Calibratable minimum height.** The readout turns the desk's raw Bluetooth value into cm
  by adding the desk's mechanical minimum, which was hardcoded and assumed to be 62 cm. It
  now defaults to **68 cm** and is editable in the popover ("Min height"), so the reading
  matches your physical panel. The usable maximum tracks it (minimum + a fixed 65 cm travel),
  and changing it refreshes the readout immediately.

## [1.3.0] - 2026-08-06

### Added
- **Local control socket for the MCP server.** DeskBar now opens a Unix-domain
  socket (`~/Library/Application Support/DeskBar/control.sock`, 0600) on launch and
  performs all desk moves requested over it. The `deskbar` MCP server talks to this
  socket instead of driving Bluetooth itself.
- **`stop` MCP tool** to halt the desk (e.g. cancel a preset/hotkey-initiated move).

### Fixed
- **MCP server no longer crashes under Claude Code.** macOS attributes a
  CoreBluetooth request to the *responsible* process; when the MCP server's Python
  was spawned by the `claude` CLI (which has no `NSBluetoothAlwaysUsageDescription`),
  TCC hard-aborted the process (SIGABRT → "Connection closed") on the first BLE call.
  Routing all Bluetooth through the signed, Bluetooth-granted app fixes this — the
  MCP server never links CoreBluetooth. No re-registration or launcher needed.
- **A stalled or stopped-short move is no longer reported as success** — the control
  socket surfaces whether the desk actually reached its target.
- **Robustness:** `SO_NOSIGPIPE` on control connections (a client that hangs up mid-reply
  can no longer take the app down); the MCP client uses non-blocking async socket I/O so a
  long move doesn't stall its event loop; and the socket is created 0600 from the start.

## [1.2.0] - 2026-08-06

### Added
- **Customizable global shortcuts.** A new **Shortcuts…** window lets you rebind any
  action — click a row, press a combo, applied live. It rejects a combo already assigned
  to another action and surfaces combos macOS refuses to register instead of failing
  silently.
- **Configurable nudge distance** (0.5–20 cm), editable inline in the popover (was fixed
  at 2 cm).
- **Color-coded menu-bar icon** reflecting connection state — green = ready,
  orange = moving, red = disconnected.
- **Connected desk's CoreBluetooth UUID** shown in the popover (selectable) for
  troubleshooting.
- **`build.sh --install`** installs the app to `~/Applications` and registers it with
  Launch Services so it appears in Spotlight.
- **App icon** — desk + up/down chevrons on a purple→blue gradient, generated reproducibly
  with CoreGraphics (`tools/make_icon.swift`).

### Fixed
- **Connections no longer hang on "Connecting…" forever.** `CBCentralManager.connect()`
  has no timeout, so a BLE-asleep, out-of-range, or stale-cached peripheral would stall
  indefinitely. Each connect attempt now arms a 6 s grace timer that cancels the stuck
  attempt and falls back to an active re-scan.
- **Stale-instance bug.** `DeskBarApp.init()` read a `@StateObject` before SwiftUI had
  installed its storage, wiring hotkeys to a throwaway controller (e.g. a changed nudge
  amount applied to the on-screen buttons but not the hotkey). `DeskController`,
  `ShortcutSettings`, and `HotKeyManager` are now backed by shared singletons.

### Changed
- Shortcut labels are keyboard-layout-aware (via `UCKeyTranslate`) instead of assuming a
  QWERTY physical layout.

Thanks to [@razor54](https://github.com/razor54) (André Gaudêncio) for the connection-timeout
fix, the shortcut editor, and the UI improvements ([#1](https://github.com/pedrocorreia/DeskBar/pull/1)).

## [1.1.0] - 2026-08-06

### Added
- Single-instance guard: launching a second copy focuses the running app and exits instead
  of stacking another menu-bar item.

### Fixed
- Sit/Stand buttons now use dark text/icons on their bright fills — white-on-cyan was
  nearly unreadable.

## [1.0.0] - 2026-08-06

### Added
- Initial release: native macOS menu-bar app to control LINAK DPG1C Bluetooth standing
  desks.
- Sit/Stand presets, live height readout, ± nudge, and stop.
- Global keyboard shortcuts via Carbon hotkeys — no Accessibility permission required.
- Multi-desk switcher by Bluetooth signal strength, with auto-connect and auto-reconnect.
- Python/`bleak` prototype and the documented DPG1C wakeup handshake.

[Unreleased]: https://github.com/pedrocorreia/DeskBar/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/pedrocorreia/DeskBar/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/pedrocorreia/DeskBar/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/pedrocorreia/DeskBar/releases/tag/v1.0.0
