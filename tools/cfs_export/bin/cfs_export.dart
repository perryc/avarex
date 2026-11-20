// Builds canada.efb for the cb-tfc-disp cockpit display from Canada Flight
// Supplement volumes, with the same parser the app's CFS import uses
// (lib/canada/cfs_parse.dart).
//
//   dart run bin/cfs_export.dart --pdf eCFS3.pdf [--pdf ...] -o canada.efb
//   dart run bin/cfs_export.dart --json <dataDir>/canada/cfs/eCFS3.pdf.json -o canada.efb
//
// --json takes the parse caches the app writes on import, so a supplement
// already imported into AvareX need not be read again.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

import '../../../lib/canada/cfs_parse.dart';
import '../lib/efb_writer.dart';

Future<List<String>> readPages(String file) async {
  final PdfDocument document = await PdfDocument.openFile(file);
  try {
    final List<String> pages = [];
    for (int i = 0; i < document.pages.length; i++) {
      pages.add((await document.pages[i].loadText())?.fullText ?? "");
    }
    return pages;
  } finally {
    document.dispose();
  }
}

void report(String source, CfsVolume v) {
  final a = v.aerodromes;
  final landplanes = a.where((x) => !x.isHeliport && !x.isWaterAerodrome).toList();
  final withRunway = landplanes.where((x) => x.runways.isNotEmpty).length;
  final withPosition = a.where((x) => x.latitude != null).length;
  String pct(int n, int of) => of == 0 ? "-" : "${(100 * n / of).toStringAsFixed(1)}%";
  stdout.writeln("$source: ${a.length} aerodromes, position ${pct(withPosition, a.length)}, "
      "runways ${pct(withRunway, landplanes.length)} of landplanes, "
      "frequencies ${pct(a.where((x) => x.frequencies.isNotEmpty).length, a.length)}, "
      "cycle ${v.effectiveFrom?.toIso8601String().substring(0, 10) ?? "?"} to "
      "${v.effectiveTo?.toIso8601String().substring(0, 10) ?? "?"}");
}

Future<void> main(List<String> argv) async {
  final ArgParser parser = ArgParser()
    ..addMultiOption("pdf", help: "a CFS volume PDF")
    ..addMultiOption("json", help: "an AvareX CFS parse cache (<file>.pdf.json)")
    ..addOption("out", abbr: "o", defaultsTo: "canada.efb", help: "output file")
    ..addFlag("help", abbr: "h", negatable: false);
  final ArgResults args = parser.parse(argv);
  final List<String> pdfs = args["pdf"] as List<String>;
  final List<String> jsons = args["json"] as List<String>;
  if (args["help"] as bool || (pdfs.isEmpty && jsons.isEmpty)) {
    stdout.writeln("usage: dart run bin/cfs_export.dart (--pdf FILE | --json FILE)... [-o canada.efb]\n${parser.usage}");
    exit(pdfs.isEmpty && jsons.isEmpty ? 64 : 0);
  }

  final List<CfsVolume> volumes = [];
  if (pdfs.isNotEmpty) await pdfrxInitialize();
  for (final String pdf in pdfs) {
    final CfsVolume v = CfsParser.parse(await readPages(pdf));
    report(pdf, v);
    if (v.aerodromes.isEmpty) {
      stderr.writeln("$pdf: no aerodrome directory found");
      exit(1);
    }
    volumes.add(v);
  }
  for (final String json in jsons) {
    final CfsVolume v = CfsVolume.fromJson(
        (jsonDecode(await File(json).readAsString()) as Map).cast<String, Object?>());
    report(json, v);
    volumes.add(v);
  }

  final bytes = writeEfb(volumes);
  await File(args["out"] as String).writeAsBytes(bytes);
  stdout.writeln("wrote ${args["out"]}: ${bytes.length} bytes");
}
