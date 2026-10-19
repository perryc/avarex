import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Where a fix came from. External receivers win over the phone when both
/// are present (see Storage.gpsSourceMode).
enum GpsFixSource { internal, nmea, adsb }

/// One raw position fix, published as soon as it is decoded rather than on
/// the 1 Hz fused cadence. Precision guidance needs every epoch an RTK
/// receiver produces (typically 5-10 Hz) and needs to know how good it is.
class GpsFix {
  /// NMEA GGA fix quality codes.
  static const int qualityNone = 0;
  static const int qualityGps = 1;
  static const int qualityDgps = 2;
  static const int qualityPps = 3;
  static const int qualityRtkFixed = 4;
  static const int qualityRtkFloat = 5;
  static const int qualityEstimated = 6;

  final LatLng position;
  /// Metres above mean sea level as the receiver reported it (no geoid fiddling).
  final double altitudeMslM;
  final double speedMps;
  final double trackDeg;
  final GpsFixSource source;
  /// NMEA quality code; for non-NMEA sources this is [qualityGps] when a fix
  /// is present.
  final int fixQuality;
  final int satellites;
  final double hdop;
  /// Receiver-reported horizontal accuracy in metres when known.
  final double? accuracyM;
  final double? diffAgeS;
  final DateTime time;

  const GpsFix({
    required this.position,
    required this.altitudeMslM,
    required this.speedMps,
    required this.trackDeg,
    required this.source,
    required this.fixQuality,
    this.satellites = 0,
    this.hdop = 99,
    this.accuracyM,
    this.diffAgeS,
    required this.time,
  });

  factory GpsFix.fromPosition(Position p, GpsFixSource source,
      {int fixQuality = qualityGps, int satellites = 0, double hdop = 99, double? diffAgeS}) {
    return GpsFix(
      position: LatLng(p.latitude, p.longitude),
      altitudeMslM: p.altitude,
      speedMps: p.speed,
      trackDeg: p.heading,
      source: source,
      fixQuality: fixQuality,
      satellites: satellites,
      hdop: hdop,
      accuracyM: source == GpsFixSource.internal && p.accuracy > 0 ? p.accuracy : null,
      diffAgeS: diffAgeS,
      time: DateTime.now(),
    );
  }

  bool get isRtkFixed => fixQuality == qualityRtkFixed;
  bool get isRtkFloat => fixQuality == qualityRtkFloat;
  bool get isRtk => isRtkFixed || isRtkFloat;

  /// Short badge for the display: RTK FIX, RTK FLT, DGPS, GPS, ADS-B, INT.
  String get qualityLabel {
    switch (fixQuality) {
      case qualityRtkFixed:
        return "RTK FIX";
      case qualityRtkFloat:
        return "RTK FLT";
      case qualityDgps:
        return "DGPS";
      case qualityPps:
        return "PPS";
      case qualityEstimated:
        return "DR";
      case qualityNone:
        return "NO FIX";
    }
    switch (source) {
      case GpsFixSource.adsb:
        return "ADS-B";
      case GpsFixSource.internal:
        return "INT GPS";
      case GpsFixSource.nmea:
        return "GPS";
    }
  }

  /// Rough 1-sigma horizontal error in metres used to size the guidance
  /// confidence band when the receiver does not report accuracy.
  double get estimatedErrorM {
    if (accuracyM != null) return accuracyM!;
    switch (fixQuality) {
      case qualityRtkFixed:
        return 0.03;
      case qualityRtkFloat:
        return 0.5;
      case qualityDgps:
        return 1.0;
      default:
        return 3.0;
    }
  }
}
