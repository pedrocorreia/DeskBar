#!/usr/bin/env python3
"""
LINAK desk control prototype (Phase 1).

Goal: confirm we can talk to the desk over BLE before building the Swift
menu-bar app. Uses the reverse-engineered LINAK Bluetooth protocol (the same
one the `idasen` project uses).

Usage (run with the project venv):
    ./.venv/bin/python prototype/desk.py scan
    ./.venv/bin/python prototype/desk.py info      [--address <UUID>]
    ./.venv/bin/python prototype/desk.py monitor    --address <UUID>
    ./.venv/bin/python prototype/desk.py up         --address <UUID> [--seconds 2]
    ./.venv/bin/python prototype/desk.py down       --address <UUID> [--seconds 2]
    ./.venv/bin/python prototype/desk.py to         --address <UUID> --cm 110

Notes for macOS: the FIRST time you run this, macOS will ask Terminal for
Bluetooth permission — click Allow, then re-run. The `--address` is a macOS
CoreBluetooth UUID (not a MAC address); `scan` prints it for you.
"""

import argparse
import asyncio
import sys

from bleak import BleakScanner, BleakClient

# --- LINAK BLE protocol constants ---------------------------------------------
# Control service + characteristic (where movement commands are written)
UUID_CONTROL_SVC = "99fa0001-338a-1024-8a49-009c0215f78a"
UUID_COMMAND = "99fa0002-338a-1024-8a49-009c0215f78a"
# Height + speed (read / notify). Two little-endian uint16: raw height, raw speed.
UUID_HEIGHT_SPEED = "99fa0021-338a-1024-8a49-009c0215f78a"
# "Reference input" — write a target position here (repeatedly) to move-to.
UUID_REFERENCE_INPUT = "99fa0031-338a-1024-8a49-009c0215f78a"

CMD_UP = bytearray([0x47, 0x00])
CMD_DOWN = bytearray([0x46, 0x00])
CMD_STOP = bytearray([0xFF, 0x00])
CMD_WAKEUP = bytearray([0xFE, 0x00])
CMD_REF_STOP = bytearray([0x01, 0x80])

# Height math. Raw value is in 0.1 mm units, offset from the desk's minimum.
# Physical minimum is ~62.0 cm for most LINAK desks; adjust if yours differs.
BASE_HEIGHT_CM = 62.0


def raw_to_cm(raw: int) -> float:
    return raw / 100.0 + BASE_HEIGHT_CM


def cm_to_raw(cm: float) -> int:
    return int(round((cm - BASE_HEIGHT_CM) * 100.0))


def parse_height_speed(data: bytearray) -> tuple[float, int]:
    raw_height = int.from_bytes(data[0:2], "little")
    raw_speed = int.from_bytes(data[2:4], "little") if len(data) >= 4 else 0
    return raw_to_cm(raw_height), raw_speed


# --- discovery ----------------------------------------------------------------
def looks_like_desk(name: str | None) -> bool:
    if not name:
        return False
    n = name.lower()
    return any(k in n for k in ("desk", "linak", "idasen", "jarvis", "fully"))


async def cmd_scan(_args):
    print("Scanning for BLE devices for 8s...\n")
    devices = await BleakScanner.discover(timeout=8.0, return_adv=True)
    if not devices:
        print("No BLE devices found. Is Bluetooth on? Did you allow the permission prompt?")
        return
    rows = []
    for address, (dev, adv) in devices.items():
        name = dev.name or adv.local_name or "(no name)"
        svc_uuids = [u.lower() for u in (adv.service_uuids or [])]
        is_desk = looks_like_desk(name) or UUID_CONTROL_SVC in svc_uuids
        rows.append((is_desk, name, address, adv.rssi))
    rows.sort(key=lambda r: (not r[0], -(r[3] or -999)))
    print(f"{'':2}  {'NAME':28}  {'ADDRESS (use with --address)':40}  RSSI")
    print("-" * 90)
    for is_desk, name, address, rssi in rows:
        mark = "->" if is_desk else "  "
        print(f"{mark}  {name[:28]:28}  {address:40}  {rssi}")
    print("\n'->' = likely a desk. Copy its ADDRESS and use it with --address.")


async def _connect(address: str) -> BleakClient:
    client = BleakClient(address, timeout=20.0)
    await client.connect()
    return client


async def cmd_info(args):
    if not args.address:
        print("Pass --address (run `scan` first to get it).")
        return
    print(f"Connecting to {args.address} ...")
    async with BleakClient(args.address, timeout=20.0) as client:
        print("Connected. Services / characteristics:\n")
        for svc in client.services:
            print(f"  service {svc.uuid}  ({svc.description})")
            for ch in svc.characteristics:
                props = ",".join(ch.properties)
                print(f"    char  {ch.uuid}  [{props}]")
        print("\nChecking for expected LINAK characteristics:")
        chars = {ch.uuid.lower() for svc in client.services for ch in svc.characteristics}
        for label, uuid in (
            ("command", UUID_COMMAND),
            ("height/speed", UUID_HEIGHT_SPEED),
            ("reference-input", UUID_REFERENCE_INPUT),
        ):
            print(f"  {'FOUND' if uuid in chars else 'MISSING':7} {label:16} {uuid}")
        if UUID_HEIGHT_SPEED in chars:
            data = await client.read_gatt_char(UUID_HEIGHT_SPEED)
            cm, speed = parse_height_speed(bytearray(data))
            print(f"\nCurrent height: {cm:.1f} cm  (raw bytes: {data.hex()})")


async def cmd_monitor(args):
    print(f"Connecting to {args.address} ... (Ctrl-C to stop)")
    async with BleakClient(args.address, timeout=20.0) as client:
        def on_change(_handle, data: bytearray):
            cm, speed = parse_height_speed(data)
            print(f"  height {cm:6.1f} cm   speed {speed}")
        await client.start_notify(UUID_HEIGHT_SPEED, on_change)
        # also print an initial read
        data = await client.read_gatt_char(UUID_HEIGHT_SPEED)
        cm, _ = parse_height_speed(bytearray(data))
        print(f"  height {cm:6.1f} cm   (initial)")
        try:
            await asyncio.sleep(3600)
        except asyncio.CancelledError:
            pass


async def _move_for(client: BleakClient, cmd: bytearray, seconds: float):
    # LINAK is a dead-man's switch: keep sending the command while moving.
    await client.write_gatt_char(UUID_COMMAND, CMD_WAKEUP, response=False)
    end = asyncio.get_event_loop().time() + seconds
    while asyncio.get_event_loop().time() < end:
        await client.write_gatt_char(UUID_COMMAND, cmd, response=False)
        await asyncio.sleep(0.2)
    await client.write_gatt_char(UUID_COMMAND, CMD_STOP, response=False)


async def cmd_up(args):
    async with BleakClient(args.address, timeout=20.0) as client:
        print(f"Moving UP for {args.seconds}s ...")
        await _move_for(client, CMD_UP, args.seconds)
        data = await client.read_gatt_char(UUID_HEIGHT_SPEED)
        print(f"Done. Height now {parse_height_speed(bytearray(data))[0]:.1f} cm")


async def cmd_down(args):
    async with BleakClient(args.address, timeout=20.0) as client:
        print(f"Moving DOWN for {args.seconds}s ...")
        await _move_for(client, CMD_DOWN, args.seconds)
        data = await client.read_gatt_char(UUID_HEIGHT_SPEED)
        print(f"Done. Height now {parse_height_speed(bytearray(data))[0]:.1f} cm")


async def cmd_to(args):
    target_cm = args.cm
    target_raw = cm_to_raw(target_cm)
    async with BleakClient(args.address, timeout=20.0) as client:
        print(f"Moving to {target_cm:.1f} cm ...")
        await client.write_gatt_char(UUID_COMMAND, CMD_WAKEUP, response=False)
        payload = bytearray(target_raw.to_bytes(2, "little"))
        last_cm = None
        stalls = 0
        for _ in range(300):  # ~60s max
            data = await client.read_gatt_char(UUID_HEIGHT_SPEED)
            cm, _ = parse_height_speed(bytearray(data))
            if abs(cm - target_cm) <= 0.5:
                break
            # dead-man: keep writing the target to reference-input
            await client.write_gatt_char(UUID_REFERENCE_INPUT, payload, response=False)
            if last_cm is not None and abs(cm - last_cm) < 0.1:
                stalls += 1
                if stalls > 15:
                    print("  (stalled — desk stopped moving, giving up)")
                    break
            else:
                stalls = 0
            last_cm = cm
            await asyncio.sleep(0.2)
        data = await client.read_gatt_char(UUID_HEIGHT_SPEED)
        print(f"Done. Height now {parse_height_speed(bytearray(data))[0]:.1f} cm")


async def _read_cm(client: BleakClient) -> float:
    data = await client.read_gatt_char(UUID_HEIGHT_SPEED)
    return parse_height_speed(bytearray(data))[0]


async def _try_strategy(client, name, coro_factory, start_cm):
    print(f"\n>>> Strategy: {name}")
    try:
        await coro_factory()
    except Exception as e:  # noqa: BLE001 - diagnostic, report anything
        print(f"    raised: {type(e).__name__}: {e}")
    # let it settle, then measure
    await asyncio.sleep(0.6)
    end_cm = await _read_cm(client)
    delta = end_cm - start_cm
    moved = abs(delta) >= 0.3
    print(f"    height {start_cm:.1f} -> {end_cm:.1f} cm  (delta {delta:+.1f})  "
          f"{'*** MOVED ***' if moved else 'no change'}")
    return end_cm, moved


async def cmd_diag(args):
    print(f"Connecting to {args.address} ...")
    async with BleakClient(args.address, timeout=20.0) as client:
        # 1) properties of the characteristics we care about
        chars = {ch.uuid.lower(): ch for svc in client.services
                 for ch in svc.characteristics}
        print("\nCharacteristic properties:")
        for label, uuid in (("command", UUID_COMMAND),
                            ("height/speed", UUID_HEIGHT_SPEED),
                            ("reference-input", UUID_REFERENCE_INPUT)):
            ch = chars.get(uuid)
            if ch:
                print(f"  {label:16} FOUND  [{','.join(ch.properties)}]")
            else:
                print(f"  {label:16} MISSING")

        has_cmd = UUID_COMMAND in chars
        has_ref = UUID_REFERENCE_INPUT in chars

        start = await _read_cm(client)
        print(f"\nStart height: {start:.1f} cm")
        print("Trying strategies (each nudges UP a few cm). Watch the desk...")

        cur = start
        moved_by = None

        async def strat_cmd(resp):
            for _ in range(15):  # ~3s of repeated writes
                await client.write_gatt_char(UUID_COMMAND, CMD_UP, response=resp)
                await asyncio.sleep(0.2)
            await client.write_gatt_char(UUID_COMMAND, CMD_STOP, response=resp)

        async def strat_ref(resp):
            target_raw = cm_to_raw(cur + 4.0)
            payload = bytearray(target_raw.to_bytes(2, "little"))
            for _ in range(25):  # ~5s of dead-man writes
                await client.write_gatt_char(UUID_REFERENCE_INPUT, payload, response=resp)
                await asyncio.sleep(0.2)

        if has_cmd:
            cur, moved = await _try_strategy(
                client, "command char, write WITHOUT response",
                lambda: strat_cmd(False), cur)
            if moved:
                moved_by = "command / write-without-response"
        if not moved_by and has_cmd:
            cur, moved = await _try_strategy(
                client, "command char, write WITH response",
                lambda: strat_cmd(True), cur)
            if moved:
                moved_by = "command / write-with-response"
        if not moved_by and has_ref:
            cur, moved = await _try_strategy(
                client, "reference-input, write WITHOUT response",
                lambda: strat_ref(False), cur)
            if moved:
                moved_by = "reference-input / write-without-response"
        if not moved_by and has_ref:
            cur, moved = await _try_strategy(
                client, "reference-input, write WITH response",
                lambda: strat_ref(True), cur)
            if moved:
                moved_by = "reference-input / write-with-response"

        print("\n" + "=" * 50)
        if moved_by:
            print(f"WINNER: {moved_by}")
            print("Tell Claude this line and it'll wire the app to use it.")
        else:
            print("Nothing moved the desk. Copy the FULL output above to Claude —")
            print("the characteristic properties will point to the fix.")


async def cmd_diag2(args):
    """Same idea as diag, but subscribe to height notifications FIRST.
    Many LINAK desks only accept movement while a notify subscription is live.
    """
    print(f"Connecting to {args.address} ...")
    async with BleakClient(args.address, timeout=20.0) as client:
        latest = {"cm": None}

        def on_change(_handle, data: bytearray):
            latest["cm"] = parse_height_speed(data)[0]

        print("Enabling height notifications...")
        await client.start_notify(UUID_HEIGHT_SPEED, on_change)
        await asyncio.sleep(0.5)
        start = latest["cm"] if latest["cm"] is not None else await _read_cm(client)
        print(f"Start height: {start:.1f} cm\n")

        async def run(name, coro):
            print(f">>> {name}")
            base = latest["cm"] or start
            try:
                await coro()
            except Exception as e:  # noqa: BLE001
                print(f"    raised: {type(e).__name__}: {e}")
            await asyncio.sleep(0.6)
            now = latest["cm"] or await _read_cm(client)
            d = now - base
            moved = abs(d) >= 0.3
            print(f"    {base:.1f} -> {now:.1f} cm (delta {d:+.1f}) "
                  f"{'*** MOVED ***' if moved else 'no change'}\n")
            return moved

        winner = None

        # A) reference-input spam, notify active
        async def ref_spam():
            target = cm_to_raw((latest["cm"] or start) + 4.0)
            payload = bytearray(target.to_bytes(2, "little"))
            for _ in range(30):
                await client.write_gatt_char(UUID_REFERENCE_INPUT, payload, response=False)
                await asyncio.sleep(0.2)
        if await run("reference-input spam (notify active)", ref_spam):
            winner = "reference-input spam, notify active"

        # B) wakeup then command-char up, notify active
        if not winner:
            async def cmd_wake_up():
                await client.write_gatt_char(UUID_COMMAND, CMD_WAKEUP, response=False)
                await asyncio.sleep(0.3)
                for _ in range(15):
                    await client.write_gatt_char(UUID_COMMAND, CMD_UP, response=False)
                    await asyncio.sleep(0.2)
                await client.write_gatt_char(UUID_COMMAND, CMD_STOP, response=False)
            if await run("wakeup + command-char UP (notify active)", cmd_wake_up):
                winner = "wakeup + command-char up, notify active"

        # C) interleave wakeup on command char AND reference-input each tick
        if not winner:
            async def combo():
                target = cm_to_raw((latest["cm"] or start) + 4.0)
                payload = bytearray(target.to_bytes(2, "little"))
                for _ in range(30):
                    await client.write_gatt_char(UUID_COMMAND, CMD_WAKEUP, response=False)
                    await client.write_gatt_char(UUID_REFERENCE_INPUT, payload, response=False)
                    await asyncio.sleep(0.2)
            if await run("wakeup + reference-input each tick (notify active)", combo):
                winner = "wakeup + reference-input each tick, notify active"

        await client.stop_notify(UUID_HEIGHT_SPEED)
        print("=" * 50)
        if winner:
            print(f"WINNER: {winner}")
        else:
            print("Still nothing. Paste full output to Claude.")


def main():
    p = argparse.ArgumentParser(description="LINAK desk control prototype")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("scan", help="scan for BLE devices")

    p_info = sub.add_parser("info", help="connect and list services/characteristics")
    p_info.add_argument("--address", help="device address from scan")

    p_mon = sub.add_parser("monitor", help="stream live height")
    p_mon.add_argument("--address", required=True)

    p_up = sub.add_parser("up", help="move up")
    p_up.add_argument("--address", required=True)
    p_up.add_argument("--seconds", type=float, default=2.0)

    p_down = sub.add_parser("down", help="move down")
    p_down.add_argument("--address", required=True)
    p_down.add_argument("--seconds", type=float, default=2.0)

    p_to = sub.add_parser("to", help="move to an absolute height in cm")
    p_to.add_argument("--address", required=True)
    p_to.add_argument("--cm", type=float, required=True)

    p_diag = sub.add_parser("diag", help="try every movement strategy, report which works")
    p_diag.add_argument("--address", required=True)

    p_diag2 = sub.add_parser("diag2", help="like diag but with height notifications enabled first")
    p_diag2.add_argument("--address", required=True)

    args = p.parse_args()
    handlers = {
        "scan": cmd_scan,
        "info": cmd_info,
        "monitor": cmd_monitor,
        "up": cmd_up,
        "down": cmd_down,
        "to": cmd_to,
        "diag": cmd_diag,
        "diag2": cmd_diag2,
    }
    try:
        asyncio.run(handlers[args.command](args))
    except KeyboardInterrupt:
        print("\nStopped.")
        sys.exit(0)


if __name__ == "__main__":
    main()
