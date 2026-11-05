import 'dart:async';

import 'package:avaremp/instruments/pfd_runway.dart';
import 'package:avaremp/instruments/precision_approach.dart';
import 'package:avaremp/io/gm_protocol.dart';
import 'package:avaremp/io/gps_fix.dart';
import 'package:avaremp/io/ppa_hud_message.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:universal_io/io.dart';

// Drives the Precision Approach HUD on a pair of MemoMind glasses.
//
// The glasses are a GATT server toward the phone: one characteristic takes
// written command frames, another notifies replies and events. The approach
// is computed here, exactly as the on-screen display computes it, and sent
// as one small message per update to the glasses plugin, which draws it. See
// the ppa-hud-glasses repository for the plugin and the message layout.
//
// Two things about this link are worth knowing before trusting it. The
// plugin has to be installed and running on the glasses first - the MemoMind
// app does that, and the GMP install protocol is deliberately unpublished.
// And the SDK's own notes say the legacy GM GATT service is registered
// conditionally in some firmware builds, so a pair of glasses may simply not
// expose it; discovery here reports that rather than guessing.
class GlassesHud {

  // The characteristics the glasses expose for GM command traffic. The
  // enclosing service has had more than one UUID representation, so they are
  // found by characteristic rather than by service, which is what the SDK's
  // integration guide asks clients to do.
  static final Guid commandWrite =
      Guid("00002021-0000-1000-8000-00805F9B34FB");
  static final Guid commandNotify =
      Guid("00002022-0000-1000-8000-00805F9B34FB");

  /// Updates per second. The panel refreshes at 30 Hz, but a needle that
  /// moves ten times a second is already smoother than the aircraft, and
  /// every update is a round trip over BLE.
  static const Duration updateInterval = Duration(milliseconds: 100);

  /// How long to wait for the firmware's reply before sending the next
  /// frame. A missed acknowledgement costs one update, not the display.
  static const Duration ackTimeout = Duration(milliseconds: 250);

  /// Fixes older than this are not guidance.
  static const Duration fixStale = Duration(seconds: 2);

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  final ValueNotifier<int> change = ValueNotifier(0);
  final ValueNotifier<String> status = ValueNotifier("Not connected");
  final ValueNotifier<bool> scanning = ValueNotifier(false);

  BluetoothDevice? _device;
  BluetoothCharacteristic? _write;
  BluetoothCharacteristic? _notify;
  StreamSubscription<List<int>>? _notifications;
  StreamSubscription<BluetoothConnectionState>? _connection;
  Timer? _feed;

  final GmReassembler _uplink = GmReassembler(
      onError: (String why) => AppLog.logMessage("glasses: bad frame, $why"));

  int _event = 0;
  int _writeLimit = GmCodec.maxFrameBytes;
  bool _busy = false;
  Completer<void>? _ack;

  /// Runway chosen by hand on the approach screen; null follows the PFD's
  /// own choice, so closing the screen does not blank the glasses.
  PfdRunwayEnd? manualRunway;

  int _sent = 0;
  int _failed = 0;

  /// The last banner and when it went out. A banner is a fixed string, and
  /// resending "NO GPS" ten times a second spends the link on nothing.
  String _banner = "";
  DateTime _bannerSent = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration bannerRepeat = Duration(seconds: 1);

  bool get isConnected => _write != null;
  String get deviceName =>
      _device?.platformName.isNotEmpty == true
          ? _device!.platformName
          : (_device?.remoteId.str ?? "");
  int get sent => _sent;
  int get failed => _failed;

  /// A scan result that could be a pair of glasses. The GM service is not
  /// reliably advertised, so a name match is the practical filter and the UI
  /// offers an unfiltered list as well.
  static bool looksLikeGlasses(ScanResult r) {
    final String name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName;
    return RegExp(r'memomind|memo-mind|glass', caseSensitive: false)
        .hasMatch(name);
  }

  Future<void> scan() async {
    if(!supported || scanning.value) {
      return;
    }
    try {
      scanning.value = true;
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      await FlutterBluePlus.isScanning.where((bool s) => s == false).first;
    }
    catch(e) {
      AppLog.logMessage("glasses scan failed: $e");
      status.value = "Scan failed: $e";
    }
    finally {
      scanning.value = false;
    }
  }

  Future<void> connect(BluetoothDevice device) async {
    await disconnect();
    _device = device;
    status.value = "Connecting";
    change.value++;
    try {
      await device.connect(timeout: const Duration(seconds: 15));

      // A bigger MTU is the difference between one write per update and four.
      if(Platform.isAndroid) {
        try {
          await device.requestMtu(247);
        }
        catch(e) {
          AppLog.logMessage("glasses: MTU request refused, $e");
        }
      }
      // An ATT write value is the MTU less three bytes of header, and the
      // firmware will not accept a frame split across two writes.
      final int mtu = device.mtuNow;
      _writeLimit = (mtu - 3).clamp(20, GmCodec.maxFrameBytes);

      _connection = device.connectionState.listen((BluetoothConnectionState s) {
        if(s == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

      if(!await _discover(device)) {
        status.value = "No GM command service on this device";
        await disconnect();
        return;
      }

      // Notifications first: the firmware records the subscriber's address
      // when they are enabled and ignores writes from anyone else.
      await _notify!.setNotifyValue(true);
      _notifications = _notify!.lastValueStream.listen(_onNotification);

      // The heartbeat proves the framing before anything depends on it.
      if(!await _sendMessage(GmCodec.heartbeatFrames(_nextEvent()))) {
        status.value = "No reply to the heartbeat";
        await disconnect();
        return;
      }

      status.value = "Connected";
      await _sendBanner("AVAREX");
      _feed = Timer.periodic(updateInterval, (_) => _tick());
      change.value++;
    }
    catch(e) {
      AppLog.logMessage("glasses connect failed: $e");
      status.value = "Connect failed: $e";
      await disconnect();
    }
  }

  /// Find the command characteristics wherever they live. The SDK warns that
  /// the enclosing service UUID differs between builds, and that a build
  /// with MFi enabled may not register this service at all.
  Future<bool> _discover(BluetoothDevice device) async {
    final List<BluetoothService> services = await device.discoverServices();
    for(final BluetoothService service in services) {
      for(final BluetoothCharacteristic c in service.characteristics) {
        if(c.characteristicUuid == commandWrite) {
          _write = c;
        }
        else if(c.characteristicUuid == commandNotify) {
          _notify = c;
        }
      }
      if(_write != null && _notify != null) {
        AppLog.logMessage("glasses: GM service ${service.serviceUuid}, "
            "write limit $_writeLimit");
        return true;
      }
      _write = null;
      _notify = null;
    }
    return false;
  }

  Future<void> disconnect() async {
    _feed?.cancel();
    _feed = null;
    await _notifications?.cancel();
    _notifications = null;
    await _connection?.cancel();
    _connection = null;
    final BluetoothDevice? device = _device;
    _write = null;
    _notify = null;
    _device = null;
    _uplink.reset();
    _ack?.complete();
    _ack = null;
    _busy = false;
    if(device != null) {
      try {
        await device.disconnect();
      }
      catch(e) {
        AppLog.logMessage("glasses disconnect: $e");
      }
    }
    status.value = "Not connected";
    change.value++;
  }

  void _onDisconnected() {
    _feed?.cancel();
    _feed = null;
    _write = null;
    _notify = null;
    _uplink.reset();
    status.value = "Disconnected";
    change.value++;
  }

  void _onNotification(List<int> value) {
    if(value.isEmpty) {
      return;
    }
    final GmMessage? message = _uplink.feed(value);
    if(message == null) {
      return;
    }
    // An empty reply is the firmware asking for the next fragment; a
    // non-empty one ends the exchange. Either way this write is done.
    _ack?.complete();
    _ack = null;
    if(message.service == GmCodec.serviceApplication &&
        message.command == GmCodec.commandPluginReply) {
      AppLog.logMessage("glasses: plugin replied on channel ${message.channel}");
    }
  }

  int _nextEvent() {
    _event = (_event + 1) & 0xFF;
    // Zero reads as "no event" in some of the SDK's examples; skip it.
    if(_event == 0) {
      _event = 1;
    }
    return _event;
  }

  /// Send one logical message, one complete frame per write, waiting for the
  /// firmware between frames as the integration guide requires.
  Future<bool> _sendMessage(List<Uint8List> frames) async {
    final BluetoothCharacteristic? write = _write;
    if(write == null) {
      return false;
    }
    for(final Uint8List frame in frames) {
      final Completer<void> ack = Completer<void>();
      _ack = ack;
      try {
        await write.write(frame, withoutResponse: false);
      }
      catch(e) {
        AppLog.logMessage("glasses write failed: $e");
        _ack = null;
        _failed++;
        return false;
      }
      try {
        await ack.future.timeout(ackTimeout);
      }
      on TimeoutException {
        // The write reached the OS; the firmware did not answer in time.
        // Dropping this update beats queueing behind it.
        _ack = null;
        _failed++;
        return false;
      }
    }
    _sent++;
    return true;
  }

  Future<void> _sendState(Uint8List payload) async {
    if(_busy) {
      return;         // an update is still in flight; the next tick is soon
    }
    _busy = true;
    try {
      await _sendMessage(GmCodec.applicationFrames(
        event: _nextEvent(),
        channel: PpaHudMessage.channel,
        payload: payload,
        frameBytes: _writeLimit,
      ));
    }
    finally {
      _busy = false;
    }
  }

  /// The plugin holds the banner until a state message replaces it, so this
  /// repeats only slowly - often enough that a reconnected pair of glasses
  /// picks the text up, rarely enough to leave the link idle.
  Future<void> _sendBanner(String text) async {
    final DateTime now = DateTime.now();
    if(text == _banner && now.difference(_bannerSent) < bannerRepeat) {
      return;
    }
    _banner = text;
    _bannerSent = now;
    await _sendState(PpaHudMessage.banner(text));
  }

  /// The runway being flown: the approach screen's choice if it made one,
  /// otherwise whatever the PFD has selected.
  PfdRunwayEnd? get _runway => manualRunway ?? Storage().pfdData.runway;

  ApproachSettings get _settings {
    final s = Storage().settings;
    return ApproachSettings(
      glideslopeDeg: s.getApproachGlideslope(),
      tchFt: s.getApproachTch(),
      chevronStepM: s.getApproachChevronStep(),
      centerlineToleranceM: s.getApproachTolerance(),
    );
  }

  void _tick() {
    if(!isConnected) {
      return;
    }
    final GpsFix? fix = Storage().rawFixChange.value;
    final PfdRunwayEnd? runway = _runway;

    if(fix == null || DateTime.now().difference(fix.time) > fixStale) {
      // Say why there is no guidance. The plugin flags a stale needle on its
      // own after two seconds, so silence would also be safe - but not
      // informative.
      _sendBanner("NO GPS");
      return;
    }
    if(runway == null) {
      _sendBanner("NO RUNWAY");
      return;
    }
    _banner = "";
    _sendState(PpaHudMessage.fromGuidance(
        ApproachGuidance.compute(runway, fix, _settings)));
  }
}
