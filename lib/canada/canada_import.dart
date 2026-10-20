import 'package:avaremp/canada/canada_registry.dart';
import 'package:avaremp/data/main_database_helper.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:universal_io/io.dart';

// Imports Canadian airports/runways/frequencies/navaids from OurAirports CSV
// files into main.db, alongside the FAA data. Rows are keyed with DLID
// prefix 'CA-' so they can be purged and re-imported without touching FAA
// rows. main.db is replaced on every DatabasesX cycle update, so the import
// re-runs from the cached CSVs afterward (reimportIfInstalled).
class CanadaImport {

  static const String dlidPrefix = "CA-";
  static const String subDir = "canada";

  static const String airportsCsv = "airports.csv";
  static const String runwaysCsv = "runways.csv";
  static const String frequenciesCsv = "airport-frequencies.csv";
  static const String navaidsCsv = "navaids.csv";
  static const String airspaceFile = "airspace.txt";
  static const String registryFile = "carscurr.txt"; // TC civil aircraft register

  static String dataPath(String file) =>
      path.join(Storage().dataDir, subDir, file);

  // parse one CSV file into header-keyed rows, keeping only Canadian rows
  static List<Map<String, String>> parseCsv(String text) {
    List<List<dynamic>> rows = const CsvToListConverter(
        shouldParseNumbers: false, eol: "\n")
        .convert(text.replaceAll("\r\n", "\n"));
    if(rows.isEmpty) {
      return [];
    }
    List<String> header = rows[0].map((e) => e.toString().trim()).toList();
    int countryIndex = header.indexOf("iso_country");
    List<Map<String, String>> result = [];
    for(int i = 1; i < rows.length; i++) {
      List<dynamic> row = rows[i];
      if(row.length != header.length) {
        continue;
      }
      if(countryIndex >= 0 && row[countryIndex].toString() != "CA") {
        continue;
      }
      result.add({for(int c = 0; c < header.length; c++) header[c]: row[c].toString()});
    }
    return result;
  }

  // runways.csv and airport-frequencies.csv have no iso_country column;
  // filter them by the airport idents that made the cut
  static List<Map<String, String>> filterByAirport(
      List<Map<String, String>> rows, Set<String> idents) {
    return rows.where((r) => idents.contains(r["airport_ident"])).toList();
  }

  static Map<String, Object?>? airportRow(Map<String, String> csv,
      Map<String, String> ctaf, Map<String, String> unicom) {
    String ident = (csv["ident"] ?? "").toUpperCase();
    if(ident.isEmpty) {
      return null;
    }
    String? type = const {
      "small_airport": "AIRPORT",
      "medium_airport": "AIRPORT",
      "large_airport": "AIRPORT",
      "seaplane_base": "SEAPLANE BAS",
      "heliport": "HELIPORT",
      "balloonport": "BALLOONPORT",
    }[csv["type"]];
    if(type == null) {
      return null; // closed or unknown
    }
    double? lat = double.tryParse(csv["latitude_deg"] ?? "");
    double? lon = double.tryParse(csv["longitude_deg"] ?? "");
    if(lat == null || lon == null) {
      return null;
    }
    // OurAirports uses synthetic idents (CA-0015) for airports without ICAO
    // codes; the Transport Canada code lives in gps_code/local_code. DLID
    // stays ident-based since runways/frequencies key on airport_ident.
    String code = (csv["gps_code"] ?? "").isNotEmpty
        ? csv["gps_code"]!
        : ((csv["local_code"] ?? "").isNotEmpty ? csv["local_code"]! : ident);
    String region = csv["iso_region"] ?? ""; // "CA-ON" -> "ON"
    return {
      "LocationID": code.toUpperCase(),
      "DLID": "$dlidPrefix$ident",
      "FaaID": (csv["local_code"] ?? "").isEmpty ? ident : csv["local_code"]!,
      "ARPLatitude": lat,
      "ARPLongitude": lon,
      "Type": type,
      "FacilityName": csv["name"] ?? "",
      "Use": "PU",
      "FSSPhone": "",
      "Manager": "",
      "ManagerPhone": "",
      "ARPElevation": (csv["elevation_ft"] ?? "").isEmpty ? "0" : csv["elevation_ft"]!,
      "MagneticVariation": "",
      "TrafficPatternAltitude": "",
      "FuelTypes": "",
      "Customs": "",
      "Beacon": "",
      "LightSchedule": "",
      "SegCircle": "",
      "ATCT": "",
      "UNICOMFrequencies": unicom[ident] ?? "",
      "CTAFFrequency": ctaf[ident] ?? "",
      "NonCommercialLandingFee": "",
      "State": region.startsWith("CA-") ? region.substring(3) : "",
      "City": csv["municipality"] ?? "",
    };
  }

  static Map<String, Object?>? runwayRow(Map<String, String> csv) {
    if(csv["closed"] == "1") {
      return null;
    }
    String ident = (csv["airport_ident"] ?? "").toUpperCase();
    if(ident.isEmpty) {
      return null;
    }
    String lights = csv["lighted"] == "1" ? "LIGHTED" : "";
    return {
      "DLID": "$dlidPrefix$ident",
      "Length": csv["length_ft"] ?? "",
      "Width": csv["width_ft"] ?? "",
      "Surface": csv["surface"] ?? "",
      "LEIdent": csv["le_ident"] ?? "",
      "HEIdent": csv["he_ident"] ?? "",
      "LELatitude": csv["le_latitude_deg"] ?? "",
      "HELatitude": csv["he_latitude_deg"] ?? "",
      "LELongitude": csv["le_longitude_deg"] ?? "",
      "HELongitude": csv["he_longitude_deg"] ?? "",
      "LEElevation": csv["le_elevation_ft"] ?? "",
      "HEElevation": csv["he_elevation_ft"] ?? "",
      "LEHeadingT": csv["le_heading_degT"] ?? "",
      "HEHeading": csv["he_heading_degT"] ?? "",
      "LEDT": csv["le_displaced_threshold_ft"] ?? "",
      "HEDT": csv["he_displaced_threshold_ft"] ?? "",
      "LELights": lights,
      "HELights": lights,
      "LEILS": "",
      "HEILS": "",
      "LEVGSI": "",
      "HEVGSI": "",
      "LEPattern": "N",
      "HEPattern": "N",
    };
  }

  // returns (airportfreq rows, CTAF by airport, UNICOM by airport)
  static (List<Map<String, Object?>>, Map<String, String>, Map<String, String>)
      frequencyRows(List<Map<String, String>> csvRows) {
    List<Map<String, Object?>> rows = [];
    Map<String, String> ctaf = {};
    Map<String, String> unicom = {};
    for(Map<String, String> csv in csvRows) {
      String ident = (csv["airport_ident"] ?? "").toUpperCase();
      String freq = csv["frequency_mhz"] ?? "";
      String type = (csv["type"] ?? "").toUpperCase();
      if(ident.isEmpty || freq.isEmpty) {
        continue;
      }
      String dlid = "$dlidPrefix$ident";
      switch(type) {
        case "TWR":
          rows.add({"DLID": dlid, "Type": "LCL/P", "Freq": freq});
          break;
        case "GND":
          rows.add({"DLID": dlid, "Type": "GND/P", "Freq": freq});
          break;
        case "ATIS":
          rows.add({"DLID": dlid, "Type": "ATIS", "Freq": freq});
          break;
        case "APP":
        case "DEP":
        case "ARR":
          rows.add({"DLID": dlid, "Type": "APCH/P DEP/P", "Freq": freq});
          break;
        case "CLD":
        case "DEL":
          rows.add({"DLID": dlid, "Type": "CD/P", "Freq": freq});
          break;
        case "CTAF":
        case "MF":
        case "ATF":
          ctaf.putIfAbsent(ident, () => freq);
          break;
        case "UNIC":
        case "UNICOM":
          unicom.putIfAbsent(ident, () => freq);
          break;
        default:
          // FSS/RCO/RDO/... keep visible as remarks
          rows.add({"DLID": dlid, "Type": "Remark",
            "Freq": "${csv['description'] ?? type} $freq"});
          break;
      }
    }
    return (rows, ctaf, unicom);
  }

  static Map<String, Object?>? navaidRow(Map<String, String> csv) {
    String ident = (csv["ident"] ?? "").toUpperCase();
    if(ident.isEmpty) {
      return null;
    }
    String? type = const {
      "VOR": "VOR",
      "VOR-DME": "VOR/DME",
      "VORTAC": "VORTAC",
      "TACAN": "TACAN",
      "NDB": "NDB",
      "NDB-DME": "NDB/DME",
      "DME": "DME",
    }[csv["type"]];
    if(type == null) {
      return null;
    }
    double? lat = double.tryParse(csv["latitude_deg"] ?? "");
    double? lon = double.tryParse(csv["longitude_deg"] ?? "");
    if(lat == null || lon == null) {
      return null;
    }
    // FAA style embeds the frequency in the facility name ("BOSTON 112.70")
    String name = (csv["name"] ?? "").toUpperCase();
    double? khz = double.tryParse(csv["frequency_khz"] ?? "");
    if(khz != null && khz > 0) {
      name = type.startsWith("NDB")
          ? "$name ${khz.toInt()}"
          : "$name ${(khz / 1000).toStringAsFixed(2)}";
    }
    int variation =
        double.tryParse(csv["magnetic_variation_deg"] ?? "")?.round() ?? 0;
    String? cls = const {"HIGH": "H", "MEDIUM": "M", "LOW": "L"}[
        (csv["power"] ?? "").toUpperCase()];
    return {
      "LocationID": ident,
      "ARPLatitude": lat,
      "ARPLongitude": lon,
      "Type": type,
      "FacilityName": name,
      "Variation": variation,
      "Class": cls ?? "",
      "Hiwas": "N",
      "Elevation": (csv["elevation_ft"] ?? "").isEmpty ? "0" : csv["elevation_ft"]!,
    };
  }

  // isolate entry: file paths in, mapped table rows out
  static Map<String, dynamic> _parseAll(Map<String, String> files) {
    List<Map<String, String>> airports =
        parseCsv(File(files[airportsCsv]!).readAsStringSync());
    Set<String> idents =
        airports.map((a) => (a["ident"] ?? "").toUpperCase()).toSet();

    List<Map<String, String>> runways = filterByAirport(
        parseCsv(File(files[runwaysCsv]!).readAsStringSync()), idents);
    List<Map<String, String>> frequencies = filterByAirport(
        parseCsv(File(files[frequenciesCsv]!).readAsStringSync()), idents);
    List<Map<String, String>> navaids =
        parseCsv(File(files[navaidsCsv]!).readAsStringSync());

    final (freqRows, ctaf, unicom) = frequencyRows(frequencies);

    // Transport Canada register (optional: older downloads lack it)
    List<Map<String, Object?>> registry = [];
    String? registryPath = files[registryFile];
    if (registryPath != null && File(registryPath).existsSync()) {
      registry = CanadaRegistry.parse(File(registryPath).readAsBytesSync());
    }

    return {
      "registry": registry,
      "airports": airports
          .map((a) => airportRow(a, ctaf, unicom))
          .whereType<Map<String, Object?>>()
          .toList(),
      "runways": runways
          .map(runwayRow)
          .whereType<Map<String, Object?>>()
          .toList(),
      "frequencies": freqRows,
      "navaids": navaids
          .map(navaidRow)
          .whereType<Map<String, Object?>>()
          .toList(),
    };
  }

  static bool _filesPresent() {
    return [airportsCsv, runwaysCsv, frequenciesCsv, navaidsCsv]
        .every((f) => File(dataPath(f)).existsSync());
  }

  // parse cached CSVs and (re)populate main.db; throws on failure
  static Future<void> importAll() async {
    Database? db = await MainDatabaseHelper.db.database;
    if(db == null || !_filesPresent()) {
      return;
    }

    Map<String, dynamic> parsed = await compute(_parseAll, {
      airportsCsv: dataPath(airportsCsv),
      runwaysCsv: dataPath(runwaysCsv),
      frequenciesCsv: dataPath(frequenciesCsv),
      navaidsCsv: dataPath(navaidsCsv),
      registryFile: dataPath(registryFile),
    });
    List<Map<String, Object?>> registry = List.from(parsed["registry"]);

    List<Map<String, Object?>> airports = List.from(parsed["airports"]);
    List<Map<String, Object?>> runways = List.from(parsed["runways"]);
    List<Map<String, Object?>> frequencies = List.from(parsed["frequencies"]);
    List<Map<String, Object?>> navaids = List.from(parsed["navaids"]);

    // main.db ships some Canadian airports (State='CN') and navaids from FAA
    // data; those stay authoritative. airports has UNIQUE(LocationID) so
    // INSERT OR IGNORE skips them, but skip their child rows explicitly.
    Set<String> existing = (await db.query("airports", columns: ["LocationID"]))
        .map((r) => r["LocationID"] as String)
        .toSet();
    List<Map<String, Object?>> existingNavs =
        await db.query("nav", columns: ["LocationID", "Type", "ARPLatitude"]);
    Set<String> existingNavKeys = existingNavs
        .map((r) => "${r['LocationID']}.${r['Type']}")
        .toSet();

    // main.db ships without this table; it is recreated after every
    // DatabasesX cycle update along with the rest of the import
    await db.execute("create table if not exists caregistry("
        "ICAO integer primary key, Mark text, Model text, CommonName text)");

    await db.transaction((txn) async {
      await _purgeTxn(txn);
      Batch batch = txn.batch();
      for(Map<String, Object?> row in registry) {
        batch.insert("caregistry", row,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for(Map<String, Object?> row in airports) {
        batch.insert("airports", row,
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      Set<String> skippedDlid = airports
          .where((a) => existing.contains(a["LocationID"]))
          .map((a) => a["DLID"] as String)
          .toSet();
      for(Map<String, Object?> row in runways) {
        if(!skippedDlid.contains(row["DLID"])) {
          batch.insert("airportrunways", row);
        }
      }
      for(Map<String, Object?> row in frequencies) {
        if(!skippedDlid.contains(row["DLID"])) {
          batch.insert("airportfreq", row);
        }
      }
      for(Map<String, Object?> row in navaids) {
        // nav has no unique constraint; do not duplicate FAA-provided navaids
        if(!existingNavKeys.contains("${row['LocationID']}.${row['Type']}")) {
          batch.insert("nav", row);
        }
      }
      await batch.commit(noResult: true);
    });
    AppLog.logMessage("Canada import: ${airports.length} airports, "
        "${runways.length} runways, ${navaids.length} navaids, "
        "${registry.length} registered aircraft");
  }

  // remove all imported rows (navaids matched from the cached CSV since nav
  // has no DLID column)
  static Future<void> purge() async {
    Database? db = await MainDatabaseHelper.db.database;
    if(db == null) {
      return;
    }
    await db.transaction(_purgeTxn);
  }

  static Future<void> _purgeTxn(Transaction txn) async {
    try {
      await txn.delete("caregistry");
    }
    catch(e) {
      // table absent on a fresh main.db
    }
    await txn.delete("airports", where: "DLID like '$dlidPrefix%'");
    await txn.delete("airportrunways", where: "DLID like '$dlidPrefix%'");
    await txn.delete("airportfreq", where: "DLID like '$dlidPrefix%'");
    try {
      String text = await File(dataPath(navaidsCsv)).readAsString();
      for(Map<String, String> csv in parseCsv(text)) {
        Map<String, Object?>? row = navaidRow(csv);
        if(row != null) {
          await txn.delete("nav",
              where: "LocationID = ? and FacilityName = ?",
              whereArgs: [row["LocationID"], row["FacilityName"]]);
        }
      }
    }
    catch(e) {
      // navaids csv missing; nothing to purge by
    }
  }

  // imported airports for the map marker layer
  static Future<List<Map<String, Object?>>> getAirports() async {
    Database? db = await MainDatabaseHelper.db.database;
    if(db == null) {
      return [];
    }
    return db.rawQuery("select LocationID, FacilityName, Type, ARPLatitude, "
        "ARPLongitude from airports where DLID like '$dlidPrefix%'");
  }

  // Transport Canada register rows for the in-memory lookup
  static Future<List<Map<String, Object?>>> getRegistry() async {
    Database? db = await MainDatabaseHelper.db.database;
    if(db == null) {
      return [];
    }
    try {
      return await db.query("caregistry",
          columns: ["ICAO", "Mark", "Model", "CommonName"]);
    }
    catch(e) {
      return []; // table absent: registry never imported
    }
  }

  // after a DatabasesX update replaces main.db, or on startup after a failed
  // import, restore Canadian rows from the cached CSVs (no network needed)
  static Future<void> reimportIfInstalled() async {
    try {
      if(!_filesPresent()) {
        return; // canada product not downloaded
      }
      Database? db = await MainDatabaseHelper.db.database;
      if(db == null) {
        return;
      }
      List<Map<String, Object?>> count = await db.rawQuery(
          "select count(*) as c from airports where DLID like '$dlidPrefix%'");
      if((count[0]["c"] as int) > 0) {
        return; // still populated
      }
      await importAll();
    }
    catch(e) {
      AppLog.logMessage("Canada reimport failed: $e");
    }
  }
}
