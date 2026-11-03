// Finding an airport by its name, not just its identifier. The clause is run
// against a real SQLite database rather than compared as a string, because
// what matters is what SQLite does with it.
import 'package:avaremp/data/main_database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute("create table airports("
        "LocationID text, FacilityName text, City text)");
    for(final List<String> a in const [
      ["CDS2", "DISLEY", "DISLEY"],
      ["CYBW", "CALGARY / SPRINGBANK", "CALGARY"],
      ["CYQR", "REGINA INTL", "REGINA"],
      ["CYYC", "CALGARY / YYC CALGARY INTL", "CALGARY"],
      ["KBOS", "GENERAL EDWARD LAWRENCE LOGAN INTL", "BOSTON"],
      ["CDJ3", "O'CONNOR FARM", "O'CONNOR"],
    ]) {
      await db.insert("airports",
          {"LocationID": a[0], "FacilityName": a[1], "City": a[2]});
    }
  });

  tearDownAll(() async => db.close());

  /// The airports half of findDestinations, run for real.
  Future<List<String>> find(String typed, {bool exact = false}) async {
    final String safe = typed.replaceAll("'", "''");
    final String eMatch = exact ? " = '$safe'" : "like '$safe%'";
    final String byName =
        MainDatabaseHelper.airportNameClause(safe, exact: exact);
    final List<Map<String, Object?>> rows = await db.rawQuery(
        "select LocationID from airports "
        "where ((LocationID $eMatch) or $byName) order by LocationID");
    return rows.map((r) => r["LocationID"] as String).toList();
  }

  test("the identifier still finds it", () async {
    expect(await find("CDS2"), ["CDS2"]);
    expect(await find("cds2"), ["CDS2"]);     // LIKE is case-insensitive
    expect(await find("CY"), containsAll(["CYBW", "CYQR", "CYYC"]));
  });

  test("the name finds it, which is what was missing", () async {
    expect(await find("Disley"), ["CDS2"]);
    expect(await find("disley"), ["CDS2"]);
    expect(await find("Regina"), ["CYQR"]);
  });

  test("the second half of a Canadian name is findable", () async {
    // entries are titled town first, so the useful word is often not first
    expect(await find("Springbank"), ["CYBW"]);
    expect(await find("LOGAN"), ["KBOS"]);
  });

  test("a city still matches", () async {
    expect(await find("Boston"), ["KBOS"]);
    expect(await find("Calgary"), ["CYBW", "CYYC"]);
  });

  test("short searches stay on the identifier", () async {
    // two letters must not drag in every name containing them
    expect(await find("CD"), ["CDJ3", "CDS2"]);
    expect(await find("IN"), isEmpty);        // would match INTL if it scanned
  });

  test("a quote in the name does not break the query", () async {
    expect(await find("O'Connor"), ["CDJ3"]);
  });

  test("exact matching stays exact", () async {
    expect(await find("DISLEY", exact: true), ["CDS2"]);
    expect(await find("REGINA INTL", exact: true), ["CYQR"]);
    expect(await find("Regi", exact: true), isEmpty);
  });
}
