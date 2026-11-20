// Writes airspace.efb: Canadian airspace (the soaringweb.org OpenAir file,
// derived from Nav Canada's Designated Airspace Handbook) for the cb-tfc-disp map.
//
// Little-endian, records 4-byte aligned, text in a NUL-terminated UTF-8 pool
// referenced by offset (0 = ""), CRC-32 trailer:
//
//   header   40 bytes
//   areas    32 bytes each
//   points    8 bytes each: lat, lon as int32 1e-7 degrees
//   strings  pool
//   crc32     4 bytes
//
// As AvareX's map, airspace with a floor at or above 12,500 ft is left out:
// it blankets the country and doesn't matter to VFR below it.
// The C++ reader is components/disp_core/include/disp/navdb/airspace.hpp in
// cb-tfc-disp; change both together and bump kAirspaceVersion.

import 'dart:convert';
import 'dart:typed_data';

import '../../../lib/utils/openair_parser.dart';
import 'efb_writer.dart' show crc32;

const int kAirspaceVersion = 1;
const int kAirspaceHeaderSize = 40;
const int kSkipFloorFt = 12500;
const int kUnlimited = 99999;

const int flagSurface = 0x01; // floor at the surface
const int flagMf = 0x02;      // class F that is an MF/ATF zone (drawn like a control zone)

/// Feet for an OpenAir limit: SFC/GND 0, "FL 125" 12500, "UNL" unlimited,
/// "3500" or "3500 MSL"/"AGL" its number (AGL heights are approximate here).
int limitFt(String text) {
  final String t = text.toUpperCase().trim();
  if (t.isEmpty || t.startsWith("SFC") || t.startsWith("GND")) return 0;
  if (t.startsWith("UNL")) return kUnlimited;
  if (t.startsWith("FL")) {
    final int? fl = int.tryParse(t.substring(2).trim().split(RegExp(r'\D')).first);
    return fl == null ? 0 : fl * 100;
  }
  final RegExpMatch? m = RegExp(r'(\d+)').firstMatch(t);
  return m == null ? 0 : int.parse(m.group(1)!);
}

/// "EFFECTIVE: 03 SEPTEMBER 2026 NEXT ISSUE: 29 OCTOBER 2026" in the header comments.
(DateTime?, DateTime?) effectiveDates(String text) {
  const months = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST",
      "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"];
  DateTime? parse(String? s) {
    if (s == null) return null;
    final m = RegExp(r'(\d{1,2})\s+([A-Z]+)\s+(\d{4})').firstMatch(s.toUpperCase());
    if (m == null) return null;
    final int month = months.indexOf(m.group(2)!) + 1;
    return month == 0 ? null : DateTime.utc(int.parse(m.group(3)!), month, int.parse(m.group(1)!));
  }
  final m = RegExp(r'EFFECTIVE:\s*([^\n]*?)\s+NEXT ISSUE:\s*([^\n]*)', caseSensitive: false).firstMatch(text);
  return (parse(m?.group(1)), parse(m?.group(2)));
}

Uint8List writeAirspace(String openAir) {
  final List<OpenAirAirspace> all = OpenAirParser().parse(openAir);
  final (from, to) = effectiveDates(openAir);
  final kept = all.where((a) => a.points.length >= 3 && limitFt(a.floor) < kSkipFloorFt).toList();

  final BytesBuilder pool = BytesBuilder()..addByte(0);
  final Map<String, int> offsets = {"": 0};
  int str(String s) => s.isEmpty
      ? 0
      : offsets.putIfAbsent(s, () {
          final int at = pool.length;
          pool.add(utf8.encode(s));
          pool.addByte(0);
          return at;
        });

  final ByteData areas = ByteData(kept.length * 32);
  int nPoints = kept.fold(0, (n, a) => n + a.points.length);
  final ByteData points = ByteData(nPoints * 8);
  int p = 0;
  for (int i = 0; i < kept.length; i++) {
    final a = kept[i];
    final int floor = limitFt(a.floor);
    int flags = 0;
    if (floor == 0) flags |= flagSurface;
    if (a.cls.toUpperCase() == "F" && RegExp(r'\b(MF|ATF)\b').hasMatch(a.name)) flags |= flagMf;
    final int o = i * 32;
    areas.setUint32(o, str(a.name), Endian.little);
    areas.setUint8(o + 4, a.cls.isEmpty ? 0x3F : a.cls.toUpperCase().codeUnitAt(0)); // '?' when missing
    areas.setUint8(o + 5, flags);
    areas.setUint16(o + 6, 0, Endian.little);
    areas.setInt32(o + 8, floor, Endian.little);
    areas.setInt32(o + 12, limitFt(a.ceiling), Endian.little);
    areas.setUint32(o + 16, str(a.floor), Endian.little);
    areas.setUint32(o + 20, str(a.ceiling), Endian.little);
    areas.setUint32(o + 24, p, Endian.little);
    areas.setUint32(o + 28, a.points.length, Endian.little);
    for (final pt in a.points) {
      points.setInt32(p * 8, (pt.latitude * 1e7).round(), Endian.little);
      points.setInt32(p * 8 + 4, (pt.longitude * 1e7).round(), Endian.little);
      p++;
    }
  }

  final Uint8List strings = pool.toBytes();
  final int areaOff = kAirspaceHeaderSize;
  final int pointOff = areaOff + areas.lengthInBytes;
  final int strOff = pointOff + points.lengthInBytes;
  final int end = strOff + strings.length;
  final int padded = (end + 3) & ~3;

  int days(DateTime? d) => d == null ? 0 : d.difference(DateTime.utc(1970)).inDays;
  final ByteData h = ByteData(kAirspaceHeaderSize);
  h.setUint8(0, 0x45); h.setUint8(1, 0x46); h.setUint8(2, 0x42); h.setUint8(3, 0x41); // "EFBA"
  h.setUint16(4, kAirspaceVersion, Endian.little);
  h.setUint16(6, kAirspaceHeaderSize, Endian.little);
  h.setUint32(8, days(from), Endian.little);
  h.setUint32(12, days(to), Endian.little);
  h.setUint32(16, kept.length, Endian.little);
  h.setUint32(20, nPoints, Endian.little);
  h.setUint32(24, areaOff, Endian.little);
  h.setUint32(28, pointOff, Endian.little);
  h.setUint32(32, strOff, Endian.little);
  h.setUint32(36, strings.length, Endian.little);

  final BytesBuilder out = BytesBuilder()
    ..add(h.buffer.asUint8List())
    ..add(areas.buffer.asUint8List())
    ..add(points.buffer.asUint8List())
    ..add(strings)
    ..add(Uint8List(padded - end));
  final Uint8List body = out.toBytes();
  final ByteData crc = ByteData(4)..setUint32(0, crc32(body), Endian.little);
  return (BytesBuilder()..add(body)..add(crc.buffer.asUint8List())).toBytes();
}
