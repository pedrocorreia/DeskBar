#!/usr/bin/env python3
"""
DeskBar MCP server — lets an AI assistant (Claude Desktop, Claude Code, or any
MCP client) drive a LINAK DPG1C standing desk.

It does NOT talk Bluetooth itself. macOS attributes a CoreBluetooth request to
the *responsible* process, and when this server is spawned by the `claude` CLI
that CLI has no Bluetooth usage-description string — so TCC hard-aborts the
process (SIGABRT) the instant it touches BLE. Instead, this server sends
commands over a Unix-domain socket to the DeskBar macOS app, which is a properly
signed bundle that owns the Bluetooth permission and holds the live connection.

Start the DeskBar app first (it opens the control socket on launch). Run (stdio):
    ./.venv/bin/python mcp/desk_mcp.py
"""
import asyncio
import json
import os

from mcp.server.mcpserver import MCPServer

# Must match ControlServer.socketPath in the DeskBar app.
SOCKET_PATH = os.path.expanduser("~/Library/Application Support/DeskBar/control.sock")

# Movements block until the desk arrives; the app caps a move at ~45s, so give
# the socket read a bit more headroom than that.
REQUEST_TIMEOUT = 60.0

server = MCPServer(
    name="deskbar",
    version="2.0.0",
    instructions=(
        "Controls a LINAK standing desk via the DeskBar macOS app. Use `get_status` "
        "to read the current height and presets, `stand`/`sit` for the saved presets, "
        "`set_height` for an absolute height in cm, `nudge` for a relative move, and "
        "`stop` to cancel a move in progress. "
        "Heights are in centimetres, roughly 62–127. Movement tools block until the "
        "desk arrives. If calls report the app isn't reachable, launch DeskBar.app."
    ),
)


_APP_DOWN = {"ok": False, "error": (
    "The DeskBar app isn't running (control socket not reachable). "
    "Launch DeskBar.app, then try again."
)}


async def _request(payload: dict, timeout: float = REQUEST_TIMEOUT) -> dict:
    """Send one JSON command to the DeskBar app and return its JSON reply.

    Uses asyncio streams throughout so a long move (the app blocks the reply
    until the desk arrives, up to ~45s) never blocks the event loop — other
    tool calls, cancellation, and transport I/O keep flowing.
    """
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_unix_connection(SOCKET_PATH), timeout=5.0)
    except (FileNotFoundError, ConnectionRefusedError):
        return dict(_APP_DOWN)
    except (asyncio.TimeoutError, OSError) as e:
        return {"ok": False, "error": (
            f"Couldn't reach the DeskBar app ({type(e).__name__}: {e}). Is it running?"
        )}

    try:
        writer.write((json.dumps(payload) + "\n").encode())
        await writer.drain()
        line = await asyncio.wait_for(reader.readline(), timeout=timeout)
    except (asyncio.TimeoutError, OSError) as e:
        return {"ok": False, "error": (
            f"Lost contact with the DeskBar app ({type(e).__name__}: {e})."
        )}
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except OSError:
            pass

    try:
        return json.loads(line.decode())
    except (json.JSONDecodeError, ValueError) as e:
        return {"ok": False, "error": f"Unexpected reply from the DeskBar app ({e})."}


def _presets(r: dict) -> str:
    return (
        f"Presets — sit {r.get('sit_cm', 0):.0f} cm, "
        f"stand {r.get('stand_cm', 0):.0f} cm, "
        f"nudge step {r.get('nudge_cm', 0):g} cm."
    )


def _describe(r: dict) -> str:
    """Human-readable line for a status/move reply."""
    if not r.get("ok"):
        return r.get("error", "Something went wrong talking to the DeskBar app.")
    if not r.get("ready"):
        return ("DeskBar is running but hasn't connected to the desk yet "
                "(finding it over Bluetooth). " + _presets(r))
    return (f"Desk is at {r.get('height_cm', 0):.1f} cm "
            f"({r.get('posture', 'unknown')}). " + _presets(r))


def _moved(r: dict) -> str:
    if not r.get("ok"):
        return r.get("error", "Couldn't move the desk.")
    return f"Moved the desk to {r.get('height_cm', 0):.1f} cm ({r.get('posture', 'unknown')})."


@server.tool()
async def get_status() -> str:
    """Report the desk's current height, posture, and saved presets."""
    return _describe(await _request({"cmd": "status"}))


@server.tool()
async def stand() -> str:
    """Raise the desk to the saved Stand preset height."""
    return _moved(await _request({"cmd": "stand"}))


@server.tool()
async def sit() -> str:
    """Lower the desk to the saved Sit preset height."""
    return _moved(await _request({"cmd": "sit"}))


@server.tool()
async def set_height(height_cm: float) -> str:
    """Move the desk to an absolute height in centimetres (clamped to ~62–127)."""
    return _moved(await _request({"cmd": "set_height", "height_cm": height_cm}))


@server.tool()
async def nudge(delta_cm: float) -> str:
    """Move the desk up (positive) or down (negative) by a relative amount in cm."""
    return _moved(await _request({"cmd": "nudge", "delta_cm": delta_cm}))


@server.tool()
async def stop() -> str:
    """Immediately stop the desk if it's moving (e.g. to cancel a bad move)."""
    r = await _request({"cmd": "stop"})
    if not r.get("ok"):
        return r.get("error", "Couldn't stop the desk.")
    return (f"Stopped. Desk is at {r.get('height_cm', 0):.1f} cm "
            f"({r.get('posture', 'unknown')}).")


@server.tool()
async def list_desks() -> str:
    """Scan for nearby LINAK desks and list them with signal strength."""
    r = await _request({"cmd": "scan"}, timeout=15.0)
    if not r.get("ok"):
        return r.get("error", "Couldn't scan for desks.")
    desks = r.get("desks", [])
    if not desks:
        return "No desks found. Wake the desk by tapping its controller, then try again."
    rows = [f"  {d.get('name') or '(unnamed)'} — {d.get('id')} (RSSI {d.get('rssi')})"
            for d in desks]
    return "Nearby desks:\n" + "\n".join(rows)


if __name__ == "__main__":
    server.run("stdio")
