#!/usr/bin/env python3
"""
DeskBar MCP server — lets an AI assistant (Claude Desktop, Claude Code, or any
MCP client) drive a LINAK DPG1C standing desk over Bluetooth.

It reuses the same `idasen` control path proven in prototype/ (including the DPG
wakeup handshake), and reads the Sit/Stand/nudge presets straight from the
DeskBar macOS app's preferences so the two stay in sync.

Run (stdio):
    ./.venv/bin/python mcp/desk_mcp.py

Config: set DESK_ADDRESS to your desk's CoreBluetooth UUID (from `desk.py scan`);
otherwise it falls back to the project's known desk.
"""
import asyncio
import os
import subprocess

from bleak import BleakScanner
from idasen import IdasenDesk
from mcp.server.mcpserver import MCPServer

# Desk address (macOS CoreBluetooth UUID, not a MAC). Override with DESK_ADDRESS.
DESK_ADDRESS = os.environ.get("DESK_ADDRESS", "A6EB36A7-8AB4-E267-D74C-B9E8D1EC8195")

MIN_CM = 62.0
MAX_CM = 127.0
PREFS_DOMAIN = "com.pedro.deskbar"  # DeskBar app's UserDefaults domain

server = MCPServer(
    name="deskbar",
    version="1.2.0",
    instructions=(
        "Controls a LINAK standing desk over Bluetooth. Use `get_status` to read the "
        "current height and presets, `stand`/`sit` for the saved presets, `set_height` "
        "for an absolute height in cm, and `nudge` for a relative move. Heights are in "
        "centimetres, roughly 62–127. Movement tools block until the desk arrives."
    ),
)


def _read_pref(key: str, default: float) -> float:
    """Read a Double from the DeskBar app's preferences; fall back if unset."""
    try:
        r = subprocess.run(
            ["defaults", "read", PREFS_DOMAIN, key],
            capture_output=True, text=True, timeout=3,
        )
        if r.returncode == 0 and r.stdout.strip():
            return float(r.stdout.strip())
    except (ValueError, subprocess.SubprocessError):
        pass
    return default


def _presets() -> tuple[float, float, float]:
    return (
        _read_pref("sitCm", 74.0),
        _read_pref("standCm", 110.0),
        _read_pref("nudgeCm", 2.0),
    )


def _clamp(cm: float) -> float:
    return max(MIN_CM + 0.5, min(MAX_CM - 0.5, cm))


def _posture(cm: float, sit: float, stand: float) -> str:
    return "standing" if cm >= (sit + stand) / 2 else "sitting"


async def _current_height_cm(desk: IdasenDesk) -> float:
    return await desk.get_height() * 100.0


async def _move_to(cm: float) -> str:
    target = _clamp(cm)
    sit, stand, _ = _presets()
    try:
        async with IdasenDesk(mac=DESK_ADDRESS) as desk:
            await desk.wakeup()  # DPG1C ignores movement without this handshake
            await desk.move_to_target(target / 100.0)
            now = await _current_height_cm(desk)
        return f"Moved the desk to {now:.1f} cm ({_posture(now, sit, stand)})."
    except Exception as e:  # noqa: BLE001 - surface a helpful message to the assistant
        return (
            f"Couldn't move the desk ({type(e).__name__}: {e}). "
            "Is it in Bluetooth range and awake? Tapping its physical controller wakes it."
        )


@server.tool()
async def get_status() -> str:
    """Report the desk's current height, posture, and saved presets."""
    sit, stand, nudge = _presets()
    try:
        async with IdasenDesk(mac=DESK_ADDRESS) as desk:
            cm = await _current_height_cm(desk)
        return (
            f"Desk is at {cm:.1f} cm ({_posture(cm, sit, stand)}). "
            f"Presets — sit {sit:.0f} cm, stand {stand:.0f} cm, nudge step {nudge:g} cm."
        )
    except Exception as e:  # noqa: BLE001
        return (
            f"Couldn't reach the desk ({type(e).__name__}: {e}). "
            f"Presets on file — sit {sit:.0f} cm, stand {stand:.0f} cm."
        )


@server.tool()
async def stand() -> str:
    """Raise the desk to the saved Stand preset height."""
    _, stand_cm, _ = _presets()
    return await _move_to(stand_cm)


@server.tool()
async def sit() -> str:
    """Lower the desk to the saved Sit preset height."""
    sit_cm, _, _ = _presets()
    return await _move_to(sit_cm)


@server.tool()
async def set_height(height_cm: float) -> str:
    """Move the desk to an absolute height in centimetres (clamped to ~62–127)."""
    return await _move_to(height_cm)


@server.tool()
async def nudge(delta_cm: float) -> str:
    """Move the desk up (positive) or down (negative) by a relative amount in cm."""
    try:
        async with IdasenDesk(mac=DESK_ADDRESS) as desk:
            current = await _current_height_cm(desk)
    except Exception as e:  # noqa: BLE001
        return f"Couldn't read the desk to nudge it ({type(e).__name__}: {e})."
    return await _move_to(current + delta_cm)


@server.tool()
async def list_desks() -> str:
    """Scan for nearby LINAK desks and list them with signal strength."""
    found = await BleakScanner.discover(timeout=6.0, return_adv=True)
    rows = []
    for address, (dev, adv) in found.items():
        name = dev.name or adv.local_name or ""
        if "desk" in name.lower() or "linak" in name.lower():
            rows.append(f"  {name or '(unnamed)'} — {address} (RSSI {adv.rssi})")
    if not rows:
        return "No desks found. Wake the desk by tapping its controller, then try again."
    return "Nearby desks (set DESK_ADDRESS to one of these UUIDs):\n" + "\n".join(rows)


if __name__ == "__main__":
    server.run("stdio")
