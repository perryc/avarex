// Opt-in check of the CFS parser against a real supplement. Nothing from a
// real CFS lives in the repository: point the test at a file of page text to
// run it, and it is skipped otherwise.
//
//   CFS_PAGES=/path/to/pages.json flutter test test/cfs_coverage_test.dart
//
// pages.json is a JSON array holding the text of every page of one volume, in
// order, which is what CfsImport feeds the parser at run time.
import 'dart:convert';
import 'dart:io';

import 'package:avaremp/canada/cfs_parse.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final String path = Platform.environment["CFS_PAGES"] ?? "";

  test("coverage against a real supplement", () {
    final List<String> pages = (jsonDecode(File(path).readAsStringSync())
        as List<dynamic>).cast<String>();
    final CfsVolume v = CfsParser.parse(pages);
    final List<CfsAerodrome> a = v.aerodromes;

    int count(bool Function(CfsAerodrome) f) => a.where(f).length;
    String pct(int n) => "${(100 * n / a.length).toStringAsFixed(1)}%";
    final List<CfsAerodrome> landplanes =
        a.where((x) => !x.isHeliport && !x.isWaterAerodrome).toList();
    final int withRunway = landplanes.where((x) => x.runways.isNotEmpty).length;

    // ignore: avoid_print
    print("""
pages              ${pages.length}
aerodromes         ${a.length}
  with a position  ${pct(count((x) => x.latitude != null))}
  with elevation   ${pct(count((x) => x.elevationFt != null))}
  with variation   ${pct(count((x) => x.variation != null))}
  with a frequency ${pct(count((x) => x.frequencies.isNotEmpty))}
  with fuel        ${pct(count((x) => x.fuel != null))}
  towered          ${count((x) => x.isTowered)}
  heliports        ${count((x) => x.isHeliport)}
  multi-page       ${count((x) => x.lastPage > x.firstPage)}
landplane aerodromes ${landplanes.length}
  with a runway    ${(100 * withRunway / landplanes.length).toStringAsFixed(1)}%
  runway surface   ${landplanes.where((x) => x.runways.isNotEmpty &&
          x.runways.every((r) => r.surface.isNotEmpty)).length}
  true bearings    ${landplanes.where((x) => x.runways.isNotEmpty &&
          x.runways.every((r) => r.bearingTrue != null)).length}
navaids            ${a.expand((x) => x.navaids).length}  (${a.expand((x) => x.navaids).where((n) => n.isNdb).length} NDB)
ILS                ${a.expand((x) => x.ils).length}
cycle              ${v.effectiveFrom} to ${v.effectiveTo}""");

    expect(a.length, greaterThan(100));
    expect(count((x) => x.latitude != null) / a.length, greaterThan(0.95));
    expect(count((x) => x.elevationFt != null) / a.length, greaterThan(0.95));
    expect(withRunway / landplanes.length, greaterThan(0.95));
    expect(v.effectiveFrom, isNotNull);

    // Aerodromes whose runway line is typeset oddly, found by reading the
    // volume rather than by guessing. Each lost its runways once.
    for(final String ident in const [
      "CAG2",   // Rwy 11(105º) with a masculine ordinal, not a degree sign
      "CFM7",   // Rwy 09(089) with no degree sign at all
      "CJR2",   // the same, after an RCR line
      "CRF3",   // 2400X60, a capital X
      "CJB5",   // 5000 x75, a space before it
      "CCF6",   // 1675x 80, a space after it
      "CYWN",   // bearings but no dimensions published
      "CEZ4", "CPV9", "CRF5",
    ]) {
      final Iterable<CfsAerodrome> found = a.where((x) => x.ident == ident);
      if(found.isEmpty) {
        continue;            // a different volume
      }
      expect(found.first.runways, isNotEmpty, reason: ident);
    }
    // every position must land inside Canada
    for(final CfsAerodrome x in a.where((x) => x.latitude != null)) {
      expect(x.latitude, inInclusiveRange(41, 84), reason: x.ident);
      expect(x.longitude, inInclusiveRange(-142, -52), reason: x.ident);
    }
    // every navaid must have a position inside Canada too
    for(final CfsNavaid n in a.expand((x) => x.navaids)) {
      expect(n.latitude, inInclusiveRange(41, 84), reason: n.ident);
      expect(n.longitude, inInclusiveRange(-142, -52), reason: n.ident);
      expect(n.ident, isNotEmpty);
    }
    // runway dimensions must be sane
    for(final CfsRunway r in a.expand((x) => x.runways)) {
      if(r.lengthFt != null) {
        expect(r.lengthFt, inInclusiveRange(200, 20000), reason: r.ident);
      }
      if(r.widthFt != null) {
        expect(r.widthFt, inInclusiveRange(10, 1000), reason: r.ident);
      }
    }
  }, skip: path.isEmpty ? "set CFS_PAGES to a page-text file" : false);
}
