# AvareX

Avare, written in Flutter. Runs on Linux, Windows, MacOS, iOS, Android, and Raspberry Pi.

AvareX is a pilot's all in one electronic flight bag solution.

By Apps4Av.

## Canadian Data (work in progress — this fork)

This fork (`canadian-data` branch) adds Canadian airport and airspace
support to AvareX:

- A **Canada** item in the Download screen imports Canadian airports,
  runways, frequencies, and navaids from [OurAirports](https://ourairports.com)
  and Canadian airspace from the community-maintained OpenAir file on
  [soaringweb.org](http://soaringweb.org/Airspace/NA/) (derived from Nav
  Canada's Designated Airspace Handbook). Data refreshes on a 28-day cycle
  and survives DatabasesX updates.
- New **CA Airspace** and **CA Airports** map layers: VFR-styled airspace
  polygons (control zones, MF areas, CYA/CYR/CYD; airspace above 12,500 ft
  is not drawn) and clustered tappable airport markers.
- `tools/` contains scripts for contributing missing runway/frequency data
  back to OurAirports, including OCR of Garmin airport-page captures.

All of this is **unofficial data, not for navigation**. Coverage gaps are
real — many small aerodromes lack runway/frequency data in OurAirports;
help fill them in.

Building this fork: the Firebase config files (`lib/firebase_options.dart`,
`android/app/google-services.json`) are gitignored and must be created as
placeholder stubs — see `CLAUDE.md` for details. Cloud features (community,
scheduler, AI) are inert without them; all core EFB features work.

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

Microsoft version scheme: pubspec.yaml (versions go like 1.0.9.0, last digit must be 0)

Apple version scheme: pubspec.yaml 0.0.9+9

Google version scheme: pubspec.yaml 0.0.9+9  (+9) is what shows up in the package)

Snap version scheme: snap/snapcraft.yaml 0.0.9


