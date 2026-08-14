import 'package:latlong2/latlong.dart';

// One airspace block from an OpenAir file: class, name, vertical limits, and
// the polygon outline (arcs and circles are interpolated into points).
class OpenAirAirspace {
  String cls = "";
  String name = "";
  String floor = "";
  String ceiling = "";
  String frequency = "";
  List<LatLng> points = [];

  // floor in ft MSL for display filtering; SFC/GND = 0, FL nnn = nnn * 100,
  // unparsable = 0
  int get floorFt {
    String f = floor.toUpperCase();
    if(f.startsWith("FL")) {
      int? fl = int.tryParse(f.substring(2).trim());
      return fl == null ? 0 : fl * 100;
    }
    RegExpMatch? m = RegExp(r'(\d+)').firstMatch(f);
    if(m == null) {
      return 0;
    }
    return int.parse(m.group(1)!);
  }

  bool contains(LatLng c) {
    // ray casting
    bool inside = false;
    for(int i = 0, j = points.length - 1; i < points.length; j = i++) {
      if(((points[i].latitude > c.latitude) != (points[j].latitude > c.latitude)) &&
          (c.longitude < (points[j].longitude - points[i].longitude) *
              (c.latitude - points[i].latitude) /
              (points[j].latitude - points[i].latitude) + points[i].longitude)) {
        inside = !inside;
      }
    }
    return inside;
  }
}

// Parser for the OpenAir airspace format (AC/AN/AL/AH/AF/DP/DC/DB/DA/V
// records), as used by the soaringweb.org Canadian airspace file.
class OpenAirParser {

  static const Distance _distance = Distance(calculator: Haversine());
  static const double _nmToM = 1852;
  static const double _arcStepDegrees = 5;

  // "50:32:00.0N 113:50:29.0W" (deg:min:sec) or "50:32.5N 113:50.29W"
  // (deg:decimal minutes)
  static LatLng? parseCoordinate(String text) {
    RegExpMatch? m = RegExp(
        r'([\d:.]+)\s*([NS])[\s,]+([\d:.]+)\s*([EW])', caseSensitive: false)
        .firstMatch(text);
    if(m == null) {
      return null;
    }
    double? lat = _toDegrees(m.group(1)!);
    double? lon = _toDegrees(m.group(3)!);
    if(lat == null || lon == null || lat > 90 || lon > 180) {
      return null;
    }
    if(m.group(2)!.toUpperCase() == "S") {
      lat = -lat;
    }
    if(m.group(4)!.toUpperCase() == "W") {
      lon = -lon;
    }
    return LatLng(lat, lon);
  }

  // "50:32:00.0" -> deg:min:sec, "50:32.5" -> deg:decimal minutes
  static double? _toDegrees(String text) {
    List<String> parts = text.split(":");
    try {
      double degrees = double.parse(parts[0]);
      if(parts.length > 1) {
        degrees += double.parse(parts[1]) / 60;
      }
      if(parts.length > 2) {
        degrees += double.parse(parts[2]) / 3600;
      }
      return degrees;
    }
    catch(e) {
      return null;
    }
  }

  List<OpenAirAirspace> parse(String text) {
    List<OpenAirAirspace> result = [];
    OpenAirAirspace? current;
    LatLng? center; // V X=
    bool clockwise = true; // V D=

    void flush() {
      if(current != null && current!.points.length >= 3) {
        result.add(current!);
      }
      current = null;
      center = null;
      clockwise = true;
    }

    for(String lineRaw in text.split("\n")) {
      String line = lineRaw.trim();
      if(line.isEmpty || line.startsWith("*")) {
        continue;
      }
      List<String> parts = line.split(RegExp(r'\s+'));
      String record = parts[0].toUpperCase();
      String value = line.length > parts[0].length ? line.substring(parts[0].length).trim() : "";

      switch(record) {
        case "AC":
          flush();
          current = OpenAirAirspace();
          current!.cls = value;
          break;
        case "AN":
          current?.name = value;
          break;
        case "AL":
          current?.floor = value;
          break;
        case "AH":
          current?.ceiling = value;
          break;
        case "AF":
          current?.frequency = value;
          break;
        case "V":
          if(value.toUpperCase().startsWith("X=")) {
            center = parseCoordinate(value.substring(2));
          }
          else if(value.toUpperCase().startsWith("D=")) {
            clockwise = !value.substring(2).trim().startsWith("-");
          }
          break;
        case "DP":
          LatLng? ll = parseCoordinate(value);
          if(ll != null) {
            current?.points.add(ll);
          }
          break;
        case "DC":
          double? radius = double.tryParse(value);
          if(current != null && center != null && radius != null) {
            for(double angle = 0; angle <= 360; angle += _arcStepDegrees) {
              current!.points.add(_offsetNm(center!, radius, angle));
            }
          }
          break;
        case "DB":
          List<String> coords = value.split(",");
          if(current != null && center != null && coords.length >= 2) {
            LatLng? from = parseCoordinate(coords[0]);
            LatLng? to = parseCoordinate(coords[1]);
            if(from != null && to != null) {
              current!.points.addAll(_arc(center!, from, to, clockwise));
            }
          }
          clockwise = true; // direction resets after each arc
          break;
        case "DA":
          // radius,angleStart,angleEnd around V X= center
          List<String> args = value.split(",");
          if(current != null && center != null && args.length >= 3) {
            double? radius = double.tryParse(args[0].trim());
            double? start = double.tryParse(args[1].trim());
            double? end = double.tryParse(args[2].trim());
            if(radius != null && start != null && end != null) {
              double sweep = clockwise ? (end - start) % 360 : ((end - start) % 360) - 360;
              int steps = (sweep.abs() / _arcStepDegrees).ceil().clamp(1, 360 ~/ _arcStepDegrees * 2);
              for(int i = 0; i <= steps; i++) {
                current!.points.add(_offsetNm(center!, radius, start + sweep * i / steps));
              }
            }
          }
          clockwise = true;
          break;
        default:
          break; // SP, SB, TO, TC, etc. are styling records, ignored
      }
    }
    flush();
    return result;
  }

  static LatLng _offsetNm(LatLng from, double nm, double heading) {
    // Distance.offset accepts -180 to 180 only
    heading = heading % 360;
    if(heading > 180) {
      heading -= 360;
    }
    if(heading < -180) {
      heading += 360;
    }
    return _distance.offset(from, nm * _nmToM, heading);
  }

  static List<LatLng> _arc(LatLng center, LatLng from, LatLng to, bool clockwise) {
    double radius = _distance(center, from) / _nmToM;
    double start = _distance.bearing(center, from) % 360;
    double end = _distance.bearing(center, to) % 360;
    if(start < 0) {
      start += 360;
    }
    if(end < 0) {
      end += 360;
    }
    double sweep = (end - start) % 360;
    if(sweep < 0) {
      sweep += 360;
    }
    if(!clockwise) {
      sweep = sweep - 360;
    }
    if(sweep == 0) {
      sweep = clockwise ? 360 : -360;
    }
    int steps = (sweep.abs() / _arcStepDegrees).ceil();
    List<LatLng> points = [];
    for(int i = 0; i <= steps; i++) {
      points.add(_offsetNm(center, radius, start + sweep * i / steps));
    }
    return points;
  }
}
