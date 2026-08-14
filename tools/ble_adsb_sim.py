#!/usr/bin/env python3
"""Simulate a BLE ADS-B receiver (docs/BLE_ADSB_SERVICE.md) for app testing.

Advertises the ADS-B Receiver GATT service and replays a recorded GDL90
capture (tests/*.bin) on the Traffic/Ownship/Status characteristics - one
complete framed GDL90 message per notification, exactly as ADSBee BLE
firmware would. Lets AvareX's BLE client be tested with zero hardware.

Requires the 'bless' BLE peripheral library (pip install bless).
macOS note: grant Bluetooth permission to your terminal app when prompted.

Usage:
  python3 tools/ble_adsb_sim.py tests/adsb_dallas.bin
"""

import asyncio
import sys
from pathlib import Path

from bless import BlessServer, BlessGATTCharacteristic, GATTCharacteristicProperties, GATTAttributePermissions

SERVICE = "0BEE0001-1090-46F0-A9AC-52D6BE4C29CC"
TRAFFIC = "0BEE0010-1090-46F0-A9AC-52D6BE4C29CC"
OWNSHIP = "0BEE0011-1090-46F0-A9AC-52D6BE4C29CC"
STATUS = "0BEE0012-1090-46F0-A9AC-52D6BE4C29CC"
CONTROL = "0BEE0020-1090-46F0-A9AC-52D6BE4C29CC"

FLAG = 0x7E


def split_gdl90(data: bytes):
    """Split a raw capture into individual framed messages.

    GDL90 byte stuffing guarantees 0x7E never appears inside frame content,
    so splitting on the flag byte yields the content chunks directly
    (regardless of shared/doubled flags between frames); re-frame each.
    """
    flag = bytes([FLAG])
    return [flag + chunk + flag for chunk in data.split(flag) if len(chunk) > 3]


def char_for_message(msg: bytes) -> str | None:
    msg_id = msg[1] if len(msg) > 1 else 0
    if msg_id == 0x07 or len(msg) > 240:
        return None  # FIS-B uplink: US-only, exceeds MTU, not in the BLE spec
    if msg_id == 0x14:
        return TRAFFIC
    if msg_id in (0x0A, 0x0B):
        return OWNSHIP
    return STATUS


async def main(path: str):
    raw = Path(path).read_bytes()
    messages = split_gdl90(raw)
    print(f"{len(messages)} GDL90 messages in {path}")

    server = BlessServer(name="ADSBee-SIM")
    await server.add_new_service(SERVICE)
    notify = GATTCharacteristicProperties.notify | GATTCharacteristicProperties.read
    for uuid in (TRAFFIC, OWNSHIP, STATUS):
        await server.add_new_characteristic(
            SERVICE, uuid, notify, b"", GATTAttributePermissions.readable)
    await server.add_new_characteristic(
        SERVICE, CONTROL,
        GATTCharacteristicProperties.write | GATTCharacteristicProperties.write_without_response,
        b"", GATTAttributePermissions.writeable)

    await server.start()
    print("advertising as ADSBee-SIM; connect from the app's IO screen")

    # replay forever at ~ real time (captures are dense; pace to ~20 msg/s)
    while True:
        for msg in messages:
            uuid = char_for_message(msg)
            if uuid is None:
                continue
            c: BlessGATTCharacteristic = server.get_characteristic(uuid)
            c.value = msg
            server.update_value(SERVICE, uuid)
            await asyncio.sleep(0.05)
        print("capture replayed; looping")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    asyncio.run(main(sys.argv[1]))
