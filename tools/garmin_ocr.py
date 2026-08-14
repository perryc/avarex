#!/usr/bin/env python3
"""Extract airport data from photos/video of Garmin airport info pages.

Point a camera at the Garmin (or use its screenshot feature), page through
the Waypoint/Airport Info screens, then run this tool on the captures. It
extracts frames (for video), OCRs them with tesseract, and parses runway
and frequency values into a JSON file of suggestions that
ourairports_populate.py can review/submit with --from-json.

Note on provenance: the Garmin navigation database is a licensed product
(Garmin/Jeppesen). Use these captures to jog your own verification -
cross-check values against imagery or personal knowledge before publishing
them to OurAirports, and don't bulk-transcribe the database.

Usage:
  python3 tools/garmin_ocr.py IMG_1234.jpg IMG_1235.jpg -o suggestions.json
  python3 tools/garmin_ocr.py garmin_pages.mp4 -o suggestions.json
  python3 tools/garmin_ocr.py --debug IMG_1234.jpg     # show raw OCR text
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

VIDEO_EXT = {".mp4", ".mov", ".m4v", ".avi"}

# CYYZ style identifier on the page
IDENT_RE = re.compile(r"\b(C[A-Z0-9]{3})\b")
# 118.35 style VHF frequency with a label somewhere before it
FREQ_RE = re.compile(
    r"(TOWER|TWR|GROUND|GND|ATIS|AWOS|ASOS|UNICOM|CTAF|MF|ATF|CLEARANCE|CLNC|"
    r"APPROACH|APP|DEPARTURE|DEP|CENTER|CTR|RADIO|FSS)[^\d]{0,12}"
    r"(1[123][0-9]\.\d{1,3})", re.I)
# 13/31 4300FT x 75FT or similar runway lines
RWY_RE = re.compile(
    r"\b(\d{2}[LRC]?)\s*/\s*(\d{2}[LRC]?)\b[^\n]{0,40}?(\d{3,5})\s*(?:FT|')",
    re.I)
SURFACE_RE = re.compile(r"\b(HARD|ASPHALT|CONCRETE|TURF|GRASS|GRAVEL|DIRT|WATER)\b", re.I)

FREQ_LABEL_MAP = {
    "TOWER": "TWR", "TWR": "TWR", "GROUND": "GND", "GND": "GND",
    "ATIS": "ATIS", "AWOS": "AWOS", "ASOS": "ASOS", "UNICOM": "UNIC",
    "CTAF": "CTAF", "MF": "MF", "ATF": "ATF", "CLEARANCE": "CLD", "CLNC": "CLD",
    "APPROACH": "APP", "APP": "APP", "DEPARTURE": "DEP", "DEP": "DEP",
    "CENTER": "CNTR", "CTR": "CNTR", "RADIO": "RDO", "FSS": "FSS",
}
SURFACE_MAP = {"HARD": "ASP", "ASPHALT": "ASP", "CONCRETE": "CON",
               "TURF": "TURF", "GRASS": "TURF", "GRAVEL": "GRE",
               "DIRT": "DIRT", "WATER": "WATER"}


def extract_frames(video, outdir):
    # one frame every 2 seconds is plenty for page-through footage
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(video),
         "-vf", "fps=1/2", str(outdir / "frame_%04d.png")],
        check=True)
    return sorted(outdir.glob("frame_*.png"))


def ocr(image):
    r = subprocess.run(
        ["tesseract", str(image), "stdout", "--psm", "6"],
        capture_output=True, text=True)
    return r.stdout


def parse_page(text):
    """One OCR'd screen -> (ident or None, runways, frequencies)."""
    ident = None
    m = IDENT_RE.search(text)
    if m:
        ident = m.group(1)
    freqs = []
    for fm in FREQ_RE.finditer(text):
        label = FREQ_LABEL_MAP.get(fm.group(1).upper(), fm.group(1).upper())
        freqs.append({"type": label, "frequency_mhz": fm.group(2)})
    runways = []
    for rm in RWY_RE.finditer(text):
        sm = SURFACE_RE.search(text)
        runways.append({
            "le_ident": rm.group(1).upper(), "he_ident": rm.group(2).upper(),
            "length_ft": rm.group(3),
            "surface": SURFACE_MAP.get(sm.group(1).upper(), "") if sm else "",
        })
    return ident, runways, freqs


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("captures", nargs="+", help="images and/or videos of Garmin pages")
    ap.add_argument("-o", "--out", default="suggestions.json")
    ap.add_argument("--debug", action="store_true", help="print raw OCR text per frame")
    args = ap.parse_args()

    images = []
    tmp = Path(tempfile.mkdtemp(prefix="garmin_ocr_"))
    for c in args.captures:
        p = Path(c)
        if not p.exists():
            sys.exit(f"{c}: not found")
        if p.suffix.lower() in VIDEO_EXT:
            images.extend(extract_frames(p, tmp))
        else:
            images.append(p)

    by_ident = {}
    current = None
    for img in images:
        text = ocr(img)
        if args.debug:
            print(f"----- {img}\n{text}")
        ident, runways, freqs = parse_page(text)
        if ident:
            current = ident
        if current is None:
            continue
        entry = by_ident.setdefault(current, {"runways": [], "frequencies": []})
        for r in runways:
            if r not in entry["runways"]:
                entry["runways"].append(r)
        for f in freqs:
            if f not in entry["frequencies"]:
                entry["frequencies"].append(f)

    for ident, entry in by_ident.items():
        print(f"{ident}: {len(entry['runways'])} runways, "
              f"{len(entry['frequencies'])} frequencies")
        for r in entry["runways"]:
            print(f"  RWY {r['le_ident']}/{r['he_ident']} {r['length_ft']}ft {r['surface']}")
        for f in entry["frequencies"]:
            print(f"  {f['type']} {f['frequency_mhz']}")

    Path(args.out).write_text(json.dumps(by_ident, indent=2))
    print(f"\nwrote {args.out} - review it, then feed to ourairports_populate.py "
          f"--from-json {args.out}")


if __name__ == "__main__":
    main()
