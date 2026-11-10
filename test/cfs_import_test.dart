// The rows the CFS importer writes into main.db. Checked without a database:
// what matters is that CFS wording lands in the columns the rest of the app
// already reads for FAA data.
import 'package:avaremp/canada/cfs_import.dart';
import 'package:avaremp/canada/cfs_parse.dart';
import 'package:flutter_test/flutter_test.dart';

CfsAerodrome aerodrome({
  String ident = "CTS1",
  String name = "TESTVILLE / SPRINGFIELD",
  bool heliport = false,
  bool water = false,
  int? variation = 15,
  List<CfsRunway> runways = const [],
  List<CfsFrequency> frequencies = const [],
  List<CfsNavaid> navaids = const [],
  List<CfsIls> ils = const [],
  String? fuel,
}) =>
    CfsAerodrome(
      ident: ident,
      province: "AB",
      name: name,
      isHeliport: heliport,
      isWaterAerodrome: water,
      latitude: 51.26,
      longitude: -113.93,
      elevationFt: 3653,
      variation: variation,
      runways: runways,
      frequencies: frequencies,
      navaids: navaids,
      ils: ils,
      fuel: fuel,
      operator: "Testville Airpark Ltd 403-555-0100",
      firstPage: 4,
      lastPage: 5,
    );

void main() {

  test("the airport row", () {
    final Map<String, Object?> r = CfsImport.airportRow(aerodrome(
      frequencies: const [CfsFrequency("MF", "122.9")],
      fuel: "100LL, JA-1 (FSII avbl), SP, HPR 12-04Z",
    ));
    expect(r["LocationID"], "CTS1");
    expect(r["DLID"], "CA-CTS1");
    expect(r["Type"], "AIRPORT");
    expect(r["ARPElevation"], "3653");
    expect(r["MagneticVariation"], "15E");
    expect(r["State"], "AB");
    expect(r["City"], "TESTVILLE");
    expect(r["ATCT"], "");
    expect(r["CTAFFrequency"], "122.9");
    expect(r["Manager"], startsWith("Testville Airpark"));
    expect(r["FuelTypes"], "100LL,JA-1,SP");
  });

  test("west variation and a tower", () {
    final Map<String, Object?> r = CfsImport.airportRow(aerodrome(
      variation: -18,
      frequencies: const [CfsFrequency("TWR", "118.6")],
    ));
    expect(r["MagneticVariation"], "18W");
    expect(r["ATCT"], "Y");
  });

  test("heliports and water aerodromes keep their type", () {
    expect(CfsImport.airportRow(aerodrome(heliport: true))["Type"], "HELIPORT");
    expect(CfsImport.airportRow(aerodrome(water: true))["Type"], "SEAPLANE BAS");
  });

  test("fuel grades are picked out of the prose", () {
    expect(CfsImport.fuelCodes(null), "");
    expect(CfsImport.fuelCodes("No fuel avbl"), "");
    expect(CfsImport.fuelCodes("100LL Self Serve 403-555-0101"), "100LL");
    expect(CfsImport.fuelCodes("JET A, 100LL"), contains("100LL"));
  });

  test("runway rows carry the true bearings", () {
    final List<Map<String, Object?>> rows = CfsImport.runwayRows(aerodrome(
      runways: const [
        CfsRunway(ident: "13", oppositeIdent: "31", bearingTrue: 128,
            oppositeBearingTrue: 308, lengthFt: 7901, widthFt: 150,
            surface: "ASPH"),
      ],
      ils: const [CfsIls("IQR", "109.5", "13")],
    ));
    final Map<String, Object?> r = rows.single;
    expect(r["DLID"], "CA-CTS1");
    expect(r["LEIdent"], "13");
    expect(r["HEIdent"], "31");
    expect(r["LEHeadingT"], "128");
    expect(r["HEHeading"], "308");
    expect(r["Length"], "7901");
    expect(r["Surface"], "ASPH");
    expect(r["LEILS"], "ILS");
    expect(r["HEILS"], "");
    // no threshold coordinates exist in the CFS
    expect(r["LELatitude"], "");
  });

  test("a runway with no printed bearing is corrected by the variation", () {
    final Map<String, Object?> r = CfsImport.runwayRows(aerodrome(
      runways: const [
        CfsRunway(ident: "18", oppositeIdent: "36", lengthFt: 3000,
            widthFt: 190, surface: "TURF"),
      ],
    )).single;
    expect(r["LEHeadingT"], "195");       // 180 magnetic, 15 east
    expect(r["HEHeading"], "15");
  });

  test("communications map onto the types the app already reads", () {
    final List<Map<String, Object?>> rows = CfsImport.frequencyRows(aerodrome(
      frequencies: const [
        CfsFrequency("TWR", "118.6"),
        CfsFrequency("GND", "121.9"),
        CfsFrequency("ATIS", "127.0"),
        CfsFrequency("APP", "119.4"),
      ],
    ));
    expect(rows.map((r) => r["Type"]).toList(),
        ["LCL/P", "GND/P", "ATIS", "APCH/P DEP/P"]);
    expect(rows.map((r) => r["Freq"]).toList(),
        ["118.6", "121.9", "127.0", "119.4"]);
    expect(rows.every((r) => r["DLID"] == "CA-CTS1"), true);
  });

  test("frequencies the airport page cannot bucket keep their label", () {
    // the page drops any type it does not recognise, so a mandatory
    // frequency, an ATF or a UNICOM has to go in as a remark that still says
    // what it is
    final List<Map<String, Object?>> rows = CfsImport.frequencyRows(aerodrome(
      frequencies: const [
        CfsFrequency("MF", "118.6"),
        CfsFrequency("ATF", "122.9"),
        CfsFrequency("UNICOM", "122.8"),
        CfsFrequency("PAL", "120.1"),
      ],
    ));
    expect(rows.every((r) => r["Type"] == "Remark"), true);
    expect(rows.map((r) => r["Freq"]).toList(),
        ["MF 118.6", "ATF 122.9", "UNICOM 122.8", "PAL 120.1"]);
  });

  test("navaid rows, with the frequency in the name as the app expects", () {
    final Map<String, Object?>? r = CfsImport.navaidRow(const CfsNavaid(
      type: "VORTAC", ident: "VLN", name: "Testburg", frequency: "114.2",
      latitude: 50.66, longitude: -104.88, elevationFt: 1895));
    expect(r?["LocationID"], "VLN");
    expect(r?["Type"], "VORTAC");
    expect(r?["FacilityName"], "TESTBURG 114.2");
    expect(r?["Elevation"], "1895");
    // an aid with no position cannot be placed
    expect(CfsImport.navaidRow(const CfsNavaid(type: "NDB", ident: "X2")), isNull);
  });

  test("an expired volume is a warning, not a failure", () {
    final CfsVolumeInfo old = CfsVolumeInfo(
      file: "eCFS3.pdf",
      effectiveFrom: DateTime.utc(2024, 5, 16),
      effectiveTo: DateTime.utc(2024, 7, 11),
      aerodromes: 581,
    );
    expect(old.isExpired, true);
    expect(old.daysRemaining, lessThan(0));
    expect(old.aerodromes, 581);          // still carries its data

    final CfsVolumeInfo current = CfsVolumeInfo(
      file: "eCFS3.pdf",
      effectiveTo: DateTime.now().toUtc().add(const Duration(days: 20)),
    );
    expect(current.isExpired, false);
    expect(current.daysRemaining, inInclusiveRange(19, 20));

    // a volume whose cycle could not be read is not called expired
    const CfsVolumeInfo unknown = CfsVolumeInfo(file: "x.pdf");
    expect(unknown.isExpired, false);
    expect(unknown.daysRemaining, isNull);
  });
}
