import 'package:avaremp/canada/canada_import.dart';
import 'package:avaremp/chart/chart.dart';
import 'package:avaremp/chart/download.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:universal_io/io.dart';

// Downloadable "Canada" product: Canadian airports/runways/frequencies/
// navaids from OurAirports, and airspace from the soaringweb.org OpenAir
// file. Unlike the FAA products this fetches from public sources directly
// (this fork has no access to the apps4av data pipeline), so it has its own
// date-based versioning instead of FAA cycles.
class CanadaDownload extends Download {

  static const String filename = "canadax"; // manifest file name in dataDir

  static const String _ourAirportsBase =
      "https://davidmegginson.github.io/ourairports-data";
  static const String _ourAirportsMirror =
      "https://raw.githubusercontent.com/davidmegginson/ourairports-data/main";
  // Canadian airspace in OpenAir format, maintained by Chris Gough, derived
  // from Nav Canada's Designated Airspace Handbook. The file name carries a
  // version number (e.g. CanAirspace322all.txt) so it is located from the
  // index page at download time.
  static const String _airspaceIndex =
      "http://soaringweb.org/Airspace/NA/HomePage.html";

  // Transport Canada Canadian Civil Aircraft Register, refreshed daily: a
  // zip of carscurr.txt (current aircraft), carsownr.txt, carslayout.txt.
  // Gives registration mark, model and Mode S address for every Canadian
  // aircraft, which labels traffic ("C-FMHP RV-10") that broadcasts no
  // callsign - most Canadian ADS-B and all FLARM/FANET targets.
  static const String _registryZip =
      "https://wwwapps.tc.gc.ca/saf-sec-sur/2/ccarcs-riacc/download/ccarcsdb.zip";

  static const int _expiryDays = 28; // OurAirports updates nightly

  bool _cancelled = false;

  @override
  void cancel() {
    _cancelled = true;
    super.cancel();
  }

  static bool isVersionExpired(String version) {
    DateTime? downloaded = DateTime.tryParse(version);
    if(downloaded == null) {
      return true;
    }
    return DateTime.now().difference(downloaded).inDays >= _expiryDays;
  }

  Future<void> _fetch(String url, File to) async {
    final request = http.Request("GET", Uri.parse(url));
    final response = await request.send();
    if(response.statusCode != 200) {
      throw Exception("HTTP ${response.statusCode} for $url");
    }
    final sink = to.openWrite();
    try {
      await for(final chunk in response.stream) {
        if(_cancelled) {
          throw Exception("Cancelled");
        }
        sink.add(chunk);
      }
      await sink.close();
    }
    catch(e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await to.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _fetchCsv(String name, File to) async {
    try {
      await _fetch("$_ourAirportsBase/$name", to);
    }
    catch(e) {
      if(_cancelled) {
        rethrow;
      }
      await _fetch("$_ourAirportsMirror/$name", to);
    }
  }

  // locate the current CanAirspace<version>all.txt on the index page
  Future<String> _findAirspaceUrl() async {
    String page = await http.read(Uri.parse(_airspaceIndex));
    RegExpMatch? m =
        RegExp(r'CanAirspace\d+all\.txt', caseSensitive: false).firstMatch(page);
    if(m == null) {
      throw Exception("No Canadian airspace file on index page");
    }
    Uri base = Uri.parse(_airspaceIndex);
    return base.resolve(m.group(0)!).toString();
  }

  @override
  Future<void> download(Chart chart, bool nextCycle, bool backupServer,
      Function(Chart, int)? callback) async {
    _cancelled = false;
    callback!(chart, 0);

    final String dataDir = Storage().dataDir;
    final Directory dir = Directory(path.join(dataDir, CanadaImport.subDir));

    try {
      await dir.create(recursive: true);

      // 0-50: fetch OurAirports CSVs and the airspace file
      final List<String> csvs = [
        CanadaImport.airportsCsv,
        CanadaImport.runwaysCsv,
        CanadaImport.frequenciesCsv,
        CanadaImport.navaidsCsv,
      ];
      for(int i = 0; i < csvs.length; i++) {
        await _fetchCsv(csvs[i], File(CanadaImport.dataPath(csvs[i])));
        callback(chart, ((i + 1) / csvs.length * 40).toInt());
      }

      // airspace is optional; airports still import if soaringweb is down
      bool airspaceOk = true;
      try {
        String url = await _findAirspaceUrl();
        await _fetch(url, File(CanadaImport.dataPath(CanadaImport.airspaceFile)));
      }
      catch(e) {
        if(_cancelled) {
          rethrow;
        }
        airspaceOk = false;
        AppLog.logMessage("Canada airspace download failed: $e");
      }
      callback(chart, 45);

      // register is optional too; traffic falls back to the C-F/C-G formula
      bool registryOk = true;
      try {
        final File zip = File(CanadaImport.dataPath("ccarcsdb.zip"));
        await _fetch(_registryZip, zip);
        await compute(_extractRegistry,
            [zip.path, CanadaImport.dataPath(CanadaImport.registryFile)]);
        try {
          await zip.delete();
        } catch (_) {}
      }
      catch(e) {
        if(_cancelled) {
          rethrow;
        }
        registryOk = false;
        AppLog.logMessage("Canada registry download failed: $e");
      }
      callback(chart, 50);

      // 50-95: import into main.db
      await CanadaImport.importAll();
      await Storage().canadaAirspace.loadAirports();
      await Storage().canadaRegistry.load();
      callback(chart, 95);

      if(airspaceOk) {
        await Storage().canadaAirspace
            .loadFromFile(CanadaImport.dataPath(CanadaImport.airspaceFile));
      }

      // manifest: version line then the files delete() should remove
      final String date = DateFormat("yyyy-MM-dd").format(DateTime.now());
      final List<String> managed = [
        for(String f in csvs) path.join(CanadaImport.subDir, f),
        if(airspaceOk) path.join(CanadaImport.subDir, CanadaImport.airspaceFile),
        if(registryOk) path.join(CanadaImport.subDir, CanadaImport.registryFile),
      ];
      await File(path.join(dataDir, filename))
          .writeAsString("$date\n${managed.join('\n')}\n");

      await Storage().checkChartsExist();
      callback(chart, 100);
    }
    catch(e) {
      AppLog.logMessage("Canada download failed: $e");
      callback(chart, -1);
    }
  }

  // isolate entry: pull carscurr.txt out of the register zip
  static void _extractRegistry(List<String> zipAndOut) {
    final Archive archive =
        ZipDecoder().decodeBytes(File(zipAndOut[0]).readAsBytesSync());
    for (final ArchiveFile f in archive) {
      if (f.name.toLowerCase().endsWith("carscurr.txt")) {
        File(zipAndOut[1]).writeAsBytesSync(f.content as List<int>);
        return;
      }
    }
    throw Exception("carscurr.txt not in register zip");
  }

  @override
  Future<void> delete(Chart chart, Function(Chart, int)? callback) async {
    try {
      await CanadaImport.purge();
    }
    catch(e) {
      AppLog.logMessage("Canada purge failed: $e");
    }
    Storage().canadaAirspace.clear();
    Storage().canadaRegistry.clear();
    await super.delete(chart, callback);
  }
}
