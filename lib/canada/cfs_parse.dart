// Parses the aerodrome entries out of the text of a Canada Flight Supplement
// (CFS) digital edition PDF.
//
// The CFS is NAV CANADA's authoritative aerodrome directory, and it carries
// what the crowd-sourced sources do not: every registered aerodrome including
// farm strips, runway dimensions and surfaces, true runway bearings, the whole
// communications block, fuel and operator details. This fork cannot
// redistribute it, so nothing is shipped with the app: the user points at
// their own copy and it is parsed on the device.
//
// Only the text is parsed here, so this file stays pure Dart and is testable
// without a PDF. The caller supplies one string per page, in page order.
//
// The page layout is regular. A page of the aerodrome directory looks like:
//
//     CFS                            <- the digital edition watermark
//     ENGLISH
//     Apr. 08, 2024
//     8:06 am
//     SKCYQR                         <- province + identifier, first page only
//     REGINA INTL SK CYQR            <- the title line
//     REF N50 25 56 W104 39 58 2SW 10°E (2011) UTC-6 Elev 1895´ ...
//     RWY DATA Rwy 13(128°)/31(308°) 7901x150 ASPH
//     ...
//     SASKATCHEWAN AERODROME / FACILITY DIRECTORY        <- footer
//     CANADA FLIGHT SUPPLEMENT / GPH 205 Effective ...
//
// Values that run past the width of the column continue on the next line with
// no label of their own, so a line that does not begin with one of the known
// labels belongs to the line above it. Entries longer than a page continue on
// the next, under a title line marked "(Cont'd)".

import 'dart:math' as math;

/// One runway as the CFS gives it.
class CfsRunway {
  final String ident;             // "13", "08L"
  final String? oppositeIdent;    // "31"; null for a one-way strip
  final int? bearingTrue;         // from the CFS where it prints one
  final int? oppositeBearingTrue;
  final int lengthFt;
  final int widthFt;
  final String surface;           // normalised code, "" when the CFS omits it

  const CfsRunway({
    required this.ident,
    this.oppositeIdent,
    this.bearingTrue,
    this.oppositeBearingTrue,
    required this.lengthFt,
    required this.widthFt,
    this.surface = "",
  });

  /// True bearing, from the CFS where it printed one and otherwise worked out
  /// from the runway number, which is magnetic, using the aerodrome's
  /// variation. Returns null when neither is available.
  double? trueBearing(int? variation) {
    if(bearingTrue != null) {
      return bearingTrue!.toDouble();
    }
    final int? number = int.tryParse(ident.replaceAll(RegExp(r"[^0-9]"), ""));
    if(number == null || variation == null) {
      return null;
    }
    return ((number * 10 + variation) % 360).toDouble();
  }

  bool get isHardSurface => surface == "ASPH" || surface == "CONC";

  Map<String, Object?> toJson() => {
    "i": ident, "o": oppositeIdent, "b": bearingTrue, "ob": oppositeBearingTrue,
    "l": lengthFt, "w": widthFt, "s": surface,
  };

  static CfsRunway fromJson(Map<String, Object?> j) => CfsRunway(
    ident: j["i"] as String,
    oppositeIdent: j["o"] as String?,
    bearingTrue: j["b"] as int?,
    oppositeBearingTrue: j["ob"] as int?,
    lengthFt: j["l"] as int,
    widthFt: j["w"] as int,
    surface: (j["s"] ?? "") as String,
  );
}

/// One line of the COMM block that carried a frequency.
class CfsFrequency {
  final String type;              // TWR, GND, ATIS, MF, ATF, UNICOM, ...
  final String mhz;               // "118.6"
  const CfsFrequency(this.type, this.mhz);

  Map<String, Object?> toJson() => {"t": type, "f": mhz};

  static CfsFrequency fromJson(Map<String, Object?> j) =>
      CfsFrequency(j["t"] as String, j["f"] as String);
}

/// A navigation aid listed under an aerodrome's NAV block.
class CfsNavaid {
  final String type;              // VORTAC, VOR/DME, DME, NDB, TACAN
  final String ident;             // VLN, YYC, X2
  final String name;              // "LUMSDEN"; often empty
  final String frequency;         // "114.2" MHz, or "329" kHz for an NDB
  final double? latitude;
  final double? longitude;
  final int? elevationFt;

  const CfsNavaid({
    required this.type,
    required this.ident,
    this.name = "",
    this.frequency = "",
    this.latitude,
    this.longitude,
    this.elevationFt,
  });

  bool get isNdb => type.startsWith("NDB");

  Map<String, Object?> toJson() => {
    "t": type, "i": ident, "n": name, "f": frequency,
    "la": latitude, "lo": longitude, "e": elevationFt,
  };

  static CfsNavaid fromJson(Map<String, Object?> j) => CfsNavaid(
    type: j["t"] as String,
    ident: j["i"] as String,
    name: (j["n"] ?? "") as String,
    frequency: (j["f"] ?? "") as String,
    latitude: (j["la"] as num?)?.toDouble(),
    longitude: (j["lo"] as num?)?.toDouble(),
    elevationFt: j["e"] as int?,
  );
}

/// An ILS, which belongs to a runway rather than to a position.
class CfsIls {
  final String ident;             // IQR
  final String frequency;         // "109.5"
  final String runway;            // "13", "35L"
  const CfsIls(this.ident, this.frequency, this.runway);

  Map<String, Object?> toJson() => {"i": ident, "f": frequency, "r": runway};

  static CfsIls fromJson(Map<String, Object?> j) =>
      CfsIls(j["i"] as String, j["f"] as String, j["r"] as String);
}

/// One aerodrome entry.
class CfsAerodrome {
  final String ident;             // CYQR, CEF4
  final String province;          // AB, SK, MB, ...
  final String name;              // "REGINA INTL"
  final bool isHeliport;
  final bool isWaterAerodrome;
  final double? latitude;
  final double? longitude;
  final int? elevationFt;
  final int? variation;           // degrees, east positive
  final int? utcOffset;
  final List<CfsRunway> runways;
  final List<CfsFrequency> frequencies;
  final List<CfsNavaid> navaids;
  final List<CfsIls> ils;
  final String? fuel;             // the FUEL line verbatim
  final String? operator;         // the OPR line verbatim
  final int firstPage;            // 1-based page in the source PDF
  final int lastPage;

  const CfsAerodrome({
    required this.ident,
    required this.province,
    required this.name,
    this.isHeliport = false,
    this.isWaterAerodrome = false,
    this.latitude,
    this.longitude,
    this.elevationFt,
    this.variation,
    this.utcOffset,
    this.runways = const [],
    this.frequencies = const [],
    this.navaids = const [],
    this.ils = const [],
    this.fuel,
    this.operator,
    required this.firstPage,
    required this.lastPage,
  });

  /// A tower frequency in the COMM block is what makes an aerodrome towered,
  /// which is what a chart draws in blue rather than magenta.
  bool get isTowered => frequencies.any((f) => f.type == "TWR");

  /// The city a chart would label the aerodrome with: entries are titled
  /// "CALGARY / SPRINGBANK", town first.
  String get city => name.contains("/") ? name.split("/").first.trim() : name;

  String? frequencyOf(String type) {
    for(final CfsFrequency f in frequencies) {
      if(f.type == type) {
        return f.mhz;
      }
    }
    return null;
  }
}

/// One CFS volume: the aerodromes it holds and the cycle it is good for.
class CfsVolume {
  final List<CfsAerodrome> aerodromes;
  final DateTime? effectiveFrom;
  final DateTime? effectiveTo;

  const CfsVolume({
    this.aerodromes = const [],
    this.effectiveFrom,
    this.effectiveTo,
  });

  bool get isExpired =>
      effectiveTo != null && DateTime.now().toUtc().isAfter(effectiveTo!);
}

class CfsParser {

  // Labels that start a field. Longest first, so "RWY DATA" wins over "RWY"
  // and "FLT PLN" is not mistaken for a continuation line.
  static const List<String> labels = [
    "HELI DATA", "RWY DATA", "RWY CERT", "TWY CERT", "CLNC DEL", "PVT ADV",
    "MIL CON", "FLT PLN", "SUP FL", "SERVICES", "LIGHTING", "CAUTION",
    "VOR/DME", "NDB/DME", "VOR/TACAN",
    "VORTAC", "UNICOM", "TACAN", "APRON", "NOISE", "RADIO", "ATIS", "CUST",
    "JASU", "ARFF", "AWOS", "TACAN", "VDF", "TWR", "GND", "RCO", "RCR", "PAL",
    "ATF", "APP", "DEP", "ARR", "TML", "NAV", "VOR", "DME", "NDB", "ILS",
    "LOC", "SSB", "IFR", "OIL", "REF", "OPR", "FIC", "ACC", "PF", "WX", "MF",
    "TWY", "PRO", "COMM", "FUEL", "S",
  ];

  static final RegExp _label =
      RegExp("^(${labels.map(RegExp.escape).join("|")})(?=\\s|\$)");
  static final RegExp _pageCode = RegExp(r"^([A-Z]{2})([A-Z0-9]{3,4})$");
  static final RegExp _footer = RegExp(
      r"AERODROME / FACILITY DIRECTORY|CANADA FLIGHT SUPPLEMENT|"
      r"^\d{1,2}-[A-Za-z]{3}-\d{4}");
  static final RegExp _watermarkDate = RegExp(r"^[A-Z][a-z]{2}\. \d{2}, \d{4}$");
  static final RegExp _watermarkTime = RegExp(r"^\d{1,2}:\d{2} [ap]m$");

  static const String _provinces =
      "AB|SK|MB|BC|ON|QC|NB|NS|PE|NL|YT|NT|NU";
  static final RegExp _title = RegExp(
      "^(?<name>.+?)\\s+(?<prov>$_provinces)\\s*"
      r"(?<kind>\(Heli\)|\(Water\))?\s*"
      r"(?<cont>\(Cont’d\)|\(Cont'd\))?\s+(?<id>[A-Z][A-Z0-9]{2,3})$");

  // N50 25 56 W104 39 58, and the degrees-and-minutes form small aerodromes
  // are given in. The lookahead keeps the second form from matching the first
  // and silently dropping the seconds.
  static final RegExp _positionDms =
      RegExp(r"N(\d{2}) (\d{2}) (\d{2}(?:\.\d+)?) W(\d{2,3}) (\d{2}) (\d{2}(?:\.\d+)?)");
  static final RegExp _positionDm =
      RegExp(r"N(\d{2}) (\d{2})(?!\s+\d{2}\b) W(\d{2,3}) (\d{2})(?!\s+\d{2}\b)");
  static final RegExp _variation = RegExp(r"(\d{1,2})°([EW])");
  static final RegExp _elevation = RegExp(r"Elev\s+(-?[\d,]+)");
  static final RegExp _utc = RegExp(r"UTC([-+]\d{1,2})");

  // Rwy 13(128°)/31(308°) 7901x150 ASPH   -- bearings given
  // Rwy 18/36 3000x190 GRASS/SNOW         -- no bearings, small aerodromes
  // Rwy 12(123°) 2500x60 GRASS            -- one direction only
  // Lengths carry thousands separators at the big fields (10,995x200), and the
  // surface is optional: a runway must not be lost because it has no surface.
  // The surface is one word: letting it run on would swallow the "Rwy" that
  // starts the next runway on the same folded line.
  static const String _dims = r"\s+([\d,]+)x([\d,]+)(?:\s+([A-Za-z][A-Za-z/\-]*))?";
  static final RegExp _runwayBoth =
      RegExp(r"Rwy\s+(\w{2,3})\((\d{1,3})°\)/(\w{2,3})\((\d{1,3})°\)" + _dims);
  static final RegExp _runwayPlain =
      RegExp(r"Rwy\s+(\d{2}[LRC]?)/(\d{2}[LRC]?)" + _dims);
  static final RegExp _runwayOne =
      RegExp(r"Rwy\s+(\w{2,3})\((\d{1,3})°\)" + _dims);

  static final RegExp _frequency = RegExp(r"\b(1[0-9]{2}\.[0-9]{1,3})\b");

  // NAV block lines:
  //   VORTAC LUMSDEN VLN 114.2 Ch 89 N50 40 01 W104 53 23 (1895´)
  //   VOR/DME YYC 116.7 Ch 114 N51 06 55 W113 52 55 (3573')
  //   NDB X2 329 (L) N54 44 14 W113 12 05 Pvt Unmonitored
  // The name is optional, so whatever sits before the frequency is taken as
  // the identifier and anything earlier as the name.
  static const List<String> navLabels = [
    "VORTAC", "VOR/TACAN", "VOR/DME", "VOR", "NDB/DME", "NDB", "TACAN", "DME",
  ];
  static final RegExp _navHead = RegExp(
      "^(${navLabels.map(RegExp.escape).join("|")})\\s+(.*)");
  static final RegExp _navFrequency = RegExp(r"\b(\d{3}(?:\.\d{1,2})?)\b");
  static final RegExp _navElevation = RegExp(r"\((-?[\d,]+)\s*[´'’]\)");
  // ILS IQR 109.5 (Rwy 13) ...
  static final RegExp _ils =
      RegExp(r"^ILS\s+([A-Z]{2,4})\s+(\d{3}\.\d{1,2})\s+\(Rwy\s+(\w{2,3})\)");
  static final RegExp _effective = RegExp(
      r"Effective\s+\d{4}Z\s+(\d{1,2})\s+(\w+)\s+(\d{4})\s+to\s+"
      r"\d{4}Z\s+(\d{1,2})\s+(\w+)\s+(\d{4})");

  // Lines of the COMM block worth keeping as frequencies.
  static const List<String> commLabels = [
    "ATIS", "TWR", "GND", "MF", "ATF", "UNICOM", "RADIO", "RCO", "PAL",
    "APP", "DEP", "ARR", "CLNC DEL", "TML", "VDF", "AWOS",
  ];

  static const Map<String, String> _surfaces = {
    "ASPHALT": "ASPH", "ASPH": "ASPH", "PAVED": "ASPH", "TAR": "ASPH",
    "CONCRETE": "CONC", "CONC": "CONC",
    "GRAVEL": "GRVL", "GRVL": "GRVL", "CRUSHED": "GRVL",
    "GRASS": "TURF", "TURF": "TURF", "SOD": "TURF",
    "DIRT": "DIRT", "CLAY": "DIRT", "SAND": "SAND",
    "WATER": "WATER", "ICE": "ICE", "SNOW": "SNOW",
    "TREATED": "TREATED", "OIL": "TREATED",
  };

  static const Map<String, int> _months = {
    "JANUARY": 1, "FEBRUARY": 2, "MARCH": 3, "APRIL": 4, "MAY": 5, "JUNE": 6,
    "JULY": 7, "AUGUST": 8, "SEPTEMBER": 9, "OCTOBER": 10, "NOVEMBER": 11,
    "DECEMBER": 12,
  };

  /// Parse one volume. [pages] is the text of every page, in order.
  static CfsVolume parse(List<String> pages) {
    final List<_Entry> entries = _collect(pages);
    return CfsVolume(
      aerodromes: entries.map(_build).toList(),
      effectiveFrom: _effectiveDate(pages, from: true),
      effectiveTo: _effectiveDate(pages, from: false),
    );
  }

  /// Walk the pages and group them into entries, one per aerodrome.
  static List<_Entry> _collect(List<String> pages) {
    final List<_Entry> out = [];
    _Entry? current;
    for(int i = 0; i < pages.length; i++) {
      final String text = pages[i];
      if(!text.contains("AERODROME / FACILITY DIRECTORY")) {
        continue;                       // planning pages, charts, front matter
      }
      final List<String> body = [];
      for(final String raw in text.split("\n")) {
        final String line = raw.trimRight();
        if(line.trim().isEmpty || line == "CFS" || line == "ENGLISH" ||
           _footer.hasMatch(line) || _watermarkDate.hasMatch(line) ||
           _watermarkTime.hasMatch(line)) {
          continue;
        }
        body.add(line);
      }
      if(body.isEmpty) {
        continue;
      }
      final RegExpMatch? code = _pageCode.firstMatch(body.first);
      RegExpMatch? title;
      for(final String line in body.take(3)) {
        title = _title.firstMatch(line);
        if(title != null) {
          break;
        }
      }
      if(code != null && title != null && title.namedGroup("cont") == null) {
        current = _Entry(
          ident: title.namedGroup("id")!,
          province: code.group(1)!,
          name: title.namedGroup("name")!.trim(),
          isHeliport: title.namedGroup("kind") == "(Heli)",
          isWater: title.namedGroup("kind") == "(Water)",
          firstPage: i + 1,
        );
        out.add(current);
      } else if(current == null) {
        continue;                       // a stray page before any entry
      }
      current.lastPage = i + 1;
      // Only the first line of a page can be the page code: "GRASS" and
      // "ASPH" look exactly like one, and dropping them would lose the
      // runway surface that sits on its own line.
      final Iterable<String> rest = code != null ? body.skip(1) : body;
      current.lines.addAll(
          _fold(rest.where((l) => !_title.hasMatch(l)).toList()));
    }
    return out;
  }

  /// Join each continuation line onto the labelled line that owns it.
  static List<String> _fold(List<String> lines) {
    final List<String> out = [];
    for(final String line in lines) {
      if(out.isEmpty || _label.hasMatch(line)) {
        out.add(line);
      } else {
        out[out.length - 1] = "${out.last.trimRight()} ${line.trim()}";
      }
    }
    return out;
  }

  static CfsAerodrome _build(_Entry e) {
    double? latitude, longitude;
    int? elevation, variation, utcOffset;
    String? fuel, operator;
    final List<CfsRunway> runways = [];
    final List<CfsFrequency> frequencies = [];
    final List<CfsNavaid> navaids = [];
    final List<CfsIls> ilsList = [];

    for(final String line in e.lines) {
      if(latitude == null) {
        final RegExpMatch? dms = _positionDms.firstMatch(line);
        if(dms != null) {
          latitude = _dms(dms.group(1)!, dms.group(2)!, dms.group(3)!);
          longitude = -_dms(dms.group(4)!, dms.group(5)!, dms.group(6)!);
        } else {
          final RegExpMatch? dm = _positionDm.firstMatch(line);
          if(dm != null) {
            latitude = _dms(dm.group(1)!, dm.group(2)!, "0");
            longitude = -_dms(dm.group(3)!, dm.group(4)!, "0");
          }
        }
      }
      if(elevation == null) {
        final RegExpMatch? m = _elevation.firstMatch(line);
        if(m != null) {
          elevation = int.tryParse(m.group(1)!.replaceAll(",", ""));
        }
      }
      if(variation == null) {
        final RegExpMatch? m = _variation.firstMatch(line);
        if(m != null) {
          variation = int.parse(m.group(1)!) * (m.group(2) == "E" ? 1 : -1);
        }
      }
      if(utcOffset == null) {
        final RegExpMatch? m = _utc.firstMatch(line);
        if(m != null) {
          utcOffset = int.tryParse(m.group(1)!);
        }
      }
      if(line.contains("Rwy ")) {
        runways.addAll(_runways(line));
      }
      for(final String label in commLabels) {
        if(line.startsWith("$label ")) {
          final RegExpMatch? f = _frequency.firstMatch(line);
          if(f != null) {
            frequencies.add(CfsFrequency(label, f.group(1)!));
          }
        }
      }
      if(line.startsWith("FUEL ")) {
        fuel ??= line.substring(5).trim();
      }
      if(line.startsWith("OPR ")) {
        operator ??= line.substring(4).trim();
      }
      final CfsNavaid? nav = _navaid(line);
      if(nav != null) {
        navaids.add(nav);
      }
      final RegExpMatch? i = _ils.firstMatch(line);
      if(i != null) {
        ilsList.add(CfsIls(i.group(1)!, i.group(2)!, i.group(3)!));
      }
    }

    return CfsAerodrome(
      ident: e.ident,
      province: e.province,
      name: e.name,
      isHeliport: e.isHeliport,
      isWaterAerodrome: e.isWater,
      latitude: latitude,
      longitude: longitude,
      elevationFt: elevation,
      variation: variation,
      utcOffset: utcOffset,
      runways: runways,
      frequencies: frequencies,
      navaids: navaids,
      ils: ilsList,
      fuel: fuel,
      operator: operator,
      firstPage: e.firstPage,
      lastPage: e.lastPage,
    );
  }

  /// One line of the NAV block, or null when the line is not a navigation aid.
  /// Aids with no position of their own are skipped: an ILS belongs to a
  /// runway and is collected separately.
  static CfsNavaid? _navaid(String line) {
    final RegExpMatch? head = _navHead.firstMatch(line);
    if(head == null) {
      return null;
    }
    final String rest = head.group(2)!;
    final RegExpMatch? position = _positionDms.firstMatch(rest);
    if(position == null) {
      return null;             // a legend entry, or an aid listed without one
    }
    final String before = rest.substring(0, position.start);
    final RegExpMatch? frequency = _navFrequency.firstMatch(before);
    if(frequency == null) {
      return null;
    }
    final List<String> words = before
        .substring(0, frequency.start)
        .split(RegExp(r"\s+"))
        .where((w) => w.isNotEmpty)
        .toList();
    if(words.isEmpty) {
      return null;
    }
    final RegExpMatch? elevation =
        _navElevation.firstMatch(rest.substring(position.end));
    return CfsNavaid(
      type: head.group(1)!,
      ident: words.last,
      name: words.sublist(0, words.length - 1).join(" "),
      frequency: frequency.group(1)!,
      latitude: _dms(position.group(1)!, position.group(2)!, position.group(3)!),
      longitude:
          -_dms(position.group(4)!, position.group(5)!, position.group(6)!),
      elevationFt: elevation == null
          ? null
          : int.tryParse(elevation.group(1)!.replaceAll(",", "")),
    );
  }

  /// Every runway on one folded line. A second runway continues the RWY DATA
  /// line rather than starting a new field, so a line can hold several.
  static List<CfsRunway> _runways(String line) {
    final List<CfsRunway> out = [];
    for(final RegExpMatch m in _runwayBoth.allMatches(line)) {
      out.add(CfsRunway(
        ident: m.group(1)!,
        bearingTrue: int.parse(m.group(2)!),
        oppositeIdent: m.group(3),
        oppositeBearingTrue: int.parse(m.group(4)!),
        lengthFt: _int(m.group(5)!),
        widthFt: _int(m.group(6)!),
        surface: _surface(m.group(7)),
      ));
    }
    if(out.isNotEmpty) {
      return out;
    }
    for(final RegExpMatch m in _runwayPlain.allMatches(line)) {
      out.add(CfsRunway(
        ident: m.group(1)!,
        oppositeIdent: m.group(2),
        lengthFt: _int(m.group(3)!),
        widthFt: _int(m.group(4)!),
        surface: _surface(m.group(5)),
      ));
    }
    for(final RegExpMatch m in _runwayOne.allMatches(line)) {
      out.add(CfsRunway(
        ident: m.group(1)!,
        bearingTrue: int.parse(m.group(2)!),
        lengthFt: _int(m.group(3)!),
        widthFt: _int(m.group(4)!),
        surface: _surface(m.group(5)),
      ));
    }
    return out;
  }

  /// The CFS writes surfaces free-hand ("asphalt", "GRASS/SNOW", "crushed
  /// rock"), so fold them onto the codes the rest of the app uses. An
  /// unrecognised surface is left empty rather than guessed at: the capture
  /// may have run on into the text that follows the dimensions.
  static String _surface(String? text) {
    final String s = (text ?? "").trim().toUpperCase();
    if(s.isEmpty) {
      return "";
    }
    for(final MapEntry<String, String> e in _surfaces.entries) {
      if(s.contains(e.key)) {
        return e.value;
      }
    }
    return "";
  }

  static double _dms(String d, String m, String s) =>
      int.parse(d) + int.parse(m) / 60 + (double.tryParse(s) ?? 0) / 3600;

  static int _int(String s) => int.parse(s.replaceAll(",", ""));

  /// "Effective 0901Z 16 May 2024 to 0901Z 11 July 2024", off the footer.
  static DateTime? _effectiveDate(List<String> pages, {required bool from}) {
    for(final String page in pages.take(40)) {
      final RegExpMatch? m = _effective.firstMatch(page.replaceAll("\n", " "));
      if(m == null) {
        continue;
      }
      final int day = int.parse(m.group(from ? 1 : 4)!);
      final int? month = _months[m.group(from ? 2 : 5)!.toUpperCase()];
      final int year = int.parse(m.group(from ? 3 : 6)!);
      if(month == null) {
        continue;
      }
      return DateTime.utc(year, month, day, 9, 1);
    }
    return null;
  }

  /// Great-circle bearing is not available without threshold coordinates, so
  /// the map symbol works from the runway bearing. Exposed for callers that
  /// want it folded to 0..180, which is all a runway line needs.
  static double foldBearing(double bearing) {
    final double b = bearing % 180;
    return b < 0 ? b + 180 : b;
  }

  /// Distance in nautical miles, used to match CFS entries against rows that
  /// came from another source.
  static double distanceNm(double lat1, double lon1, double lat2, double lon2) {
    const double r = 3440.065;
    final double p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final double dp = p2 - p1, dl = (lon2 - lon1) * math.pi / 180;
    final double a = math.sin(dp / 2) * math.sin(dp / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}

/// An entry while it is being collected across its pages.
class _Entry {
  final String ident;
  final String province;
  final String name;
  final bool isHeliport;
  final bool isWater;
  final int firstPage;
  int lastPage;
  final List<String> lines = [];

  _Entry({
    required this.ident,
    required this.province,
    required this.name,
    required this.isHeliport,
    required this.isWater,
    required this.firstPage,
  }) : lastPage = firstPage;
}
