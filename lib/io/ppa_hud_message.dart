import 'dart:math';
import 'dart:typed_data';

import 'package:avaremp/instruments/precision_approach.dart';

// The approach state sent to the Precision Approach HUD plugin on the
// glasses. The glasses draw; everything here is already computed by
// ApproachGuidance, and the wire form only has to survive the trip.
//
// Fixed 36 bytes, big-endian like the rest of the GM protocol, so one update
// is one BLE write at any sane MTU. The same layout is parsed by
// ppa_hud.c in the ppa-hud-glasses repository; change one and you change
// both, which is why the version byte is there.

class PpaHudMessage {
  /// Our application channel. The low channel numbers belong to the SDK's own
  /// Web Bridge example, so this is "PA" in ASCII to stay clear of them.
  static const int channel = 0x5041;

  static const int version = 1;

  static const int typeState = 1;
  static const int typeBanner = 2;

  static const int stateBytes = 36;
  static const int runwayBytes = 8;
  static const int modeBytes = 10;
  static const int bannerMaxText = 64;

  static const int flagLateralValid = 0x01;
  static const int flagVerticalValid = 0x02;
  static const int flagPrecision = 0x04;
  static const int flagRollout = 0x08;

  /// Full-scale needle deflection on the wire.
  static const int needleFull = 1000;

  /// Sent when the aircraft is beyond the reach of the approach engine, so
  /// the glasses show no distance rather than a wrong one.
  static const int unknownDistance = 0xFFFF;

  /// Encode one approach state. Only [guidance] is needed in flight; the
  /// named arguments exist so the layout can be exercised directly.
  static Uint8List state({
    required bool lateralValid,
    required bool verticalValid,
    required bool precision,
    required bool rollout,
    required int chevrons,
    required int arrows,
    required double localizerNeedle,
    required double glideslopeNeedle,
    required int? distanceMetres,
    required int heightFt,
    required double groundSpeedKt,
    required double trackDiffDeg,
    required String runway,
    required String mode,
  }) {
    final Uint8List out = Uint8List(stateBytes);
    final ByteData view = ByteData.sublistView(out);
    out[0] = typeState;
    out[1] = version;
    out[2] = (lateralValid ? flagLateralValid : 0) |
        (verticalValid ? flagVerticalValid : 0) |
        (precision ? flagPrecision : 0) |
        (rollout ? flagRollout : 0);
    view.setInt8(3, chevrons.clamp(-3, 3));
    view.setInt8(4, arrows.clamp(-3, 3));
    out[5] = 0;                           // reserved, must be zero
    view.setInt16(6, _needle(localizerNeedle));
    view.setInt16(8, _needle(glideslopeNeedle));
    view.setUint16(10, distanceMetres == null
        ? unknownDistance
        : distanceMetres.clamp(0, unknownDistance - 1));
    view.setInt16(12, heightFt.clamp(-32768, 32767));
    view.setUint16(14, (groundSpeedKt * 10).round().clamp(0, 65535));
    view.setInt16(16, (trackDiffDeg * 10).round().clamp(-32768, 32767));
    _writeText(out, 18, runwayBytes, runway);
    _writeText(out, 26, modeBytes, mode);
    return out;
  }

  /// The state of a live approach, as the HUD wants it.
  static Uint8List fromGuidance(ApproachGuidance g) {
    // Metres as an integer keeps the field two bytes; beyond 65 km the
    // approach engine has already called the geometry invalid.
    final double metres = g.distanceM;
    return state(
      lateralValid: g.lateralValid,
      verticalValid: g.verticalValid,
      precision: g.precision,
      rollout: g.phase == ApproachPhase.rollout,
      chevrons: g.lateralChevrons,
      arrows: g.verticalArrows,
      localizerNeedle: g.lateralNeedle,
      glideslopeNeedle: g.verticalNeedle,
      distanceMetres:
          !g.lateralValid || metres.isNaN || metres > unknownDistance - 1
              ? null
              : metres.round(),
      heightFt: g.heightAboveThresholdFt.isFinite
          ? g.heightAboveThresholdFt.round()
          : 0,
      groundSpeedKt: g.groundSpeedKt,
      trackDiffDeg: g.trackDiffDeg,
      runway: "${g.runway.airportId} ${g.runway.ident}",
      // The lateral scale is the one being actively flown, and ten bytes is
      // not enough to carry both sensitivities.
      mode: g.lateralScaleLabel,
    );
  }

  /// A line of text for the status row - what the phone is doing when there
  /// is no approach to fly.
  static Uint8List banner(String text) {
    final List<int> ascii = _ascii(text, bannerMaxText);
    final Uint8List out = Uint8List(2 + ascii.length);
    out[0] = typeBanner;
    out[1] = version;
    out.setRange(2, out.length, ascii);
    return out;
  }

  static int _needle(double value) {
    if(value.isNaN) {
      return 0;
    }
    return (value * needleFull).round().clamp(-needleFull, needleFull);
  }

  /// Fixed-width, NUL-padded, printable ASCII. The glasses font has no
  /// business being handed a degree sign or a non-breaking space, and the
  /// plugin drops anything outside this range anyway.
  static void _writeText(Uint8List out, int offset, int size, String text) {
    final List<int> ascii = _ascii(text, size);
    out.setRange(offset, offset + ascii.length, ascii);
    for(int i = offset + ascii.length; i < offset + size; i++) {
      out[i] = 0;
    }
  }

  static List<int> _ascii(String text, int limit) {
    final List<int> out = [];
    for(final int unit in text.codeUnits) {
      if(unit == 0xB1) {
        out.add(0x2B);                    // a plus sign stands in for "±"
        continue;
      }
      if(unit == 0xB0) {
        out.add(0x64);                    // degrees become a "d"
        continue;
      }
      if(unit < 0x20 || unit > 0x7E) {
        continue;
      }
      out.add(unit);
      if(out.length == limit) {
        break;
      }
    }
    return out.sublist(0, min(out.length, limit));
  }
}
