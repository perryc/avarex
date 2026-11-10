# AvareX

Avare, written in Flutter. Runs on Linux, Windows, MacOS, iOS, Android, and Raspberry Pi.

AvareX is a pilot's all in one electronic flight bag solution.

By Apps4Av.

## Canadian Data (work in progress — this fork)

**📦 Try it: [download the latest APK](https://github.com/perryc/avarex/releases/latest)** (Android sideload; see release notes).

This fork (`canadian-data` branch) adds Canadian aerodrome and airspace
support to AvareX.

### Aerodromes come from your own Canada Flight Supplement

The CFS is Nav Canada's own aerodrome directory, and it is the only
source that has every registered aerodrome with its runway dimensions,
surfaces, true bearings, full communications block, fuel and operator.
It cannot be redistributed, so **nothing ships with the app**: you point
it at the volumes you already have and they are parsed on the device.

**Menu → Data → Canadian CFS Import** → *Choose files* (or *Choose a
folder* on desktop), pick the volume PDFs, and wait. One volume of about
a thousand pages takes a couple of seconds on a desktop and a little
longer on a tablet.

Measured against one real volume (Alberta, Saskatchewan and Manitoba,
1059 pages):

| | |
|---|---|
| aerodromes | 581 |
| with a position / elevation | 98.1% / 100% |
| landplane aerodromes with runway data | 100% |
| with a frequency | 97.1% |
| navaids / ILS | 68 / 12 |

Each imported volume stays on the device so that **tapping a Canadian
airport gives you its actual CFS page** — the procedures, cautions and
operator hours that no database row can hold. A volume that has gone out
of cycle is marked in amber with the date and keeps working; runways and
frequencies rarely move, but check NOTAMs.

Earlier versions took aerodromes from [OurAirports](https://ourairports.com),
which is crowd-sourced and thin for Canada — no trustworthy surfaces, no
true bearings, few frequencies, and whole aerodromes missing. That import
is gone, and so is the need to contribute corrections back to it.

### The rest

- The **Canada** item in the Download screen now fetches only what the
  supplement does not carry: Canadian airspace from the community
  OpenAir file on [soaringweb.org](http://soaringweb.org/Airspace/NA/)
  (derived from Nav Canada's Designated Airspace Handbook) and the
  Transport Canada aircraft register, which labels traffic that
  broadcasts no callsign. Refreshes on a 28-day cycle and survives
  DatabasesX updates.
- **CA Airspace** and **CA Airports** map layers: VFR-styled airspace
  polygons (control zones, MF areas, CYA/CYR/CYD; airspace above
  12,500 ft is not drawn) and sectional-style airport symbols drawn the
  way a VNC draws them — open circle for an unpaved field, runways
  through the circle for a paved one, the runway layout alone above
  8069 ft, blue for towered, ticks for fuel.
- Airports are found by **name as well as identifier**: "Springbank"
  finds CYBW even though the entry is titled "CALGARY / SPRINGBANK".

All of this is **unofficial data, not for navigation**.

Note on reading the PDFs: this uses [pdfrx](https://pub.dev/packages/pdfrx)
(pdfium) rather than the Syncfusion reader already in the app. The CFS is
set in subset Type 1C fonts with no ToUnicode map, and Syncfusion returns
glyph codes for exactly the runway and frequency lines that matter.

Building this fork: the Firebase config files (`lib/firebase_options.dart`,
`android/app/google-services.json`) are gitignored and must be created as
placeholder stubs — see `CLAUDE.md` for details. Cloud features (community,
scheduler, AI) are inert without them; all core EFB features work.

## BLE ADS-B Receivers (work in progress — this fork)

This branch also includes the `ble-adsb` feature: traffic/ownship/FIS-B
over Bluetooth LE GATT instead of WiFi, so your tablet's WiFi stays free
for a phone hotspot, and iOS/iPadOS work too (Bluetooth SPP never did).
Interface spec: [docs/BLE_ADSB_SERVICE.md](docs/BLE_ADSB_SERVICE.md).

Target receivers:

- **[ADSBee 1090U](https://pantsforbirds.com/product/adsbee-1090u/)** —
  open-source 1090ES (+978 UAT capable) receiver. BLE firmware lives in the
  [perryc/adsbee fork, `ble-gdl90` branch](https://github.com/perryc/adsbee/tree/ble-gdl90):
  typed GDL90 characteristics, FIS-B uplink fragmentation (hello
  [CIFIB](https://cifib.ca)), and the full AT command console over BLE so
  any serial terminal app can configure it wirelessly.
- **cb-tfc** — MIT-licensed firmware turning a [Seeed SenseCAP MeshTracker
  X1](https://www.seeedstudio.com/) (nRF52840 + Semtech LR2021) into a
  see-and-be-seen traffic device: 1090ES ADS-B and FANET on 915 MHz on the
  one radio, time-sliced against GPS, both arriving over the same BLE
  service. It transmits its own position on FANET, so two of them see each
  other. **Currently in flight testing**; not published yet.
- **[SoftRF Card Edition MkIII](https://github.com/lyusupov/SoftRF/wiki/Card-Edition-MkIII)**
  (~US$42) — LoRa radio covering FANET/OGN glider and paraglider traffic;
  connects as a second BLE receiver alongside the ADSBee (set it to
  Bluetooth LE + GDL90 output).

In development: a board carrying **1090ES, 978 UAT and 915 MHz together**,
built around the ADSBee m1421 module — its LR2021 takes 1090 while the
CC1314's own sub-GHz radio takes 978, including TIS-B and FIS-B, which
matters north of the border only near a US ground station but matters a
great deal south of it.

The "$42 TCAS" plan: 1090ES plus FANET feeding one merged BLE traffic
picture in AvareX — transponder traffic, gliders, and paragliders on one
moving map over Canadian charts and airspace, no WiFi juggling, for less
than a fill-up. (It is, of course, not TCAS: unofficial data, no
resolution advisories, not for navigation — it's extra eyes, not a
certified system.)

Note: on the ADSBee 1090U, BLE mode and WiFi mode are mutually exclusive
(the ESP32-S3 module lacks the RAM to run both radios' stacks); switch
modes with `AT+WIFI_AP` over USB or the BLE console.

## User Manual

A comprehensive, code-derived user manual is available at:

- [USER_MANUAL.md](USER_MANUAL.md)

## Getting Started



### Downloading


** Windows 

Download on Windows using Microsoft Store.

** MacOS

Download on Apple App Store from your Mac with Apple Silicon.

** Linux

Download on Linux using Snap Store.

** iOS

Download on Apple App Store from your iPhone or iPad.

** Android

Download on Google Play Store from your Android device.

** Raspberry Pi

Download at https://github.com/apps4av/avarex/actions/workflows/arm64.yaml from your Pi. 

Tested on 64-bit Raspberry Pi OS (may run on other configurations).
 - Pi 5 with 8 GB memory
 - Pi 4 with 1 GB memory
 - Prerequisites: sudo apt-get install libgtk-3-0 libblkid1 liblzma5 libsqlite3-dev

## Store Consoles

Google / Android: https://play.google.com/console

iOS, MacOS: https://appstoreconnect.apple.com/login

Linux: https://snapcraft.io

Windows: https://partner.microsoft.com/en-us/dashboard/home

## Store Locations

Google / Android : https://play.google.com/store/apps/details?id=com.apps4av.avaremp

iOS, MacOS: https://apps.apple.com/us/app/avarex/id6502421523

Linux: https://snapcraft.io/avarex

Windows: https://apps.microsoft.com/detail/9mx4hkl30mww?hl=en-us&gl=US

## Building:

Github Actions builds all store builds.

On `master`, a version change in `pubspec.yaml` uploads Android to the Play **internal** track, iOS to **TestFlight**, and Windows to Partner Center with **Manual** publish (package committed for certification, not released). A version change in `snap/snapcraft.yaml` uploads Linux to Snap **edge**. Builds still go to apps4av.org on every push. Nothing is sent to production, stable, or a public store listing until you click **Publish** in Partner Center after Windows certification.

To retry a Windows draft upload without bumping the version: **Actions → Windows → Run workflow** (branch `master`).

Play and TestFlight “What’s new” is generated from the **AvareX Releases** section in `USER_MANUAL.md` (`bash .github/scripts/update-whatsnew.sh`). Do not hand-edit `store/whatsnew/whatsnew-en-US`.

Required secrets (that store is skipped if the credential is unset):

- Play internal: `PLAY_STORE_SERVICE_ACCOUNT_JSON`
- TestFlight: `APPSTORE_ISSUER_ID`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_PRIVATE_KEY`
- Snap edge: `SNAPCRAFT_STORE_CREDENTIALS` (`snapcraft export-login --snaps=avarex --channels=edge snapcraft-login.txt`)
- Windows draft: `PARTNER_CENTER_TENANT_ID`, `PARTNER_CENTER_SELLER_ID`, `PARTNER_CENTER_CLIENT_ID`, `PARTNER_CENTER_CLIENT_SECRET`

Microsoft version scheme: pubspec.yaml (versions go like 1.0.9.0, last digit must be 0)

Apple version scheme: pubspec.yaml 0.0.9+9

Google version scheme: pubspec.yaml 0.0.9+9  (+9) is what shows up in the package)

Snap version scheme: snap/snapcraft.yaml 0.0.9


