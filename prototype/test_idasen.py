#!/usr/bin/env python3
"""
Test movement using the proven `idasen` library (handles the DPG1C handshake).
Moves the desk UP by 5 cm. Keep clearance above the desk and a hand near the
physical controller.

    ./.venv/bin/python prototype/test_idasen.py
"""
import asyncio
import logging

from idasen import IdasenDesk

ADDRESS = "A6EB36A7-8AB4-E267-D74C-B9E8D1EC8195"

logging.basicConfig(level=logging.INFO, format="%(message)s")


async def main():
    print(f"Connecting to {ADDRESS} ...")
    async with IdasenDesk(mac=ADDRESS) as desk:
        start = await desk.get_height()  # meters
        print(f"Start height: {start * 100:.1f} cm")

        print("Sending DPG wakeup handshake...")
        await desk.wakeup()

        target = min(start + 0.05, IdasenDesk.MAX_HEIGHT - 0.01)
        print(f"Moving to {target * 100:.1f} cm (up 5 cm)...")
        await desk.move_to_target(target)

        end = await desk.get_height()
        print(f"Done. Height now {end * 100:.1f} cm")
        if abs(end - start) >= 0.02:
            print("\n*** SUCCESS — the desk moved! ***")
        else:
            print("\nDesk did not move even via idasen — paste this output to Claude.")


if __name__ == "__main__":
    asyncio.run(main())
