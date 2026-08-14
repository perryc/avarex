#!/usr/bin/env python3
"""Post-flight analysis of AvareX reception logs.

Inputs are the CSVs the in-app reception logger writes (IO screen toggle) to
<dataDir>/reception_logs/ on the tablet. Pull them with:

  adb shell 'ls /storage/emulated/0/Android/data/com.apps4av.avaremp/files/reception_logs' 2>/dev/null \
    || adb shell run-as com.apps4av.avaremp ls files/reception_logs
  adb pull <that path> ./flightlogs/

Produces:
  - FIS-B coverage vs altitude: per altitude band, fraction of samples with
    uplink reception, plus max/median range from the ground station
  - Per-band reception rates vs altitude (1090 / 978 ADS-B / 978 FIS-B)
  - Plane-to-plane detection ranges per radio link (ADSBee 1090ES vs SoftRF
    915 FANET arrive on differently named links): first-contact range and
    range distribution per target
  - Optional PNG maps if matplotlib is installed (--plot)

Usage:
  python3 tools/coverage_analyze.py flightlogs/samples_*.csv \
      [--targets flightlogs/targets_*.csv] \
      [--station 51.2647,-102.4614]  # CIFIB station location (default: auto)
      [--bands 3500,5500,7500,9500,11500]  # band edges ft
      [--plot out_prefix]
"""

import argparse
import csv
import math
import sys
from collections import defaultdict
from pathlib import Path


def nm(lat1, lon1, lat2, lon2):
    p = math.pi / 180
    a = (0.5 - math.cos((lat2 - lat1) * p) / 2
         + math.cos(lat1 * p) * math.cos(lat2 * p) * (1 - math.cos((lon2 - lon1) * p)) / 2)
    return 6371 * 2 * math.asin(math.sqrt(a)) * 0.539957


def load(paths):
    rows = []
    for path in paths:
        with open(path) as f:
            rows.extend(csv.DictReader(f))
    return rows


def band_label(alt, edges):
    for i in range(len(edges) - 1):
        if edges[i] <= alt < edges[i + 1]:
            return f"{edges[i]}-{edges[i+1]}ft"
    return f"<{edges[0]}ft" if alt < edges[0] else f">{edges[-1]}ft"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("samples", nargs="+", help="samples_*.csv files")
    ap.add_argument("--targets", nargs="*", default=[], help="targets_*.csv files")
    ap.add_argument("--station", help="FIS-B ground station lat,lon (default: centroid of in-coverage samples)")
    ap.add_argument("--bands", default="3500,5500,7500,9500,11500",
                    help="altitude band edges, ft")
    ap.add_argument("--plot", help="write PNG maps with this filename prefix")
    args = ap.parse_args()

    edges = [int(x) for x in args.bands.split(",")]
    samples = load(args.samples)
    if not samples:
        sys.exit("no samples")
    for s in samples:
        s["alt"] = int(s["alt_ft"])
        s["lat"] = float(s["lat"])
        s["lon"] = float(s["lon"])
        s["fisb"] = int(s.get("frames_978_fisb", 0)) + 0
        s["uplinks"] = int(s["uplinks"])
        s["covered"] = (s["uplinks"] > 0 or s["fisb"] > 0)

    # ---- FIS-B ground station location ------------------------------------
    if args.station:
        slat, slon = (float(x) for x in args.station.split(","))
    else:
        cov = [s for s in samples if s["covered"]]
        if cov:
            slat = sum(s["lat"] for s in cov) / len(cov)
            slon = sum(s["lon"] for s in cov) / len(cov)
            print(f"station auto-estimate (centroid of covered samples): {slat:.4f},{slon:.4f}")
        else:
            slat = slon = None

    # ---- coverage vs altitude ---------------------------------------------
    print("\n=== FIS-B coverage vs altitude ===")
    by_band = defaultdict(list)
    for s in samples:
        by_band[band_label(s["alt"], edges)].append(s)
    for band in sorted(by_band, key=lambda b: min(x["alt"] for x in by_band[b])):
        rows = by_band[band]
        covered = [s for s in rows if s["covered"]]
        frac = len(covered) / len(rows)
        line = f"{band:>16}: {len(rows):5d} samples, coverage {frac*100:5.1f}%"
        if slat is not None and covered:
            ranges = sorted(nm(s["lat"], s["lon"], slat, slon) for s in covered)
            line += (f", range covered: median {ranges[len(ranges)//2]:.1f} nm,"
                     f" max {ranges[-1]:.1f} nm")
        print(line)

    print("\n=== per-band reception rates (frames/s, mean while receiving) ===")
    for band in sorted(by_band, key=lambda b: min(x["alt"] for x in by_band[b])):
        rows = by_band[band]
        def rate(key):
            vals = [int(s.get(key, 0)) for s in rows]
            nz = [v for v in vals if v > 0]
            return f"{(sum(nz)/len(nz)):6.1f}" if nz else "     -"
        print(f"{band:>16}: 1090 {rate('frames_1090')}  978adsb {rate('frames_978')}"
              f"  978fisb {rate('frames_978_fisb')}")

    # ---- plane-to-plane detection ranges ----------------------------------
    targets = load(args.targets) if args.targets else []
    if targets:
        print("\n=== plane-to-plane detection ranges per link ===")
        per = defaultdict(list)  # (link, icao) -> [range nm]
        for t in targets:
            try:
                r = nm(float(t["lat"]), float(t["lon"]), float(t["tlat"]), float(t["tlon"]))
            except ValueError:
                continue
            if r > 400:  # garbage filter (unstuffed-frame parse errors etc.)
                continue
            per[(t["link"], t["icao"])].append(r)
        for (link, icao), ranges in sorted(per.items()):
            ranges.sort()
            print(f"{link:>12} {icao:>6}: {len(ranges):5d} reports, "
                  f"first-contact {ranges[-1]:.1f} nm (max), "
                  f"median {ranges[len(ranges)//2]:.1f} nm, min {ranges[0]:.1f} nm")

    # ---- optional maps -----------------------------------------------------
    if args.plot:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
        except ImportError:
            sys.exit("--plot needs matplotlib (pip install matplotlib)")
        for band, rows in by_band.items():
            fig, ax = plt.subplots(figsize=(8, 8))
            cov = [s for s in rows if s["covered"]]
            no = [s for s in rows if not s["covered"]]
            ax.scatter([s["lon"] for s in no], [s["lat"] for s in no],
                       s=4, c="#cccccc", label="no FIS-B")
            ax.scatter([s["lon"] for s in cov], [s["lat"] for s in cov],
                       s=4, c="#2a6db0", label="FIS-B received")
            if slat is not None:
                ax.plot(slon, slat, "r^", markersize=10, label="station")
            ax.set_title(f"FIS-B coverage {band}")
            ax.legend()
            ax.set_aspect(1 / math.cos(rows[0]["lat"] * math.pi / 180))
            name = f"{args.plot}_{band.replace('>','gt').replace('<','lt')}.png"
            fig.savefig(name, dpi=150, bbox_inches="tight")
            print(f"wrote {name}")


if __name__ == "__main__":
    main()
