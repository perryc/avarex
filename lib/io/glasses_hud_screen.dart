import 'package:avaremp/io/glasses_hud.dart';
import 'package:avaremp/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// Connecting a pair of MemoMind glasses to the Precision Approach HUD.
//
// Deliberately a sheet rather than a screen: this is a one-off pairing step,
// and after it the glasses are driven from wherever the aircraft is, with the
// phone in a pocket.
class GlassesHudSheet extends StatefulWidget {
  const GlassesHudSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (BuildContext c) => const GlassesHudSheet(),
      );

  @override
  State<GlassesHudSheet> createState() => GlassesHudSheetState();
}

class GlassesHudSheetState extends State<GlassesHudSheet> {

  GlassesHud get _hud => Storage().glassesHud;

  /// The GM command service is not reliably advertised, so the filtered list
  /// can come up empty on perfectly good glasses.
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    if(GlassesHud.supported) {
      _hud.scan();
    }
  }

  Widget _status(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _hud.change,
      builder: (BuildContext c, int _, Widget? __) {
        return ValueListenableBuilder<String>(
          valueListenable: _hud.status,
          builder: (BuildContext c, String status, Widget? ___) {
            final bool connected = _hud.isConnected;
            return ListTile(
              leading: Icon(connected ? Icons.visibility : Icons.visibility_off,
                  color: connected ? Colors.greenAccent : null),
              title: Text(connected
                  ? "HUD on ${_hud.deviceName}"
                  : "Precision Approach HUD"),
              subtitle: Text(connected
                  ? "$status · ${_hud.sent} updates, ${_hud.failed} missed"
                  : status),
              trailing: connected
                  ? TextButton(
                      onPressed: () async {
                        await _hud.disconnect();
                        if(mounted) setState(() {});
                      },
                      child: const Text("Disconnect"))
                  : null,
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if(!GlassesHud.supported) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text("Bluetooth LE is not available on this platform."),
        ),
      );
    }
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _status(context),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
                "The glasses must already be running the Precision Approach "
                "HUD plugin, installed with the MemoMind app. Guidance is "
                "computed here and drawn there.",
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline)),
          ),
          Row(
            children: [
              const SizedBox(width: 8),
              ValueListenableBuilder<bool>(
                valueListenable: _hud.scanning,
                builder: (BuildContext c, bool scanning, Widget? _) =>
                    TextButton.icon(
                  onPressed: scanning ? null : () => _hud.scan(),
                  icon: scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: Text(scanning ? "Scanning" : "Scan"),
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  const Text("All devices", style: TextStyle(fontSize: 12)),
                  Switch(
                      value: _showAll,
                      onChanged: (bool v) => setState(() => _showAll = v)),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          Flexible(
            child: StreamBuilder<List<ScanResult>>(
              stream: FlutterBluePlus.scanResults,
              initialData: const [],
              builder: (BuildContext c,
                  AsyncSnapshot<List<ScanResult>> snapshot) {
                final List<ScanResult> results = (snapshot.data ?? [])
                    .where((ScanResult r) =>
                        _showAll || GlassesHud.looksLikeGlasses(r))
                    .toList();
                if(results.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                        _showAll
                            ? "Nothing found. Make sure the glasses are on "
                                "and not already connected to the phone."
                            : "No glasses found. Turn on All devices if yours "
                                "advertise under another name.",
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12)),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: results.length,
                  itemBuilder: (BuildContext c, int i) {
                    final ScanResult r = results[i];
                    final String name =
                        r.advertisementData.advName.isNotEmpty
                            ? r.advertisementData.advName
                            : (r.device.platformName.isNotEmpty
                                ? r.device.platformName
                                : "(unnamed)");
                    return ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(name),
                      subtitle: Text("${r.device.remoteId.str}  "
                          "${r.rssi} dBm"),
                      onTap: () async {
                        await _hud.connect(r.device);
                        if(mounted) setState(() {});
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
