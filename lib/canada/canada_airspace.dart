import 'package:avaremp/canada/canada_import.dart';
import 'package:avaremp/destination/destination.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:avaremp/utils/openair_parser.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:universal_io/io.dart';

// Holds parsed Canadian airspace, its map polygons, and the imported
// airports for the marker layer. Same pattern as GeoJsonParser: Storage owns
// one instance, the map listens on [change].
class CanadaAirspace {

  List<Polygon> polygons = [];
  List<OpenAirAirspace> airspaces = [];
  List<Destination> airports = [];
  ValueNotifier<int> change = ValueNotifier<int>(0);

  // VFR-focused styling: airspace with floors at or above Canadian Class B
  // (12,500' to 18,000', upper airways and high control areas) is not drawn
  // at all - it blankets the country and does not matter below it
  static const int _skipFloorFt = 12500;

  static const Color _magenta = Color(0xFFFF00FF);
  static const Color _blue = Color(0xFF0088FF);
  static const Color _brown = Color(0xFF996633);
  static const Color _red = Color(0xFFFF0000);
  static const Color _orange = Color(0xFFFF8800);
  static const Color _gray = Color(0xFF888888);

  static List<OpenAirAirspace> _parseFile(String filePath) {
    return OpenAirParser().parse(File(filePath).readAsStringSync());
  }

  Future<void> loadFromFile(String filePath) async {
    try {
      if(!File(filePath).existsSync()) {
        return;
      }
      airspaces = await compute(_parseFile, filePath);
      polygons = airspaces.map(_makePolygon).whereType<Polygon>().toList();
      change.value++;
    }
    catch(e) {
      AppLog.logMessage("Canada airspace load failed: $e");
    }
  }

  Future<void> loadAirports() async {
    try {
      airports = (await CanadaImport.getAirports())
          .map(Destination.fromMap)
          .toList();
      change.value++;
    }
    catch(e) {
      AppLog.logMessage("Canada airports load failed: $e");
    }
  }

  void clear() {
    polygons = [];
    airspaces = [];
    airports = [];
    change.value++;
  }

  Polygon _poly(OpenAirAirspace a, Color color,
      {double? fill, double border = 1.5, double borderAlpha = 1.0}) {
    return Polygon(
      points: a.points,
      color: fill == null ? null : color.withValues(alpha: fill),
      borderStrokeWidth: border,
      borderColor: color.withValues(alpha: borderAlpha),
    );
  }

  Polygon? _makePolygon(OpenAirAirspace a) {
    if(a.floorFt >= _skipFloorFt) {
      return null; // upper airways / high control areas, not for VFR
    }
    bool sfc = a.floorFt == 0;
    switch(a.cls.toUpperCase()) {
      case "C": // TCA steps and Class C control zones
        return _poly(a, _magenta, fill: sfc ? 0.15 : 0.06, border: 2.0);
      case "D":
        return _poly(a, _blue, fill: sfc ? 0.15 : 0.06, border: 2.0);
      case "E": // control zones stand out; transition/CAE areas fade back
        return sfc
            ? _poly(a, _blue, fill: 0.10, border: 2.0)
            : _poly(a, _magenta, border: 0.8, borderAlpha: 0.5);
      case "B": // rare below 12,500
        return _poly(a, _blue, border: 1.5);
      case "F": // MF zones read like control zones; CYA advisory stays brown
        return a.name.contains(RegExp(r'\b(MF|ATF)\b'))
            ? _poly(a, _blue, fill: 0.10, border: 2.0)
            : _poly(a, _brown, fill: 0.10, border: 1.5);
      case "R": // CYR
        return _poly(a, _red, fill: 0.12, border: 2.0);
      case "P":
        return _poly(a, _red, fill: 0.35, border: 2.0);
      case "Q": // CYD danger
        return _poly(a, _orange, fill: 0.10, border: 2.0);
      default:
        return _poly(a, _gray, border: 1.0);
    }
  }

  // airspaces containing a point, for long press info
  List<OpenAirAirspace> at(LatLng point) {
    return airspaces.where((a) => a.contains(point)).toList();
  }
}
