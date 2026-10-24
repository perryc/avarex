#!/usr/bin/env python3
"""Visual review of proposed runway data before it goes to OurAirports.

For each candidate airport this opens a satellite view centred on the field, draws
the runway we are proposing to submit on top of the imagery, and lets you accept,
edit or reject it. Edits are made by dragging the two runway ends onto what you can
actually see; length, true heading and the magnetic runway numbers recompute as you
drag.

That drag is the point of the tool. A value derived from OpenStreetMap is ODbL and
cannot simply be copied into OurAirports, which is public domain. Once you have
positioned the ends against imagery yourself the submitted figure is your own
measurement, and the provenance recorded in the output says so.

Decisions are written to a JSON file that ourairports_populate.py reads back with
--decisions, so nothing is submitted from here.

Usage:
  python3 tools/runway_review.py --region SK --ppa --osm
  python3 tools/runway_review.py --ident CJA7 --osm --out decisions.json
  python3 tools/runway_review.py --region SK --from-json garmin.json

Imagery is Esri World Imagery, the same basemap the app uses. Review is a local
page; nothing is uploaded.
"""

import argparse
import json
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ourairports_populate as op  # noqa: E402  (same directory, intentional)

PORT = 8787
PAGE = Path(__file__).with_name("runway_review.html")


def build_jobs(args):
    """One entry per airport: its position, declination and proposed runways."""
    ocr = json.loads(Path(args.from_json).read_text()) if args.from_json else {}
    airports = op.load_csv("airports.csv")
    runways = op.load_csv("runways.csv")
    freqs = op.load_csv("airport-frequencies.csv")
    candidates = op.find_candidates(airports, runways, freqs)
    if args.region:
        candidates = [(a, m) for a, m in candidates
                      if a["iso_region"] == f"CA-{args.region.upper()}"]
    if args.ident:
        want = args.ident.upper()
        candidates = [(a, m) for a, m in candidates
                      if want in (a["ident"].upper(), a["gps_code"].upper(),
                                  a["local_code"].upper())]
    # Only airports actually missing runways are reviewable here.
    candidates = [(a, m) for a, m in candidates if "runways" in m]

    jobs = []
    for a, missing in candidates[:args.limit]:
        lat, lon = float(a["latitude_deg"]), float(a["longitude_deg"])
        code = a["gps_code"] or a["local_code"] or a["ident"]
        sug = []
        if args.ppa:
            try:
                sug = op.ppa_runways(code)
            except Exception as e:
                print(f"  {code}: ppa_airports lookup failed ({e})")
        # Surveyed runways win; tracing is only the fallback where there is no survey.
        if not sug and args.osm:
            try:
                sug = op.osm_runways(lat, lon)
            except Exception as e:                      # Overpass is flaky; keep going
                print(f"  {code}: overpass failed ({e}) - review with no proposal")
        for r in (ocr.get(code) or ocr.get(a["ident"]) or {}).get("runways", []):
            if not any({s["le_ident"], s["he_ident"]} & {r["le_ident"], r["he_ident"]}
                       for s in sug):
                sug.append({**{k: "" for k in (
                    "width_ft", "le_latitude_deg", "le_longitude_deg",
                    "he_latitude_deg", "he_longitude_deg")},
                    "le_ident": r["le_ident"], "he_ident": r["he_ident"],
                    "length_ft": r.get("length_ft", ""), "surface": r.get("surface", ""),
                    "lighted": "0", "note": "from garmin ocr (no geometry)"})
        jobs.append({
            "code": code, "ident": a["ident"], "name": a["name"],
            "lat": lat, "lon": lon, "missing": missing,
            # One declination per airport: it varies by far less than a runway
            # number over the span of a single field.
            "variation": round(op.magnetic_declination(lat, lon), 2),
            "runways": sug,
            "oa_url": f"{op.OA_BASE}/airports/{a['ident']}/",
        })
        print(f"  {code:8s} {len(sug)} proposed runway(s)")
    return jobs


class Handler(BaseHTTPRequestHandler):
    jobs = []
    out_path = Path("runway_decisions.json")
    decisions = []
    done = threading.Event()

    def log_message(self, *a):
        pass                                            # quiet; we print our own

    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, PAGE.read_text(), "text/html; charset=utf-8")
        elif self.path == "/jobs":
            self._send(200, json.dumps(Handler.jobs))
        else:
            self._send(404, "{}")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        payload = json.loads(self.rfile.read(n) or "{}")
        if self.path == "/decision":
            Handler.decisions.append(payload)
            Handler.out_path.write_text(json.dumps(Handler.decisions, indent=2))
            d = payload.get("decision")
            print(f"  {payload.get('code'):8s} {d}"
                  f"{' (edited)' if payload.get('edited') else ''}")
            self._send(200, '{"ok":true}')
        elif self.path == "/done":
            self._send(200, '{"ok":true}')
            Handler.done.set()
        else:
            self._send(404, "{}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ident", help="review a single airport")
    ap.add_argument("--region", help="province filter, e.g. SK")
    ap.add_argument("--ppa", action="store_true",
                    help="propose RTK/PPP surveyed runways from the ppa_airports repo")
    ap.add_argument("--osm", action="store_true",
                    help="propose runway geometry from OpenStreetMap")
    ap.add_argument("--from-json", help="suggestions from garmin_ocr.py")
    ap.add_argument("--limit", type=int, default=50, help="max airports per session")
    ap.add_argument("--out", default="runway_decisions.json",
                    help="where accepted/edited runways are written")
    args = ap.parse_args()

    if not PAGE.exists():
        sys.exit(f"missing {PAGE.name} (it ships next to this script)")

    print("building review list ...")
    jobs = build_jobs(args)
    if not jobs:
        sys.exit("nothing to review")

    Handler.jobs = jobs
    Handler.out_path = Path(args.out)
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{PORT}/"
    print(f"\nreviewing {len(jobs)} airport(s) at {url}")
    print("drag the runway ends onto the imagery; close the page or press Done when finished")
    webbrowser.open(url)
    try:
        Handler.done.wait()
    except KeyboardInterrupt:
        pass
    server.shutdown()
    kept = [d for d in Handler.decisions if d.get("decision") == "accept"]
    print(f"\n{len(kept)} accepted of {len(Handler.decisions)} reviewed "
          f"-> {Handler.out_path}")
    print("submit them with:  python3 tools/ourairports_populate.py "
          f"--decisions {Handler.out_path} --email you@example.com")


if __name__ == "__main__":
    main()
