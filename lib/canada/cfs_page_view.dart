// Shows an aerodrome's own page out of the Canada Flight Supplement the user
// imported. Everything the parser could not turn into a database row - the
// procedures, the cautions, the operator's hours - is on that page, so being
// able to read it is most of the point of importing the supplement.

import 'package:avaremp/canada/cfs_import.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdfrx/pdfrx.dart';

class CfsPageView extends StatefulWidget {
  final String ident;

  const CfsPageView({super.key, required this.ident});

  @override
  State<CfsPageView> createState() => CfsPageViewState();
}

class CfsPageViewState extends State<CfsPageView> {

  late Future<(CfsPageRef?, CfsVolumeInfo?)> _lookup;
  final PdfViewerController _controller = PdfViewerController();

  static final DateFormat _date = DateFormat("d MMM yyyy");

  @override
  void initState() {
    super.initState();
    _lookup = _find();
  }

  Future<(CfsPageRef?, CfsVolumeInfo?)> _find() async {
    final CfsPageRef? ref = await CfsImport.pageFor(widget.ident);
    return (ref, ref == null ? null : await CfsImport.volumeFor(widget.ident));
  }

  /// Out of cycle still works, so this is a strip across the top rather than
  /// anything that gets in the way.
  Widget _staleBanner(CfsVolumeInfo v) {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade800,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              "This supplement went out of cycle on "
              "${_date.format(v.effectiveTo!.toLocal())}. Check NOTAMs.",
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(CfsPageRef?, CfsVolumeInfo?)>(
      future: _lookup,
      builder: (BuildContext context,
          AsyncSnapshot<(CfsPageRef?, CfsVolumeInfo?)> snapshot) {
        if(!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (CfsPageRef? ref, CfsVolumeInfo? volume) = snapshot.data!;
        if(ref == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("${widget.ident} is not in any supplement you have.",
                      textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                      "Add the volume that covers it from the menu, under "
                      "Flight Supplement.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.outline)),
                ],
              ),
            ),
          );
        }
        return Column(
          children: [
            if(volume != null && volume.isExpired && volume.effectiveTo != null)
              _staleBanner(volume),
            Expanded(
              child: PdfViewer.file(
                ref.fullPath,
                controller: _controller,
                initialPageNumber: ref.firstPage,
                params: PdfViewerParams(
                  margin: 0,
                  backgroundColor: Theme.of(context).colorScheme.surface,
                ),
              ),
            ),
            if(ref.pageCount > 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for(int p = ref.firstPage; p <= ref.lastPage; p++)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: OutlinedButton(
                          onPressed: () => _controller.goToPage(pageNumber: p),
                          child: Text("${p - ref.firstPage + 1}"),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
