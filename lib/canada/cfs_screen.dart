// Where the user hands over their Canada Flight Supplement volumes and sees
// what came out of them. Nothing is downloaded here: the supplements are the
// user's own copies, and everything happens on the device.

import 'package:avaremp/canada/cfs_import.dart';
import 'package:avaremp/storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class CfsScreen extends StatefulWidget {
  const CfsScreen({super.key});

  @override
  State<CfsScreen> createState() => CfsScreenState();
}

class CfsScreenState extends State<CfsScreen> {

  List<CfsVolumeInfo> _volumes = [];
  bool _busy = false;
  String _status = "";
  double _progress = 0;

  static final DateFormat _date = DateFormat("d MMM yyyy");

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final List<CfsVolumeInfo> v = await CfsImport.volumes();
    if(mounted) {
      setState(() => _volumes = v);
    }
  }

  Future<void> _import(List<String> paths) async {
    if(paths.isEmpty) {
      setState(() => _status = "No PDF files there");
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _status = "Starting";
    });
    try {
      await CfsImport.importFiles(paths, onProgress: (what, fraction) {
        if(mounted) {
          setState(() {
            _status = what;
            _progress = fraction;
          });
        }
      });
      // the map layer reads the imported rows
      await Storage().canadaAirspace.loadAirports();
      if(mounted) {
        setState(() => _status = "Imported");
      }
    }
    catch(e) {
      if(mounted) {
        setState(() => _status = "Could not read that: $e");
      }
    }
    finally {
      if(mounted) {
        setState(() => _busy = false);
      }
      await _reload();
    }
  }

  /// A folder of volumes. Android hands back a tree that cannot be listed as
  /// ordinary files, so the file picker is the way in there.
  Future<void> _pickFolder() async {
    final String? dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: "Folder holding your CFS volumes");
    if(dir == null) {
      return;
    }
    final List<String> pdfs = CfsImport.findPdfs(dir);
    if(pdfs.isEmpty) {
      setState(() => _status =
          "No PDFs in that folder. On Android, use Choose files instead.");
      return;
    }
    await _import(pdfs);
  }

  Future<void> _pickFiles() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ["pdf"],
        dialogTitle: "Your CFS volumes");
    if(result == null) {
      return;
    }
    await _import(result.files
        .map((f) => f.path)
        .whereType<String>()
        .toList());
  }

  Future<void> _delete(CfsVolumeInfo v) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text("Remove this supplement?"),
        content: Text("${v.file} and the ${v.aerodromes} aerodromes it put on "
            "the map will be removed."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text("Keep")),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text("Remove")),
        ],
      ),
    );
    if(yes != true) {
      return;
    }
    setState(() => _busy = true);
    await CfsImport.deleteVolume(v.file);
    await Storage().canadaAirspace.loadAirports();
    if(mounted) {
      setState(() => _busy = false);
    }
    await _reload();
  }

  /// Out of cycle is a warning, not a failure: the supplement still has every
  /// runway and frequency in it, and that is most of why it is here.
  Widget _cycle(BuildContext context, CfsVolumeInfo v) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if(v.effectiveTo == null) {
      return const Text("Cycle dates not found in this volume");
    }
    final bool expired = v.isExpired;
    final int? days = v.daysRemaining;
    final Color colour = expired ? Colors.amber.shade800 : scheme.primary;
    final String when = expired
        ? "Out of cycle since ${_date.format(v.effectiveTo!.toLocal())}"
        : "In cycle until ${_date.format(v.effectiveTo!.toLocal())}"
            "${days == null ? "" : ", $days days"}";
    return Row(
      children: [
        Icon(expired ? Icons.warning_amber_rounded : Icons.check_circle_outline,
            size: 16, color: colour),
        const SizedBox(width: 6),
        Expanded(child: Text(when, style: TextStyle(color: colour))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Canadian CFS Import")),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                "Canadian aerodromes come from your own copy of the CFS. "
                "Download the volumes you fly in from NAV CANADA, then point "
                "this at them: runways, surfaces, frequencies, fuel and the "
                "aerodrome's own CFS page all come from the supplement.",
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _pickFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text("Choose a folder"),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickFiles,
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text("Choose files"),
                ),
              ],
            ),
            if(_busy || _status.isNotEmpty) ...[
              const SizedBox(height: 12),
              if(_busy) LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 6),
              Text(_status, style: const TextStyle(fontSize: 12)),
            ],
            const SizedBox(height: 12),
            const Divider(),
            Expanded(
              child: _volumes.isEmpty
                  ? Center(
                      child: Text("No supplements yet.",
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.outline)))
                  : ListView.builder(
                      itemCount: _volumes.length,
                      itemBuilder: (BuildContext c, int i) {
                        final CfsVolumeInfo v = _volumes[i];
                        return Card(
                          child: ListTile(
                            title: Text(v.file),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text("${v.aerodromes} aerodromes"
                                    "${v.regions.isEmpty ? "" : " · ${v.regions}"}"
                                    "${v.pages == 0 ? "" : " · ${v.pages} pages"}"),
                                const SizedBox(height: 2),
                                _cycle(c, v),
                              ],
                            ),
                            isThreeLine: true,
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _busy ? null : () => _delete(v),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
