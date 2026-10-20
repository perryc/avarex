#!/usr/bin/env python3
"""Set or query the ICAO (Mode S) address on a SoftRF unit running the
perryc/SoftRF 'aircraft-address' firmware, via the $PSRFA NMEA sentence.

The address is what the unit transmits as its ident on FLARM/OGNTP/FANET
and reports as ownship over GDL90, so set it to the aircraft's 24-bit
address from the Transport Canada register (e.g. C-FMHP -> C02076).
A zero address reverts to the chip-derived default.

Usage:
  softrf_set_address.py /dev/cu.usbmodemXXXX            # query
  softrf_set_address.py /dev/cu.usbmodemXXXX C02076     # set (unit restarts)
"""
import sys, time
import serial

def nmea(body):
    cs = 0
    for ch in body[1:]:
        cs ^= ord(ch)
    return f"{body}*{cs:02X}\r\n"

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    port = sys.argv[1]
    addr = sys.argv[2].upper() if len(sys.argv) > 2 else None
    with serial.Serial(port, 115200, timeout=1) as s:
        if addr:
            int(addr, 16)  # validate hex
            s.write(nmea(f"$PSRFA,1,{addr}").encode())
            print(f"sent address {addr}; unit restarts to apply")
            time.sleep(2)
        s.write(nmea("$PSRFA,?").encode())
        end = time.time() + 3
        while time.time() < end:
            line = s.readline().decode("ascii", "replace").strip()
            if line.startswith("$PSRFA,"):
                print("unit reports:", line); return
        print("no $PSRFA reply (is this the aircraft-address firmware?)")

if __name__ == "__main__":
    main()
