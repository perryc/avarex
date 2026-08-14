import 'package:avaremp/canada/canada_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseCsv filters to Canada and handles quoted commas', () {
    const String text = 'id,ident,type,name,latitude_deg,longitude_deg,'
        'elevation_ft,continent,iso_country,iso_region,municipality\n'
        '1,CYYZ,large_airport,"Toronto, Lester B. Pearson Intl",43.67,-79.63,'
        '569,NA,CA,CA-ON,Toronto\n'
        '2,KBOS,large_airport,Logan Intl,42.36,-71.00,20,NA,US,US-MA,Boston\n';
    List<Map<String, String>> rows = CanadaImport.parseCsv(text);
    expect(rows.length, 1);
    expect(rows[0]["ident"], "CYYZ");
    expect(rows[0]["name"], "Toronto, Lester B. Pearson Intl");
  });

  test('airportRow maps types and defaults', () {
    Map<String, Object?>? row = CanadaImport.airportRow({
      "ident": "CYYZ",
      "type": "large_airport",
      "name": "Toronto Pearson",
      "latitude_deg": "43.67",
      "longitude_deg": "-79.63",
      "elevation_ft": "569",
      "iso_region": "CA-ON",
      "municipality": "Toronto",
    }, {"CYYZ": "118.7"}, {});
    expect(row, isNotNull);
    expect(row!["LocationID"], "CYYZ");
    expect(row["DLID"], "CA-CYYZ");
    expect(row["Type"], "AIRPORT");
    expect(row["ARPLatitude"], 43.67);
    expect(row["ARPElevation"], "569");
    expect(row["State"], "ON");
    expect(row["CTAFFrequency"], "118.7");
    expect(row["UNICOMFrequencies"], "");

    // missing elevation defaults, heliport maps, closed is dropped
    Map<String, Object?>? heli = CanadaImport.airportRow({
      "ident": "CNW7",
      "type": "heliport",
      "name": "Somewhere Heli",
      "latitude_deg": "44.0",
      "longitude_deg": "-79.0",
    }, {}, {});
    expect(heli!["Type"], "HELIPORT");
    expect(heli["ARPElevation"], "0");

    expect(CanadaImport.airportRow({
      "ident": "CXXX",
      "type": "closed",
      "latitude_deg": "44.0",
      "longitude_deg": "-79.0",
    }, {}, {}), isNull);

    // no coordinates -> dropped
    expect(CanadaImport.airportRow({
      "ident": "CYYY",
      "type": "small_airport",
    }, {}, {}), isNull);
  });

  test('airportRow prefers gps_code/local_code over synthetic ident', () {
    Map<String, Object?>? row = CanadaImport.airportRow({
      "ident": "CA-0015",
      "type": "small_airport",
      "name": "Maxville Airport",
      "latitude_deg": "45.28",
      "longitude_deg": "-74.85",
      "gps_code": "CMX2",
      "local_code": "CMX2",
    }, {}, {});
    expect(row!["LocationID"], "CMX2");
    // DLID stays ident-based to match runway/frequency child rows
    expect(row["DLID"], "CA-CA-0015");

    Map<String, Object?>? localOnly = CanadaImport.airportRow({
      "ident": "CA-0027",
      "type": "small_airport",
      "name": "Danville Airport",
      "latitude_deg": "45.78",
      "longitude_deg": "-72.02",
      "local_code": "CDN2",
    }, {}, {});
    expect(localOnly!["LocationID"], "CDN2");

    // nothing better exists -> keep the synthetic ident
    Map<String, Object?>? synth = CanadaImport.airportRow({
      "ident": "CA-0002",
      "type": "small_airport",
      "name": "Pourvoirie Joncas Airstrip",
      "latitude_deg": "47.0",
      "longitude_deg": "-75.0",
    }, {}, {});
    expect(synth!["LocationID"], "CA-0002");
  });

  test('runwayRow skips closed and maps lights', () {
    Map<String, Object?>? row = CanadaImport.runwayRow({
      "airport_ident": "CYYZ",
      "length_ft": "11120",
      "width_ft": "200",
      "surface": "ASP",
      "lighted": "1",
      "closed": "0",
      "le_ident": "05",
      "he_ident": "23",
      "le_latitude_deg": "43.66",
      "le_longitude_deg": "-79.64",
      "he_latitude_deg": "43.68",
      "he_longitude_deg": "-79.61",
      "le_heading_degT": "57",
      "he_heading_degT": "237",
    });
    expect(row, isNotNull);
    expect(row!["DLID"], "CA-CYYZ");
    expect(row["LELights"], "LIGHTED");
    expect(row["LEHeadingT"], "57");
    expect(row["HEHeading"], "237");
    expect(row["LEPattern"], "N");

    expect(CanadaImport.runwayRow({
      "airport_ident": "CYYZ",
      "closed": "1",
    }), isNull);
  });

  test('frequencyRows buckets by type', () {
    final (rows, ctaf, unicom) = CanadaImport.frequencyRows([
      {"airport_ident": "CYYZ", "type": "TWR", "frequency_mhz": "118.35"},
      {"airport_ident": "CYYZ", "type": "GND", "frequency_mhz": "121.9"},
      {"airport_ident": "CYYZ", "type": "ATIS", "frequency_mhz": "120.825"},
      {"airport_ident": "CYYZ", "type": "APP", "frequency_mhz": "124.475"},
      {"airport_ident": "CYTZ", "type": "MF", "frequency_mhz": "118.2"},
      {"airport_ident": "CNC3", "type": "UNIC", "frequency_mhz": "122.8"},
      {"airport_ident": "CYOO", "type": "FSS", "description": "RDO",
        "frequency_mhz": "122.37"},
    ]);
    expect(rows.where((r) => r["Type"] == "LCL/P").length, 1);
    expect(rows.where((r) => r["Type"] == "GND/P").length, 1);
    expect(rows.where((r) => r["Type"] == "ATIS").length, 1);
    expect(rows.where((r) => r["Type"] == "APCH/P DEP/P").length, 1);
    expect(rows.where((r) => r["Type"] == "Remark").length, 1);
    expect(ctaf["CYTZ"], "118.2");
    expect(unicom["CNC3"], "122.8");
  });

  test('navaidRow maps types and embeds frequency in name', () {
    Map<String, Object?>? vor = CanadaImport.navaidRow({
      "ident": "YYZ",
      "name": "Toronto",
      "type": "VOR-DME",
      "frequency_khz": "113300",
      "latitude_deg": "43.67",
      "longitude_deg": "-79.63",
      "elevation_ft": "569",
      "magnetic_variation_deg": "-10.2",
      "power": "HIGH",
    });
    expect(vor, isNotNull);
    expect(vor!["Type"], "VOR/DME");
    expect(vor["FacilityName"], "TORONTO 113.30");
    expect(vor["Variation"], -10);
    expect(vor["Class"], "H");
    expect(vor["Hiwas"], "N");

    Map<String, Object?>? ndb = CanadaImport.navaidRow({
      "ident": "ZYZ",
      "name": "Toronto",
      "type": "NDB",
      "frequency_khz": "356",
      "latitude_deg": "43.6",
      "longitude_deg": "-79.6",
    });
    expect(ndb!["FacilityName"], "TORONTO 356");
    expect(ndb["Elevation"], "0");

    // unknown type dropped
    expect(CanadaImport.navaidRow({
      "ident": "XXX",
      "type": "GLIDE_PATH",
      "latitude_deg": "43.6",
      "longitude_deg": "-79.6",
    }), isNull);
  });
}
