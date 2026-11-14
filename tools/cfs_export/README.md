# cfs_export

Builds `canada.efb`, the aerodrome file for the
[efb-p4](../../../efb-p4) cockpit display (Waveshare ESP32-P4). The source is your
own Canada Flight Supplement volumes, read with the same parser the app's CFS
import uses (`lib/canada/cfs_parse.dart`). As with the app, nothing from the
supplement is redistributed: you build the file from your own copy and put it
on the display's SD card.

```bash
cd tools/cfs_export
~/fvm/versions/3.44.1/bin/dart pub get
~/fvm/versions/3.44.1/bin/dart run bin/cfs_export.dart --pdf ~/Downloads/eCFS3.pdf -o canada.efb
```

You can pass several volumes. When an aerodrome appears in more than one, the
newest edition wins. If the app has already imported a volume, `--json` takes
the parse cache it keeps (`<dataDir>/canada/cfs/<file>.pdf.json`), so the PDF
isn't read again.

`lib/efb_writer.dart` documents the binary layout. Its C++ reader in efb-p4
must change with it.
