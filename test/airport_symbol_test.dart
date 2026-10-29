import 'package:avaremp/canada/airport_symbol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bearing comes from the threshold coordinates', () {
    // CYQR 13/31: thresholds roughly south-east of each other
    final RunwayLine? r = RunwayLine.fromRow({
      "Length": "7900", "Surface": "ASP", "LEIdent": "13",
      "LELatitude": "50.4500", "LELongitude": "-104.6000",
      "HELatitude": "50.4350", "HELongitude": "-104.5750",
    });
    expect(r, isNotNull);
    expect(r!.hard, isTrue);
    expect(r.lengthFt, 7900);
    expect(r.bearingDeg, closeTo(130, 6));
  });

  test('bearing falls back to the runway number', () {
    final RunwayLine? r = RunwayLine.fromRow(
        {"Length": "2500", "Surface": "TURF", "LEIdent": "07"});
    expect(r, isNotNull);
    expect(r!.bearingDeg, 70);
    expect(r.hard, isFalse);
  });

  test('a runway is drawn without direction, so bearings fold to 0..180', () {
    final RunwayLine? r = RunwayLine.fromRow(
        {"Length": "3000", "Surface": "ASPH", "LEIdent": "31"});
    expect(r!.bearingDeg, 130);
  });

  test('surfaces sort into hard and soft', () {
    expect(RunwayLine.isHardSurface("ASP"), isTrue);
    expect(RunwayLine.isHardSurface("CON"), isTrue);
    expect(RunwayLine.isHardSurface("asphalt"), isTrue);
    expect(RunwayLine.isHardSurface("GRASS"), isFalse);
    expect(RunwayLine.isHardSurface("WATER"), isFalse);
    expect(RunwayLine.isHardSurface(""), isFalse);
  });

  test('the longest hard runway decides the symbol', () {
    const AirportSymbolData d = AirportSymbolData(runways: [
      RunwayLine(90, 2000, false),
      RunwayLine(130, 7900, true),
      RunwayLine(40, 5000, true),
    ]);
    expect(d.hardLengthFt, 7900);
    expect(const AirportSymbolData(runways: [RunwayLine(90, 4000, false)]).hardLengthFt, 0);
  });
}
