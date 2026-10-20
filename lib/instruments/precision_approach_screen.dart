import 'dart:async';
import 'dart:math';

import 'package:avaremp/data/main_database_helper.dart';
import 'package:avaremp/destination/destination.dart';
import 'package:avaremp/instruments/pfd_runway.dart';
import 'package:avaremp/instruments/precision_approach.dart';
import 'package:avaremp/instruments/runway_survey.dart';
import 'package:avaremp/io/gps_fix.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/geo_calculations.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:universal_io/io.dart';

/// ILS-style precision approach guidance driven by raw GPS fixes (RTK when
/// available) against a surveyed or database runway. Port of the PPA app's
/// main display into AvareX, on top of the PFD runway selector.
class PrecisionApproachScreen extends StatefulWidget {
  const PrecisionApproachScreen({super.key});

  @override
  State<PrecisionApproachScreen> createState() => _PrecisionApproachScreenState();
}

class _PrecisionApproachScreenState extends State<PrecisionApproachScreen> {
  /// Fixes older than this are shown as stale.
  static const Duration _stale = Duration(seconds: 2);

  late ApproachSettings _settings;
  late bool _auto;
  PfdRunwayEnd? _manual;
  GpsFix? _fix;
  final List<int> _fixTimesMs = []; // for the rate readout
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    final s = Storage().settings;
    _settings = ApproachSettings(
      glideslopeDeg: s.getApproachGlideslope(),
      tchFt: s.getApproachTch(),
      chevronStepM: s.getApproachChevronStep(),
      centerlineToleranceM: s.getApproachTolerance(),
    );
    _auto = s.getApproachAuto();
    _fix = Storage().rawFixChange.value;
    Storage().rawFixChange.addListener(_onFix);
    // repaint once a second even without fixes so staleness shows
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    Storage().rawFixChange.removeListener(_onFix);
    _tick?.cancel();
    super.dispose();
  }

  void _onFix() {
    final GpsFix? f = Storage().rawFixChange.value;
    if (f == null) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    _fixTimesMs.add(now);
    _fixTimesMs.removeWhere((t) => now - t > 2000);
    if (mounted) {
      setState(() {
        _fix = f;
      });
    }
  }

  PfdRunwayEnd? get _runway => _auto ? Storage().pfdData.runway : _manual;

  double get _rateHz => _fixTimesMs.length / 2.0;

  bool get _fixStale => _fix == null || DateTime.now().difference(_fix!.time) > _stale;

  @override
  Widget build(BuildContext context) {
    final PfdRunwayEnd? rw = _runway;
    final GpsFix? fix = _fix;
    final ApproachGuidance? g = (rw != null && fix != null) ? ApproachGuidance.compute(rw, fix, _settings) : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Precision Approach"),
        actions: [
          IconButton(
            tooltip: _auto ? "Runway: automatic (tap to choose)" : "Runway: manual (tap to change)",
            onPressed: _pickRunway,
            icon: Icon(_auto ? Icons.auto_mode : Icons.flight_land),
          ),
          IconButton(
            tooltip: "Surveyed runways",
            onPressed: _showSurveys,
            icon: const Icon(Icons.straighten),
          ),
          IconButton(
            tooltip: "Settings",
            onPressed: _showSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _statusBar(context, rw, fix, g),
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                return CustomPaint(
                  size: Size(c.maxWidth, c.maxHeight),
                  painter: _IlsPainter(g, stale: _fixStale),
                );
              }),
            ),
            _dataStrip(context, g),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- status

  Widget _statusBar(BuildContext context, PfdRunwayEnd? rw, GpsFix? fix, ApproachGuidance? g) {
    final bool stale = _fixStale;
    Color qColor;
    String qText;
    if (fix == null) {
      qColor = Colors.grey;
      qText = "NO GPS";
    } else {
      qText = fix.qualityLabel;
      qColor = fix.isRtkFixed
          ? Colors.greenAccent
          : (fix.isRtkFloat ? Colors.yellowAccent : (fix.fixQuality == GpsFix.qualityDgps ? Colors.lightBlueAccent : Colors.orangeAccent));
      if (stale) {
        qColor = Colors.redAccent;
        qText = "$qText STALE";
      }
    }
    final String rwText = rw == null
        ? (_auto ? "AUTO: no runway lined up" : "no runway selected")
        : "${rw.airportId} RWY ${rw.ident}${_auto ? ' (auto)' : ''}";
    final String detail = fix == null
        ? ""
        : [
            if (fix.satellites > 0) "${fix.satellites} sat",
            if (fix.hdop < 50) "HDOP ${fix.hdop.toStringAsFixed(1)}",
            if (fix.diffAgeS != null) "corr ${fix.diffAgeS!.toStringAsFixed(0)} s",
            "${_rateHz.toStringAsFixed(_rateHz >= 10 ? 0 : 1)} Hz",
          ].join("  ");
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: qColor.withValues(alpha: 0.2),
              border: Border.all(color: qColor),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(qText, style: TextStyle(color: qColor, fontWeight: FontWeight.bold, fontFamily: "monospace")),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(rwText, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                if (detail.isNotEmpty) Text(detail, style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
              ],
            ),
          ),
          if (g != null) _phaseChip(g),
        ],
      ),
    );
  }

  Widget _phaseChip(ApproachGuidance g) {
    String text;
    Color color;
    switch (g.phase) {
      case ApproachPhase.approach:
        text = g.precision ? "PRECISION" : "ANGULAR";
        color = g.precision ? Colors.greenAccent : Colors.cyanAccent;
        break;
      case ApproachPhase.rollout:
        text = "ROLLOUT";
        color = Colors.amberAccent;
        break;
      case ApproachPhase.invalid:
        text = "NO GUIDANCE";
        color = Colors.redAccent;
        break;
    }
    return Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontFamily: "monospace"));
  }

  // ------------------------------------------------------------ data strip

  Widget _dataStrip(BuildContext context, ApproachGuidance? g) {
    String dist = "--", xtk = "--", vert = "--", hat = "--", gs = "--", gp = "--", trk = "--";
    if (g != null && g.phase != ApproachPhase.invalid) {
      dist = g.distanceNm >= 1 ? "${g.distanceNm.toStringAsFixed(2)} NM" : "${g.distanceM.toStringAsFixed(0)} m";
      final double x = g.crossTrackM;
      xtk = x.abs() < 0.05 ? "0.0 m" : "${x < 0 ? 'L' : 'R'} ${x.abs().toStringAsFixed(x.abs() < 10 ? 1 : 0)} m";
      if (g.verticalValid) {
        final double v = g.verticalErrorFt;
        vert = v.abs() < 0.5 ? "0 ft" : "${v > 0 ? 'HI' : 'LO'} ${v.abs().toStringAsFixed(0)} ft";
        gp = "${g.glidepathDeg.toStringAsFixed(2)}°";
      }
      hat = "${g.heightAboveThresholdFt.toStringAsFixed(0)} ft";
      gs = "${g.groundSpeedKt.toStringAsFixed(0)} kt";
      final double mag = GeoCalculations.getMagneticHeading(g.fix.trackDeg, Storage().area.variation);
      final double rwMag = GeoCalculations.getMagneticHeading(g.runway.headingTrue, Storage().area.variation);
      trk = "${mag.round().toString().padLeft(3, '0')}° / ${rwMag.round().toString().padLeft(3, '0')}°";
    }
    Widget cell(String label, String value) => Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
              FittedBox(
                child: Text(value,
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, fontFamily: "monospace")),
              ),
            ],
          ),
        );
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          cell("DIST", dist),
          cell("X-TRK", xtk),
          cell("G/S", vert),
          cell("HAT", hat),
          cell("GND SPD", gs),
          cell("GP", gp),
          cell("TRK / RWY", trk),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- sheets

  Future<void> _pickRunway() async {
    final List<PfdRunwayEnd> candidates = [...Storage().area.pfdRunwaySelector.candidates];
    final Set<String> seen = candidates.map((e) => e.key).toSet();
    for (final sr in RunwaySurveyStore().all) {
      for (final e in sr.toRunwayEnds()) {
        if (seen.add(e.key)) candidates.add(e);
      }
    }
    final TextEditingController lookup = TextEditingController();
    final PfdRunwayEnd? choice = await showModalBottomSheet<PfdRunwayEnd?>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        List<PfdRunwayEnd> list = candidates;
        return StatefulBuilder(builder: (ctx, setSheet) {
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.auto_mode),
                    title: const Text("Automatic"),
                    subtitle: const Text("Runway you are lined up with, within 10 NM (same as the PFD)"),
                    selected: _auto,
                    onTap: () {
                      setState(() {
                        _auto = true;
                        Storage().settings.setApproachAuto(true);
                      });
                      Navigator.pop(ctx);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: lookup,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: "Airport ID", hintText: "e.g. CDS2", isDense: true),
                      onSubmitted: (v) async {
                        final String id = v.trim().toUpperCase();
                        if (id.isEmpty) return;
                        List<PfdRunwayEnd> ends = [];
                        try {
                          final AirportDestination? ap = await MainDatabaseHelper.db.findAirport(id);
                          if (ap != null) ends = PfdRunwayParser.parse(ap);
                        } catch (_) {}
                        ends = PfdRunwaySelector.withSurveys(ends, RunwaySurveyStore().forAirport(id));
                        setSheet(() {
                          list = ends;
                        });
                      },
                    ),
                  ),
                  const Divider(),
                  Flexible(
                    child: list.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text("No runways. Fly nearer an airport, type an ID above, or import a survey."),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: list.length,
                            itemBuilder: (ctx, i) {
                              final PfdRunwayEnd e = list[i];
                              final bool surveyed = RunwaySurveyStore()
                                  .forAirport(e.airportId)
                                  .any((sr) => sr.matchesIdents(e.ident, e.farIdent));
                              final double mag = GeoCalculations.getMagneticHeading(e.headingTrue, Storage().area.variation);
                              return ListTile(
                                leading: Icon(surveyed ? Icons.verified : Icons.flight_land,
                                    color: surveyed ? Colors.greenAccent : null),
                                title: Text("${e.airportId} RWY ${e.ident}"),
                                subtitle: Text(
                                    "${mag.round().toString().padLeft(3, '0')}°M  ${e.lengthFt.round()} x ${e.widthFt.round()} ft  elev ${e.endElevFt.round()} ft${surveyed ? '  RTK surveyed' : ''}"),
                                selected: !_auto && _manual?.key == e.key,
                                onTap: () => Navigator.pop(ctx, e),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
    if (choice != null) {
      setState(() {
        _manual = choice;
        _auto = false;
        Storage().settings.setApproachAuto(false);
      });
    }
  }

  Future<void> _showSettings() async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          void save(ApproachSettings s) {
            setSheet(() {});
            setState(() {
              _settings = s;
            });
            final st = Storage().settings;
            st.setApproachGlideslope(s.glideslopeDeg);
            st.setApproachTch(s.tchFt);
            st.setApproachChevronStep(s.chevronStepM);
            st.setApproachTolerance(s.centerlineToleranceM);
          }

          Widget slider(String label, double value, double min, double max, int divisions, String unit,
              ApproachSettings Function(double) apply) {
            return ListTile(
              title: Text("$label: ${value.toStringAsFixed(unit == '°' ? 1 : (unit == 'm' ? 1 : 0))} $unit"),
              subtitle: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: (v) => save(apply(v)),
              ),
            );
          }

          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                slider("Glideslope", _settings.glideslopeDeg, 2.0, 5.0, 30, "°",
                    (v) => _settings.copyWith(glideslopeDeg: v)),
                slider("Threshold crossing height", _settings.tchFt, 0, 60, 12, "ft",
                    (v) => _settings.copyWith(tchFt: v)),
                slider("Chevron step", _settings.chevronStepM, 0.5, 5.0, 9, "m",
                    (v) => _settings.copyWith(chevronStepM: v)),
                slider("On-centerline tolerance", _settings.centerlineToleranceM, 0.5, 5.0, 9, "m",
                    (v) => _settings.copyWith(centerlineToleranceM: v)),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    "Experimental supplemental guidance only. Geometry comes from GPS and the runway "
                    "survey; verify visually. Not a substitute for an approved approach.",
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  Future<void> _showSurveys() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          final List<SurveyedRunway> rows = RunwaySurveyStore().all;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: _syncing ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_download),
                  title: const Text("Sync community database"),
                  subtitle: Text(_syncing
                      ? "Fetching $_syncProgress"
                      : (Storage().settings.getSurveySyncMs() == 0
                          ? "github.com/${RunwaySurveySync.repo}, never synced"
                          : "github.com/${RunwaySurveySync.repo}, last ${DateTime.fromMillisecondsSinceEpoch(Storage().settings.getSurveySyncMs()).toLocal().toString().substring(0, 16)}")),
                  enabled: !_syncing,
                  onTap: () async {
                    final String msg = await _syncSurveys(() => setSheet(() {}));
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));
                      setSheet(() {});
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.file_open),
                  title: const Text("Import survey file"),
                  subtitle: const Text("PPA airport .json or survey .geojson"),
                  onTap: () async {
                    final String msg = await _importSurvey();
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));
                      setSheet(() {});
                    }
                  },
                ),
                const Divider(),
                Flexible(
                  child: rows.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text("No surveyed runways yet. Survey with the PPA app and import the file here."),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: rows.length,
                          itemBuilder: (ctx, i) {
                            final SurveyedRunway r = rows[i];
                            final String acc = r.accuracyM == null ? "" : "  ±${r.accuracyM!.toStringAsFixed(2)} m";
                            final String date = r.surveyDateMs == null
                                ? ""
                                : "  ${DateTime.fromMillisecondsSinceEpoch(r.surveyDateMs!).toIso8601String().substring(0, 10)}";
                            return ListTile(
                              leading: const Icon(Icons.verified, color: Colors.greenAccent),
                              title: Text("${r.airport} ${r.designator}"),
                              subtitle: Text("${r.lengthFt.round()} x ${r.widthFt.round()} ft$acc$date"),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  await RunwaySurveyStore().remove(r);
                                  setSheet(() {});
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  bool _syncing = false;
  String _syncProgress = "";

  Future<String> _syncSurveys(void Function() refresh) async {
    if (_syncing) return "Sync already running";
    _syncing = true;
    _syncProgress = "airport list";
    refresh();
    try {
      final (int airports, int runways) = await RunwaySurveySync.fetchAll(onProgress: (name) {
        _syncProgress = name;
        refresh();
      });
      Storage().settings.setSurveySyncMs(DateTime.now().millisecondsSinceEpoch);
      Storage().area.update(Storage().position);
      return "Synced $airports airport${airports == 1 ? '' : 's'}, $runways runway${runways == 1 ? '' : 's'}";
    } catch (e) {
      return "Sync failed: ${e.toString().replaceFirst('Exception: ', '')}";
    } finally {
      _syncing = false;
      refresh();
    }
  }

  Future<String> _importSurvey() async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
          type: FileType.custom, allowedExtensions: ["json", "geojson"], allowMultiple: true);
      if (result == null) return "Import cancelled";
      int count = 0;
      for (final f in result.files) {
        final String? path = f.path;
        if (path == null) continue;
        final String content = await File(path).readAsString();
        final List<SurveyedRunway> rows = RunwaySurveyImporter.parse(content, source: f.name);
        for (final r in rows) {
          await RunwaySurveyStore().put(r);
          count++;
        }
      }
      // let the PFD selector pick the new geometry up right away
      Storage().area.update(Storage().position);
      return "Imported $count runway${count == 1 ? '' : 's'}";
    } catch (e) {
      return "Import failed: $e";
    }
  }
}

/// The ILS head: localizer and glideslope needles on a dot scale, chevrons,
/// and the two headline numbers.
class _IlsPainter extends CustomPainter {
  final ApproachGuidance? g;
  final bool stale;

  _IlsPainter(this.g, {required this.stale});

  static const Color _needle = Color(0xFFFF00FF);

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    final Offset c = Offset(w / 2, h / 2);
    final double r = min(w, h) * 0.42;
    final Paint ring = Paint()
      ..color = Colors.grey.shade700
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final Paint dot = Paint()..color = Colors.grey.shade500;
    final Paint cross = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;

    canvas.drawCircle(c, r, ring);
    // dots at 1/2 and full scale, both axes (ILS style)
    for (final double f in [0.5, 1.0]) {
      final double d = r * 0.82 * f;
      canvas.drawCircle(Offset(c.dx - d, c.dy), 4, dot);
      canvas.drawCircle(Offset(c.dx + d, c.dy), 4, dot);
      canvas.drawCircle(Offset(c.dx, c.dy - d), 4, dot);
      canvas.drawCircle(Offset(c.dx, c.dy + d), 4, dot);
    }
    // aircraft reference cross
    canvas.drawLine(Offset(c.dx - 16, c.dy), Offset(c.dx + 16, c.dy), cross);
    canvas.drawLine(Offset(c.dx, c.dy - 16), Offset(c.dx, c.dy + 16), cross);

    final ApproachGuidance? g = this.g;
    if (g == null || g.phase == ApproachPhase.invalid) {
      _text(canvas, g == null ? "NO RUNWAY" : "BEHIND RUNWAY", c.translate(0, -r - 28), 22, Colors.grey.shade500);
      return;
    }

    final Color needleColor = stale ? Colors.grey.shade600 : _needle;
    final Paint needle = Paint()
      ..color = needleColor
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    final double scale = r * 0.82;

    // localizer: vertical bar, displaced horizontally (fly-to)
    final double lx = c.dx + g.lateralNeedle * scale;
    canvas.drawLine(Offset(lx, c.dy - r * 0.9), Offset(lx, c.dy + r * 0.9), needle);
    // glideslope: horizontal bar, displaced vertically (fly-to)
    if (g.verticalValid) {
      final double gy = c.dy + g.verticalNeedle * scale;
      canvas.drawLine(Offset(c.dx - r * 0.9, gy), Offset(c.dx + r * 0.9, gy), needle);
    }

    // scale labels
    _text(canvas, g.lateralScaleLabel, Offset(c.dx, c.dy + r + 14), 12, Colors.grey.shade500);
    if (g.verticalValid) {
      _text(canvas, g.verticalScaleLabel, Offset(c.dx + r + 34, c.dy), 12, Colors.grey.shade500);
    }

    // chevrons: fly-to arrows under the display, count per PPA
    final int chev = g.lateralChevrons;
    String lat;
    if (chev == 0) {
      lat = g.lateralValid ? "○" : "";
    } else {
      // aircraft left (chev < 0) -> fly right -> '>'
      lat = (chev < 0 ? ">" : "<") * chev.abs();
    }
    final double x = g.crossTrackM;
    final String xtk = x.abs() < 0.05 ? "" : "  ${x.abs().toStringAsFixed(x.abs() < 10 ? 1 : 0)} m ${x < 0 ? 'L' : 'R'}";
    _text(canvas, "$lat$xtk", Offset(c.dx, h - 22), 24, stale ? Colors.grey.shade600 : (chev == 0 ? Colors.greenAccent : Colors.white));

    // vertical arrows on the right
    final int arrows = g.verticalArrows;
    if (g.verticalValid) {
      final String v = arrows == 0 ? "○" : ((arrows > 0 ? "↓" : "↑") * arrows.abs());
      _text(canvas, v, Offset(w - 34, c.dy), 26, stale ? Colors.grey.shade600 : (arrows == 0 ? Colors.greenAccent : Colors.white));
    }

    // headline numbers: distance top-left, height above threshold top-right
    final String dist = g.distanceNm >= 1 ? "${g.distanceNm.toStringAsFixed(2)} NM" : "${g.distanceM.toStringAsFixed(0)} m";
    _text(canvas, dist, Offset(w * 0.18, 26), 20, Colors.white, align: TextAlign.center);
    _text(canvas, "${g.heightAboveThresholdFt.toStringAsFixed(0)} ft", Offset(w * 0.82, 26), 20, Colors.white);
    final double? eta = g.secondsToThreshold;
    if (eta != null && eta < 600) {
      _text(canvas, "${eta.toStringAsFixed(0)} s", Offset(w * 0.18, 50), 14, Colors.grey.shade400);
    }
    if (stale) {
      _text(canvas, "GPS STALE", c.translate(0, -r - 28), 22, Colors.redAccent);
    } else if (!g.fix.isRtk && g.precision) {
      _text(canvas, "NOT RTK  ±${g.fix.estimatedErrorM.toStringAsFixed(g.fix.estimatedErrorM < 1 ? 1 : 0)} m",
          c.translate(0, -r - 28), 16, Colors.orangeAccent);
    }
  }

  void _text(Canvas canvas, String s, Offset center, double size, Color color, {TextAlign align = TextAlign.center}) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size, fontFamily: "monospace", fontWeight: FontWeight.bold)),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _IlsPainter old) => true;
}
