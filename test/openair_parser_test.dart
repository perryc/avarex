import 'package:avaremp/utils/openair_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('coordinate formats', () {
    LatLng? dms = OpenAirParser.parseCoordinate("50:32:00.0N 113:50:29.0W");
    expect(dms, isNotNull);
    expect(dms!.latitude, closeTo(50.5333, 0.001));
    expect(dms.longitude, closeTo(-113.8414, 0.001));

    LatLng? dm = OpenAirParser.parseCoordinate("43:30.5S 080:15.25E");
    expect(dm, isNotNull);
    expect(dm!.latitude, closeTo(-43.5083, 0.001));
    expect(dm.longitude, closeTo(80.2542, 0.001));

    expect(OpenAirParser.parseCoordinate("garbage"), isNull);
  });

  test('polygon block with DP records', () {
    const String text = """
* comment
AC F
AN GUELPH CORRIDOR
AL 5500MSL
AH 12500MSL
DP 43:32:49.0N 080:12:30.0W
DP 43:27:01.0N 080:09:17.0W
DP 43:26:07.0N 080:14:34.0W
DP 43:26:44.0N 080:15:58.0W
""";
    List<OpenAirAirspace> result = OpenAirParser().parse(text);
    expect(result.length, 1);
    expect(result[0].cls, "F");
    expect(result[0].name, "GUELPH CORRIDOR");
    expect(result[0].floor, "5500MSL");
    expect(result[0].ceiling, "12500MSL");
    expect(result[0].points.length, 4);
    expect(result[0].floorFt, 5500);
  });

  test('circle via V X= and DC', () {
    const String text = """
AC F
AN HIGH RIVER MF 123.0
AL SFC
AH 6400MSL
AF 123.000
V X= 50:32:00.0N 113:50:29.0W
DC 5
""";
    List<OpenAirAirspace> result = OpenAirParser().parse(text);
    expect(result.length, 1);
    expect(result[0].frequency, "123.000");
    expect(result[0].floorFt, 0); // SFC
    // 0..360 in 5 degree steps inclusive
    expect(result[0].points.length, 73);
    // all points ~5nm (9260m) from center
    const Distance distance = Distance(calculator: Haversine());
    LatLng center = const LatLng(50.5333333, -113.8413888);
    for (LatLng p in result[0].points) {
      expect(distance(center, p), closeTo(9260, 50));
    }
  });

  test('arc direction with V D=- and DB', () {
    const String text = """
AC C
AN ARC TEST
AL SFC
AH 3000MSL
V X= 43:39:29.0N 079:37:54.0W
DP 43:49:29.0N 079:37:54.0W
V D=-
DB 43:49:29.0N 079:37:54.0W, 43:39:29.0N 079:24:00.0W
""";
    List<OpenAirAirspace> result = OpenAirParser().parse(text);
    expect(result.length, 1);
    List<LatLng> points = result[0].points;
    expect(points.length, greaterThan(10));
    // counterclockwise from north (0 deg) to east (90 deg) goes the long way
    // through west and south; verify a point west of center exists
    expect(points.any((p) => p.longitude < -79.7), isTrue);
  });

  test('multiple blocks and unknown records ignored', () {
    const String text = """
AC B
AN FIRST
AL 12500MSL
AH FL180
SP 0,1,0,0,255
DP 50:00:00N 100:00:00W
DP 50:00:00N 099:00:00W
DP 51:00:00N 099:00:00W
AC D
AN SECOND
AL SFC
AH 3000MSL
DP 45:00:00N 075:00:00W
DP 45:00:00N 074:00:00W
DP 46:00:00N 074:00:00W
""";
    List<OpenAirAirspace> result = OpenAirParser().parse(text);
    expect(result.length, 2);
    expect(result[0].cls, "B");
    expect(result[0].floorFt, 12500);
    expect(result[1].cls, "D");
    expect(result[1].ceiling, "3000MSL");
  });

  test('blocks with fewer than 3 points are dropped', () {
    const String text = """
AC E
AN DEGENERATE
DP 50:00:00N 100:00:00W
DP 50:00:00N 099:00:00W
""";
    expect(OpenAirParser().parse(text), isEmpty);
  });

  test('point in polygon', () {
    OpenAirAirspace a = OpenAirAirspace();
    a.points = [
      const LatLng(45, -76),
      const LatLng(45, -75),
      const LatLng(46, -75),
      const LatLng(46, -76),
    ];
    expect(a.contains(const LatLng(45.5, -75.5)), isTrue);
    expect(a.contains(const LatLng(44.5, -75.5)), isFalse);
  });

  test('FL floor parsing', () {
    OpenAirAirspace a = OpenAirAirspace();
    a.floor = "FL 180";
    expect(a.floorFt, 18000);
  });
}
