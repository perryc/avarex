import 'dart:typed_data';

import 'package:avaremp/nmea/nmea_message_factory.dart';
import 'package:avaremp/nmea/pflaa_message.dart';
import 'package:avaremp/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

// Builds a sentence with a valid NMEA checksum.
String withChecksum(String body) {
  int xor = 0;
  for (int i = 1; i < body.length; i++) {
    xor ^= body.codeUnitAt(i);
  }
  return "$body*${xor.toRadixString(16).toUpperCase().padLeft(2, '0')}\r\n";
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // ownship at Calgary, 1100 m
    Storage().position = Position(
        latitude: 51.0, longitude: -114.0, timestamp: DateTime.now(),
        accuracy: 0, altitude: 1100, altitudeAccuracy: 0, heading: 0,
        headingAccuracy: 0, speed: 0, speedAccuracy: 0);
  });

  test("PFLAA converts relative offsets to an absolute traffic report", () {
    // 1000 m north, 2000 m east, 100 m above, ICAO C0FFEE, powered aircraft
    String s = withChecksum(r"$PFLAA,1,1000,2000,100,1,C0FFEE,90,,50,2.0,8");
    var m = NmeaMessageFactory.buildMessage(Uint8List.fromList(s.codeUnits));
    expect(m, isA<PFLAAMessage>());
    var t = (m as PFLAAMessage).traffic!;
    expect(t.icao, 0xC0FFEE);
    expect(t.coordinates.latitude, closeTo(51.0 + 1000 / 111320.0, 1e-6));
    expect(t.coordinates.longitude,
        closeTo(-114.0 + 2000 / (111320.0 * 0.629320), 1e-4));
    expect(t.altitude, closeTo(1200 * 3.28084, 1));
    expect(t.velocity, 50);
    expect(t.verticalSpeed, closeTo(2.0 * 196.85, 1));
    expect(t.heading, 90);
    expect(t.emitter, 1);
    expect(t.alertStatus, 1);
    expect(t.addressType, 0);
    expect(t.airborne, isTrue);
  });

  test("other proprietary sentences are ignored", () {
    String s = withChecksum(r"$PFLAU,1,1,2,1,0,,0,,,");
    expect(NmeaMessageFactory.buildMessage(Uint8List.fromList(s.codeUnits)), isNull);
  });

  test("bad checksum is rejected", () {
    String s = r"$PFLAA,0,1000,2000,100,1,C0FFEE,90,,50,2.0,8*00" "\r\n";
    expect(NmeaMessageFactory.buildMessage(Uint8List.fromList(s.codeUnits)), isNull);
  });
}
