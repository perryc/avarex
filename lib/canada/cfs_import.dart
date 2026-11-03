// Reads Canada Flight Supplement PDFs the user supplies and puts the
// aerodromes they hold into main.db, where the rest of the app finds them
// alongside the FAA data.
//
// Nothing is downloaded and nothing is redistributed. The user points at the
// volumes they bought or downloaded from NAV CANADA, they are copied into the
// app's own storage, and the parsing happens on the device.
//
// Why pdfium and not the Syncfusion reader already in the app: the CFS is set
// in subset Type 1C fonts with no ToUnicode map, and Syncfusion hands back
// glyph codes for exactly the runway and frequency lines that matter.
//
// Each imported volume leaves three things behind: the PDF itself, so the
// aerodrome's own CFS page can be shown; a .json of what was parsed, so a
// cycle update that replaces main.db can be undone without reading the PDFs
// again; and a row in cfsvolume recording the cycle it is good for.

import 'dart:convert';

import 'package:avaremp/canada/canada_import.dart';
import 'package:avaremp/canada/cfs_parse.dart';
import 'package:avaremp/data/main_database_helper.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite/sqflite.dart';
import 'package:universal_io/io.dart';

/// What one imported volume holds, for the import screen to list.
class CfsVolumeInfo {
  final String file;              // base name, which is also the key
  final String regions;           // "AB, SK, MB"
  final DateTime? effectiveFrom;
  final DateTime? effectiveTo;
  final int aerodromes;
  final int pages;

  const CfsVolumeInfo({
    required this.file,
    this.regions = "",
    this.effectiveFrom,
    this.effectiveTo,
    this.aerodromes = 0,
    this.pages = 0,
  });

  /// Out of cycle. The data stays in use and stays useful - runways and
  /// frequencies rarely move - so this is a warning rather than a failure.
  bool get isExpired =>
      effectiveTo != null && DateTime.now().toUtc().isAfter(effectiveTo!);

  /// Days until the cycle ends, negative once it has.
  int? get daysRemaining =>
      effectiveTo?.difference(DateTime.now().toUtc()).inDays;

  static CfsVolumeInfo fromRow(Map<String, Object?> r) => CfsVolumeInfo(
    file: (r["File"] ?? "") as String,
    regions: (r["Regions"] ?? "") as String,
    effectiveFrom: DateTime.tryParse((r["EffectiveFrom"] ?? "") as String),
    effectiveTo: DateTime.tryParse((r["EffectiveTo"] ?? "") as String),
    aerodromes: (r["Aerodromes"] ?? 0) as int,
    pages: (r["Pages"] ?? 0) as int,
  );
}

/// Where one aerodrome sits in which volume, for showing its CFS page.
class CfsPageRef {
  final String file;              // base name of the PDF
  final int firstPage;            // 1-based
  final int lastPage;
  const CfsPageRef(this.file, this.firstPage, this.lastPage);

  String get fullPath => CfsImport.pdfPath(file);
  int get pageCount => lastPage - firstPage + 1;
}

class CfsImport {

  static const String subDir = "canada/cfs";
  static const String dlidPrefix = CanadaImport.dlidPrefix;

  /// Bumped when the rows written here change shape, so an install re-imports
  /// from its cached .json files.
  static const int importVersion = 1;

  static String get directory => path.join(Storage().dataDir, subDir);
  static String pdfPath(String file) => path.join(directory, file);
  static String _jsonPath(String file) => path.join(directory, "$file.json");

  static Future<Directory> _ensureDirectory() =>
      Directory(directory).create(recursive: true);

  // ---------------------------------------------------------------- reading

  /// Every PDF directly inside [dir]. Sub-folders are not walked: a CFS
  /// download is a flat set of volumes.
  static List<String> findPdfs(String dir) {
    try {
      return Directory(dir)
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => p.toLowerCase().endsWith(".pdf"))
          .toList()
        ..sort();
    }
    catch(e) {
      return [];
    }
  }

  /// Pull the text out of every page of one PDF. Reported through [onPage] so
  /// a long volume can show progress; the work is asynchronous rather than in
  /// an isolate because pdfium would have to be initialised in each one.
  static Future<List<String>> readPages(String file,
      {void Function(int page, int of)? onPage}) async {
    await pdfrxFlutterInitialize();
    final PdfDocument document = await PdfDocument.openFile(file);
    try {
      final List<String> pages = [];
      for(int i = 0; i < document.pages.length; i++) {
        final PdfPageRawText? text = await document.pages[i].loadText();
        pages.add(text?.fullText ?? "");
        onPage?.call(i + 1, document.pages.length);
      }
      return pages;
    }
    finally {
      document.dispose();
    }
  }

  // ---------------------------------------------------------------- import

  /// Copy the PDFs in, parse them and write what they hold into main.db.
  /// Returns the volumes that went in. [onProgress] gets a line of text and a
  /// fraction from 0 to 1 so the screen can show where it is.
  static Future<List<CfsVolumeInfo>> importFiles(List<String> paths,
      {void Function(String what, double fraction)? onProgress}) async {
    await _ensureDirectory();
    final List<CfsVolumeInfo> done = [];

    for(int i = 0; i < paths.length; i++) {
      final String source = paths[i];
      final String file = path.basename(source);
      final double base = i / paths.length, span = 1 / paths.length;
      onProgress?.call("Copying $file", base);

      final String target = pdfPath(file);
      if(path.normalize(source) != path.normalize(target)) {
        await File(source).copy(target);
      }

      final List<String> pages = await readPages(target, onPage: (p, of) {
        onProgress?.call("Reading $file, page $p of $of",
            base + span * 0.8 * p / of);
      });

      onProgress?.call("Sorting out $file", base + span * 0.85);
      final CfsVolume volume = await compute(_parse, pages);
      if(volume.aerodromes.isEmpty) {
        AppLog.logMessage("CFS: $file holds no aerodrome directory");
        await File(target).delete();
        continue;
      }
      await File(_jsonPath(file))
          .writeAsString(jsonEncode(volume.toJson()));

      onProgress?.call("Storing ${volume.aerodromes.length} aerodromes",
          base + span * 0.9);
      done.add(await _store(file, volume, pages.length));
    }

    onProgress?.call("Done", 1);
    return done;
  }

  /// Isolate entry: parsing is pure and the page text can be large.
  static CfsVolume _parse(List<String> pages) => CfsParser.parse(pages);

  static Future<CfsVolumeInfo> _store(
      String file, CfsVolume volume, int pages) async {
    final Database? db = await MainDatabaseHelper.db.database;
    final List<String> regions =
        volume.aerodromes.map((a) => a.province).toSet().toList()..sort();
    final CfsVolumeInfo info = CfsVolumeInfo(
      file: file,
      regions: regions.join(", "),
      effectiveFrom: volume.effectiveFrom,
      effectiveTo: volume.effectiveTo,
      aerodromes: volume.aerodromes.length,
      pages: pages,
    );
    if(db == null) {
      return info;
    }
    await createTables(db);

    await db.transaction((txn) async {
      // this volume only: another volume's provinces stay as they are
      await _purgeVolumeTxn(txn, file);

      final Batch batch = txn.batch();
      batch.insert("cfsvolume", {
        "File": file,
        "Regions": info.regions,
        "EffectiveFrom": volume.effectiveFrom?.toIso8601String() ?? "",
        "EffectiveTo": volume.effectiveTo?.toIso8601String() ?? "",
        "Aerodromes": info.aerodromes,
        "Pages": pages,
        "Imported": DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      for(final CfsAerodrome a in volume.aerodromes) {
        batch.insert("cfspage", {
          "Ident": a.ident,
          "File": file,
          "FirstPage": a.firstPage,
          "LastPage": a.lastPage,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        if(a.latitude == null || a.longitude == null) {
          continue;             // nothing to put on a map without a position
        }
        batch.insert("airports", airportRow(a),
            conflictAlgorithm: ConflictAlgorithm.replace);
        for(final Map<String, Object?> r in runwayRows(a)) {
          batch.insert("airportrunways", r);
        }
        for(final Map<String, Object?> f in frequencyRows(a)) {
          batch.insert("airportfreq", f);
        }
        for(final CfsNavaid n in a.navaids) {
          final Map<String, Object?>? row = navaidRow(n);
          if(row != null) {
            batch.insert("nav", row);
          }
        }
      }
      batch.insert("cfsimport", {"Version": importVersion},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await batch.commit(noResult: true);
    });

    AppLog.logMessage("CFS $file: ${info.aerodromes} aerodromes "
        "(${info.regions}), cycle to ${volume.effectiveTo}");
    return info;
  }

  // ------------------------------------------------------------ row shapes

  static Map<String, Object?> airportRow(CfsAerodrome a) {
    final String ident = a.ident.toUpperCase();
    return {
      "LocationID": ident,
      "DLID": "$dlidPrefix$ident",
      "FaaID": ident,
      "ARPLatitude": a.latitude,
      "ARPLongitude": a.longitude,
      "Type": a.isHeliport
          ? "HELIPORT"
          : (a.isWaterAerodrome ? "SEAPLANE BAS" : "AIRPORT"),
      "FacilityName": a.name,
      "Use": "PU",
      "FSSPhone": "",
      "Manager": a.operator ?? "",
      "ManagerPhone": "",
      "ARPElevation": (a.elevationFt ?? 0).toString(),
      "MagneticVariation": a.variation == null
          ? ""
          : "${a.variation!.abs()}${a.variation! >= 0 ? 'E' : 'W'}",
      "TrafficPatternAltitude": "",
      "FuelTypes": fuelCodes(a.fuel),
      "Customs": "",
      "Beacon": "",
      "LightSchedule": "",
      "SegCircle": "",
      "ATCT": a.isTowered ? "Y" : "",
      "UNICOMFrequencies": a.frequencyOf("UNICOM") ?? "",
      // a Canadian aerodrome calls it a mandatory frequency or an aerodrome
      // traffic frequency; both are what the rest of the app means by CTAF
      "CTAFFrequency":
          a.frequencyOf("MF") ?? a.frequencyOf("ATF") ?? a.frequencyOf("UNICOM") ?? "",
      "NonCommercialLandingFee": "",
      "State": a.province,
      "City": a.city,
    };
  }

  /// The FUEL line is prose ("100LL, JA-1 (FSII avbl), SP, HPR 12-04Z"), so
  /// pick the grades out of it and leave the rest.
  static String fuelCodes(String? fuel) {
    if(fuel == null) {
      return "";
    }
    const List<String> grades = [
      "100LL", "100", "JA-1", "JET A-1", "JET A", "JA", "80", "MOGAS", "SP",
    ];
    final String upper = fuel.toUpperCase();
    final List<String> found = [];
    for(final String g in grades) {
      if(upper.contains(g) && !found.any((f) => f.contains(g))) {
        found.add(g);
      }
    }
    return found.join(",");
  }

  static List<Map<String, Object?>> runwayRows(CfsAerodrome a) {
    final String dlid = "$dlidPrefix${a.ident.toUpperCase()}";
    return a.runways.map((r) {
      final double? le = r.trueBearing(a.variation);
      final double? he = r.oppositeBearingTrue?.toDouble() ??
          (le == null ? null : (le + 180) % 360);
      return <String, Object?>{
        "DLID": dlid,
        // empty, not "null": a few entries publish no dimensions at all
        "Length": r.lengthFt?.toString() ?? "",
        "Width": r.widthFt?.toString() ?? "",
        "Surface": r.surface,
        "LEIdent": r.ident,
        "HEIdent": r.oppositeIdent ?? "",
        // the CFS gives no threshold coordinates, only bearings
        "LELatitude": "", "HELatitude": "",
        "LELongitude": "", "HELongitude": "",
        "LEElevation": "", "HEElevation": "",
        "LEHeadingT": le == null ? "" : le.round().toString(),
        "HEHeading": he == null ? "" : he.round().toString(),
        "LEDT": "", "HEDT": "",
        "LELights": "", "HELights": "",
        "LEILS": a.ils.any((i) => i.runway == r.ident) ? "ILS" : "",
        "HEILS": a.ils.any((i) => i.runway == (r.oppositeIdent ?? "")) ? "ILS" : "",
        "LEVGSI": "", "HEVGSI": "",
        "LEPattern": "N", "HEPattern": "N",
      };
    }).toList();
  }

  /// CFS communications labels in the terms the rest of the app uses.
  ///
  /// Only these types get bucketed by the airport page; it drops anything
  /// else on the floor. A Canadian aerodrome's mandatory frequency, its
  /// aerodrome traffic frequency and its UNICOM have no equivalent there, so
  /// they go in as remarks carrying their label in the text, which is how
  /// they stay visible. Approach, arrival and departure share one type
  /// because that is the single string the page tests for.
  static const Map<String, String> _frequencyTypes = {
    "TWR": "LCL/P",
    "GND": "GND/P",
    "ATIS": "ATIS",
    "APP": "APCH/P DEP/P",
    "DEP": "APCH/P DEP/P",
    "ARR": "APCH/P DEP/P",
    "CLNC DEL": "CD/P",
  };

  static List<Map<String, Object?>> frequencyRows(CfsAerodrome a) {
    final String dlid = "$dlidPrefix${a.ident.toUpperCase()}";
    return a.frequencies.map((f) {
      final String? type = _frequencyTypes[f.type];
      return <String, Object?>{
        "DLID": dlid,
        "Type": type ?? "Remark",
        "Freq": type == null ? "${f.type} ${f.mhz}" : f.mhz,
      };
    }).toList();
  }

  static Map<String, Object?>? navaidRow(CfsNavaid n) {
    if(n.latitude == null || n.longitude == null) {
      return null;
    }
    // FAA style puts the frequency in the facility name
    final String name =
        "${n.name.isEmpty ? n.ident : n.name} ${n.frequency}".trim();
    return {
      "LocationID": n.ident,
      "ARPLatitude": n.latitude,
      "ARPLongitude": n.longitude,
      "Type": n.type,
      "FacilityName": name.toUpperCase(),
      "Variation": 0,
      "Class": "",
      "Hiwas": "N",
      "Elevation": (n.elevationFt ?? 0).toString(),
    };
  }

  // ---------------------------------------------------------------- tables

  static Future<void> createTables(Database db) async {
    await db.execute("create table if not exists cfsvolume("
        "File text primary key, Regions text, EffectiveFrom text, "
        "EffectiveTo text, Aerodromes integer, Pages integer, Imported text)");
    await db.execute("create table if not exists cfspage("
        "Ident text primary key, File text, FirstPage integer, "
        "LastPage integer)");
    await db.execute("create table if not exists cfsimport(Version integer)");
  }

  // ---------------------------------------------------------------- queries

  static Future<List<CfsVolumeInfo>> volumes() async {
    final Database? db = await MainDatabaseHelper.db.database;
    if(db == null) {
      return [];
    }
    try {
      return (await db.query("cfsvolume", orderBy: "File"))
          .map(CfsVolumeInfo.fromRow)
          .toList();
    }
    catch(e) {
      return [];     // never imported
    }
  }

  /// Where to find an aerodrome's own pages, or null when it is not in any
  /// volume the user has.
  static Future<CfsPageRef?> pageFor(String ident) async {
    final Database? db = await MainDatabaseHelper.db.database;
    if(db == null) {
      return null;
    }
    try {
      final List<Map<String, Object?>> rows = await db.query("cfspage",
          where: "Ident = ?", whereArgs: [ident.toUpperCase()], limit: 1);
      if(rows.isEmpty) {
        return null;
      }
      final CfsPageRef ref = CfsPageRef(rows.first["File"] as String,
          rows.first["FirstPage"] as int, rows.first["LastPage"] as int);
      return File(ref.fullPath).existsSync() ? ref : null;
    }
    catch(e) {
      return null;
    }
  }

  /// The cycle status of whichever volume holds [ident], for showing the
  /// aerodrome's data with a warning when the supplement is out of date.
  static Future<CfsVolumeInfo?> volumeFor(String ident) async {
    final CfsPageRef? ref = await pageFor(ident);
    if(ref == null) {
      return null;
    }
    for(final CfsVolumeInfo v in await volumes()) {
      if(v.file == ref.file) {
        return v;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- removal

  /// Forget one volume: its rows, its cached parse and its PDF.
  static Future<void> deleteVolume(String file) async {
    final Database? db = await MainDatabaseHelper.db.database;
    if(db != null) {
      await createTables(db);
      await db.transaction((txn) => _purgeVolumeTxn(txn, file));
      await db.delete("cfsvolume", where: "File = ?", whereArgs: [file]);
    }
    for(final String p in [pdfPath(file), _jsonPath(file)]) {
      try {
        final File f = File(p);
        if(f.existsSync()) {
          await f.delete();
        }
      }
      catch(e) {
        AppLog.logMessage("CFS: could not remove $p");
      }
    }
  }

  /// Remove the rows one volume put in, leaving other volumes alone.
  static Future<void> _purgeVolumeTxn(Transaction txn, String file) async {
    final List<Map<String, Object?>> mine = await txn.query("cfspage",
        columns: ["Ident"], where: "File = ?", whereArgs: [file]);
    for(final Map<String, Object?> row in mine) {
      final String dlid = "$dlidPrefix${row['Ident']}";
      await txn.delete("airports", where: "DLID = ?", whereArgs: [dlid]);
      await txn.delete("airportrunways", where: "DLID = ?", whereArgs: [dlid]);
      await txn.delete("airportfreq", where: "DLID = ?", whereArgs: [dlid]);
    }
    await txn.delete("cfspage", where: "File = ?", whereArgs: [file]);
  }

  /// Remove everything this importer wrote.
  static Future<void> purge() async {
    for(final CfsVolumeInfo v in await volumes()) {
      await deleteVolume(v.file);
    }
  }

  // ------------------------------------------------------------- re-import

  /// A cycle update replaces main.db and takes the imported rows with it.
  /// The cached .json files hold what was parsed, so this puts them back
  /// without reading the PDFs again.
  static Future<void> reimportIfInstalled() async {
    try {
      final Database? db = await MainDatabaseHelper.db.database;
      if(db == null) {
        return;
      }
      await createTables(db);
      final List<Map<String, Object?>> rows = await db.query("cfsimport");
      if(rows.isNotEmpty && (rows.first["Version"] as int? ?? 0) >= importVersion
          && (await volumes()).isNotEmpty) {
        return;             // still populated
      }
      final Directory dir = Directory(directory);
      if(!dir.existsSync()) {
        return;             // nothing ever imported
      }
      for(final File f in dir.listSync().whereType<File>()) {
        if(!f.path.endsWith(".pdf.json")) {
          continue;
        }
        final String file = path.basename(f.path);
        final String pdf = file.substring(0, file.length - ".json".length);
        final CfsVolume volume = CfsVolume.fromJson(
            (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>());
        await _store(pdf, volume, 0);
      }
    }
    catch(e) {
      AppLog.logMessage("CFS reimport failed: $e");
    }
  }
}
