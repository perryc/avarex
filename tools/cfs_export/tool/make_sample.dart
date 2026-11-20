// Writes sample.efb: a few made-up aerodromes (no supplement data) for the
// cb-tfc-disp reader's tests, so both sides of the format are checked together.
//
//   dart run tool/make_sample.dart ../../../cb-tfc-disp/host_test/fixtures/sample.efb

import 'dart:io';

import '../../../lib/canada/cfs_parse.dart';
import '../lib/efb_writer.dart';

void main(List<String> args) {
  final volume = CfsVolume(
    effectiveFrom: DateTime.utc(2026, 10, 2),
    effectiveTo: DateTime.utc(2026, 11, 26),
    aerodromes: [
      // Sorted out of order on purpose: the writer sorts by ident.
      CfsAerodrome(
        ident: "CZZB", province: "SK", name: "SAMPLE TOWN / BRAVO", latitude: 50.5, longitude: -104.0,
        elevationFt: 1900, variation: 8, utcOffset: -6, firstPage: 12, lastPage: 12,
        runways: const [CfsRunway(ident: "09", oppositeIdent: "27", bearingTrue: 96, oppositeBearingTrue: 276,
            lengthFt: 2600, widthFt: 60, surface: "TURF")],
        frequencies: const [CfsFrequency("ATF", "123.2")],
        fuel: "100LL", operator: "Town of Sample 306 555-0100",
      ),
      CfsAerodrome(
        ident: "CZZA", province: "SK", name: "SAMPLE CITY INTL", latitude: 50.43, longitude: -104.66,
        elevationFt: 1894, variation: 8, utcOffset: -6, firstPage: 10, lastPage: 11,
        runways: const [
          CfsRunway(ident: "13", oppositeIdent: "31", bearingTrue: 128, oppositeBearingTrue: 308,
              lengthFt: 7900, widthFt: 150, surface: "ASPH"),
          CfsRunway(ident: "08", oppositeIdent: "26", bearingTrue: 89, oppositeBearingTrue: 269,
              lengthFt: 6200, widthFt: 150, surface: "ASPH"),
        ],
        frequencies: const [
          CfsFrequency("TWR", "118.2"), CfsFrequency("GND", "121.9"), CfsFrequency("ATIS", "124.15"),
        ],
        navaids: const [CfsNavaid(type: "VOR/DME", ident: "ZZA", name: "SAMPLE", frequency: "116.4",
            latitude: 50.42, longitude: -104.61, elevationFt: 1890)],
        ils: const [CfsIls("IZA", "109.5", "13")],
        fuel: "100LL Jet A", operator: "Sample Airport Authority",
      ),
      CfsAerodrome(
        ident: "CZZH", province: "SK", name: "SAMPLE CITY (HOSPITAL) HELI", isHeliport: true,
        latitude: 50.44, longitude: -104.62, elevationFt: 1910, firstPage: 13, lastPage: 13,
      ),
      CfsAerodrome(
        ident: "CZZW", province: "MB", name: "SAMPLE LAKE WATER", isWaterAerodrome: true,
        latitude: 51.0, longitude: -100.0, firstPage: 14, lastPage: 14,
      ),
      CfsAerodrome(
        // no position: kept for Find, never in Nearest
        ident: "CZZN", province: "AB", name: "SAMPLE NOWHERE", firstPage: 15, lastPage: 15,
      ),
    ],
  );
  final out = args.isEmpty ? "sample.efb" : args.first;
  File(out).writeAsBytesSync(writeEfb([volume]));
  stdout.writeln("wrote $out");
}
