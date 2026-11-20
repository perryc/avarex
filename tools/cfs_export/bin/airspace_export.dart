// Builds airspace.efb for the cb-tfc-disp map from the soaringweb.org Canadian
// OpenAir file (the one AvareX's Canada download fetches).
//
//   dart run bin/airspace_export.dart CanAirspace323all.txt -o airspace.efb

import 'dart:io';

import 'package:args/args.dart';

import '../lib/airspace_writer.dart';

void main(List<String> argv) {
  final ArgParser parser = ArgParser()
    ..addOption("out", abbr: "o", defaultsTo: "airspace.efb", help: "output file")
    ..addFlag("help", abbr: "h", negatable: false);
  final ArgResults args = parser.parse(argv);
  if (args["help"] as bool || args.rest.length != 1) {
    stdout.writeln("usage: dart run bin/airspace_export.dart CanAirspaceNNNall.txt [-o airspace.efb]\n${parser.usage}");
    exit(args.rest.length == 1 ? 0 : 64);
  }
  final String text = File(args.rest.first).readAsStringSync(encoding: const SystemEncoding());
  final (from, to) = effectiveDates(text);
  final bytes = writeAirspace(text);
  File(args["out"] as String).writeAsBytesSync(bytes);
  stdout.writeln("wrote ${args["out"]}: ${bytes.length} bytes, effective "
      "${from?.toIso8601String().substring(0, 10) ?? "?"} to ${to?.toIso8601String().substring(0, 10) ?? "?"}");
}
