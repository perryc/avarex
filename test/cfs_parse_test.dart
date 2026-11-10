// Fixtures are written in the CFS page format rather than copied out of a
// real supplement, so the test data carries no NAV CANADA content.
import 'package:avaremp/canada/cfs_parse.dart';
import 'package:flutter_test/flutter_test.dart';

const String watermark = "CFS\nENGLISH\nApr. 08, 2024\n8:06 am\n";
const String footer =
    "ALBERTA AERODROME / FACILITY DIRECTORY\n"
    "CANADA FLIGHT SUPPLEMENT / GPH 205 Effective 0901Z 16 May 2024 to "
    "0901Z 11 July 2024";

String page(String body, {String? code}) =>
    "$watermark${code == null ? "" : "$code\n"}$body\n$footer";

void main() {

  test("a simple aerodrome", () {
    final CfsVolume v = CfsParser.parse([page(code: "ABCTS1", """
TESTVILLE AB CTS1
REF N51 15 50 W113 56 04 2.6SE
15°E (2012) UTC-7(6) Elev 3653´
OPR Testville Airpark Ltd 403-555-0100 Reg PPR
FUEL 100LL Self Serve 403-555-0101
RWY DATA Rwy 12(123°)/30(303°) 5000x100 asphalt
LIGHTING 12-AS(TE LO), 30-AS(TE LO)
COMM
ATF UNICOM ltd hrs O/T tfc 122.9 2NM 4800 ASL""")]);

    expect(v.aerodromes.length, 1);
    final CfsAerodrome a = v.aerodromes.first;
    expect(a.ident, "CTS1");
    expect(a.province, "AB");
    expect(a.name, "TESTVILLE");
    expect(a.latitude, closeTo(51.2639, 0.001));
    expect(a.longitude, closeTo(-113.9344, 0.001));
    expect(a.elevationFt, 3653);
    expect(a.variation, 15);
    expect(a.utcOffset, -7);
    expect(a.isTowered, false);
    expect(a.fuel, startsWith("100LL"));
    expect(a.operator, startsWith("Testville Airpark"));
    expect(a.runways.length, 1);
    expect(a.runways.first.ident, "12");
    expect(a.runways.first.oppositeIdent, "30");
    expect(a.runways.first.bearingTrue, 123);
    expect(a.runways.first.lengthFt, 5000);
    expect(a.runways.first.widthFt, 100);
    expect(a.runways.first.surface, "ASPH");
    expect(a.runways.first.isHardSurface, true);
    expect(a.frequencyOf("ATF"), "122.9");
    expect(a.firstPage, 1);
    expect(a.lastPage, 1);
  });

  test("a towered aerodrome, several runways, lengths with separators", () {
    final CfsVolume v = CfsParser.parse([page(code: "ABCTS2", """
TEST INTL AB CTS2
REF N53 18 36 W113 34 46 6SSW 15°E (2013) UTC-7(6) Elev 2373’
RWY DATA Rwy 02(020°)/20(200°) 10,995x200 ASPH
Rwy 12(120°)/30(300°) 10,200x200 ASPH Rwy 30 down 0.48%.
COMM
ATIS 127.0
GND 121.9 12-04Z
TWR 118.6 (E) 12-04Z""")]);

    final CfsAerodrome a = v.aerodromes.single;
    expect(a.isTowered, true);
    expect(a.frequencyOf("TWR"), "118.6");
    expect(a.frequencyOf("ATIS"), "127.0");
    expect(a.runways.length, 2);
    expect(a.runways[0].lengthFt, 10995);
    expect(a.runways[0].surface, "ASPH");
    // the trailing note must not be swallowed into the surface
    expect(a.runways[1].lengthFt, 10200);
    expect(a.runways[1].surface, "ASPH");
    expect(a.runways[1].ident, "12");
  });

  test("a surface that wrapped onto its own line", () {
    final CfsVolume v = CfsParser.parse([page(code: "ABCTS3", """
TEST FARM AB CTS3
REF N52 20 45 W114 40 02 Adj NE
15°E (2012) UTC-7(6) Elev 3212'
RWY DATA Rwy 09(094°)/27(274°) 2500x60
GRASS
RCR Opr Ltd win maint""")]);

    final CfsRunway r = v.aerodromes.single.runways.single;
    expect(r.surface, "TURF");
    expect(r.isHardSurface, false);
    expect(r.lengthFt, 2500);
  });

  test("no printed bearings and a degrees-and-minutes position", () {
    final CfsVolume v = CfsParser.parse([page(code: "ABCTS4", """
TEST PARK AB CTS4
REF N51 12 W115 32 1.7NNE 16°E (2012)
UTC-7(6) Elev 4583´
RWY DATA Rwy 18/36 3000x190 GRASS/SNOW
COMM
ATF tfc 123.3 5NM 7600 ASL""")]);

    final CfsAerodrome a = v.aerodromes.single;
    expect(a.latitude, closeTo(51.2, 0.001));
    expect(a.longitude, closeTo(-115.5333, 0.001));
    expect(a.elevationFt, 4583);
    final CfsRunway r = a.runways.single;
    expect(r.ident, "18");
    expect(r.oppositeIdent, "36");
    expect(r.bearingTrue, isNull);
    expect(r.surface, "TURF");
    // 180 magnetic at 16 degrees east is 196 true
    expect(r.trueBearing(a.variation), closeTo(196, 0.001));
    expect(r.trueBearing(null), isNull);
  });

  test("a heliport has no runway block", () {
    final CfsVolume v = CfsParser.parse([page(code: "ABCTS5", """
TEST HOSPITAL AB (Heli) CTS5
REF N51 02 50 W114 04 04 Adj
15°E (2012) UTC-7(6) Elev 3400´
HELI DATA 50' x 66' concrete
COMM
ATF tfc 123.0 5NM 5000 ASL""")]);

    final CfsAerodrome a = v.aerodromes.single;
    expect(a.isHeliport, true);
    expect(a.runways, isEmpty);
    expect(a.frequencyOf("ATF"), "123.0");
  });

  test("an entry that runs over two pages", () {
    final CfsVolume v = CfsParser.parse([
      page(code: "ABCTS6", """
TEST REGIONAL AB CTS6
REF N50 25 56 W104 39 58 2SW 10°E (2011) UTC-6 Elev 1895´
OPR Test Aprt Authority 306-555-0100"""),
      page("""
TEST REGIONAL AB (Cont’d) CTS6
RWY DATA Rwy 13(128°)/31(308°) 7901x150 ASPH
Rwy 08(080°)/26(260°) 6200x150 ASPH
COMM
TWR 118.6 (E) 12-04Z"""),
    ]);

    expect(v.aerodromes.length, 1);
    final CfsAerodrome a = v.aerodromes.single;
    expect(a.firstPage, 1);
    expect(a.lastPage, 2);
    expect(a.elevationFt, 1895);
    expect(a.runways.length, 2);
    expect(a.isTowered, true);
    expect(a.city, "TEST REGIONAL");
  });

  test("the name of a two-part entry gives the town", () {
    final CfsVolume v = CfsParser.parse([page(code: "ABCTS7", """
TESTVILLE / SPRINGFIELD AB CTS7
REF N51 06 15 W114 22 29 Adj 15°E (2012) UTC-7(6) Elev 3940´
RWY DATA Rwy 07(070°)/25(250°) 3200x75 ASPH""")]);
    expect(v.aerodromes.single.city, "TESTVILLE");
  });

  test("the cycle is read off the footer", () {
    final CfsVolume v = CfsParser.parse([page(code: "ABCTS8", """
TESTVILLE AB CTS8
REF N51 15 50 W113 56 04 2.6SE 15°E (2012) UTC-7(6) Elev 3653´""")]);
    expect(v.effectiveFrom, DateTime.utc(2024, 5, 16, 9, 1));
    expect(v.effectiveTo, DateTime.utc(2024, 7, 11, 9, 1));
    expect(v.isExpired, true);
  });

  test("pages that are not the aerodrome directory are skipped", () {
    final CfsVolume v = CfsParser.parse([
      "CFS\nENGLISH\nCANADA FLIGHT SUPPLEMENT\nGENERAL SECTION\nsome preamble",
      page(code: "ABCTS9", """
TESTVILLE AB CTS9
REF N51 15 50 W113 56 04 2.6SE 15°E (2012) UTC-7(6) Elev 3653´"""),
    ]);
    expect(v.aerodromes.length, 1);
    expect(v.aerodromes.single.firstPage, 2);
  });

  test("the NAV block", () {
    final CfsVolume v = CfsParser.parse([page(code: "ABCTS0", """
TEST INTL AB CTS0
REF N50 25 56 W104 39 58 2SW 10°E (2011) UTC-6 Elev 1895´
NAV
VORTAC TESTBURG VLN 114.2 Ch 89 N50 40 01 W104 53 23 (1895´)
VOR/DME YYC 116.7 Ch 114 N51 06 55 W113 52 55 (3573')
NDB X2 329 (L) N54 44 14 W113 12 05 Pvt Unmonitored
ILS IQR 109.5 (Rwy 13) RVR LOC reliable only within 10° either side""")]);

    final CfsAerodrome a = v.aerodromes.single;
    expect(a.navaids.length, 3);
    expect(a.navaids[0].type, "VORTAC");
    expect(a.navaids[0].name, "TESTBURG");
    expect(a.navaids[0].ident, "VLN");
    expect(a.navaids[0].frequency, "114.2");
    expect(a.navaids[0].latitude, closeTo(50.6669, 0.001));
    expect(a.navaids[0].longitude, closeTo(-104.8897, 0.001));
    expect(a.navaids[0].elevationFt, 1895);
    expect(a.navaids[0].isNdb, false);
    // no name printed: the one word before the frequency is the identifier
    expect(a.navaids[1].type, "VOR/DME");
    expect(a.navaids[1].ident, "YYC");
    expect(a.navaids[1].name, "");
    expect(a.navaids[2].isNdb, true);
    expect(a.navaids[2].ident, "X2");
    expect(a.navaids[2].frequency, "329");
    expect(a.navaids[2].elevationFt, isNull);
    // an ILS has no position of its own; it belongs to its runway
    expect(a.ils.single.ident, "IQR");
    expect(a.ils.single.frequency, "109.5");
    expect(a.ils.single.runway, "13");
  });

  // The supplement is not typeset consistently. Each of these cost an
  // aerodrome its runways on the map until it was handled.
  test("a masculine ordinal instead of a degree sign", () {
    // real example: CAG2, which mixes the two within one line
    final CfsVolume v = CfsParser.parse([page(code: "SKCTSA", """
TESTVILLE / AEROGATE SK CTSA
REF N50 35 52 W104 36 04 6N 10°E (2011) UTC-6 Elev 1980’
RWY DATA Rwy 11(105º)/29(285°) 1900x30 broken
ASPH""")]);
    final CfsRunway r = v.aerodromes.single.runways.single;
    expect(r.ident, "11");
    expect(r.bearingTrue, 105);
    expect(r.oppositeBearingTrue, 285);
    expect(r.lengthFt, 1900);
    expect(r.surface, "ASPH");
  });

  test("no degree sign at all", () {
    final CfsVolume v = CfsParser.parse([page(code: "ABCTSB", """
TESTVILLE AB CTSB
REF N51 15 50 W113 56 04 2.6SE 15°E (2012) UTC-7(6) Elev 3653´
RWY DATA Rwy 09(089)/27(269) 3031x75 GRASS""")]);
    final CfsRunway r = v.aerodromes.single.runways.single;
    expect(r.bearingTrue, 89);
    expect(r.lengthFt, 3031);
    expect(r.surface, "TURF");
  });

  test("a capital X and spaces around it", () {
    final CfsVolume v = CfsParser.parse([page(code: "ABCTSC", """
TESTVILLE AB CTSC
REF N51 15 50 W113 56 04 2.6SE 15°E (2012) UTC-7(6) Elev 3653´
RWY DATA
Rwy 07(072°)/25(252°) 2400X60
Rwy 13(132°)/31(312°) 5000 x75 GRVL
Rwy 16(164°)/34(344°) 1675x 80 GRASS""")]);
    final List<CfsRunway> r = v.aerodromes.single.runways;
    expect(r.length, 3);
    expect(r[0].lengthFt, 2400);
    expect(r[0].widthFt, 60);
    expect(r[1].lengthFt, 5000);
    expect(r[1].widthFt, 75);
    expect(r[1].surface, "GRVL");
    expect(r[2].lengthFt, 1675);
    expect(r[2].widthFt, 80);
  });

  test("a runway with no dimensions published is still a runway", () {
    final CfsVolume v = CfsParser.parse([page(code: "ABCTSD", """
TESTVILLE AB CTSD
REF N51 15 50 W113 56 04 2.6SE 15°E (2012) UTC-7(6) Elev 3653´
RWY DATA Rwy 12(119°)/30(299°)
RCR Opr Ltd win maint. Rwy 12/30 PCN""")]);
    final CfsRunway r = v.aerodromes.single.runways.single;
    expect(r.ident, "12");
    expect(r.bearingTrue, 119);
    expect(r.lengthFt, isNull);
    expect(r.widthFt, isNull);
  });

  test("a runway mentioned in prose is not mistaken for runway data", () {
    // "Rwy 12/30 PCN" and "Rgt hand circuits Rwy 12" must not become runways
    final CfsVolume v = CfsParser.parse([page(code: "ABCTSE", """
TESTVILLE AB CTSE
REF N51 15 50 W113 56 04 2.6SE 15°E (2012) UTC-7(6) Elev 3653´
RCR Opr Ltd win maint. Rwy 12/30 PCN
PRO Rgt hand circuits Rwy 12 (CAR 602.96).
CAUTION Watch for tfc on hwy 44 when landing Rwy 07 and dep Rwy 25.""")]);
    expect(v.aerodromes.single.runways, isEmpty);
  });
}
