// The approach state as it goes on the wire to the glasses. The layout is
// pinned field by field here because the C plugin decodes it by offset: a
// silent shift of one byte would put the glideslope bar on the localizer.
import 'dart:typed_data';

import 'package:avaremp/instruments/pfd_runway.dart';
import 'package:avaremp/instruments/precision_approach.dart';
import 'package:avaremp/io/gps_fix.dart';
import 'package:avaremp/io/ppa_hud_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

Uint8List plainState({
  double localizer = 0,
  double glideslope = 0,
  bool lateral = true,
  bool vertical = true,
  bool precision = false,
  bool rollout = false,
  int chevrons = 0,
  int arrows = 0,
  int? distance = 1852,
  int height = 300,
  double speed = 78.4,
  double trackDiff = -2.5,
  String runway = "CYBW 25",
  String mode = "+-12 m",
}) =>
    PpaHudMessage.state(
      lateralValid: lateral,
      verticalValid: vertical,
      precision: precision,
      rollout: rollout,
      chevrons: chevrons,
      arrows: arrows,
      localizerNeedle: localizer,
      glideslopeNeedle: glideslope,
      distanceMetres: distance,
      heightFt: height,
      groundSpeedKt: speed,
      trackDiffDeg: trackDiff,
      runway: runway,
      mode: mode,
    );

String textAt(Uint8List state, int offset, int size) {
  final List<int> bytes = [];
  for(int i = offset; i < offset + size; i++) {
    if(state[i] == 0) break;
    bytes.add(state[i]);
  }
  return String.fromCharCodes(bytes);
}

void main() {

  test("the fixed layout, field by field", () {
    final Uint8List s = plainState(localizer: 0.5, glideslope: -0.25);
    final ByteData view = ByteData.sublistView(s);
    expect(s.length, PpaHudMessage.stateBytes);
    expect(s[0], PpaHudMessage.typeState);
    expect(s[1], PpaHudMessage.version);
    expect(s[2],
        PpaHudMessage.flagLateralValid | PpaHudMessage.flagVerticalValid);
    expect(view.getInt8(3), 0);
    expect(view.getInt8(4), 0);
    expect(s[5], 0, reason: "reserved byte must stay zero");
    expect(view.getInt16(6), 500);
    expect(view.getInt16(8), -250);
    expect(view.getUint16(10), 1852);
    expect(view.getInt16(12), 300);
    expect(view.getUint16(14), 784);
    expect(view.getInt16(16), -25);
    expect(textAt(s, 18, PpaHudMessage.runwayBytes), "CYBW 25");
    expect(textAt(s, 26, PpaHudMessage.modeBytes), "+-12 m");
  });

  test("one update is one BLE write at a sane MTU", () {
    // 36 payload bytes become a 46-byte body and a 55-byte frame; anything
    // that fragments at 10 Hz would spend the link on headers.
    expect(PpaHudMessage.stateBytes, 36);
  });

  test("flags carry the phase and the sensitivity", () {
    expect(plainState(precision: true, rollout: true)[2],
        PpaHudMessage.flagLateralValid |
            PpaHudMessage.flagVerticalValid |
            PpaHudMessage.flagPrecision |
            PpaHudMessage.flagRollout);
    expect(plainState(lateral: false, vertical: false)[2], 0);
  });

  test("needles are clamped to full scale", () {
    expect(ByteData.sublistView(plainState(localizer: 4.0)).getInt16(6),
        PpaHudMessage.needleFull);
    expect(ByteData.sublistView(plainState(localizer: -4.0)).getInt16(6),
        -PpaHudMessage.needleFull);
    expect(ByteData.sublistView(plainState(glideslope: double.nan)).getInt16(8),
        0);
  });

  test("chevrons and arrows stay within three", () {
    final ByteData view =
        ByteData.sublistView(plainState(chevrons: -9, arrows: 7));
    expect(view.getInt8(3), -3);
    expect(view.getInt8(4), 3);
  });

  test("an unknown distance is sent as such, not as zero", () {
    expect(ByteData.sublistView(plainState(distance: null)).getUint16(10),
        PpaHudMessage.unknownDistance);
    // Zero metres is a real value: the wheels are at the threshold.
    expect(ByteData.sublistView(plainState(distance: 0)).getUint16(10), 0);
  });

  test("text is cut to the field, never past it", () {
    final Uint8List s = plainState(
        runway: "CYYC 35LX", mode: "++++++++++++++");
    expect(textAt(s, 18, PpaHudMessage.runwayBytes), "CYYC 35L");
    expect(textAt(s, 26, PpaHudMessage.modeBytes), "++++++++++");
    // The NUL padding has to stop at the field boundary.
    expect(s.length, PpaHudMessage.stateBytes);
  });

  test("the degree sign and plus-minus survive as ASCII", () {
    // ApproachGuidance writes its scale labels with ± and °, and the glasses
    // font is handed printable ASCII only.
    final Uint8List s = plainState(mode: "±1.0°");
    expect(textAt(s, 26, PpaHudMessage.modeBytes), "+1.0d");
  });

  test("a banner is type, version and text", () {
    final Uint8List b = PpaHudMessage.banner("CONNECTED");
    expect(b[0], PpaHudMessage.typeBanner);
    expect(b[1], PpaHudMessage.version);
    expect(String.fromCharCodes(b.sublist(2)), "CONNECTED");
    expect(PpaHudMessage.banner("x" * 200).length,
        PpaHudMessage.bannerMaxText + 2);
  });

  group("from a computed approach", () {

    /// A straight north runway, 3000 ft, threshold at 1800 ft.
    PfdRunwayEnd runway() {
      const LatLng end = LatLng(50.0, -105.0);
      return PfdRunwayEnd(
        airportId: "CYBW",
        ident: "36",
        farIdent: "18",
        physicalEnd: end,
        farEnd: LatLng(50.0 + 3000 / PfdRunwayEnd.ftPerDegLat, -105.0),
        headingTrue: 0,
        lengthFt: 3000,
        widthFt: 75,
        displacedFt: 0,
        farDisplacedFt: 0,
        endElevFt: 1800,
        farElevFt: 1800,
      );
    }

    GpsFix fixAt({required double southFt, required double altFt}) => GpsFix(
          position: LatLng(50.0 - southFt / PfdRunwayEnd.ftPerDegLat, -105.0),
          altitudeMslM: altFt / ApproachGuidance.ftPerM,
          speedMps: 30.87,
          trackDeg: 0,
          source: GpsFixSource.nmea,
          fixQuality: GpsFix.qualityRtkFixed,
          time: DateTime.now(),
        );

    test("a fix on profile sends centred needles and the real numbers", () {
      const ApproachSettings s = ApproachSettings();
      final ApproachGuidance g = ApproachGuidance.compute(
          runway(), fixAt(southFt: 6076, altFt: 2120), s);
      final Uint8List wire = PpaHudMessage.fromGuidance(g);
      final ByteData view = ByteData.sublistView(wire);

      expect(wire[0], PpaHudMessage.typeState);
      expect(wire[2] & PpaHudMessage.flagLateralValid,
          PpaHudMessage.flagLateralValid);
      expect(view.getInt16(6), 0, reason: "on the centreline");
      // One nautical mile out, within a few metres of the rounding.
      expect(view.getUint16(10), closeTo(1852, 4));
      expect(view.getInt16(12), closeTo(320, 2));
      expect(view.getUint16(14), closeTo(600, 2));
      expect(textAt(wire, 18, PpaHudMessage.runwayBytes), "CYBW 36");
      expect(textAt(wire, 26, PpaHudMessage.modeBytes), isNotEmpty);
    });

    test("behind the runway nothing is claimed to be valid", () {
      const ApproachSettings s = ApproachSettings();
      // North of the far end, flying away: the engine calls this invalid.
      final ApproachGuidance g = ApproachGuidance.compute(
          runway(), fixAt(southFt: -9000, altFt: 2500), s);
      final Uint8List wire = PpaHudMessage.fromGuidance(g);
      expect(g.phase, ApproachPhase.invalid);
      expect(wire[2] & PpaHudMessage.flagLateralValid, 0);
      expect(ByteData.sublistView(wire).getUint16(10),
          PpaHudMessage.unknownDistance);
    });
  });
}
