import 'dart:convert';

import 'package:avaremp/canada/canada_import.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';

/// One aircraft from the Transport Canada Canadian Civil Aircraft Register.
class CanadaAircraft {
  final String mark;   // "C-FMHP"
  final String model;  // "RV-10"
  final String common; // "Van'S"
  const CanadaAircraft(this.mark, this.model, this.common);
}

/// In-memory lookup of Canadian aircraft by 24-bit Mode S address, loaded
/// from the `caregistry` table that the Canada download product fills from
/// Transport Canada's daily register dump (carscurr.txt). Every registered
/// Canadian aircraft carries a Mode S address in the register, ultralights
/// (C-Ixx) included, so this resolves the traffic the C-F/C-G formula in
/// TrafficReportMessage.displayId cannot, and adds the model.
class CanadaRegistry {

  final Map<int, CanadaAircraft> _byIcao = {};
  final ValueNotifier<int> change = ValueNotifier<int>(0);

  int get count => _byIcao.length;

  CanadaAircraft? lookup(int icao) => _byIcao[icao];

  /// Replace the table (used by tests and after an import).
  void seed(Map<int, CanadaAircraft> entries) {
    _byIcao
      ..clear()
      ..addAll(entries);
    change.value++;
  }

  void clear() => seed(const {});

  Future<void> load() async {
    try {
      final Map<int, CanadaAircraft> entries = {};
      for (final row in await CanadaImport.getRegistry()) {
        entries[row["ICAO"] as int] = CanadaAircraft(
            row["Mark"] as String, row["Model"] as String, row["CommonName"] as String);
      }
      seed(entries);
    }
    catch (e) {
      AppLog.logMessage("Canada registry load failed: $e");
    }
  }

  // carscurr.txt columns (0-based): 0 MARK, 3 COMMON_NAME, 4 MODEL_NAME,
  // 42 MODE_S_TRANSPONDER_BINARY (24 chars of '0'/'1'). Latin-1 encoded.
  static const int _colMark = 0;
  static const int _colCommon = 3;
  static const int _colModel = 4;
  static const int _colModeS = 42;

  /// Parse the register dump into rows for the `caregistry` table.
  static List<Map<String, Object?>> parse(List<int> latin1Bytes) {
    final String text = latin1.decode(latin1Bytes).replaceAll("\r\n", "\n");
    final List<List<dynamic>> rows =
        const CsvToListConverter(shouldParseNumbers: false, eol: "\n").convert(text);
    final List<Map<String, Object?>> out = [];
    for (final row in rows) {
      if (row.length <= _colModeS) {
        continue;
      }
      final String bits = row[_colModeS].toString().trim();
      final String mark = row[_colMark].toString().trim().toUpperCase();
      if (bits.length != 24 || mark.isEmpty) {
        continue;
      }
      final int? icao = int.tryParse(bits, radix: 2);
      if (icao == null) {
        continue;
      }
      out.add({
        "ICAO": icao,
        "Mark": "C-$mark",
        "Model": _clean(row[_colModel].toString()),
        "CommonName": _clean(row[_colCommon].toString()),
      });
    }
    return out;
  }

  static String _clean(String s) =>
      s.trim().replaceAll(RegExp(r"\s+"), " ").toUpperCase();
}
