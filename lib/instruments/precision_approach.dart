import 'dart:math';

import 'package:avaremp/instruments/pfd_runway.dart';
import 'package:avaremp/io/gps_fix.dart';

/// Tunables for the precision approach display. Defaults follow the PPA app.
class ApproachSettings {
  final double glideslopeDeg;
  /// Threshold crossing height: the glidepath passes this far above the
  /// landing threshold.
  final double tchFt;
  /// Lateral error treated as "on centerline".
  final double centerlineToleranceM;
  /// One lateral chevron per this many metres, up to [maxChevrons].
  final double chevronStepM;
  /// Switch from angular (ILS-like) to metre-based guidance inside this.
  final double precisionSwitchM;

  static const int maxChevrons = 10;

  const ApproachSettings({
    this.glideslopeDeg = 3.0,
    this.tchFt = 25.0,
    this.centerlineToleranceM = 2.0,
    this.chevronStepM = 2.0,
    this.precisionSwitchM = 200.0,
  });

  ApproachSettings copyWith({
    double? glideslopeDeg,
    double? tchFt,
    double? centerlineToleranceM,
    double? chevronStepM,
    double? precisionSwitchM,
  }) =>
      ApproachSettings(
        glideslopeDeg: glideslopeDeg ?? this.glideslopeDeg,
        tchFt: tchFt ?? this.tchFt,
        centerlineToleranceM: centerlineToleranceM ?? this.centerlineToleranceM,
        chevronStepM: chevronStepM ?? this.chevronStepM,
        precisionSwitchM: precisionSwitchM ?? this.precisionSwitchM,
      );
}

enum ApproachPhase {
  /// In front of the threshold, guidance valid.
  approach,
  /// Over the pavement: lateral centerline guidance only.
  rollout,
  /// Behind the runway or too far away.
  invalid,
}

/// Guidance for one fix against one runway end. All geometry is done in the
/// runway frame from [PfdRunwayEnd.frameOf]: `along` increases down the
/// runway from the landing threshold's physical end, `cross` is positive to
/// the right of the extended centerline.
///
/// Sign conventions on the outputs are "where the aircraft is": positive
/// cross-track is right of centerline, positive vertical error is above the
/// glidepath. The display turns those into fly-to needles.
class ApproachGuidance {
  static const double ftPerM = 3.28084;
  static const double ftPerNm = 6076.12;
  /// Guidance is not offered beyond this.
  static const double maxRangeNm = 20;
  /// Angular full-scale deflections (ILS-like) used outside precision mode.
  static const double locFullScaleDeg = 2.5;
  static const double gsFullScaleDeg = 0.7;
  /// Vertical precision full scale and arrow thresholds in metres (PPA).
  static const double vertFullScaleM = 15;

  final PfdRunwayEnd runway;
  final GpsFix fix;
  final ApproachSettings settings;
  final ApproachPhase phase;

  /// Horizontal distance from the landing threshold along the centerline,
  /// positive on the approach side.
  final double distanceFt;
  final double crossTrackM;
  /// Angle of the aircraft off the extended centerline as seen from the
  /// threshold, positive right.
  final double localizerDevDeg;
  final double altitudeFt;
  final double idealAltitudeFt;
  final double verticalErrorFt;
  /// Aircraft's actual glidepath angle to the threshold crossing point.
  final double glidepathDeg;
  final double glideslopeDevDeg;
  final double heightAboveThresholdFt;
  final bool precision;
  final double trackDiffDeg;

  const ApproachGuidance._({
    required this.runway,
    required this.fix,
    required this.settings,
    required this.phase,
    required this.distanceFt,
    required this.crossTrackM,
    required this.localizerDevDeg,
    required this.altitudeFt,
    required this.idealAltitudeFt,
    required this.verticalErrorFt,
    required this.glidepathDeg,
    required this.glideslopeDevDeg,
    required this.heightAboveThresholdFt,
    required this.precision,
    required this.trackDiffDeg,
  });

  static ApproachGuidance compute(PfdRunwayEnd rw, GpsFix fix, ApproachSettings s) {
    final (along, cross) = rw.frameOf(fix.position.latitude, fix.position.longitude);
    final double dAlong = along - rw.displacedFt; // negative on approach
    final double distanceFt = -dAlong;
    final double crossTrackM = cross / ftPerM;

    final double thresholdElevFt = rw.elevationAt(rw.displacedFt);
    final double altitudeFt = fix.altitudeMslM * ftPerM;
    final double hat = altitudeFt - thresholdElevFt;
    final double gsRad = s.glideslopeDeg * pi / 180;

    ApproachPhase phase;
    if (dAlong < 0 && distanceFt <= maxRangeNm * ftPerNm) {
      phase = ApproachPhase.approach;
    } else if (dAlong >= 0 && along <= rw.lengthFt + 300) {
      phase = ApproachPhase.rollout;
    } else {
      phase = ApproachPhase.invalid;
    }

    double locDev = 0;
    double ideal = thresholdElevFt + s.tchFt;
    double vErr = 0;
    double gpDeg = s.glideslopeDeg;
    double gsDev = 0;
    if (phase == ApproachPhase.approach) {
      locDev = atan2(cross, distanceFt) * 180 / pi;
      ideal = thresholdElevFt + s.tchFt + distanceFt * tan(gsRad);
      vErr = altitudeFt - ideal;
      gpDeg = atan2(hat - s.tchFt, distanceFt) * 180 / pi;
      gsDev = gpDeg - s.glideslopeDeg;
    }

    double track = fix.trackDeg;
    double diff = (track - rw.headingTrue).abs() % 360;
    if (diff > 180) diff = 360 - diff;

    return ApproachGuidance._(
      runway: rw,
      fix: fix,
      settings: s,
      phase: phase,
      distanceFt: distanceFt,
      crossTrackM: crossTrackM,
      localizerDevDeg: locDev,
      altitudeFt: altitudeFt,
      idealAltitudeFt: ideal,
      verticalErrorFt: vErr,
      glidepathDeg: gpDeg,
      glideslopeDevDeg: gsDev,
      heightAboveThresholdFt: hat,
      precision: crossTrackM.abs() < s.precisionSwitchM,
      trackDiffDeg: diff,
    );
  }

  double get distanceNm => distanceFt / ftPerNm;
  double get distanceM => distanceFt / ftPerM;
  double get verticalErrorM => verticalErrorFt / ftPerM;
  double get groundSpeedKt => fix.speedMps * 1.94384;
  bool get onCenterline => crossTrackM.abs() < settings.centerlineToleranceM;
  bool get onGlidepath => verticalErrorM.abs() < 3.0;
  bool get lateralValid => phase != ApproachPhase.invalid;
  bool get verticalValid => phase == ApproachPhase.approach;

  /// Signed chevron count: negative means the aircraft is left of centerline
  /// (fly right), positive right of centerline (fly left). 0 on centerline.
  int get lateralChevrons {
    if (!lateralValid || onCenterline) return 0;
    final int n = min(ApproachSettings.maxChevrons,
        ((crossTrackM.abs() + 1e-6) / settings.chevronStepM).floor().clamp(1, ApproachSettings.maxChevrons));
    return crossTrackM < 0 ? -n : n;
  }

  /// Signed vertical arrow count per the PPA thresholds (3 / 9 / 15 m):
  /// positive means above the glidepath (fly down).
  int get verticalArrows {
    if (!verticalValid) return 0;
    final double e = verticalErrorM;
    if (e.abs() < 3) return 0;
    final int n = e.abs() > 15 ? 3 : (e.abs() > 9 ? 2 : 1);
    return e < 0 ? -n : n;
  }

  /// Localizer needle, fly-to, -1 (full left) .. +1 (full right).
  double get lateralNeedle {
    if (!lateralValid) return 0;
    double d;
    if (precision || phase == ApproachPhase.rollout) {
      d = -crossTrackM / (settings.chevronStepM * ApproachSettings.maxChevrons);
    } else {
      d = -localizerDevDeg / locFullScaleDeg;
    }
    return d.clamp(-1.0, 1.0);
  }

  /// Glideslope needle, fly-to, -1 (full up, aircraft low) .. +1 (full down).
  double get verticalNeedle {
    if (!verticalValid) return 0;
    double d;
    if (precision) {
      d = verticalErrorM / vertFullScaleM;
    } else {
      d = glideslopeDevDeg / gsFullScaleDeg;
    }
    return d.clamp(-1.0, 1.0);
  }

  /// Human-readable scale for the current needle sensitivity.
  String get lateralScaleLabel => (precision || phase == ApproachPhase.rollout)
      ? "±${(settings.chevronStepM * ApproachSettings.maxChevrons).toStringAsFixed(0)} m"
      : "±${locFullScaleDeg.toStringAsFixed(1)}°";
  String get verticalScaleLabel =>
      precision ? "±${vertFullScaleM.toStringAsFixed(0)} m" : "±${gsFullScaleDeg.toStringAsFixed(1)}°";

  /// Seconds to the threshold at the current ground speed, null when parked.
  double? get secondsToThreshold {
    if (phase != ApproachPhase.approach || fix.speedMps < 1) return null;
    return distanceM / fix.speedMps;
  }
}
