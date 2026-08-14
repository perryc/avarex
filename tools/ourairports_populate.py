#!/usr/bin/env python3
"""Assisted population of OurAirports with Canadian airport data.

Finds Canadian airports in OurAirports that lack runway/frequency data,
derives suggested runway values from OpenStreetMap geometry (Overpass API),
and helps submit them to ourairports.com with your member account by
mimicking the website's forms.

Every submission is reviewed and confirmed by you, one airport at a time,
with throttling between posts. This is assistive tooling for your own
contributions, not a bulk importer: for large-scale changes coordinate with
the OurAirports maintainers first.

Data provenance notes:
 - OSM data is ODbL-licensed; treat the derived values as a starting point
   and verify them against satellite imagery or personal knowledge before
   submitting.
 - Do not transcribe the CFS or other Nav Canada publications; they are
   copyrighted and licensed commercially.

Usage:
  python3 tools/ourairports_populate.py --ident CDS2            # one airport
  python3 tools/ourairports_populate.py --near CYYZ --radius 50 # candidates nearby
  python3 tools/ourairports_populate.py --list                  # list candidates only

Login (only needed to submit; suggestions and browser-open work without):
  python3 tools/ourairports_populate.py --ident CDS2 --email you@example.com
"""

import argparse
import csv
import getpass
import http.cookiejar
import io
import json
import math
import re
import sys
import time
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

OA_BASE = "https://ourairports.com"
OA_DATA = "https://davidmegginson.github.io/ourairports-data"
OVERPASS = "https://overpass-api.de/api/interpreter"
CACHE = Path.home() / ".cache" / "ourairports-populate"
THROTTLE_S = 10          # pause between form submissions
MAX_SUBMITS_PER_RUN = 20
UA = "ourairports-populate/1.0 (assisted manual contribution tool)"

FT_PER_M = 3.28084

SURFACE_MAP = {
    "asphalt": "ASP", "concrete": "CON", "grass": "TURF", "turf": "TURF",
    "gravel": "GRE", "dirt": "DIRT", "earth": "DIRT", "sand": "SAND",
    "water": "WATER", "snow": "SNOW", "ice": "ICE", "paved": "ASP",
    "unpaved": "TURF",
}


def fetch(url, data=None, opener=None, headers=None):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, **(headers or {})})
    op = opener.open if opener else urllib.request.urlopen
    with op(req, timeout=60) as r:
        return r.read().decode("utf-8", "replace"), r.geturl()


def load_csv(name):
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / name
    if not path.exists() or time.time() - path.stat().st_mtime > 86400:
        print(f"downloading {name} ...")
        text, _ = fetch(f"{OA_DATA}/{name}")
        path.write_text(text)
    return list(csv.DictReader(io.StringIO(path.read_text())))


def nm(lat1, lon1, lat2, lon2):
    p = math.pi / 180
    a = (0.5 - math.cos((lat2 - lat1) * p) / 2
         + math.cos(lat1 * p) * math.cos(lat2 * p) * (1 - math.cos((lon2 - lon1) * p)) / 2)
    return 6371 * 2 * math.asin(math.sqrt(a)) * 0.539957


def bearing(lat1, lon1, lat2, lon2):
    p = math.pi / 180
    y = math.sin((lon2 - lon1) * p) * math.cos(lat2 * p)
    x = (math.cos(lat1 * p) * math.sin(lat2 * p)
         - math.sin(lat1 * p) * math.cos(lat2 * p) * math.cos((lon2 - lon1) * p))
    return (math.atan2(y, x) / p) % 360


def find_candidates(airports, runways, freqs):
    """Canadian, open, with a real TC code, missing runways or frequencies."""
    have_rwy = {r["airport_ident"] for r in runways if r["closed"] != "1"}
    have_frq = {f["airport_ident"] for f in freqs}
    out = []
    for a in airports:
        if a["iso_country"] != "CA" or a["type"] in ("closed", "heliport", "balloonport"):
            continue
        missing = []
        if a["ident"] not in have_rwy:
            missing.append("runways")
        if a["ident"] not in have_frq:
            missing.append("frequencies")
        if missing:
            out.append((a, missing))
    return out


def osm_runways(lat, lon, radius_m=2500):
    query = (f"[out:json][timeout:20];"
             f"way[aeroway=runway](around:{radius_m},{lat},{lon});out geom;")
    body, _ = fetch(OVERPASS, data=urllib.parse.urlencode({"data": query}).encode())
    suggestions = []
    for way in json.loads(body).get("elements", []):
        geom = way.get("geometry") or []
        if len(geom) < 2:
            continue
        tags = way.get("tags", {})
        p1, p2 = geom[0], geom[-1]
        length_ft = nm(p1["lat"], p1["lon"], p2["lat"], p2["lon"]) * 6076.12
        hdg = bearing(p1["lat"], p1["lon"], p2["lat"], p2["lon"])
        ref = tags.get("ref", "")
        if re.fullmatch(r"\d{2}[LRC]?/\d{2}[LRC]?", ref):
            le_ident, he_ident = ref.split("/")
        else:
            n = round(hdg / 10) % 36 or 36
            le_ident = f"{n:02d}"
            he_ident = f"{(n + 18 - 1) % 36 + 1:02d}"
        width = tags.get("width", "")
        width_ft = ""
        try:
            width_ft = str(round(float(re.sub(r"[^\d.]", "", width)) * FT_PER_M))
        except ValueError:
            pass
        suggestions.append({
            "le_ident": le_ident, "he_ident": he_ident,
            "length_ft": str(round(length_ft)),
            "width_ft": width_ft,
            "surface": SURFACE_MAP.get(tags.get("surface", ""), tags.get("surface", "")).upper(),
            "lighted": "1" if tags.get("lit") == "yes" else "0",
            "le_latitude_deg": f"{p1['lat']:.6f}", "le_longitude_deg": f"{p1['lon']:.6f}",
            "he_latitude_deg": f"{p2['lat']:.6f}", "he_longitude_deg": f"{p2['lon']:.6f}",
            "le_heading_degT": f"{hdg:.0f}", "he_heading_degT": f"{(hdg + 180) % 360:.0f}",
            "note": f"derived from OSM way {way.get('id')} (headings TRUE, idents "
                    f"{'from OSM ref' if ref else 'estimated from true heading - verify magnetic'})",
        })
    return suggestions


def show_suggestions(airport, suggestions):
    code = airport["gps_code"] or airport["local_code"] or airport["ident"]
    print(f"\n=== {code} {airport['name']} ({airport['ident']}) "
          f"{airport['latitude_deg']},{airport['longitude_deg']}")
    print(f"    {OA_BASE}/airports/{airport['ident']}/")
    if not suggestions:
        print("    no OSM runway geometry found nearby")
    for s in suggestions:
        print(f"    RWY {s['le_ident']}/{s['he_ident']}  {s['length_ft']}ft"
              f"{'x' + s['width_ft'] + 'ft' if s['width_ft'] else ''}"
              f"  {s['surface'] or 'surface?'}  {'lighted' if s['lighted'] == '1' else ''}")
        if s["le_latitude_deg"]:
            print(f"      LE {s['le_latitude_deg']},{s['le_longitude_deg']}"
                  f"  HE {s['he_latitude_deg']},{s['he_longitude_deg']}")
        print(f"      {s['note']}")


class Session:
    """Authenticated ourairports.com session mimicking browser form posts."""

    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.logged_in = False

    def login(self, email, password):
        page, _ = fetch(f"{OA_BASE}/login", opener=self.opener)
        fields = parse_form_fields(page, "/actions/login")
        fields.update({"email": email, "password": password})
        body, url = fetch(f"{OA_BASE}/actions/login",
                          data=urllib.parse.urlencode(fields).encode(), opener=self.opener)
        self.logged_in = "/login" not in url and "logout" in body.lower()
        if not self.logged_in:
            print("login failed (check email/password; site may have changed)")
        return self.logged_in

    def submit_runway(self, airport, s):
        """Fetch the airport's runway edit form, prefill from suggestion, post."""
        ident = airport["ident"]
        page, _ = fetch(f"{OA_BASE}/airports/{ident}/runways.html", opener=self.opener)
        m = re.search(r'(?:href|action)="([^"]*runway[^"]*(?:new|add|edit)[^"]*)"', page, re.I) \
            or re.search(r'(?:href|action)="([^"]*(?:new|add|edit)[^"]*runway[^"]*)"', page, re.I)
        if not m:
            print("    could not find a runway edit form (site layout may differ when "
                  "logged in - use [o]pen browser, or run with --dump-form and share "
                  "the output so the script can be adapted)")
            return False
        form_url = urllib.parse.urljoin(f"{OA_BASE}/airports/{ident}/runways.html", m.group(1))
        form_page, form_url = fetch(form_url, opener=self.opener)
        action, fields = parse_form(form_page)
        matched = 0
        for k in list(fields):
            base = k.lower().strip("_")
            for want, val in s.items():
                if want in ("note",):
                    continue
                if base == want or base.replace("deg", "").strip("_") == want.replace("_deg", ""):
                    fields[k] = val
                    matched += 1
        if matched < 3:
            print(f"    form fields did not match suggestions ({matched} matched): "
                  f"{sorted(fields)[:12]}")
            return False
        post_url = urllib.parse.urljoin(form_url, action or "")
        fetch(post_url, data=urllib.parse.urlencode(fields).encode(), opener=self.opener)
        print("    submitted")
        return True


def parse_form(page):
    m = re.search(r'<form[^>]*method="post"[^>]*action="([^"]*)"[^>]*>(.*?)</form>',
                  page, re.I | re.S)
    if not m:
        return None, {}
    return m.group(1), _fields(m.group(2))


def parse_form_fields(page, action_contains):
    m = re.search(r'<form[^>]*action="[^"]*' + re.escape(action_contains)
                  + r'[^"]*"[^>]*>(.*?)</form>', page, re.I | re.S)
    return _fields(m.group(1)) if m else {}


def _fields(form_html):
    fields = {}
    for inp in re.finditer(r"<input[^>]*>", form_html, re.I):
        tag = inp.group(0)
        name = re.search(r'name="([^"]*)"', tag)
        value = re.search(r'value="([^"]*)"', tag)
        if name and "submit" not in tag.lower():
            fields[name.group(1)] = value.group(1) if value else ""
    for sel in re.finditer(r'<select[^>]*name="([^"]*)"', form_html, re.I):
        fields[sel.group(1)] = ""
    for ta in re.finditer(r'<textarea[^>]*name="([^"]*)"', form_html, re.I):
        fields[ta.group(1)] = ""
    return fields


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ident", help="single airport (TC code or OurAirports ident)")
    ap.add_argument("--near", help="center airport code for candidate search")
    ap.add_argument("--region", help="province filter, e.g. SK (iso_region CA-SK)")
    ap.add_argument("--radius", type=float, default=50, help="radius NM for --near")
    ap.add_argument("--list", action="store_true", help="list candidates and exit")
    ap.add_argument("--email", help="ourairports.com member email (enables submission)")
    ap.add_argument("--dump-form", action="store_true",
                    help="print discovered form fields instead of submitting")
    ap.add_argument("--from-json",
                    help="suggestions file from garmin_ocr.py (primary runway source)")
    ap.add_argument("--osm", action="store_true",
                    help="also derive runway geometry suggestions from OpenStreetMap")
    args = ap.parse_args()

    ocr_suggestions = {}
    if args.from_json:
        ocr_suggestions = json.loads(Path(args.from_json).read_text())

    airports = load_csv("airports.csv")
    runways = load_csv("runways.csv")
    freqs = load_csv("airport-frequencies.csv")

    def resolve(code):
        code = code.upper()
        for a in airports:
            if code in (a["ident"].upper(), a["gps_code"].upper(), a["local_code"].upper()):
                return a
        sys.exit(f"airport {code} not found in OurAirports")

    candidates = find_candidates(airports, runways, freqs)
    if args.region:
        candidates = [(a, m) for a, m in candidates
                      if a["iso_region"] == f"CA-{args.region.upper()}"]

    if args.ident:
        a = resolve(args.ident)
        work = [(a, m) for (c, m) in candidates if c is a] or [(a, ["(has data already)"])]
    elif args.near:
        c = resolve(args.near)
        clat, clon = float(c["latitude_deg"]), float(c["longitude_deg"])
        work = sorted(
            ((a, m) for a, m in candidates
             if nm(clat, clon, float(a["latitude_deg"]), float(a["longitude_deg"])) <= args.radius),
            key=lambda t: nm(clat, clon, float(t[0]["latitude_deg"]), float(t[0]["longitude_deg"])))
    else:
        work = candidates

    if args.list or not (args.ident or args.near):
        print(f"{len(work)} Canadian airports missing data:")
        for a, missing in work[:200]:
            code = a["gps_code"] or a["local_code"] or a["ident"]
            print(f"  {code:8} {a['name'][:40]:42} missing: {', '.join(missing)}")
        if len(work) > 200:
            print(f"  ... and {len(work) - 200} more")
        return

    session = None
    if args.email:
        session = Session()
        if not session.login(args.email, getpass.getpass("ourairports.com password: ")):
            session = None

    submitted = 0
    for a, missing in work:
        if submitted >= MAX_SUBMITS_PER_RUN:
            print(f"\nreached {MAX_SUBMITS_PER_RUN} submissions this run; stopping")
            break
        suggestions = osm_runways(float(a["latitude_deg"]), float(a["longitude_deg"])) \
            if args.osm else []
        code = a["gps_code"] or a["local_code"] or a["ident"]
        ocr = ocr_suggestions.get(code) or ocr_suggestions.get(a["ident"]) or {}
        for r in ocr.get("runways", []):
            # OCR gives idents/length/surface; OSM gives geometry - merge when
            # they describe the same runway, else add as endpoint-less entry
            match = next((s for s in suggestions
                          if {s["le_ident"], s["he_ident"]} & {r["le_ident"], r["he_ident"]}),
                         None)
            if match:
                match.update({k: v for k, v in r.items() if v})
                match["note"] += " + garmin ocr"
            else:
                suggestions.append({**{
                    "le_ident": r["le_ident"], "he_ident": r["he_ident"],
                    "length_ft": r.get("length_ft", ""), "width_ft": "",
                    "surface": r.get("surface", ""), "lighted": "0",
                    "le_latitude_deg": "", "le_longitude_deg": "",
                    "he_latitude_deg": "", "he_longitude_deg": "",
                    "le_heading_degT": "", "he_heading_degT": "",
                    "note": "from garmin ocr (no geometry)"}})
        show_suggestions(a, suggestions)
        for f in ocr.get("frequencies", []):
            print(f"    OCR FREQ: {f['type']} {f['frequency_mhz']}")
        print(f"    missing: {', '.join(missing)}")
        for s in suggestions:
            prompt = "[s]ubmit / [o]pen browser / s[k]ip / [q]uit: " if session \
                else "[o]pen browser / s[k]ip / [q]uit (login with --email to submit): "
            choice = input(f"  RWY {s['le_ident']}/{s['he_ident']} -> {prompt}").strip().lower()
            if choice == "q":
                return
            if choice == "o":
                webbrowser.open(f"{OA_BASE}/airports/{a['ident']}/")
            elif choice == "s" and session:
                if session.submit_runway(a, s):
                    submitted += 1
                    time.sleep(THROTTLE_S)
        if not suggestions:
            choice = input("  [o]pen browser / s[k]ip / [q]uit: ").strip().lower()
            if choice == "q":
                return
            if choice == "o":
                webbrowser.open(f"{OA_BASE}/airports/{a['ident']}/")


if __name__ == "__main__":
    main()
