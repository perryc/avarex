import 'dart:math' as math;

import 'package:flutter/material.dart';

// Sectional-style airport symbols for the Canadian airport layer. Canada has
// no raster chart in the app, so the symbols have to carry what a chart would
// show: whether the field is paved, how its runways lie, and whether it is
// towered.
//
// The conventions are the FAA sectional ones, which Canadian VNCs share:
//
//   open circle                     surface other than hard
//   circle with the runways in it   hard surface, longest runway <= 8069 ft
//   the runway layout alone         hard surface, longest runway > 8069 ft
//   tick marks at the quadrants     fuel available
//   circle with an H                heliport
//   blue instead of magenta         control tower
//
// Runway bearings are true, taken from the published threshold coordinates
// where they exist and from the runway number otherwise. The symbol rotates
// with the map, so what is drawn lines up with the ground.

/// One runway, reduced to what the symbol needs.
class RunwayLine {
  final double bearingDeg;   // true, 0..180 (a runway has no direction)
  final double lengthFt;
  final bool hard;

  const RunwayLine(this.bearingDeg, this.lengthFt, this.hard);

  /// Bearing from the threshold coordinates when both are known, else from
  /// the runway number ("07" means 070 magnetic, close enough to draw).
  static RunwayLine? fromRow(Map<String, Object?> r) {
    double? toDouble(Object? v) {
      if(v == null) {
        return null;
      }
      if(v is num) {
        return v.toDouble();
      }
      return double.tryParse(v.toString().trim());
    }

    final double length = toDouble(r["Length"]) ?? 0;
    final bool hard = isHardSurface((r["Surface"] ?? "").toString());
    final double? leLat = toDouble(r["LELatitude"]), leLon = toDouble(r["LELongitude"]);
    final double? heLat = toDouble(r["HELatitude"]), heLon = toDouble(r["HELongitude"]);

    if(leLat != null && leLon != null && heLat != null && heLon != null &&
        (leLat != heLat || leLon != heLon)) {
      final double lat1 = leLat * math.pi / 180, lat2 = heLat * math.pi / 180;
      final double dLon = (heLon - leLon) * math.pi / 180;
      final double y = math.sin(dLon) * math.cos(lat2);
      final double x = math.cos(lat1) * math.sin(lat2) -
          math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
      final double deg = (math.atan2(y, x) * 180 / math.pi + 360) % 180;
      return RunwayLine(deg, length, hard);
    }

    final RegExpMatch? m = RegExp(r'^(\d{1,2})').firstMatch((r["LEIdent"] ?? "").toString().trim());
    if(m == null) {
      return null;
    }
    final double deg = (int.parse(m.group(1)!) * 10) % 180;
    return RunwayLine(deg.toDouble(), length, hard);
  }

  /// OurAirports surface codes are free text; these are the paved ones.
  static bool isHardSurface(String surface) {
    final String s = surface.toUpperCase();
    if(s.isEmpty) {
      return false;
    }
    for(final String hard in const ["ASP", "ASPH", "CON", "CONC", "PEM", "BIT",
                                    "TAR", "MAC", "PAV", "COP", "ASC"]) {
      if(s.startsWith(hard)) {
        return true;
      }
    }
    return s.contains("ASPHALT") || s.contains("CONCRETE") || s.contains("PAVED");
  }
}

/// Everything the symbol for one airport depends on.
class AirportSymbolData {
  final List<RunwayLine> runways;
  final bool towered;
  final bool fuel;
  final bool heliport;
  final bool water;

  const AirportSymbolData({
    this.runways = const [],
    this.towered = false,
    this.fuel = false,
    this.heliport = false,
    this.water = false,
  });

  /// Longest hard runway, 0 when the field is not paved.
  double get hardLengthFt {
    double longest = 0;
    for(final RunwayLine r in runways) {
      if(r.hard && r.lengthFt > longest) {
        longest = r.lengthFt;
      }
    }
    return longest;
  }
}

/// Sectional symbol for one airport, sized to [size] logical pixels.
class AirportSymbol extends StatelessWidget {
  final AirportSymbolData data;
  final double size;

  const AirportSymbol({super.key, required this.data, this.size = 26});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(size, size), painter: _AirportSymbolPainter(data));
}

class _AirportSymbolPainter extends CustomPainter {
  final AirportSymbolData d;

  // Chart colours: magenta for fields without a tower, blue for towered ones.
  static const Color _magenta = Color(0xFFA0409A);
  static const Color _blue = Color(0xFF1565C0);

  // A sectional draws the runway layout instead of a circle above this length.
  static const double _bigRunwayFt = 8069;

  _AirportSymbolPainter(this.d);

  @override
  void paint(Canvas canvas, Size size) {
    final Color color = d.towered ? _blue : _magenta;
    final Offset c = Offset(size.width / 2, size.height / 2);
    final double r = size.width * 0.34;

    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.4, size.width * 0.07)
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;

    if(d.heliport) {
      canvas.drawCircle(c, r, stroke);
      _letter(canvas, c, "H", color, size.width * 0.42);
      return;
    }
    if(d.water) {
      canvas.drawCircle(c, r, stroke);
      _letter(canvas, c, "S", color, size.width * 0.42);
      return;
    }

    final double hard = d.hardLengthFt;
    if(hard <= 0) {
      // not hard surfaced: an open circle says only that the field is there
      canvas.drawCircle(c, r, stroke);
      _ticks(canvas, c, r, stroke);
      return;
    }

    if(hard > _bigRunwayFt) {
      // long field: the runways themselves are the symbol
      _runways(canvas, c, size.width * 0.46, stroke, all: true);
      return;
    }

    canvas.drawCircle(c, r, stroke);
    _ticks(canvas, c, r, stroke);
    _runways(canvas, c, r, stroke, all: false);
  }

  /// Runway bars through the centre. The longest sets the full length and the
  /// others are drawn in proportion, as a chart does.
  void _runways(Canvas canvas, Offset c, double reach, Paint stroke, {required bool all}) {
    final List<RunwayLine> hard = d.runways.where((r) => r.hard).toList()
      ..sort((a, b) => b.lengthFt.compareTo(a.lengthFt));
    if(hard.isEmpty) {
      return;
    }
    final double longest = hard.first.lengthFt;
    final List<RunwayLine> draw = all ? hard.take(3).toList() : hard.take(1).toList();
    for(final RunwayLine rw in draw) {
      final double half = reach *
          (longest > 0 ? math.max(0.55, rw.lengthFt / longest) : 1.0);
      // bearings are compass degrees: 0 is up the screen, 90 to the right
      final double a = (rw.bearingDeg - 90) * math.pi / 180;
      final Offset v = Offset(math.cos(a) * half, math.sin(a) * half);
      canvas.drawLine(c - v, c + v, stroke);
    }
  }

  /// The four marks that say fuel and services are available.
  void _ticks(Canvas canvas, Offset c, double r, Paint stroke) {
    if(!d.fuel) {
      return;
    }
    for(int i = 0; i < 4; i++) {
      final double a = (45 + i * 90) * math.pi / 180;
      final Offset dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * r, c + dir * (r * 1.55), stroke);
    }
  }

  void _letter(Canvas canvas, Offset c, String s, Color color, double fontSize) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(
          color: color, fontSize: fontSize, fontWeight: FontWeight.w700, height: 1)),
      textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _AirportSymbolPainter old) => old.d != d;
}
