import 'dart:convert';
import 'dart:math';

import 'package:avaremp/data/user_database_helper.dart';
import 'package:avaremp/instruments/pfd_runway.dart';
import 'package:avaremp/utils/geo_calculations.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

/// A runway whose threshold positions were measured on the ground with a
/// precision (RTK / PPP) receiver, as produced by the PPA survey app
/// (github.com/perryc/ppa). Overrides the FAA / Nav Canada database row for
/// the same runway and adds strips the database does not know about.
///
/// Distances in feet, headings true, elevations feet MSL. Threshold 1 is the
/// landing threshold when landing on [ident1]; threshold 2 for [ident2].
class SurveyedRunway {
  final String airport;
  final String designator; // "11/29"
  final String ident1;
  final String ident2;
  final LatLng threshold1;
  final LatLng threshold2;
  final double elev1Ft;
  final double elev2Ft;
  final double widthFt;
  final double glideslopeDeg;
  final double tchFt;
  final double? accuracyM;
  final String? surveyedBy;
  final int? surveyDateMs;
  final String source;

  SurveyedRunway({
    required this.airport,
    required this.designator,
    required this.ident1,
    required this.ident2,
    required this.threshold1,
    required this.threshold2,
    required this.elev1Ft,
    required this.elev2Ft,
    required this.widthFt,
    this.glideslopeDeg = 3.0,
    this.tchFt = 25.0,
    this.accuracyM,
    this.surveyedBy,
    this.surveyDateMs,
    this.source = "",
  });

  String get key => "$airport|$designator";

  /// Pavement length from the surveyed thresholds.
  double get lengthFt {
    const Distance d = Distance(calculator: Haversine());
    return d.as(LengthUnit.Meter, threshold1, threshold2) * 3.28084;
  }

  double get heading1True => GeoCalculations().calculateBearing(threshold1, threshold2);
  double get heading2True => GeoCalculations().calculateBearing(threshold2, threshold1);

  /// Both landing directions as the PFD painter / approach engine expect.
  List<PfdRunwayEnd> toRunwayEnds() {
    final double len = lengthFt;
    return [
      PfdRunwayEnd(
        airportId: airport,
        ident: ident1,
        farIdent: ident2,
        physicalEnd: threshold1,
        farEnd: threshold2,
        headingTrue: heading1True,
        lengthFt: len,
        widthFt: widthFt,
        displacedFt: 0,
        farDisplacedFt: 0,
        endElevFt: elev1Ft,
        farElevFt: elev2Ft,
      ),
      PfdRunwayEnd(
        airportId: airport,
        ident: ident2,
        farIdent: ident1,
        physicalEnd: threshold2,
        farEnd: threshold1,
        headingTrue: heading2True,
        lengthFt: len,
        widthFt: widthFt,
        displacedFt: 0,
        farDisplacedFt: 0,
        endElevFt: elev2Ft,
        farElevFt: elev1Ft,
      ),
    ];
  }

  /// True when this survey describes the same physical runway as a database
  /// row with the given end idents (either order, e.g. "11"/"29").
  bool matchesIdents(String le, String he) {
    final String a = _normIdent(le), b = _normIdent(he);
    final String i1 = _normIdent(ident1), i2 = _normIdent(ident2);
    return (a == i1 && b == i2) || (a == i2 && b == i1);
  }

  static String _normIdent(String s) {
    s = s.trim().toUpperCase();
    // database idents can be zero padded ("05") or not ("5")
    final RegExp re = RegExp(r'^0*(\d+)([LRC]?)$');
    final Match? m = re.firstMatch(s);
    return m == null ? s : "${m.group(1)}${m.group(2)}";
  }

  Map<String, dynamic> toMap() => {
        "airport": airport,
        "designator": designator,
        "ident1": ident1,
        "ident2": ident2,
        "t1_lat": threshold1.latitude,
        "t1_lon": threshold1.longitude,
        "t1_elev_ft": elev1Ft,
        "t2_lat": threshold2.latitude,
        "t2_lon": threshold2.longitude,
        "t2_elev_ft": elev2Ft,
        "width_ft": widthFt,
        "glideslope_deg": glideslopeDeg,
        "tch_ft": tchFt,
        "accuracy_m": accuracyM,
        "surveyed_by": surveyedBy,
        "survey_date_ms": surveyDateMs,
        "source": source,
      };

  factory SurveyedRunway.fromMap(Map<String, dynamic> m) {
    double d(dynamic v, [double f = 0]) =>
        v == null ? f : (double.tryParse(v.toString()) ?? f);
    return SurveyedRunway(
      airport: m["airport"] as String,
      designator: m["designator"] as String,
      ident1: m["ident1"] as String,
      ident2: m["ident2"] as String,
      threshold1: LatLng(d(m["t1_lat"]), d(m["t1_lon"])),
      threshold2: LatLng(d(m["t2_lat"]), d(m["t2_lon"])),
      elev1Ft: d(m["t1_elev_ft"]),
      elev2Ft: d(m["t2_elev_ft"]),
      widthFt: d(m["width_ft"], 75),
      glideslopeDeg: d(m["glideslope_deg"], 3),
      tchFt: d(m["tch_ft"], 25),
      accuracyM: m["accuracy_m"] == null ? null : d(m["accuracy_m"]),
      surveyedBy: m["surveyed_by"] as String?,
      surveyDateMs: m["survey_date_ms"] == null ? null : int.tryParse(m["survey_date_ms"].toString()),
      source: (m["source"] as String?) ?? "",
    );
  }

  SurveyedRunway copyWith({double? glideslopeDeg, double? tchFt}) => SurveyedRunway(
        airport: airport,
        designator: designator,
        ident1: ident1,
        ident2: ident2,
        threshold1: threshold1,
        threshold2: threshold2,
        elev1Ft: elev1Ft,
        elev2Ft: elev2Ft,
        widthFt: widthFt,
        glideslopeDeg: glideslopeDeg ?? this.glideslopeDeg,
        tchFt: tchFt ?? this.tchFt,
        accuracyM: accuracyM,
        surveyedBy: surveyedBy,
        surveyDateMs: surveyDateMs,
        source: source,
      );
}

/// Parses the two file formats the PPA app produces.
///
/// 1. Community airport JSON (github.com/perryc/ppa_airports, `airports/XX/ICAO.json`):
///    `{icao_code, elevation_ft, runways:[{designation, width_ft, threshold1:{latitude,
///    longitude, elevation_ft}, threshold2:{...}, survey_metadata:{...}}]}`
/// 2. PPA survey GeoJSON export: a FeatureCollection with a `runway_centerline`
///    LineString (threshold 1 to threshold 2, `[lon, lat, elev_ft, lon, lat, elev_ft]`)
///    plus optional `CORNER_n` Point features used to derive the width.
class RunwaySurveyImporter {
  static List<SurveyedRunway> parse(String content, {String source = ""}) {
    final dynamic root = json.decode(content);
    if (root is Map<String, dynamic>) {
      if (root["type"] == "FeatureCollection") {
        return _parseGeoJson(root, source);
      }
      if (root.containsKey("icao_code")) {
        return _parseAirportJson(root, source);
      }
    }
    if (root is List) {
      // a bundle of airport files
      final List<SurveyedRunway> out = [];
      for (final e in root) {
        if (e is Map<String, dynamic> && e.containsKey("icao_code")) {
          out.addAll(_parseAirportJson(e, source));
        }
      }
      return out;
    }
    throw const FormatException("Not a PPA airport JSON or survey GeoJSON file");
  }

  static (String, String) splitDesignator(String designator) {
    final List<String> parts = designator.toUpperCase().split("/");
    if (parts.length == 2 && parts[0].trim().isNotEmpty && parts[1].trim().isNotEmpty) {
      return (parts[0].trim(), parts[1].trim());
    }
    // single ident: compute the reciprocal
    final String one = designator.trim().toUpperCase();
    final RegExp re = RegExp(r'^(\d+)([LRC]?)$');
    final Match? m = re.firstMatch(one);
    if (m == null) return (one, "");
    final int n = int.parse(m.group(1)!);
    final int r = ((n + 18 - 1) % 36) + 1;
    final String side = m.group(2) == "L" ? "R" : (m.group(2) == "R" ? "L" : m.group(2)!);
    return (one, "${r.toString().padLeft(2, '0')}$side");
  }

  static double _d(dynamic v, [double f = 0]) =>
      v == null ? f : (double.tryParse(v.toString()) ?? f);

  static List<SurveyedRunway> _parseAirportJson(Map<String, dynamic> a, String source) {
    final String icao = (a["icao_code"] as String).trim().toUpperCase();
    final double apElev = _d(a["elevation_ft"]);
    final List<SurveyedRunway> out = [];
    for (final r in (a["runways"] as List? ?? [])) {
      if (r is! Map<String, dynamic>) continue;
      final Map<String, dynamic>? t1 = r["threshold1"] as Map<String, dynamic>?;
      final Map<String, dynamic>? t2 = r["threshold2"] as Map<String, dynamic>?;
      if (t1 == null || t2 == null) continue;
      final (i1, i2) = splitDesignator(r["designation"].toString());
      final Map<String, dynamic>? meta = r["survey_metadata"] as Map<String, dynamic>?;
      out.add(SurveyedRunway(
        airport: icao,
        designator: "$i1/$i2",
        ident1: i1,
        ident2: i2,
        threshold1: LatLng(_d(t1["latitude"]), _d(t1["longitude"])),
        threshold2: LatLng(_d(t2["latitude"]), _d(t2["longitude"])),
        elev1Ft: _d(t1["elevation_ft"], apElev),
        elev2Ft: _d(t2["elevation_ft"], apElev),
        widthFt: max(20.0, _d(r["width_ft"], 75)),
        glideslopeDeg: _d(r["glideslope_deg"], 3.0),
        tchFt: _d(r["tch_ft"], 25.0),
        accuracyM: meta == null ? null : _d(meta["gps_accuracy_m"], 999),
        surveyedBy: meta?["surveyed_by"]?.toString(),
        surveyDateMs: meta == null ? null : int.tryParse(meta["survey_date"].toString()),
        source: source,
      ));
    }
    return out;
  }

  static List<SurveyedRunway> _parseGeoJson(Map<String, dynamic> fc, String source) {
    final List<SurveyedRunway> out = [];
    final List<LatLng> corners = [];
    Map<String, dynamic>? centerline;
    for (final f in (fc["features"] as List? ?? [])) {
      if (f is! Map<String, dynamic>) continue;
      final Map<String, dynamic> props = (f["properties"] as Map<String, dynamic>?) ?? {};
      final Map<String, dynamic> geom = (f["geometry"] as Map<String, dynamic>?) ?? {};
      final String type = props["type"]?.toString() ?? "";
      if (type == "runway_centerline") {
        centerline = f;
      } else if (type.startsWith("CORNER") && geom["type"] == "Point") {
        final List c = geom["coordinates"] as List;
        if (c.length >= 2) corners.add(LatLng(_d(c[1]), _d(c[0])));
      }
    }
    if (centerline == null) return out;
    final Map<String, dynamic> props = centerline["properties"] as Map<String, dynamic>;
    final List c = (centerline["geometry"] as Map<String, dynamic>)["coordinates"] as List;
    // PPA writes a flat [lon, lat, elev, lon, lat, elev]; standard GeoJSON
    // nests [[lon, lat, elev], [lon, lat, elev]]. Accept both.
    final List<double> flat = [];
    for (final v in c) {
      if (v is List) {
        for (final w in v) {
          flat.add(_d(w));
        }
      } else {
        flat.add(_d(v));
      }
    }
    if (flat.length < 4) return out;
    final bool hasElev = flat.length >= 6;
    final int stride = hasElev ? 3 : 2;
    final LatLng t1 = LatLng(flat[1], flat[0]);
    final LatLng t2 = LatLng(flat[stride + 1], flat[stride]);
    final double e1 = hasElev ? flat[2] : 0;
    final double e2 = hasElev ? flat[5] : 0;
    final (i1, i2) = splitDesignator(props["designator"]?.toString() ?? "");
    double width = _d(props["width_ft"], 0);
    if (width <= 0 && corners.length >= 2) {
      // corners 1 and 2 are the two edges of the same threshold
      const Distance d = Distance(calculator: Haversine());
      width = d.as(LengthUnit.Meter, corners[0], corners[1]) * 3.28084;
    }
    final Map<String, dynamic>? meta = fc["properties"] as Map<String, dynamic>?;
    out.add(SurveyedRunway(
      airport: (props["airport"]?.toString() ?? "").toUpperCase(),
      designator: "$i1/$i2",
      ident1: i1,
      ident2: i2,
      threshold1: t1,
      threshold2: t2,
      elev1Ft: e1,
      elev2Ft: e2,
      widthFt: width > 0 ? max(20.0, width) : 75,
      accuracyM: meta == null ? null : _d(meta["surveyAccuracy"], 999),
      surveyedBy: meta?["surveyedBy"]?.toString(),
      surveyDateMs: meta == null ? null : int.tryParse(meta["surveyDate"].toString()),
      source: source,
    ));
    return out;
  }
}

/// In-memory copy of the user.db `runway_survey` table so the 1 Hz runway
/// selector never touches the database.
class RunwaySurveyStore {
  RunwaySurveyStore._();
  static final RunwaySurveyStore _instance = RunwaySurveyStore._();
  factory RunwaySurveyStore() => _instance;

  final Map<String, SurveyedRunway> _byKey = {};
  final ValueNotifier<int> change = ValueNotifier(0);

  List<SurveyedRunway> get all => _byKey.values.toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  List<SurveyedRunway> forAirport(String airport) {
    final String id = airport.toUpperCase();
    return _byKey.values.where((r) => r.airport == id).toList();
  }

  /// Surveys whose nearer threshold is within [rangeNm] of [near].
  List<SurveyedRunway> near(LatLng near, double rangeNm) {
    const Distance d = Distance(calculator: Haversine());
    final double rangeM = rangeNm * 1852;
    return _byKey.values.where((r) {
      return d.as(LengthUnit.Meter, near, r.threshold1) <= rangeM ||
          d.as(LengthUnit.Meter, near, r.threshold2) <= rangeM;
    }).toList();
  }

  Future<void> load() async {
    _byKey.clear();
    for (final m in await UserDatabaseHelper.db.getAllRunwaySurveys()) {
      try {
        final SurveyedRunway r = SurveyedRunway.fromMap(m);
        _byKey[r.key] = r;
      } catch (_) {}
    }
    change.value++;
  }

  Future<void> put(SurveyedRunway r) async {
    await UserDatabaseHelper.db.addRunwaySurvey(r.toMap());
    _byKey[r.key] = r;
    change.value++;
  }

  Future<void> remove(SurveyedRunway r) async {
    await UserDatabaseHelper.db.deleteRunwaySurvey(r.airport, r.designator);
    _byKey.remove(r.key);
    change.value++;
  }

  /// For tests: seed without a database.
  @visibleForTesting
  void seed(List<SurveyedRunway> rows) {
    _byKey.clear();
    for (final r in rows) {
      _byKey[r.key] = r;
    }
    change.value++;
  }
}
