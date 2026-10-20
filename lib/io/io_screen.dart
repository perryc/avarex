import 'dart:async';
import 'dart:convert';
import 'package:avaremp/constants.dart';
import 'package:avaremp/io/ble_receiver.dart';
import 'package:avaremp/utils/toast.dart';
import 'package:avaremp/io/softrf_config.dart';
import 'package:avaremp/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_bluetooth_serial_ble/flutter_bluetooth_serial_ble.dart';


class IoScreen extends StatefulWidget {
  const IoScreen({super.key});
  final bool start = true;
  @override
  State<StatefulWidget> createState() => IoScreenState();
}

class IoScreenState extends State<IoScreen> {

  StreamSubscription<BluetoothDiscoveryResult>? _streamSubscription;
  List<BluetoothDiscoveryResult> results = List<BluetoothDiscoveryResult>.empty(growable: true);
  bool isDiscovering = false;
  static BluetoothConnection? connection;
  static BluetoothDevice? connectedDevice;// this should stay in memory, not putting in storage as this is platform specific
  static bool transferInProgress = false;

  // send data to remote
  static void sendData(String data) async {
    if(transferInProgress) {
      return;
    }
    // this sends autopilot data
    if(connection == null || (!connection!.isConnected)) {
      return;
    }
    try {
      connection!.output.add(utf8.encode(data));
      await connection!.output.allSent;
    }
    catch(e) {
      Storage().setException("Failed to drive the autopilot.");
      return;
    }
  }

  void _startDiscovery() {
    _streamSubscription?.cancel();
    _streamSubscription =
        FlutterBluetoothSerial.instance.startDiscovery().listen((r) {
          setState(() {
            final existingIndex = results.indexWhere(
                    (element) => element.device.address == r.device.address);
            if (existingIndex >= 0) {
              results[existingIndex] = r;
            }
            else {
              results.add(r);
            }
          });
        });

    _streamSubscription!.onDone(() {
      setState(() {
        isDiscovering = false;
      });
    });
  }

  void _restartDiscovery() {
    setState(() {
      results.clear();
      isDiscovering = true;
    });

    _startDiscovery();
  }


  @override
  void initState() {
    super.initState();
    isDiscovering = widget.start && Constants.shouldShowBluetoothSpp;
    if(isDiscovering) {
      _startDiscovery();
    }
  }

  // Push the AvareX traffic-link settings and the aircraft's own ICAO address
  // to a connected SoftRF unit (address needs the aircraft-address firmware).
  void _showSoftRfConfig(BuildContext context, BleLink link) {
    final TextEditingController reg =
        TextEditingController(text: Storage().myAircraftCallsign);
    int protocol = SoftRfConfig.protocolFanet;
    bool mux = false;
    showDialog(context: context, builder: (context) => StatefulBuilder(
        builder: (context, setState) {
      final int? icao = SoftRfConfig.icaoForRegistration(reg.text);
      final String resolved = icao == null
          ? (reg.text.trim().isEmpty ? "Enter the registration (set in Aircraft to prefill)"
                                     : "Not a Canadian registration the app can resolve")
          : "ICAO ${icao.toRadixString(16).toUpperCase()}"
            "${Storage().canadaRegistry.lookup(icao) == null ? "" : " \u00b7 ${Storage().canadaRegistry.lookup(icao)!.model}"}";
      return AlertDialog(
        title: Text("Configure ${link.name}"),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: reg,
            decoration: const InputDecoration(labelText: "Registration", hintText: "C-FMHP"),
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
          ),
          Padding(padding: const EdgeInsets.only(top: 6, bottom: 12), child: Text(resolved)),
          DropdownButton<int>(
            value: protocol,
            isExpanded: true,
            items: [for(final e in SoftRfConfig.protocolNames.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() {
              protocol = v ?? protocol;
              if(protocol != SoftRfConfig.protocolFanet) {
                mux = false; // mux needs FANET as the beacon protocol
              }
            }),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text("Also receive 1090 ADS-B (mux)"),
            subtitle: const Text("Alternates the radio between FANET and 1090; slower updates on both"),
            value: mux,
            onChanged: protocol == SoftRfConfig.protocolFanet
                ? (v) => setState(() => mux = v) : null,
          ),
          const Padding(padding: EdgeInsets.only(top: 12), child: Text(
            "Sets US/CA band, powered aircraft, vector alarms, full power, "
            "NMEA + GDL90 over Bluetooth. The unit restarts and reconnects.",
            style: TextStyle(fontSize: 12))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          TextButton(
            onPressed: icao == null ? null : () {
              link.configureSoftRf(icao: icao, protocol: protocol, mux: mux);
              Navigator.pop(context);
              Toast.showToast(context, "Sent to ${link.name}", null, 3);
            },
            child: const Text("Apply")),
        ],
      );
    }));
  }

  // BLE ADS-B receivers section (works on iOS too, unlike SPP). Multiple
  // receivers can be connected at once - e.g. ADSBee for 1090ES plus a
  // SoftRF unit for FANET - and are merged into one traffic picture.
  Widget _bleSection(BuildContext context) {
    return Expanded(flex: 5, child: Card(child: Column(children: [
      ListTile(
        leading: const Icon(Icons.bluetooth),
        title: const Text("BLE ADS-B Receivers"),
        subtitle: const Text("Tap a found device to connect; multiple allowed"),
        trailing: ValueListenableBuilder<bool>(
            valueListenable: Storage().bleReceiver.scanning,
            builder: (context, scanning, _) => scanning
                ? const Padding(padding: EdgeInsets.all(12),
                    child: SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(
                    icon: const Icon(Icons.bluetooth_searching),
                    tooltip: "Scan",
                    onPressed: () {
                      Storage().bleReceiver.scan();
                    })),
      ),
      ValueListenableBuilder<int>(
          valueListenable: Storage().bleReceiver.change,
          builder: (context, value, _) => Column(children: [
            for(BleLink link in Storage().bleReceiver.links)
              ListTile(
                dense: true,
                leading: Icon(Icons.router,
                    color: link.isConnected ? Colors.green : Colors.grey),
                title: Text(link.name),
                subtitle: ValueListenableBuilder<String>(
                    valueListenable: link.status,
                    builder: (context, s, _) => ValueListenableBuilder<String>(
                        valueListenable: link.softRfInfo,
                        builder: (context, info, _) =>
                            Text(info.isEmpty ? s : "$s \u00b7 $info"))),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if(link.isSoftRf)
                    IconButton(
                        icon: const Icon(Icons.tune),
                        tooltip: "Configure SoftRF for the AvareX traffic link",
                        onPressed: () => _showSoftRfConfig(context, link)),
                  IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: "Disconnect & forget",
                      onPressed: () {
                        Storage().bleReceiver.disconnect(link);
                      }),
                ]),
              ),
          ])),
      ValueListenableBuilder<bool>(
          valueListenable: Storage().receptionLogger.enabled,
          builder: (context, logging, _) => SwitchListTile(
            dense: true,
            title: const Text("Log reception (coverage flights)"),
            subtitle: const Text("1 Hz samples + per-target rows to reception_logs/"),
            value: logging,
            onChanged: (on) {
              on ? Storage().receptionLogger.start() : Storage().receptionLogger.stop();
            },
          )),
      ValueListenableBuilder<String>(
          valueListenable: Storage().bleReceiver.scanError,
          builder: (context, error, _) => error.isEmpty
              ? const SizedBox.shrink()
              : Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(error, style: const TextStyle(color: Colors.red)))),
      Expanded(child: StreamBuilder<List<fbp.ScanResult>>(
          stream: fbp.FlutterBluePlus.scanResults,
          initialData: const [],
          builder: (context, snapshot) {
            List<fbp.ScanResult> found = (snapshot.data ?? [])
                .where(BleReceiver.isReceiver)
                .toList();
            return ListView(children: [
              for(fbp.ScanResult r in found)
                if(!Storage().bleReceiver.links.any((l) => l.id == r.device.remoteId.str))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.settings_input_antenna),
                    title: Text(r.device.platformName.isEmpty
                        ? r.device.remoteId.str
                        : r.device.platformName),
                    subtitle: Text("${r.rssi} dBm"),
                    onTap: () {
                      Storage().bleReceiver.connect(r.device);
                      Toast.showToast(context,
                          "Connecting to ${r.device.platformName}", null, 3);
                    },
                  ),
            ]);
          })),
    ])));
  }

  @override
  void dispose() {
    // Avoid memory leak (`setState` after dispose) and cancel discovery
    _streamSubscription?.cancel();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('IO (Bluetooth)'),
        actions: <Widget>[
          isDiscovering
              ? FittedBox(
            child: Container(
              margin: const EdgeInsets.all(16.0),
              child: const CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          )
              : IconButton(
            icon: const Icon(Icons.replay),
            onPressed: _restartDiscovery,
          )
        ],
      ),
      body: Column(children: [
      if(Constants.shouldShowBle) _bleSection(context),
      if(Constants.shouldShowBluetoothSpp) Expanded(flex: 8, child:ListView.builder(
        itemCount: results.length,
        itemBuilder: (BuildContext context, index) {
          BluetoothDiscoveryResult result = results[index];
          return _BluetoothDeviceListEntry(
            device: result.device,
            rssi: result.rssi,
            onTap: () {
              showDialog(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: Text(result.device.name ?? result.device.address),
                    content: const Text('Choose an operation with this device.'),
                    actions: <Widget>[
                      if(!(result.device.isConnected) && result.device.isBonded) TextButton(
                        child: const Text("Connect\u2190"),
                        onPressed: () {
                          BluetoothConnection.toAddress(result.device.address).then((value) {
                            if(mounted) {
                              setState(() {
                                if(value.isConnected) {
                                  results[results.indexOf(result)] =
                                      makeResult(result, true,
                                          result.device.bondState);

                                  connection = value;
                                  connectedDevice = result.device;
                                  if(connection != null) {
                                    if (connection!.input != null) {
                                      connection!.input!.listen((data) {
                                        Storage().gdl90Buffer.put(data);
                                        Storage().nmeaBuffer.put(data);
                                      });
                                    }
                                  }
                                }
                                else {
                                  Toast.showToast(context, "Failed to connect to ${result.device.name ?? result.device.address}", const Icon(Icons.error, color: Colors.red), 3);
                                }
                              });
                            }
                          }).onError((error, stackTrace) {
                            if(mounted) {
                              setState(() {
                                Toast.showToast(context, "Failed to connect to ${result.device.name ?? result.device.address}", const Icon(Icons.error, color: Colors.red,), 3);
                              });
                            }
                          });
                          Toast.showToast(context, "Connecting to ${result.device.name ?? result.device.address}", const Icon(Icons.error, color: Colors.red,), 3);
                          Navigator.of(context).pop();
                        },
                      ),
                      if(result.device.isBonded) TextButton(
                        child: const Text("Unpair"),
                        onPressed: () {
                          FlutterBluetoothSerial.instance.removeDeviceBondWithAddress(result.device.address).then((value) {
                            if(mounted) {
                              setState(() {
                                results[results.indexOf(result)] =
                                  makeResult(result, result.device.isConnected, BluetoothBondState.none);
                              });
                            }
                          })
                          .onError((error, stackTrace) {
                            if(mounted) {
                              setState(() {
                                Toast.showToast(context, "Failed to unpair with ${result.device.name ?? result.device.address}", const Icon(Icons.error, color: Colors.red), 3);
                              });
                            }
                          });
                          Toast.showToast(context, "Unpairing with ${result.device.name ?? result.device.address} ...", null, 3);
                          Navigator.of(context).pop();
                        },
                      ),
                      if(!result.device.isBonded) TextButton(
                        child: const Text("Pair"),
                        onPressed: () {
                          FlutterBluetoothSerial.instance.bondDeviceAtAddress(result.device.address).then((value) {
                            if(mounted) {
                              setState(() {
                                results[results.indexOf(result)] = makeResult(result, result.device.isConnected,
                                  value == null
                                    ? BluetoothBondState.none
                                    : value ? BluetoothBondState
                                    .bonded : BluetoothBondState.none,
                                );
                              });
                            }
                          })
                          .onError((error, stackTrace) {
                            if(mounted) {
                              setState(() {
                                Toast.showToast(context, "Failed to pair with ${result.device.name ?? result.device.address}", const Icon(Icons.error, color: Colors.red), 3);
                              });
                            }
                          });
                          Toast.showToast(context, "Pairing with ${result.device.name ?? result.device.address} ...", null, 3);
                          Navigator.of(context).pop();
                        },
                      ),
                      TextButton(
                        child: const Text("Cancel"),
                        onPressed: () {
                          Navigator.of(context).pop();
                        },
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      )),
      if(Constants.shouldShowBluetoothSpp) Expanded(flex: 1, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Text(connectedDevice == null? "Not connected" : "Connected to ${connectedDevice!.name ?? connectedDevice!.address}"),
      if(connectedDevice != null) TextButton(
        child: const Text("Disconnect"),
        onPressed: () {
          disconnect();
          Toast.showToast(context, "Disconnecting ...", null, 3);
        },
      ),
      ])),
      ]),
    );

  }

  BluetoothDiscoveryResult makeResult(BluetoothDiscoveryResult result, bool isConnected, BluetoothBondState bondState) {
    return BluetoothDiscoveryResult(
        device: BluetoothDevice(
          name: result.device.name ?? '',
          address: result.device.address,
          type: result.device.type,
          bondState: bondState,
          isConnected: isConnected,
        ),
        rssi: result.rssi);
  }

  void disconnect() {
    if(mounted && connectedDevice != null) {
      setState(() {
        int index = results.indexWhere((element) => element.device.address == connectedDevice!.address);
        if(index >= 0) {
          BluetoothDiscoveryResult result = results[index];
          results[index] = makeResult(result, false, result.device.bondState);
        }
      });
    }

    connection?.dispose();
    connection = null;
    connectedDevice = null;
  }
}

class _BluetoothDeviceListEntry extends ListTile {
  _BluetoothDeviceListEntry({
    required BluetoothDevice device,
    int? rssi,
    super.onTap,
  }) : super(
    leading:
    const Icon(Icons.devices),
    title: Text(device.name ?? ""),
    subtitle: Text(device.address.toString()),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        rssi != null
            ? Container(
          margin: const EdgeInsets.all(8.0),
          child: DefaultTextStyle(
            style: _computeTextStyle(rssi),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(rssi.toString()),
                const Text('dBm'),
              ],
            ),
          ),
        )
            : const SizedBox(width: 0, height: 0),
        device.isConnected
            ? const Icon(Icons.import_export)
            : const SizedBox(width: 0, height: 0),
        device.isBonded
            ? const Icon(Icons.link)
            : const SizedBox(width: 0, height: 0),
      ],
    ),
  );

  static TextStyle _computeTextStyle(int rssi) {
    if (rssi >= -35) {
      return TextStyle(color: Colors.greenAccent[700]);
    }
    else if (rssi >= -45) {
      return TextStyle(
          color: Color.lerp(
              Colors.greenAccent[700], Colors.lightGreen, -(rssi + 35) / 10));
    }
    else if (rssi >= -55) {
      return TextStyle(
          color: Color.lerp(
              Colors.lightGreen, Colors.lime[600], -(rssi + 45) / 10));
    }
    else if (rssi >= -65) {
      return TextStyle(
          color: Color.lerp(Colors.lime[600], Colors.amber, -(rssi + 55) / 10));
    }
    else if (rssi >= -75) {
      return TextStyle(
          color: Color.lerp(
              Colors.amber, Colors.deepOrangeAccent, -(rssi + 65) / 10));
    }
    else if (rssi >= -85) {
      return TextStyle(
          color: Color.lerp(
              Colors.deepOrangeAccent, Colors.redAccent, -(rssi + 75) / 10));
    }
    else {
      /*code symmetry*/
      return const TextStyle(color: Colors.redAccent);
    }
  }
}


