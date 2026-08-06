# Changelog

All notable changes to DeskBar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.2.0]: https://github.com/pedrocorreia/DeskBar/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/pedrocorreia/DeskBar/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/pedrocorreia/DeskBar/releases/tag/v1.0.0
