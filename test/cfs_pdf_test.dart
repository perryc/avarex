// Opt-in end-to-end check: a real CFS PDF through pdfrx and the parser.
// Nothing from a real supplement is in the repository, so point it at a file:
//
//   CFS_PDF=/path/to/eCFS3.pdf flutter test test/cfs_pdf_test.dart
//
// It is skipped otherwise. pdfrx is initialised here in its Dart-only form
// because a plain flutter test has no plugins; the app calls the Flutter one.
import 'dart:io';

import 'package:avaremp/canada/cfs_parse.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  final String file = Platform.environment["CFS_PDF"] ?? "";

  test("a real supplement, read with pdfrx", () async {
    await pdfrxInitialize();
    final PdfDocument document = await PdfDocument.openFile(file);
    final Stopwatch clock = Stopwatch()..start();
    final List<String> pages = [];
    for(int i = 0; i < document.pages.length; i++) {
      pages.add((await document.pages[i].loadText())?.fullText ?? "");
    }
    final int readMs = clock.elapsedMilliseconds;
    document.dispose();

    final CfsVolume v = CfsParser.parse(pages);
    final List<CfsAerodrome> a = v.aerodromes;
    final List<CfsAerodrome> landplanes =
        a.where((x) => !x.isHeliport && !x.isWaterAerodrome).toList();
    final int withRunway = landplanes.where((x) => x.runways.isNotEmpty).length;

    // ignore: avoid_print
    print("""
${pages.length} pages read in ${readMs}ms
aerodromes       ${a.length}
  position       ${a.where((x) => x.latitude != null).length}
  runway data    $withRunway of ${landplanes.length} landplane aerodromes
  frequencies    ${a.where((x) => x.frequencies.isNotEmpty).length}
navaids          ${a.expand((x) => x.navaids).length}
cycle            ${v.effectiveFrom} to ${v.effectiveTo}  expired ${v.isExpired}""");

    expect(a.length, greaterThan(100));
    expect(withRunway / landplanes.length, greaterThan(0.95));
    // the text must come out readable: a broken font fallback shows up as
    // runways and frequencies that will not parse at all
    expect(a.where((x) => x.frequencies.isNotEmpty).length / a.length,
        greaterThan(0.9));
    expect(v.effectiveFrom, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 5)),
     skip: file.isEmpty ? "set CFS_PDF to a Canada Flight Supplement" : false);
}
