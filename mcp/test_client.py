#!/usr/bin/env python3
"""
Local test harness for the DeskBar MCP server. Spawns desk_mcp.py over stdio
(exactly as a real MCP client would) and calls a tool.

Run from the repo root with the venv python so the child inherits mcp+idasen and
your terminal's Bluetooth permission:

    ./.venv/bin/python mcp/test_client.py --list          # MCP handshake only, no Bluetooth
    ./.venv/bin/python mcp/test_client.py get_status       # read height (no movement)
    ./.venv/bin/python mcp/test_client.py nudge 2          # move up 2 cm  (⚠ moves the desk)
    ./.venv/bin/python mcp/test_client.py set_height 100   # move to 100 cm (⚠ moves the desk)
    ./.venv/bin/python mcp/test_client.py stand            # ⚠ moves the desk
    ./.venv/bin/python mcp/test_client.py sit              # ⚠ moves the desk
"""
import asyncio
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

SERVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "desk_mcp.py")


async def main() -> None:
    arg = sys.argv[1] if len(sys.argv) > 1 else "--list"

    params = StdioServerParameters(
        command=sys.executable, args=[SERVER], env=os.environ.copy()
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = (await session.list_tools()).tools
            print("Connected. Tools:", ", ".join(t.name for t in tools))

            if arg == "--list":
                return

            args: dict = {}
            if arg == "set_height" and len(sys.argv) > 2:
                args = {"height_cm": float(sys.argv[2])}
            elif arg == "nudge" and len(sys.argv) > 2:
                args = {"delta_cm": float(sys.argv[2])}

            print(f"\n→ calling {arg}({args}) ...")
            result = await session.call_tool(arg, args)
            for block in result.content:
                if getattr(block, "type", None) == "text":
                    print("←", block.text)


if __name__ == "__main__":
    asyncio.run(main())
