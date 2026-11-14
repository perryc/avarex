// Writes canada.efb: the aerodromes of one or more parsed CFS volumes in the
// flat binary layout the efb-p4 firmware loads straight into memory.
//
// Little-endian throughout. Records are fixed size and 4-byte aligned; text
// lives in one string pool of NUL-terminated UTF-8, referenced by byte offset
// (offset 0 is the empty string). A CRC-32 of everything before it ends the file.
//
//   header      64 bytes
//   aerodromes  48 bytes each, sorted by ident
//   runways     20 bytes each
//   freqs        8 bytes each
//   navaids     28 bytes each
//   ils         12 bytes each
//   strings     pool
//   crc32        4 bytes
//
// The C++ reader is components/efb_core/include/efb/navdb/navdb.hpp in efb-p4;
// change both together and bump kVersion.

import 'dart:convert';
import 'dart:typed_data';

import '../../../lib/canada/cfs_parse.dart';

const int kVersion = 1;
const int kHeaderSize = 64;
const int kAerodromeSize = 48;
const int kRunwaySize = 20;
const int kFreqSize = 8;
const int kNavaidSize = 28;
const int kIlsSize = 12;

const int flagHeliport = 0x01;
const int flagWater = 0x02;
const int flagTowered = 0x04;
const int flagPosition = 0x08;

const int unknownI16 = -32768;
const int unknownI8 = -128;

class _Strings {
  final BytesBuilder _bytes = BytesBuilder()..addByte(0);
  final Map<String, int> _offsets = {"": 0};

  int add(String? s) {
    if (s == null || s.isEmpty) return 0;
    return _offsets.putIfAbsent(s, () {
      final int at = _bytes.length;
      _bytes.add(utf8.encode(s));
      _bytes.addByte(0);
      return at;
    });
  }

  Uint8List bytes() => _bytes.toBytes();
}

class _Out {
  final BytesBuilder b = BytesBuilder();
  final ByteData _scratch = ByteData(8);

  void u8(int v) => b.addByte(v & 0xFF);
  void i8(int v) => b.addByte(v & 0xFF);
  void u16(int v) { _scratch.setUint16(0, v, Endian.little); b.add(_scratch.buffer.asUint8List(0, 2)); }
  void i16(int v) { _scratch.setInt16(0, v, Endian.little); b.add(_scratch.buffer.asUint8List(0, 2)); }
  void u32(int v) { _scratch.setUint32(0, v, Endian.little); b.add(_scratch.buffer.asUint8List(0, 4)); }
  void i32(int v) { _scratch.setInt32(0, v, Endian.little); b.add(_scratch.buffer.asUint8List(0, 4)); }

  // Fixed-width ASCII, NUL padded (runway idents).
  void chars(String s, int width) {
    final List<int> c = ascii.encode(s.length > width ? s.substring(0, width) : s);
    b.add(c);
    for (int i = c.length; i < width; i++) b.addByte(0);
  }

  int get length => b.length;
}

int _e7(double? deg) => deg == null ? 0 : (deg * 1e7).round();

int? _khz(String mhz) {
  final double? v = double.tryParse(mhz.trim());
  return v == null ? null : (v * 1000).round();
}

int _days(DateTime? d) =>
    d == null ? 0 : d.toUtc().difference(DateTime.utc(1970)).inDays;

int _clampI16(int? v) => v == null ? unknownI16 : v.clamp(-32767, 32767);
int _clampI8(int? v) => v == null ? unknownI8 : v.clamp(-127, 127);

/// Merges volumes (a later edition of an aerodrome replaces an earlier one)
/// and encodes them.
Uint8List writeEfb(List<CfsVolume> volumes) {
  final List<CfsVolume> byDate = [...volumes]
    ..sort((a, b) => (a.effectiveFrom ?? DateTime(0)).compareTo(b.effectiveFrom ?? DateTime(0)));
  final Map<String, CfsAerodrome> merged = {};
  for (final CfsVolume v in byDate) {
    for (final CfsAerodrome a in v.aerodromes) {
      merged[a.ident] = a;
    }
  }
  final List<CfsAerodrome> aerodromes = merged.values.toList()
    ..sort((a, b) => a.ident.compareTo(b.ident));

  DateTime? from, to;
  for (final CfsVolume v in volumes) {
    // the file is only as current as its oldest volume
    if (v.effectiveFrom != null && (from == null || v.effectiveFrom!.isAfter(from))) from = v.effectiveFrom;
    if (v.effectiveTo != null && (to == null || v.effectiveTo!.isBefore(to))) to = v.effectiveTo;
  }

  final _Strings strings = _Strings();
  final _Out ad = _Out(), rw = _Out(), fq = _Out(), nv = _Out(), il = _Out();
  int nRunways = 0, nFreqs = 0, nNavaids = 0, nIls = 0;

  for (final CfsAerodrome a in aerodromes) {
    final int runwayFirst = nRunways, freqFirst = nFreqs, navaidFirst = nNavaids, ilsFirst = nIls;

    for (final CfsRunway r in a.runways) {
      rw.chars(r.ident, 4);
      rw.chars(r.oppositeIdent ?? "", 4);
      rw.i16(r.bearingTrue ?? -1);
      rw.i16(r.oppositeBearingTrue ?? -1);
      rw.u16((r.lengthFt ?? 0).clamp(0, 65535));
      rw.u16((r.widthFt ?? 0).clamp(0, 65535));
      rw.u32(strings.add(r.surface));
      nRunways++;
    }
    for (final CfsFrequency f in a.frequencies) {
      final int? khz = _khz(f.mhz);
      if (khz == null) continue;
      fq.u32(strings.add(f.type));
      fq.u32(khz);
      nFreqs++;
    }
    for (final CfsNavaid n in a.navaids) {
      nv.u32(strings.add(n.type));
      nv.u32(strings.add(n.ident));
      nv.u32(strings.add(n.name));
      nv.u32(strings.add(n.frequency));
      nv.i32(_e7(n.latitude));
      nv.i32(_e7(n.longitude));
      nv.i16(_clampI16(n.elevationFt));
      nv.u16(n.latitude != null && n.longitude != null ? 1 : 0);
      nNavaids++;
    }
    for (final CfsIls i in a.ils) {
      final int? khz = _khz(i.frequency);
      il.u32(strings.add(i.ident));
      il.u32(khz ?? 0);
      il.chars(i.runway, 4);
      nIls++;
    }

    int flags = 0;
    if (a.isHeliport) flags |= flagHeliport;
    if (a.isWaterAerodrome) flags |= flagWater;
    if (a.isTowered) flags |= flagTowered;
    if (a.latitude != null && a.longitude != null) flags |= flagPosition;

    ad.u32(strings.add(a.ident));
    ad.u32(strings.add(a.name));
    ad.i32(_e7(a.latitude));
    ad.i32(_e7(a.longitude));
    ad.i16(_clampI16(a.elevationFt));
    ad.i8(_clampI8(a.variation));
    ad.i8(_clampI8(a.utcOffset));
    ad.u8(flags);
    ad.chars(a.province, 2);
    ad.u8(0);
    ad.u16(runwayFirst);
    ad.u8(nRunways - runwayFirst);
    ad.u8(nFreqs - freqFirst);
    ad.u16(freqFirst);
    ad.u16(navaidFirst);
    ad.u8(nNavaids - navaidFirst);
    ad.u8(nIls - ilsFirst);
    ad.u16(ilsFirst);
    ad.u32(strings.add(a.fuel));
    ad.u32(strings.add(a.operator));
    ad.u16(a.firstPage.clamp(0, 65535));
    ad.u16(a.lastPage.clamp(0, 65535));
  }
  if (nRunways > 65535 || nFreqs > 65535 || nNavaids > 65535 || nIls > 65535) {
    throw StateError("too many records for 16-bit indexes");
  }

  final Uint8List pool = strings.bytes();
  int at = kHeaderSize;
  final int adOff = at; at += ad.length;
  final int rwOff = at; at += rw.length;
  final int fqOff = at; at += fq.length;
  final int nvOff = at; at += nv.length;
  final int ilOff = at; at += il.length;
  final int strOff = at; at += pool.length;
  final int padded = (at + 3) & ~3;

  final _Out out = _Out();
  out.chars("EFBC", 4);
  out.u16(kVersion);
  out.u16(kHeaderSize);
  out.u32(_days(from));
  out.u32(_days(to));
  out.u32(aerodromes.length);
  out.u32(nRunways);
  out.u32(nFreqs);
  out.u32(nNavaids);
  out.u32(nIls);
  out.u32(adOff);
  out.u32(rwOff);
  out.u32(fqOff);
  out.u32(nvOff);
  out.u32(ilOff);
  out.u32(strOff);
  out.u32(pool.length);
  assert(out.length == kHeaderSize);
  out.b.add(ad.b.toBytes());
  out.b.add(rw.b.toBytes());
  out.b.add(fq.b.toBytes());
  out.b.add(nv.b.toBytes());
  out.b.add(il.b.toBytes());
  out.b.add(pool);
  for (int i = at; i < padded; i++) out.u8(0);
  out.u32(crc32(out.b.toBytes()));
  return out.b.toBytes();
}

/// CRC-32 (IEEE 802.3, reflected 0xEDB88320), as zlib.
int crc32(Uint8List data) {
  int crc = 0xFFFFFFFF;
  for (final int b in data) {
    crc ^= b;
    for (int k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
