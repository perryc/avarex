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
import datetime
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
PPA_TREE = "https://api.github.com/repos/perryc/ppa_airports/git/trees/main?recursive=1"
PPA_RAW = "https://raw.githubusercontent.com/perryc/ppa_airports/main"
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


# --- World Magnetic Model (WMM2025) -----------------------------------------
# Runway numbers are MAGNETIC, but a runway traced from map geometry gives a TRUE
# heading, and the two differ by the local magnetic variation - about 10 deg E across
# Saskatchewan, which is a whole runway number. Cudworth proved it: its OSM ref says
# 08/26 while the uncorrected true heading gives 09/27.
#
# Coefficients are NOAA's official WMM.COF for 2025.0-2030.0 (US government work,
# public domain). Embedded so the tool stays stdlib-only and works offline. This
# implementation reproduces all 100 points in NOAA's WMM2025_TestValues.txt to
# within 0.005 deg.
WMM_EPOCH_VALID_UNTIL = 2030.0
WMM_COF = """\
2025.0            WMM-2025     11/13/2024
  1  0  -29351.8       0.0       12.0        0.0
  1  1   -1410.8    4545.4        9.7      -21.5
  2  0   -2556.6       0.0      -11.6        0.0
  2  1    2951.1   -3133.6       -5.2      -27.7
  2  2    1649.3    -815.1       -8.0      -12.1
  3  0    1361.0       0.0       -1.3        0.0
  3  1   -2404.1     -56.6       -4.2        4.0
  3  2    1243.8     237.5        0.4       -0.3
  3  3     453.6    -549.5      -15.6       -4.1
  4  0     895.0       0.0       -1.6        0.0
  4  1     799.5     278.6       -2.4       -1.1
  4  2      55.7    -133.9       -6.0        4.1
  4  3    -281.1     212.0        5.6        1.6
  4  4      12.1    -375.6       -7.0       -4.4
  5  0    -233.2       0.0        0.6        0.0
  5  1     368.9      45.4        1.4       -0.5
  5  2     187.2     220.2        0.0        2.2
  5  3    -138.7    -122.9        0.6        0.4
  5  4    -142.0      43.0        2.2        1.7
  5  5      20.9     106.1        0.9        1.9
  6  0      64.4       0.0       -0.2        0.0
  6  1      63.8     -18.4       -0.4        0.3
  6  2      76.9      16.8        0.9       -1.6
  6  3    -115.7      48.8        1.2       -0.4
  6  4     -40.9     -59.8       -0.9        0.9
  6  5      14.9      10.9        0.3        0.7
  6  6     -60.7      72.7        0.9        0.9
  7  0      79.5       0.0       -0.0        0.0
  7  1     -77.0     -48.9       -0.1        0.6
  7  2      -8.8     -14.4       -0.1        0.5
  7  3      59.3      -1.0        0.5       -0.8
  7  4      15.8      23.4       -0.1        0.0
  7  5       2.5      -7.4       -0.8       -1.0
  7  6     -11.1     -25.1       -0.8        0.6
  7  7      14.2      -2.3        0.8       -0.2
  8  0      23.2       0.0       -0.1        0.0
  8  1      10.8       7.1        0.2       -0.2
  8  2     -17.5     -12.6        0.0        0.5
  8  3       2.0      11.4        0.5       -0.4
  8  4     -21.7      -9.7       -0.1        0.4
  8  5      16.9      12.7        0.3       -0.5
  8  6      15.0       0.7        0.2       -0.6
  8  7     -16.8      -5.2       -0.0        0.3
  8  8       0.9       3.9        0.2        0.2
  9  0       4.6       0.0       -0.0        0.0
  9  1       7.8     -24.8       -0.1       -0.3
  9  2       3.0      12.2        0.1        0.3
  9  3      -0.2       8.3        0.3       -0.3
  9  4      -2.5      -3.3       -0.3        0.3
  9  5     -13.1      -5.2        0.0        0.2
  9  6       2.4       7.2        0.3       -0.1
  9  7       8.6      -0.6       -0.1       -0.2
  9  8      -8.7       0.8        0.1        0.4
  9  9     -12.9      10.0       -0.1        0.1
 10  0      -1.3       0.0        0.1        0.0
 10  1      -6.4       3.3        0.0        0.0
 10  2       0.2       0.0        0.1       -0.0
 10  3       2.0       2.4        0.1       -0.2
 10  4      -1.0       5.3       -0.0        0.1
 10  5      -0.6      -9.1       -0.3       -0.1
 10  6      -0.9       0.4        0.0        0.1
 10  7       1.5      -4.2       -0.1        0.0
 10  8       0.9      -3.8       -0.1       -0.1
 10  9      -2.7       0.9       -0.0        0.2
 10 10      -3.9      -9.1       -0.0       -0.0
 11  0       2.9       0.0        0.0        0.0
 11  1      -1.5       0.0       -0.0       -0.0
 11  2      -2.5       2.9        0.0        0.1
 11  3       2.4      -0.6        0.0       -0.0
 11  4      -0.6       0.2        0.0        0.1
 11  5      -0.1       0.5       -0.1       -0.0
 11  6      -0.6      -0.3        0.0       -0.0
 11  7      -0.1      -1.2       -0.0        0.1
 11  8       1.1      -1.7       -0.1       -0.0
 11  9      -1.0      -2.9       -0.1        0.0
 11 10      -0.2      -1.8       -0.1        0.0
 11 11       2.6      -2.3       -0.1        0.0
 12  0      -2.0       0.0        0.0        0.0
 12  1      -0.2      -1.3        0.0       -0.0
 12  2       0.3       0.7       -0.0        0.0
 12  3       1.2       1.0       -0.0       -0.1
 12  4      -1.3      -1.4       -0.0        0.1
 12  5       0.6      -0.0       -0.0       -0.0
 12  6       0.6       0.6        0.1       -0.0
 12  7       0.5      -0.1       -0.0       -0.0
 12  8      -0.1       0.8        0.0        0.0
 12  9      -0.4       0.1        0.0       -0.0
 12 10      -0.2      -1.0       -0.1       -0.0
 12 11      -1.3       0.1       -0.0        0.0
 12 12      -0.7       0.2       -0.1       -0.1
"""

_A_WGS84 = 6378137.0
_E2 = (1 / 298.257223563) * (2 - 1 / 298.257223563)
_RE = 6371200.0          # geomagnetic reference radius (m)
_NMAX = 12
_wmm_cache = None


def _wmm_coefficients():
    global _wmm_cache
    if _wmm_cache is None:
        epoch, g, h, dg, dh = None, {}, {}, {}, {}
        for line in WMM_COF.strip().splitlines():
            p = line.split()
            if len(p) == 3:
                epoch = float(p[0])
                continue
            if len(p) != 6:
                continue
            n, m = int(p[0]), int(p[1])
            g[(n, m)], h[(n, m)] = float(p[2]), float(p[3])
            dg[(n, m)], dh[(n, m)] = float(p[4]), float(p[5])
        _wmm_cache = (epoch, g, h, dg, dh)
    return _wmm_cache


def _legendre(theta):
    """Schmidt semi-normalised P[n][m](cos theta) and dP/dtheta."""
    c, s = math.cos(theta), math.sin(theta)
    P = [[0.0] * (_NMAX + 1) for _ in range(_NMAX + 1)]
    dP = [[0.0] * (_NMAX + 1) for _ in range(_NMAX + 1)]
    P[0][0] = 1.0
    for n in range(1, _NMAX + 1):
        for m in range(0, n + 1):
            if m == n:
                if n == 1:
                    P[1][1], dP[1][1] = s, c
                else:
                    f = math.sqrt((2 * n - 1) / (2 * n))
                    P[n][n] = s * P[n - 1][n - 1] * f
                    dP[n][n] = (c * P[n - 1][n - 1] + s * dP[n - 1][n - 1]) * f
            else:
                k = math.sqrt((n - 1) ** 2 - m * m) if n - 2 >= m else 0.0
                p2 = P[n - 2][m] if n - 2 >= m else 0.0
                d2 = dP[n - 2][m] if n - 2 >= m else 0.0
                d = math.sqrt(n * n - m * m)
                P[n][m] = ((2 * n - 1) * c * P[n - 1][m] - k * p2) / d
                dP[n][m] = ((2 * n - 1) * (c * dP[n - 1][m] - s * P[n - 1][m]) - k * d2) / d
    return P, dP


def magnetic_declination(lat, lon, year=None):
    """Magnetic variation in degrees, east positive. Sea level is fine for runways."""
    epoch, g0, h0, dg, dh = _wmm_coefficients()
    if year is None:
        now = datetime.datetime.now(datetime.timezone.utc)
        year = now.year + (now.timetuple().tm_yday - 1) / 365.25
    t = year - epoch
    lat_r, lon_r = math.radians(lat), math.radians(lon)
    sp, cp = math.sin(lat_r), math.cos(lat_r)
    rc = _A_WGS84 / math.sqrt(1 - _E2 * sp * sp)
    p, z = rc * cp, rc * (1 - _E2) * sp
    r = math.hypot(p, z)
    lat_gc = math.asin(z / r)
    theta = math.pi / 2 - lat_gc
    P, dP = _legendre(theta)
    st = math.sin(theta)
    x = y = zf = 0.0
    for n in range(1, _NMAX + 1):
        f = (_RE / r) ** (n + 2)
        for m in range(0, n + 1):
            gc = g0[(n, m)] + t * dg[(n, m)]
            hc = h0[(n, m)] + t * dh[(n, m)]
            cm, sm = math.cos(m * lon_r), math.sin(m * lon_r)
            x += f * (gc * cm + hc * sm) * dP[n][m]
            zf -= f * (n + 1) * (gc * cm + hc * sm) * P[n][m]
            if st != 0.0:
                y += f * m * (gc * sm - hc * cm) * P[n][m] / st
    d = lat_gc - lat_r
    xg = x * math.cos(d) - zf * math.sin(d)
    return math.degrees(math.atan2(y, xg))


def runway_idents(true_heading, lat, lon):
    """(le, he, magnetic heading, variation) for a runway on this true heading."""
    var = magnetic_declination(lat, lon)
    mag = (true_heading - var) % 360.0
    n = round(mag / 10) % 36 or 36
    return f"{n:02d}", f"{(n + 18 - 1) % 36 + 1:02d}", mag, var


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
        le_mag, he_mag, mag, var = runway_idents(hdg, p1["lat"], p1["lon"])
        if re.fullmatch(r"\d{2}[LRC]?/\d{2}[LRC]?", ref):
            le_ident, he_ident = ref.split("/")
            ident_note = "from OSM ref"
            if {le_ident, he_ident} & {le_mag, he_mag} == set():
                ident_note += f" (DISAGREES with magnetic estimate {le_mag}/{he_mag} - check)"
        else:
            le_ident, he_ident = le_mag, he_mag
            ident_note = (f"estimated from magnetic heading {mag:.0f} "
                          f"(true {hdg:.0f}, var {var:+.1f})")
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
            # le/he_heading_degT stay TRUE - that is what the OurAirports column means.
            "note": f"derived from OSM way {way.get('id')} (headings TRUE, idents {ident_note})",
        })
    return suggestions



_ppa_index = None


def ppa_index():
    """Map of airport code -> path in the ppa_airports survey repo."""
    global _ppa_index
    if _ppa_index is None:
        CACHE.mkdir(parents=True, exist_ok=True)
        path = CACHE / "ppa_tree.json"
        if not path.exists() or time.time() - path.stat().st_mtime > 3600:
            body, _ = fetch(PPA_TREE)
            path.write_text(body)
        tree = json.loads(path.read_text()).get("tree", [])
        _ppa_index = {Path(t["path"]).stem.upper(): t["path"]
                      for t in tree
                      if t["type"] == "blob" and t["path"].startswith("airports/")
                      and t["path"].endswith(".json")}
    return _ppa_index


def ppa_runways(code):
    """Runway suggestions from the ppa_airports RTK/PPP survey repo.

    These are measured on the ground, not traced from a map, so they need no
    imagery verification for provenance - but they are still worth eyeballing,
    because a survey can carry its own mistakes (see the magnetic cross-check
    below). Designations come from the file; we recompute the magnetic heading
    with WMM and flag any disagreement rather than trusting either blindly.
    """
    rel = ppa_index().get(code.upper())
    if not rel:
        return []
    body, _ = fetch(f"{PPA_RAW}/{urllib.parse.quote(rel)}")
    data = json.loads(body)
    out = []
    for r in data.get("runways", []):
        t1, t2 = r.get("threshold1") or {}, r.get("threshold2") or {}
        if not (t1.get("latitude") and t2.get("latitude")):
            continue
        hdg = bearing(t1["latitude"], t1["longitude"], t2["latitude"], t2["longitude"])
        le_mag, he_mag, mag, var = runway_idents(hdg, t1["latitude"], t1["longitude"])
        des = str(r.get("designation", "")).strip()
        if re.fullmatch(r"\d{2}[LRC]?/\d{2}[LRC]?", des):
            le_ident, he_ident = des.split("/")
            note_ident = "designation from survey"
            if {le_ident, he_ident} & {le_mag, he_mag} == set():
                note_ident += f" (DISAGREES with magnetic estimate {le_mag}/{he_mag} - check)"
        else:
            le_ident, he_ident = le_mag, he_mag
            note_ident = f"designation computed from magnetic {mag:.0f}"
        sm = r.get("survey_metadata", {}) or {}
        acc = [c.get("accuracy_m") for c in sm.get("corner_points", []) if c.get("accuracy_m") is not None]
        surface = str(r.get("surface", "") or "")
        out.append({
            "le_ident": le_ident, "he_ident": he_ident,
            "length_ft": str(round(float(r["length_ft"]))) if r.get("length_ft") else "",
            "width_ft": str(round(float(r["width_ft"]))) if r.get("width_ft") else "",
            "surface": "" if surface.lower() in ("", "unknown") else SURFACE_MAP.get(surface.lower(), surface).upper(),
            "lighted": "1" if r.get("lighted") else "0",
            "le_latitude_deg": f"{t1['latitude']:.7f}", "le_longitude_deg": f"{t1['longitude']:.7f}",
            "he_latitude_deg": f"{t2['latitude']:.7f}", "he_longitude_deg": f"{t2['longitude']:.7f}",
            "le_heading_degT": f"{hdg:.0f}", "he_heading_degT": f"{(hdg + 180) % 360:.0f}",
            "le_elevation_ft": str(t1.get("elevation_ft", "") or ""),
            "he_elevation_ft": str(t2.get("elevation_ft", "") or ""),
            "note": (f"ppa_airports survey ({sm.get('survey_method', 'survey')}, "
                     f"{len(acc)} corners, accuracy {min(acc):.2f}-{max(acc):.2f} m); "
                     f"{note_ident}" if acc else
                     f"ppa_airports survey; {note_ident}"),
        })
    return out


def ask(prompt_text, valid=("s", "o", "k", "q")):
    """Prompt until a real answer arrives.

    An empty line used to count as "skip", so a stray newline left in stdin - which a
    pasted command regularly leaves behind - silently skipped the first runway. Three
    separate runs lost RWY 11/29 that way. Re-ask instead.
    """
    while True:
        try:
            choice = input(prompt_text).strip().lower()
        except EOFError:
            return "q"
        if choice in valid:
            return choice
        if choice == "":
            continue                      # stray newline, not an answer
        print(f"    please answer one of: {', '.join(valid)}")

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
        print(f"      {s.get('note', 'no source note')}")


class Session:
    """Authenticated ourairports.com session mimicking browser form posts."""

    def __init__(self, dump_form=False):
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.logged_in = False
        self.dump_form = dump_form

    def login(self, email, password):
        """Post the site's real login form.

        The field is `username`, not `email` - the form labels it "Username or email"
        and accepts either, but the input name is `username`. Sending `email` left the
        username blank and every attempt failed with no useful message. The form also
        carries a hidden `from` field, so start from the parsed form and only fill in
        the credentials rather than inventing the payload.
        """
        page, _ = fetch(f"{OA_BASE}/login", opener=self.opener)
        fields = parse_form_fields(page, "/actions/login")
        if "username" not in fields:
            print("login: could not find the username field on /login - "
                  "the form has changed - the login page no longer exposes `username`")
            return False
        fields["username"] = email
        fields["password"] = password
        body, url = fetch(f"{OA_BASE}/actions/login",
                          data=urllib.parse.urlencode(fields).encode(), opener=self.opener)
        low = body.lower()
        self.logged_in = "/login" not in url and ("logout" in low or "log out" in low)
        if not self.logged_in:
            # Surface what the site actually said instead of a generic failure.
            msg = re.search(r'class="alert[^"]*"[^>]*>(.*?)</div>', body, re.S | re.I)
            detail = re.sub(r"<[^>]+>", " ", msg.group(1)).strip() if msg else ""
            detail = re.sub(r"\s+", " ", detail)[:160]
            print(f"login failed{': ' + detail if detail else ''} (landed on {url})")
        return self.logged_in


    def submit_frequency(self, airport, freq_mhz, ftype="CTAF", description="CTAF"):
        """Add one radio frequency, mirroring the create-runway flow.

        The CSV columns are id, airport_ref, airport_ident, type, description,
        frequency_mhz, so the form is expected to use airportRef / type /
        description / frequency_mhz. That is an expectation, not knowledge: if the
        real field names differ this dumps the form and refuses rather than posting a
        payload the server would silently discard, which is exactly how the first
        runway submission vanished.
        """
        ident = airport["ident"]
        live = f"{OA_BASE}/airports/{ident}/frequencies.html?v={int(time.time())}"
        page, _ = fetch(live, opener=self.opener)
        if self.dump_form:
            self.describe(page, live)

        shown = re.sub(r"<[^>]+>", " ", page)
        if freq_mhz and freq_mhz in shown:
            print(f"    {freq_mhz} is ALREADY listed for this airport - skipping")
            return False

        hrefs = [x.group(1) for x in re.finditer(r'href="([^"]*)"', page, re.I)]
        banned = re.compile(r"edit-frequency|update-frequency|delete-frequency|remove", re.I)
        link = next((h for h in hrefs if re.search(r"create-frequency", h, re.I)), None)
        if not link:
            link = next((h for h in hrefs
                         if re.search(r"(?:create|new|add)[-_]?frequency", h, re.I)
                         and not banned.search(h)), None)
        if not link:
            print("    could not find the add-frequency link on the logged-in page - "
                  "use [o]pen browser, or re-run with --dump-form")
            return False

        form_url = urllib.parse.urljoin(f"{OA_BASE}/airports/{ident}/frequencies.html", link)
        form_page, form_url = fetch(form_url, opener=self.opener)
        if self.dump_form:
            self.describe(form_page, form_url)
            print("    --dump-form: not submitting the frequency.")
            return False

        action, fields = parse_form(form_page, "create-frequency")
        if not fields:
            print(f"    no create-frequency form found at {form_url}")
            for f in re.finditer(r"<form\b([^>]*)>", form_page, re.I):
                print(f"      <form {re.sub(r'\s+', ' ', f.group(1)).strip()[:120]}>")
            return False
        if "airportRef" in fields and not fields["airportRef"]:
            fields["airportRef"] = airport.get("id", "")
            if not fields["airportRef"]:
                print("    airportRef blank and no id - refusing to post an orphan frequency")
                return False
        for key, val in (("type", ftype), ("description", description),
                         ("frequency_mhz", freq_mhz)):
            if key not in fields:
                print(f"    the form has no `{key}` field - refusing to guess. "
                      f"fields present: {sorted(fields)}")
                return False
            fields[key] = val

        print(f"    posting to {action}: " + ", ".join(
            f"{k}={fields[k]}" for k in sorted(fields) if fields.get(k) and k != "id"))
        body, landed = fetch(urllib.parse.urljoin(form_url, action or ""),
                             data=urllib.parse.urlencode(fields).encode(), opener=self.opener)
        if "create-frequency" in landed:
            err = re.search(r'class="alert[^"]*"[^>]*>(.*?)</div>', body, re.S | re.I)
            detail = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", err.group(1))).strip()[:160] if err else ""
            print(f"    NOT accepted - still on the form{': ' + detail if detail else ''}")
            return False
        check, _ = fetch(f"{OA_BASE}/airports/{ident}/frequencies.html?v={int(time.time())}",
                         opener=self.opener)
        if freq_mhz in re.sub(r"<[^>]+>", " ", check):
            print(f"    frequency submitted and confirmed on the page ({freq_mhz})")
            return True
        print(f"    posted (landed {landed}) but {freq_mhz} is NOT on the frequencies page "
              "yet - treat as unconfirmed")
        return False

    @staticmethod
    def describe(page, url):
        """Print the page's links and form structure so the real edit path can be found.

        Only names and hrefs - never input VALUES, which on a logged-in page can carry
        the account's own details.
        """
        print(f"\n--- dump-form: {url}")
        hrefs = []
        for m in re.finditer(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', page, re.S | re.I):
            href = m.group(1)
            text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", m.group(2))).strip()
            if re.search(r"runway|edit|add|new|update|fix", href + " " + text, re.I):
                hrefs.append((text[:40], href))
        print(f"    {len(hrefs)} candidate link(s):")
        for text, href in dict.fromkeys(hrefs):
            print(f"      {text:42s} -> {href}")
        forms = list(re.finditer(r"<form[^>]*>(.*?)</form>", page, re.S | re.I))
        print(f"    {len(forms)} form(s):")
        for f in forms:
            tag = f.group(0)[:f.group(0).find(">") + 1]
            print(f"      {re.sub(r'\s+', ' ', tag).strip()[:150]}")
            names = re.findall(r'<(?:input|select|textarea)[^>]*name="([^"]+)"', f.group(1), re.I)
            if names:
                print(f"         fields: {', '.join(dict.fromkeys(names))}")
        print("--- end dump-form\n")

    def submit_runway(self, airport, s):
        """Fetch the airport's runway edit form, prefill from suggestion, post."""
        ident = airport["ident"]
        # Cache-bust. These pages carry cache-control: max-age=86400, so the plain URL
        # returns a copy that can be a day old - it will still say "No runway
        # information" for an airport fixed this morning, which would defeat the
        # duplicate guard below and make the post-submit read-back lie.
        live = f"{OA_BASE}/airports/{ident}/runways.html?v={int(time.time())}"
        page, _ = fetch(live, opener=self.opener)
        if self.dump_form:
            self.describe(page, live)

        # DUPLICATE GUARD. The candidate list comes from the daily CSV dump, which lags
        # today's edits by up to a day, and the local copy of it is cached for another
        # 24 h on top. So an airport we fixed this morning still looks "missing runways"
        # this afternoon. This page is live, and we are already fetching it - ask it.
        pair = f"{s.get('le_ident', '')}-{s.get('he_ident', '')}"
        rev = f"{s.get('he_ident', '')}-{s.get('le_ident', '')}"
        shown = re.sub(r"<[^>]+>", " ", page)
        if pair.strip("-") and (pair in shown or rev in shown):
            print(f"    {pair} is ALREADY on this airport - skipping to avoid a duplicate "
                  "(the CSV dump just hasn't caught up yet)")
            return False
        # Target the ADD link precisely. Once the airport has a runway this page also
        # carries edit-runway.html?runway=<id> and a delete form, and a loose "any href
        # containing runway" match grabbed the edit page for the runway just added -
        # which has update-runway and delete-runway forms, not create. Never follow an
        # edit/update/delete link from here: this function only ever adds.
        hrefs = [x.group(1) for x in re.finditer(r'href="([^"]*)"', page, re.I)]
        banned = re.compile(r"edit-runway|update-runway|delete-runway|remove", re.I)
        m = next((h for h in hrefs if re.search(r"create-runway", h, re.I)), None)
        if not m:
            m = next((h for h in hrefs
                      if re.search(r"(?:create|new|add)[-_]?runway|runway[-_]?(?:create|new|add)", h, re.I)
                      and not banned.search(h)), None)
        if not m:
            print("    could not find the add-runway link on the logged-in page - "
                  "use [o]pen browser, or re-run with --dump-form and share the output")
            return False
        form_url = urllib.parse.urljoin(f"{OA_BASE}/airports/{ident}/runways.html", m)  # base without the cache-buster
        form_page, form_url = fetch(form_url, opener=self.opener)
        if self.dump_form:
            # Show the real field names and stop. Never post a guessed payload to a
            # public database just because a dump was requested.
            self.describe(form_page, form_url)
            print("    --dump-form: not submitting. Share the block above so the field "
                  "mapping can be written against the real form.")
            return False
        action, fields = parse_form(form_page, "create-runway")
        if "airportRef" not in fields:
            # Self-diagnosing: say what was actually on the page instead of a flat
            # "the form has changed". This page renders differently once the airport
            # has runways, so the shape can shift between runs.
            print(f"    no airportRef on the create form at {form_url}")
            found = list(re.finditer(r"<form\b([^>]*)>", form_page, re.I))
            print(f"    {len(found)} form tag(s) on that page:")
            for f in found:
                attrs = re.sub(r"\s+", " ", f.group(1)).strip()
                print(f"      <form {attrs[:120]}>")
            if action is not None:
                print(f"    matched action={action!r} fields={sorted(fields)}")
            print("    share the lines above, or use [o]pen browser")
            return False
        if not fields.get("airportRef"):
            # The form ships it blank. It is the airport's OurAirports internal id,
            # which is the first column of airports.csv - the same row we already have.
            # Posting it empty is what made the first submission vanish silently: the
            # runway had no airport to attach to, so the server dropped it.
            fields["airportRef"] = airport.get("id", "")
            if not fields["airportRef"]:
                print("    airportRef is blank and no id in the OurAirports row - "
                      "refusing to post an orphan runway. Use [o]pen browser.")
                return False
            print(f"    airportRef was blank; using OurAirports id {fields['airportRef']}")

        # Explicit allowlist. The form's names happen to match the OurAirports CSV
        # columns, but a fuzzy match that drops a length into a width is worse than a
        # refusal, and two of these fields are actively dangerous (below).
        for k in ("length_ft", "width_ft", "surface",
                  "le_ident", "le_heading_degT", "le_elevation_ft",
                  "le_latitude_deg", "le_longitude_deg",
                  "he_ident", "he_heading_degT", "he_elevation_ft",
                  "he_latitude_deg", "he_longitude_deg"):
            v = s.get(k, "")
            if k in fields and v not in ("", None):
                fields[k] = v

        # `closed` and `lighted` are checkboxes: a browser omits them when unchecked,
        # but _fields() captured their value attribute regardless. Posting the captured
        # value would mark every runway we add as CLOSED. Send them only when true.
        fields.pop("closed", None)
        if str(s.get("lighted", "0")) == "1":
            fields["lighted"] = fields.get("lighted") or "1"
        else:
            fields.pop("lighted", None)

        missing = [k for k in ("le_ident", "he_ident", "length_ft") if not fields.get(k)]
        if missing:
            print(f"    refusing to submit, required fields empty: {', '.join(missing)}")
            return False

        print(f"    posting to {action}: " + ", ".join(
            f"{k}={fields[k]}" for k in sorted(fields) if fields.get(k) and k != "id"))
        post_url = urllib.parse.urljoin(form_url, action or "")
        body, landed = fetch(post_url, data=urllib.parse.urlencode(fields).encode(),
                             opener=self.opener)
        if "create-runway" in landed:
            err = re.search(r'class="alert[^"]*"[^>]*>(.*?)</div>', body, re.S | re.I)
            detail = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", err.group(1))).strip()[:160] if err else ""
            print(f"    NOT accepted - still on the form{': ' + detail if detail else ''}")
            return False
        # Read it back. A redirect away from the form is not proof it saved: the first
        # attempt did exactly that and stored nothing.
        check, _ = fetch(f"{OA_BASE}/airports/{ident}/runways.html?v={int(time.time())}",
                         opener=self.opener)
        pair = f"{s.get('le_ident', '')}-{s.get('he_ident', '')}"
        if pair.strip("-") and pair in re.sub(r"<[^>]+>", " ", check):
            print(f"    submitted and confirmed on the page ({pair})")
            return True
        print(f"    posted (landed {landed}) but {pair} is NOT on the runways page yet - "
              "treat as unconfirmed and check in a browser before re-sending")
        return False


def parse_form(page, action_contains=None):
    """Find a POST form and return (action, fields).

    Attribute ORDER is not fixed in HTML. The old pattern demanded method="post"
    before action="...", but the real create-runway form is written
    `<form action="/actions/create-runway" method="post">`, so it matched nothing and
    the caller concluded the form had no fields at all. Parse the attributes
    separately instead of assuming an order.
    """
    for m in re.finditer(r"<form\b([^>]*)>(.*?)</form>", page, re.I | re.S):
        attrs, inner = m.group(1), m.group(2)
        action = re.search(r'action="([^"]*)"', attrs, re.I)
        method = re.search(r'method="([^"]*)"', attrs, re.I)
        if method and method.group(1).strip().lower() != "post":
            continue
        if action_contains:
            if not action or action_contains not in action.group(1):
                continue
        elif not method:
            continue                      # unfiltered: only take an explicit POST form
        return (action.group(1) if action else ""), _fields(inner)
    return None, {}


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
    ap.add_argument("--decisions",
                    help="accepted runways from runway_review.py (already verified "
                         "against imagery; skips OSM derivation)")
    ap.add_argument("--ppa", action="store_true",
                    help="use RTK/PPP surveyed runways from the ppa_airports repo")
    ap.add_argument("--osm", action="store_true",
                    help="also derive runway geometry suggestions from OpenStreetMap")
    args = ap.parse_args()

    ocr_suggestions = {}
    if args.from_json:
        ocr_suggestions = json.loads(Path(args.from_json).read_text())

    # Runways the operator accepted in runway_review.py, keyed by airport code. These
    # are already checked against imagery, so they bypass the OSM derivation entirely.
    reviewed = {}
    ctafs = {}
    if args.decisions:
        for d in json.loads(Path(args.decisions).read_text()):
            if d.get("ctaf"):
                ctafs.setdefault(d["code"], d["ctaf"])    # airport-level; first wins
            if d.get("decision") == "accept" and d.get("runway"):
                r = dict(d["runway"])
                # Downstream display and submission expect `note`; the reviewer records
                # the same thing under `provenance`.
                r.setdefault("note", r.get("provenance", "reviewed"))
                reviewed.setdefault(d["code"], []).append(r)

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

    if reviewed:
        # A decisions file IS the work list - only the airports reviewed and accepted,
        # in the order they were reviewed. Candidates that are not in it are irrelevant.
        by_code = {}
        for a in airports:
            for c in (a["gps_code"], a["local_code"], a["ident"]):
                if c:
                    by_code.setdefault(c.upper(), a)
        work = []
        for c in dict.fromkeys(list(reviewed) + list(ctafs)):
            a = by_code.get(c.upper())
            if a is None:
                print(f"  {c}: not found in OurAirports - skipped")
                continue
            missing = next((m for (x, m) in candidates if x is a), ["reviewed"])
            work.append((a, missing))
    elif args.ident:
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

    # --decisions selects the work on its own; without any selector, fall back to listing
    # rather than silently walking every candidate in the country.
    if args.list or not (args.ident or args.near or args.decisions):
        print(f"{len(work)} Canadian airports missing data:")
        for a, missing in work[:200]:
            code = a["gps_code"] or a["local_code"] or a["ident"]
            print(f"  {code:8} {a['name'][:40]:42} missing: {', '.join(missing)}")
        if len(work) > 200:
            print(f"  ... and {len(work) - 200} more")
        return

    session = None
    if args.email:
        session = Session(dump_form=args.dump_form)
        if not session.login(args.email, getpass.getpass("ourairports.com password: ")):
            session = None

    submitted = 0
    for a, missing in work:
        if submitted >= MAX_SUBMITS_PER_RUN:
            print(f"\nreached {MAX_SUBMITS_PER_RUN} submissions this run; stopping")
            break
        code = a["gps_code"] or a["local_code"] or a["ident"]
        if reviewed:
            suggestions = reviewed.get(code, []) or reviewed.get(a["ident"], [])
            if not suggestions and not (ctafs.get(code) or ctafs.get(a["ident"])):
                continue                                # nothing accepted for this airport
        else:
            suggestions = []
            if args.ppa:
                try:
                    suggestions = ppa_runways(code)
                except Exception as e:
                    print(f"  {code}: ppa_airports lookup failed ({e})")
            # Surveyed data wins; only fall back to tracing when there is none.
            if not suggestions and args.osm:
                suggestions = osm_runways(float(a["latitude_deg"]), float(a["longitude_deg"]))
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
            choice = ask(f"  RWY {s['le_ident']}/{s['he_ident']} -> {prompt}")
            if choice == "q":
                return
            if choice == "o":
                webbrowser.open(f"{OA_BASE}/airports/{a['ident']}/")
            elif choice == "s" and session:
                if session.submit_runway(a, s):
                    submitted += 1
                    time.sleep(THROTTLE_S)
        if not suggestions:
            choice = ask("  [o]pen browser / s[k]ip / [q]uit: ", ("o", "k", "q"))
            if choice == "q":
                return
            if choice == "o":
                webbrowser.open(f"{OA_BASE}/airports/{a['ident']}/")

        # One CTAF per airport, after its runways.
        ctaf = ctafs.get(code) or ctafs.get(a["ident"])
        if ctaf:
            prompt = (f"  CTAF {ctaf} -> [s]ubmit / [o]pen browser / s[k]ip / [q]uit: "
                      if session else
                      f"  CTAF {ctaf} -> [o]pen browser / s[k]ip / [q]uit "
                      "(login with --email to submit): ")
            choice = ask(prompt, ("s", "o", "k", "q") if session else ("o", "k", "q"))
            if choice == "q":
                return
            if choice == "o":
                webbrowser.open(f"{OA_BASE}/airports/{a['ident']}/frequencies.html")
            elif choice == "s" and session:
                if session.submit_frequency(a, ctaf):
                    submitted += 1
                    time.sleep(THROTTLE_S)


if __name__ == "__main__":
    main()
