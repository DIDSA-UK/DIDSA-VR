"""The P0 voice spike's relay (docs/live-sessions-spikes.md, "Spike V"): forwards every binary frame to every other connection, with
byte 1 overwritten by the sender's id (as the session hub does), and with --echo back to the sender too, so a device can time its own
round trip. Run by hand on the PC; never deployed; no auth. Prints the bytes per second it relays every 5 s.

    pip install "websockets==13.*"
    python3 spikes/voice/echo_relay.py --port 8301 --echo
"""

import argparse
import asyncio
import itertools
import json

from websockets.asyncio.server import serve

clients: dict = {}
relayed = {"frames": 0, "bytes": 0}


async def handler(ws, echo: bool, ids) -> None:
    my_id = next(ids)
    clients[ws] = my_id
    print(f"client {my_id} connected from {ws.remote_address}")
    await ws.send(json.dumps({"t": "hello", "id": my_id}))
    try:
        async for message in ws:
            if not isinstance(message, bytes) or len(message) < 5:
                continue
            frame = message[:1] + bytes([my_id]) + message[2:]
            for other in list(clients):
                if other is ws and not echo:
                    continue
                try:
                    await other.send(frame)
                    relayed["frames"] += 1
                    relayed["bytes"] += len(frame)
                except Exception:  # noqa: BLE001 - a client that went away
                    pass
    finally:
        clients.pop(ws, None)
        print(f"client {my_id} left")


async def report() -> None:
    while True:
        await asyncio.sleep(5)
        if relayed["frames"]:
            print(f"relayed {relayed['frames']} frames, {relayed['bytes'] * 8 / 5000:.1f} kbit/s, {len(clients)} clients")
        relayed["frames"] = relayed["bytes"] = 0


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8301)
    parser.add_argument("--echo", action="store_true", help="also send each frame back to its sender (round-trip timing)")
    args = parser.parse_args()
    ids = itertools.count(1)
    async with serve(lambda ws: handler(ws, args.echo, ids), "0.0.0.0", args.port):
        print(f"voice relay on ws://0.0.0.0:{args.port}/ws (echo {'on' if args.echo else 'off'})")
        await report()


if __name__ == "__main__":
    asyncio.run(main())
