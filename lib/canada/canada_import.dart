import 'package:avaremp/canada/canada_registry.dart';
import 'package:avaremp/canada/cfs_import.dart';
import 'package:avaremp/data/main_database_helper.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:universal_io/io.dart';

// The Canadian product: airspace, the aircraft register, and the queries the
// map layer runs against whatever Canadian aerodromes are installed.
//
// The aerodromes themselves come from the Canada Flight Supplement the user
// supplies; see CfsImport. They used to come from OurAirports, which was
// crowd-sourced and thin, and that import is gone. Rows still carry the
// 'CA-' DLID prefix so they can be told apart from the FAA data that shares
// these tables.
class CanadaImport {

  static const String dlidPrefix = "CA-";
  static const String subDir = "canada";

  static const String airspaceFile = "airspace.txt";
  static const String registryFile = "carscurr.txt"; // TC civil aircraft register

  // bump when importAll output changes so installs re-import from the cached
  // files at startup. 2: re-imports kept airports but dropped their runways,
  // frequencies and navaids. 3: aerodromes come from the CFS, not OurAirports.
  static const int importVersion = 3;

  static String dataPath(String file) =>
      path.join(Storage().dataDir, subDir, file);

  // isolate entry: the register is a few megabytes of fixed-width text
  static List<Map<String, Object?>> _parseRegistry(String file) {
    final File f = File(file);
    return f.existsSync() ? CanadaRegistry.parse(f.readAsBytesSync()) : [];
  }

  static bool _filesPresent() => File(dataPath(registryFile)).existsSync();

  /// The OurAirports CSVs this used to download are dead weight on every
  /// device that ran an older build - around 14 MB of files nothing reads
  /// any more. They are not in the download manifest, so deleting the
  /// product would leave them behind; remove them whenever we pass by.
  static Future<void> removeLegacyFiles() async {
    for(final String name in const [
      "airports.csv", "runways.csv", "airport-frequencies.csv", "navaids.csv",
    ]) {
      try {
        final File f = File(dataPath(name));
        if(f.existsSync()) {
          await f.delete();
          AppLog.logMessage("Canada: removed the unused $name");
        }
      }
      catch(e) {
        // read-only or already gone; it is only wasted space
      }
    }
  }

  /// Put the cached Transport Canada register into main.db. The aerodromes
  /// are CfsImport's job and are left alone.
  static Future<void> importAll() async {
    final Database? db = await MainDatabaseHelper.db.database;
    if(db == null || !_filesPresent()) {
      return;
    }

    final List<Map<String, Object?>> registry =
        await compute(_parseRegistry, dataPath(registryFile));

    // main.db ships without these tables; they are recreated after every
    // DatabasesX cycle update along with the rest of the import
    await db.execute("create table if not exists caregistry("
        "ICAO integer primary key, Mark text, Model text, CommonName text)");
    await db.execute("create table if not exists caimport(Version integer)");

    await db.transaction((txn) async {
      await txn.delete("caregistry");
      await txn.delete("caimport");
      final Batch batch = txn.batch();
      for(final Map<String, Object?> row in registry) {
        batch.insert("caregistry", row,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      batch.insert("caimport", {"Version": importVersion});
      await batch.commit(noResult: true);
    });
    AppLog.logMessage("Canada import: ${registry.length} registered aircraft");
  }

  /// Remove the register. Aerodromes belong to the supplements the user
  /// imported, so they survive deleting this product; CfsImport.purge drops
  /// those.
  static Future<void> purge() async {
    final Database? db = await MainDatabaseHelper.db.database;
    if(db == null) {
      return;
    }
    try {
      await db.delete("caregistry");
      await db.delete("caimport");
    }
    catch(e) {
      // tables absent on a fresh main.db
    }
  }

  // ---------------------------------------------------------------- queries

  // imported airports for the map marker layer
  static Future<List<Map<String, Object?>>> getAirports() async {
    final Database? db = await MainDatabaseHelper.db.database;
    if(db == null) {
      return [];
    }
    return db.rawQuery("select LocationID, FacilityName, Type, ARPLatitude, "
        "ARPLongitude from airports where DLID like '$dlidPrefix%'");
  }

  // Runway geometry for the map symbols. The CFS prints true bearings but no
  // threshold coordinates, so the symbol works from LEHeadingT.
  static Future<List<Map<String, Object?>>> getRunways() async {
    final Database? db = await MainDatabaseHelper.db.database;
    if(db == null) {
      return [];
    }
    try {
      return await db.rawQuery("select DLID, Length, Surface, LEIdent, "
          "LEHeadingT, LELatitude, LELongitude, HELatitude, HELongitude "
          "from airportrunways where DLID like '$dlidPrefix%'");
    }
    catch(e) {
      return []; // table absent: nothing imported yet
    }
  }

  // Airports that have a tower frequency, which the symbol draws in blue.
  static Future<Set<String>> getToweredIdents() async {
    final Database? db = await MainDatabaseHelper.db.database;
    if(db == null) {
      return {};
    }
    try {
      final List<Map<String, Object?>> rows = await db.rawQuery(
          "select distinct DLID from airportfreq where DLID like '$dlidPrefix%' "
          "and Type like 'LCL%'");
      return rows
          .map((r) => (r["DLID"] ?? "").toString())
          .where((d) => d.length > dlidPrefix.length)
          .map((d) => d.substring(dlidPrefix.length))
          .toSet();
    }
    catch(e) {
      return {};
    }
  }

  // Airports the CFS lists fuel for, which the symbol marks with ticks.
  static Future<Set<String>> getFuelIdents() async {
    final Database? db = await MainDatabaseHelper.db.database;
    if(db == null) {
      return {};
    }
    try {
      final List<Map<String, Object?>> rows = await db.rawQuery(
          "select LocationID from airports where DLID like '$dlidPrefix%' "
          "and FuelTypes <> ''");
      return rows.map((r) => (r["LocationID"] ?? "").toString()).toSet();
    }
    catch(e) {
      return {};
    }
  }

  // Transport Canada register rows for the in-memory lookup
  static Future<List<Map<String, Object?>>> getRegistry() async {
    final Database? db = await MainDatabaseHelper.db.database;
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

  // importer version that populated main.db, 0 if none (fresh main.db, or
  // an import from before the version was recorded)
  static Future<int> _importedVersion(Database db) async {
    try {
      final List<Map<String, Object?>> rows = await db.query("caimport");
      return rows.isEmpty ? 0 : rows.first["Version"] as int;
    }
    catch(e) {
      return 0; // table absent
    }
  }

  /// After a DatabasesX update replaces main.db, or on startup after a failed
  /// import, restore the Canadian rows from what is cached on disk. No
  /// network and no PDF reading: the register comes from its text file and
  /// the aerodromes from each supplement's parsed .json.
  static Future<void> reimportIfInstalled() async {
    try {
      final Database? db = await MainDatabaseHelper.db.database;
      if(db == null) {
        return;
      }
      if(_filesPresent() && await _importedVersion(db) < importVersion) {
        await importAll();
      }
      await removeLegacyFiles();
      await CfsImport.reimportIfInstalled();
    }
    catch(e) {
      AppLog.logMessage("Canada reimport failed: $e");
    }
  }
}
