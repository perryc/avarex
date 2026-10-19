import 'dart:math';

import 'package:avaremp/instruments/pfd_runway.dart';
import 'package:avaremp/instruments/precision_approach.dart';
import 'package:avaremp/instruments/runway_survey.dart';
import 'package:avaremp/io/gps_fix.dart';
import 'package:avaremp/nmea/gga_message.dart';
import 'package:avaremp/nmea/rmc_message.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/unit_conversion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// A straight north runway at 50N 105W, 3000 ft long, threshold at 1800 ft.
PfdRunwayEnd northRunway({double displacedFt = 0}) {
  const LatLng end = LatLng(50.0, -105.0);
  final LatLng far = LatLng(50.0 + 3000 / PfdRunwayEnd.ftPerDegLat, -105.0);
  return PfdRunwayEnd(
    airportId: "TEST",
    ident: "36",
    farIdent: "18",
    physicalEnd: end,
    farEnd: far,
    headingTrue: 0,
    lengthFt: 3000,
    widthFt: 75,
    displacedFt: displacedFt,
    farDisplacedFt: 0,
    endElevFt: 1800,
    farElevFt: 1800,
  );
}

/// Aircraft [southFt] south of the physical end, [eastM] east of centerline,
/// at [altFt] MSL, tracking north at 60 kt.
GpsFix fixAt({required double southFt, double eastM = 0, required double altFt, int quality = GpsFix.qualityRtkFixed}) {
  final double lat = 50.0 - southFt / PfdRunwayEnd.ftPerDegLat;
  final double lon = -105.0 + (eastM * ApproachGuidance.ftPerM) / (PfdRunwayEnd.ftPerDegLat * cos(50.0 * pi / 180));
  return GpsFix(
    position: LatLng(lat, lon),
    altitudeMslM: altFt / ApproachGuidance.ftPerM,
    speedMps: 30.87,
    trackDeg: 0,
    source: GpsFixSource.nmea,
    fixQuality: quality,
    time: DateTime.now(),
  );
}

double idealAltFt(double distFt, ApproachSettings s) => 1800 + s.tchFt + distFt * tan(s.glideslopeDeg * pi / 180);

const String cds2Json = '''
{"icao_code":"CDS2","name":"Disley","elevation_ft":1854,
 "location":{"latitude":50.63447131,"longitude":-105.03184237},
 "runways":[{"designation":"11/29","length_ft":2246,"width_ft":78,"surface":"unknown","magnetic_heading":110.2,
   "threshold1":{"latitude":50.6386954,"longitude":-105.04025895,"elevation_ft":1811},
   "threshold2":{"latitude":50.6358576,"longitude":-105.03164372,"elevation_ft":1811},
   "survey_metadata":{"surveyed_by":"anonymous","survey_date":1759638756620,"gps_accuracy_m":1.03,
     "corner_points":[{"corner":"CORNER_1","latitude":50.6361219,"longitude":-105.03202723,"elevation_ft":1861}]}},
  {"designation":"17/35","length_ft":1171,"width_ft":69,
   "threshold1":{"latitude":50.6361219,"longitude":-105.03188907,"elevation_ft":1861},
   "threshold2":{"latitude":50.63286546,"longitude":-105.03179566,"elevation_ft":1848}}]}
''';

const String surveyGeoJson = '''
{"type":"FeatureCollection","features":[
 {"type":"Feature","geometry":{"type":"LineString","coordinates":[-105.04025895,50.6386954,1811.0,-105.03164372,50.6358576,1811.0]},
  "properties":{"type":"runway_centerline","designator":"11/29","airport":"CDS2","length_ft":"2246.0","heading":"117.0"}},
 {"type":"Feature","geometry":{"type":"Point","coordinates":[-105.0403,50.6388,1811.0]},"properties":{"type":"CORNER_1","accuracy":"0.02","gps_source":"BLE_RTK_FIXED","timestamp":"1"}},
 {"type":"Feature","geometry":{"type":"Point","coordinates":[-105.0402,50.6386,1811.0]},"properties":{"type":"CORNER_2","accuracy":"0.02","gps_source":"BLE_RTK_FIXED","timestamp":"1"}}],
 "properties":{"surveyDate":"1759638756620","surveyAccuracy":0.02,"gpsSource":"BLE_RTK_FIXED","surveyedBy":"perry"}}
''';

void main() {
  setUpAll(() {
    // RMC speed conversion reads the app units; tests have no Storage.init()
    Storage().units = UnitConversion("Knots");
  });

  group('NMEA precision fields', () {
    test('GGA keeps sub-metre altitude and parses quality, sats, HDOP, diff age', () {
      final GGAMessage gga = GGAMessage("GGA");
      gga.parse(r"$GNGGA,181908.00,5038.21234,N,10501.98765,W,4,19,0.6,585.734,M,-23.1,M,1.2,0000*5F");
      expect(gga.fixQuality, GpsFix.qualityRtkFixed);
      expect(gga.satellites, 19);
      expect(gga.hdop, closeTo(0.6, 1e-9));
      expect(gga.altitude, closeTo(585.734, 1e-6));
      expect(gga.geoidSeparation, closeTo(-23.1, 1e-9));
      expect(gga.diffAge, closeTo(1.2, 1e-9));
      expect(gga.coordinate.latitude, closeTo(50 + 38.21234 / 60, 1e-9));
      expect(gga.coordinate.longitude, closeTo(-(105 + 1.98765 / 60), 1e-9));
    });

    test('GGA without differential fields still parses', () {
      final GGAMessage gga = GGAMessage("GGA");
      gga.parse(r"$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47");
      expect(gga.fixQuality, GpsFix.qualityGps);
      expect(gga.satellites, 8);
      expect(gga.diffAge, isNull);
      expect(gga.altitude, closeTo(545.4, 1e-9));
    });

    test('RMC keeps decimal speed and track', () {
      final RMCMessage rmc = RMCMessage("RMC");
      rmc.parse(r"$GPRMC,123519,A,4807.038,N,01131.000,E,62.37,084.4,230394,003.1,W*6A");
      expect(rmc.speed, closeTo(62.37 * 0.514446, 1e-3));
      expect(rmc.track, closeTo(84.4, 1e-9));
    });
  });

  group('GpsFix', () {
    test('quality labels and error estimates', () {
      GpsFix f(int q, GpsFixSource s) => GpsFix(
          position: const LatLng(0, 0), altitudeMslM: 0, speedMps: 0, trackDeg: 0, source: s, fixQuality: q, time: DateTime.now());
      expect(f(GpsFix.qualityRtkFixed, GpsFixSource.nmea).qualityLabel, "RTK FIX");
      expect(f(GpsFix.qualityRtkFloat, GpsFixSource.nmea).qualityLabel, "RTK FLT");
      expect(f(GpsFix.qualityGps, GpsFixSource.adsb).qualityLabel, "ADS-B");
      expect(f(GpsFix.qualityGps, GpsFixSource.internal).qualityLabel, "INT GPS");
      expect(f(GpsFix.qualityRtkFixed, GpsFixSource.nmea).isRtk, isTrue);
      expect(f(GpsFix.qualityRtkFixed, GpsFixSource.nmea).estimatedErrorM, lessThan(0.1));
      expect(f(GpsFix.qualityGps, GpsFixSource.nmea).estimatedErrorM, greaterThan(1));
    });
  });

  group('Survey import', () {
    test('PPA community airport JSON yields both runways with surveyed geometry', () {
      final List<SurveyedRunway> rows = RunwaySurveyImporter.parse(cds2Json, source: "CDS2.json");
      expect(rows.length, 2);
      final SurveyedRunway r = rows.first;
      expect(r.airport, "CDS2");
      expect(r.designator, "11/29");
      expect(r.ident1, "11");
      expect(r.ident2, "29");
      expect(r.widthFt, 78);
      expect(r.elev1Ft, 1811);
      // length from the surveyed thresholds, close to the published figure
      expect(r.lengthFt, closeTo(2246, 40));
      expect(r.heading1True, closeTo(117, 3));
      expect(r.accuracyM, closeTo(1.03, 1e-6));
      expect(r.surveyDateMs, 1759638756620);
      expect(rows[1].designator, "17/35");
      expect(rows[1].elev2Ft, 1848);
    });

    test('PPA survey GeoJSON export (flat coordinate list, corners for width)', () {
      final List<SurveyedRunway> rows = RunwaySurveyImporter.parse(surveyGeoJson);
      expect(rows.length, 1);
      final SurveyedRunway r = rows.first;
      expect(r.airport, "CDS2");
      expect(r.ident1, "11");
      expect(r.ident2, "29");
      expect(r.threshold1.latitude, closeTo(50.6386954, 1e-9));
      expect(r.threshold2.longitude, closeTo(-105.03164372, 1e-9));
      expect(r.elev1Ft, 1811);
      // corner 1 to corner 2 is about 23 m
      expect(r.widthFt, closeTo(75, 10));
      expect(r.surveyedBy, "perry");
    });

    test('rejects unrelated JSON', () {
      expect(() => RunwaySurveyImporter.parse('{"hello": 1}'), throwsFormatException);
    });

    test('designator splitting handles single idents and L/R', () {
      expect(RunwaySurveyImporter.splitDesignator("11/29"), ("11", "29"));
      expect(RunwaySurveyImporter.splitDesignator("35"), ("35", "17"));
      expect(RunwaySurveyImporter.splitDesignator("09L"), ("09L", "27R"));
      expect(RunwaySurveyImporter.splitDesignator("18"), ("18", "36"));
    });

    test('ident matching tolerates zero padding and order', () {
      final SurveyedRunway r = RunwaySurveyImporter.parse(cds2Json).first; // 11/29
      expect(r.matchesIdents("29", "11"), isTrue);
      expect(r.matchesIdents("11", "29"), isTrue);
      expect(r.matchesIdents("17", "35"), isFalse);
      final SurveyedRunway five = SurveyedRunway(
          airport: "X", designator: "5/23", ident1: "5", ident2: "23",
          threshold1: const LatLng(0, 0), threshold2: const LatLng(0.01, 0), elev1Ft: 0, elev2Ft: 0, widthFt: 60);
      expect(five.matchesIdents("05", "23"), isTrue);
    });

    test('round trips through the database map', () {
      final SurveyedRunway r = RunwaySurveyImporter.parse(cds2Json).first;
      final SurveyedRunway back = SurveyedRunway.fromMap(r.toMap());
      expect(back.key, r.key);
      expect(back.threshold1, r.threshold1);
      expect(back.widthFt, r.widthFt);
      expect(back.tchFt, 25);
    });
  });

  group('Selector merge', () {
    test('surveyed runway replaces the database row with the same idents and adds unknown ones', () {
      final PfdRunwayEnd db36 = northRunway();
      final PfdRunwayEnd db18 = PfdRunwayEnd(
          airportId: "TEST", ident: "18", farIdent: "36", physicalEnd: db36.farEnd, farEnd: db36.physicalEnd,
          headingTrue: 180, lengthFt: 3000, widthFt: 75, displacedFt: 0, farDisplacedFt: 0, endElevFt: 1800, farElevFt: 1800);
      final SurveyedRunway survey = SurveyedRunway(
          airport: "TEST", designator: "18/36", ident1: "18", ident2: "36",
          threshold1: db36.farEnd, threshold2: const LatLng(50.0001, -105.0), elev1Ft: 1805, elev2Ft: 1805, widthFt: 60);
      final SurveyedRunway other = SurveyedRunway(
          airport: "TEST", designator: "09/27", ident1: "09", ident2: "27",
          threshold1: const LatLng(50.0, -105.01), threshold2: const LatLng(50.0, -105.0), elev1Ft: 1800, elev2Ft: 1800, widthFt: 50);
      final List<PfdRunwayEnd> merged = PfdRunwaySelector.withSurveys([db36, db18], [survey, other]);
      expect(merged.length, 4);
      final PfdRunwayEnd m36 = merged.firstWhere((e) => e.ident == "36");
      expect(m36.widthFt, 60); // came from the survey
      expect(m36.endElevFt, 1805);
      expect(merged.where((e) => e.ident == "09").length, 1);
    });

    test('store finds surveys near a point', () {
      final RunwaySurveyStore store = RunwaySurveyStore();
      store.seed(RunwaySurveyImporter.parse(cds2Json));
      expect(store.near(const LatLng(50.63, -105.03), 5).length, 2);
      expect(store.near(const LatLng(52.0, -105.03), 5), isEmpty);
      expect(store.forAirport("cds2").length, 2);
      store.seed([]);
    });
  });

  group('Approach guidance', () {
    const ApproachSettings s = ApproachSettings();
    final PfdRunwayEnd rw = northRunway();
    const double oneNm = ApproachGuidance.ftPerNm;

    test('on centerline and on glidepath 1 NM out', () {
      final ApproachGuidance g = ApproachGuidance.compute(rw, fixAt(southFt: oneNm, altFt: idealAltFt(oneNm, s)), s);
      expect(g.phase, ApproachPhase.approach);
      expect(g.distanceNm, closeTo(1.0, 0.002));
      expect(g.crossTrackM.abs(), lessThan(0.05));
      expect(g.verticalErrorFt.abs(), lessThan(0.5));
      expect(g.glidepathDeg, closeTo(3.0, 0.01));
      expect(g.precision, isTrue);
      expect(g.lateralChevrons, 0);
      expect(g.verticalArrows, 0);
      expect(g.lateralNeedle.abs(), lessThan(0.01));
      expect(g.verticalNeedle.abs(), lessThan(0.01));
      expect(g.heightAboveThresholdFt, closeTo(25 + oneNm * tan(3 * pi / 180), 0.5));
      expect(g.secondsToThreshold, closeTo(1852 / 30.87, 1));
    });

    test('10 m right of centerline gives five chevrons and a fly-left needle', () {
      final ApproachGuidance g = ApproachGuidance.compute(rw, fixAt(southFt: oneNm, eastM: 10, altFt: idealAltFt(oneNm, s)), s);
      expect(g.crossTrackM, closeTo(10, 0.1));
      expect(g.lateralChevrons, 5);
      expect(g.lateralNeedle, closeTo(-0.5, 0.01));
      expect(g.localizerDevDeg, closeTo(atan2(10 * ApproachGuidance.ftPerM, oneNm) * 180 / pi, 0.01));
    });

    test('left of centerline is negative and chevrons cap at ten', () {
      final ApproachGuidance g = ApproachGuidance.compute(rw, fixAt(southFt: oneNm, eastM: -45, altFt: idealAltFt(oneNm, s)), s);
      expect(g.crossTrackM, closeTo(-45, 0.2));
      expect(g.lateralChevrons, -10);
      expect(g.lateralNeedle, 1.0); // full fly-right
    });

    test('50 ft high gives three down arrows and a full fly-down needle', () {
      final ApproachGuidance g = ApproachGuidance.compute(rw, fixAt(southFt: oneNm, altFt: idealAltFt(oneNm, s) + 50), s);
      expect(g.verticalErrorFt, closeTo(50, 0.5));
      expect(g.verticalArrows, 3);
      expect(g.verticalNeedle, 1.0);
      expect(g.glideslopeDevDeg, greaterThan(0));
    });

    test('15 ft low gives one up arrow', () {
      final ApproachGuidance g = ApproachGuidance.compute(rw, fixAt(southFt: oneNm, altFt: idealAltFt(oneNm, s) - 15), s);
      expect(g.verticalArrows, -1);
      expect(g.verticalNeedle, closeTo(-(15 / ApproachGuidance.ftPerM) / ApproachGuidance.vertFullScaleM, 0.01));
    });

    test('angular mode beyond 200 m off centerline', () {
      final ApproachGuidance g = ApproachGuidance.compute(rw, fixAt(southFt: 3 * oneNm, eastM: 300, altFt: idealAltFt(3 * oneNm, s)), s);
      expect(g.precision, isFalse);
      expect(g.lateralScaleLabel, contains("°"));
      expect(g.lateralNeedle, -1.0); // 3 degrees off, beyond 2.5 full scale
    });

    test('over the pavement is rollout with lateral guidance only', () {
      final ApproachGuidance g = ApproachGuidance.compute(rw, fixAt(southFt: -1000, eastM: 3, altFt: 1805), s);
      expect(g.phase, ApproachPhase.rollout);
      expect(g.verticalValid, isFalse);
      expect(g.verticalArrows, 0);
      expect(g.lateralChevrons, 1);
      expect(g.lateralNeedle, closeTo(-3 / 20, 0.01));
    });

    test('past the far end is invalid', () {
      final ApproachGuidance g = ApproachGuidance.compute(rw, fixAt(southFt: -4000, altFt: 2000), s);
      expect(g.phase, ApproachPhase.invalid);
      expect(g.lateralChevrons, 0);
      expect(g.lateralNeedle, 0);
    });

    test('displaced threshold moves the glidepath origin', () {
      final PfdRunwayEnd disp = northRunway(displacedFt: 500);
      final ApproachGuidance g = ApproachGuidance.compute(disp, fixAt(southFt: oneNm, altFt: idealAltFt(oneNm, s)), s);
      // 500 ft further from the displaced threshold, so lower than the path
      expect(g.distanceFt, closeTo(oneNm + 500, 1));
      expect(g.verticalErrorFt, closeTo(-500 * tan(3 * pi / 180), 0.5));
    });

    test('glideslope and TCH settings are honoured', () {
      const ApproachSettings steep = ApproachSettings(glideslopeDeg: 4.0, tchFt: 40);
      final ApproachGuidance g = ApproachGuidance.compute(rw, fixAt(southFt: oneNm, altFt: idealAltFt(oneNm, steep)), steep);
      expect(g.verticalErrorFt.abs(), lessThan(0.5));
      expect(g.glidepathDeg, closeTo(4.0, 0.01));
    });

    test('surveyed runway ends feed the engine', () {
      final SurveyedRunway sr = RunwaySurveyImporter.parse(cds2Json).first;
      final PfdRunwayEnd rw29 = sr.toRunwayEnds().firstWhere((e) => e.ident == "29");
      // 0.5 NM out on the extended centerline of 29 at the ideal altitude
      final LatLng ll = const Distance(calculator: Haversine()).offset(rw29.physicalEnd, 926, (rw29.headingTrue + 180) % 360);
      final GpsFix f = GpsFix(
          position: ll,
          altitudeMslM: (1811 + 25 + 0.5 * oneNm * tan(3 * pi / 180)) / ApproachGuidance.ftPerM,
          speedMps: 25, trackDeg: rw29.headingTrue, source: GpsFixSource.nmea,
          fixQuality: GpsFix.qualityRtkFixed, time: DateTime.now());
      final ApproachGuidance g = ApproachGuidance.compute(rw29, f, s);
      expect(g.phase, ApproachPhase.approach);
      expect(g.distanceNm, closeTo(0.5, 0.01));
      expect(g.crossTrackM.abs(), lessThan(1));
      expect(g.verticalErrorFt.abs(), lessThan(2));
    });
  });
}
