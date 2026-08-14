import 'dart:async';

import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:universal_io/io.dart';

// Logs ADS-B reception for post-flight coverage analysis (FIS-B coverage vs
// altitude, plane-to-plane detection ranges per radio link). Fed by the BLE
// receiver links; analyzed by tools/coverage_analyze.py.
//
// Two CSVs per session under dataDir/reception_logs/:
//   samples_<t>.csv  1 Hz: time, own position/altitude, per-band frame
//                    counts from the receiver's vendor 0x65 metrics message,
//                    uplink/traffic/heartbeat notification counts per second
//   targets_<t>.csv  one row per traffic report: link name, ICAO, target
//                    position/altitude, own position/altitude (range is
//                    computed offline)
class ReceptionLogger {

  static const String subDir = "reception_logs";

  final ValueNotifier<bool> enabled = ValueNotifier(false);

  IOSink? _samples;
  IOSink? _targets;
  Timer? _timer;

  // counters accumulated between 1 Hz samples
  int _heartbeats = 0;
  int _traffic = 0;
  int _uplinks = 0;
  int _band1090 = 0;
  int _band978 = 0;
  int _band978Fisb = 0;

  void start() {
    if(enabled.value) {
      return;
    }
    try {
      final dir = Directory(path.join(Storage().dataDir, subDir));
      dir.createSync(recursive: true);
      final stamp = DateTime.now().toUtc().toIso8601String()
          .replaceAll(":", "").split(".").first;
      _samples = File(path.join(dir.path, "samples_$stamp.csv")).openWrite();
      _targets = File(path.join(dir.path, "targets_$stamp.csv")).openWrite();
      _samples!.writeln("time,lat,lon,alt_ft,heartbeats,traffic,uplinks,"
          "frames_1090,frames_978,frames_978_fisb");
      _targets!.writeln("time,link,icao,tlat,tlon,talt_ft,lat,lon,alt_ft");
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
      enabled.value = true;
    }
    catch(e) {
      AppLog.logMessage("Reception logger start failed: $e");
      stop();
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _samples?.close();
    _targets?.close();
    _samples = null;
    _targets = null;
    enabled.value = false;
  }

  void _sample() {
    final sink = _samples;
    if(sink == null) {
      return;
    }
    final p = Storage().position;
    final altFt = (p.altitude * 3.28084).round();
    sink.writeln("${DateTime.now().toUtc().toIso8601String()},"
        "${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)},"
        "$altFt,$_heartbeats,$_traffic,$_uplinks,"
        "$_band1090,$_band978,$_band978Fisb");
    _heartbeats = 0;
    _traffic = 0;
    _uplinks = 0;
    _band1090 = 0;
    _band978 = 0;
    _band978Fisb = 0;
  }

  static double _semicircles(int b0, int b1, int b2) {
    int v = (b0 << 16) | (b1 << 8) | b2;
    if((v & 0x800000) != 0) {
      v -= 0x1000000;
    }
    return v * (180 / 8388608);
  }

  // called by BleLink with every complete framed GDL90 message; must stay
  // cheap when disabled
  void onFrame(String link, List<int> f) {
    if(!enabled.value || f.length < 2) {
      return;
    }
    switch(f[1]) {
      case 0x00:
        _heartbeats++;
        break;
      case 0x07:
        _uplinks++;
        break;
      case 0x14:
        _traffic++;
        if(f.length >= 29 && _targets != null) {
          // framed: [7E][14][st][icao*3][lat*3][lon*3][alt12+misc]...
          // (byte-stuffing is rare in practice; rows from stuffed frames
          // would be garbage and are filtered offline by range sanity)
          final tlat = _semicircles(f[6], f[7], f[8]);
          final tlon = _semicircles(f[9], f[10], f[11]);
          final altRaw = (f[12] << 4) | (f[13] >> 4);
          final talt = altRaw == 0xfff ? -9999 : altRaw * 25 - 1000;
          final icao = (f[3] << 16) | (f[4] << 8) | f[5];
          final p = Storage().position;
          _targets!.writeln("${DateTime.now().toUtc().toIso8601String()},"
              "$link,${icao.toRadixString(16)},"
              "${tlat.toStringAsFixed(6)},${tlon.toStringAsFixed(6)},$talt,"
              "${p.latitude.toStringAsFixed(6)},"
              "${p.longitude.toStringAsFixed(6)},"
              "${(p.altitude * 3.28084).round()}");
        }
        break;
      case 0x65:
        if(f.length >= 15 && f[2] == 0x01) {
          int u32(int o) => f[o] | (f[o + 1] << 8) | (f[o + 2] << 16) | (f[o + 3] << 24);
          _band1090 += u32(3);
          _band978 += u32(7);
          _band978Fisb += u32(11);
        }
        break;
    }
  }
}
