import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// Optional: Define a specific device MAC address for targeted debugging
// const String DEBUG_DEVICE_ID = "68:25:DD:34:3B:C2"; // Your ESP32's MAC

void main() {
  // FlutterBluePlus.setLogLevel(LogLevel.verbose, color:true); // Enable for very detailed FBP logs
  runApp(const BLEScannerApp());
}

class BLEScannerApp extends StatelessWidget {
  const BLEScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE FMDN Scanner (Robust)',
      theme: ThemeData(
        primarySwatch: Colors.deepPurple, // Yet another color
        useMaterial3: true,
      ),
      home: const ScanScreen(),
    );
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  late StreamSubscription<BluetoothAdapterState> _adapterStateStateSubscription;

  // Store ScanResult along with its parsed FMDN data to avoid re-parsing in UI
  List<Map<String, dynamic>> _processedScanResults = [];
  bool _isScanning = false;
  late StreamSubscription<List<ScanResult>> _scanResultsSubscription;
  late StreamSubscription<bool> _isScanningSubscription;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndInitBluetooth();

    _adapterStateStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (mounted) {
        setState(() {
          _adapterState = state;
        });
      }
    });    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      List<Map<String, dynamic>> newProcessedResults = [];
      for (ScanResult r in results) {
        final fmdnData = parseFMDNData(r); // Parse once
        if (fmdnData != null) { // Only add devices with FMDN data
          newProcessedResults.add({'result': r, 'fmdn': fmdnData});
          _printDeviceDetails(r, fmdnData); // Print with parsed data
        }
      }
      if (mounted) {
        setState(() {
          _processedScanResults = newProcessedResults;
        });
      }
    }, onError: (e) {
      _showErrorSnackbar('Scan Stream Error: $e');
      debugPrint('!!! Scan Stream Error: $e');
    });

    _isScanningSubscription = FlutterBluePlus.isScanning.listen((state) {
      if (mounted) {
        setState(() {
          _isScanning = state;
        });
      }
    });
  }

  @override
  void dispose() {
    _adapterStateStateSubscription.cancel();
    _scanResultsSubscription.cancel();
    _isScanningSubscription.cancel();
    if (_isScanning) {
      FlutterBluePlus.stopScan();
    }
    super.dispose();
  }

  Future<void> _checkPermissionsAndInitBluetooth() async {
    Map<Permission, PermissionStatus> statuses = {};
    if (Platform.isAndroid) {
      statuses = await [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
    } else if (Platform.isIOS) {
      statuses[Permission.locationWhenInUse] = await Permission.locationWhenInUse.request();
      statuses[Permission.bluetooth] = await Permission.bluetooth.request();
    }

    bool allGranted = true;
    statuses.forEach((permission, status) {
      if (!status.isGranted) {
        allGranted = false;
        debugPrint("Permission denied: ${permission.toString()}");
      }
    });

    if (!allGranted) {
      _showErrorSnackbar('Required permissions were not granted.');
    }
    if (await FlutterBluePlus.isSupported == false) {
        _showErrorSnackbar("Bluetooth not supported by this device");
        return;
    }
    _adapterState = await FlutterBluePlus.adapterState.first;
    if (mounted) setState(() {});
  }

  void _showErrorSnackbar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.redAccent, duration: const Duration(seconds: 4)),
      );
    }
    debugPrint("ERROR_SNACKBAR_MSG: $message");
  }
  /// Parses FMDN data from Service Data (0xFEAA), exactly matching Python implementation
  Map<String, dynamic>? parseFMDNData(ScanResult scanResult) {
    final serviceData = scanResult.advertisementData.serviceData;
    
    // Find FEAA UUID in service data (equivalent to Python's FMDN_UUID_FRAGMENT check)
    final fmdnKey = serviceData.keys
        .firstWhere((uuid) => uuid.toString().toLowerCase().contains('feaa'),
            orElse: () => Guid('00000000-0000-0000-0000-000000000000'));
              
    if (fmdnKey.toString() == '00000000-0000-0000-0000-000000000000') return null;

    final data = serviceData[fmdnKey]!;
    if (data.length < 22) return null;  // Need at least frame type + EID + flags

    // Parse exactly like Python code
    final frameType = data[0];       // First byte is frame type (0x40 or 0x41)
    final eidBytes = data.sublist(1, 21); // Next 20 bytes are EID (indices 1-20)
    final flags = data[21];          // Last byte is flags

    debugPrint("""
Device: ${scanResult.device.remoteId}  RSSI: ${scanResult.rssi} dBm
  UUID:       ${fmdnKey.toString()}
  Frame type: 0x${frameType.toRadixString(16).padLeft(2, '0')}
  EID:        ${eidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}
  Flags:      0x${flags.toRadixString(16).padLeft(2, '0')}
${'-' * 40}
""");

    return {
      'frameType': frameType,
      'eid': eidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(''),
      'flags': flags,
    };
  }

  void _printDeviceDetails(ScanResult r, Map<String, dynamic>? fmdnData) {
    // Reduce console output frequency unless specifically debugging a device
    // if (DEBUG_DEVICE_ID != null && r.device.remoteId.toString() != DEBUG_DEVICE_ID) return;

    String deviceName = r.device.platformName.isNotEmpty ? r.device.platformName : "Unknown Device";
    String deviceId = r.device.remoteId.toString();

    debugPrint('--- Device: $deviceName ($deviceId) ---');
    debugPrint('RSSI: ${r.rssi}');
    // debugPrint('Connectable: ${r.advertisementData.connectable}');
    // debugPrint('Tx Power: ${r.advertisementData.txPowerLevel ?? "N/A"}');

    // List<String> serviceUuids = r.advertisementData.serviceUuids.map((e) => e.toString().toUpperCase()).toList();
    // if (serviceUuids.isNotEmpty) {
    //   debugPrint('Advertised Service UUIDs (list): ${serviceUuids.join(", ")}');
    // }

    if (fmdnData != null) {
      if (fmdnData.containsKey('parseError')) {
        debugPrint('FMDN Data (0xFEAA): Parse Error - ${fmdnData['parseError']}');
        debugPrint('  Frame Type (if available): 0x${fmdnData['frameType']?.toRadixString(16)?.padLeft(2, '0') ?? "N/A"}');
        debugPrint('  EID (if available): ${fmdnData['eid']}');
      } else {
        debugPrint('FMDN Data (0xFEAA):');
        debugPrint('  Frame Type: 0x${fmdnData['frameType'].toRadixString(16).padLeft(2, '0')}');
        debugPrint('  EID: ${fmdnData['eid']}');
        debugPrint('  Flags: 0x${fmdnData['flags'].toRadixString(16).padLeft(2, '0')} (Status: ${fmdnData['flagsParseStatus']})');
      }
      // debugPrint('  (Raw 0xFEAA Payload Length: ${fmdnData['rawDataLength']} bytes)');
    }
    // For brevity, you might comment out printing all service data or manufacturer data
    // if (r.advertisementData.serviceData.isNotEmpty) {
    //     debugPrint('All Service Data Entries (raw):');
    //     r.advertisementData.serviceData.forEach((guid, data) {
    //         debugPrint('  Service ${guid.toString().toUpperCase()}: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}');
    //     });
    // }
    debugPrint('-------------------------------------\n');
  }

  Future<void> _toggleScan() async {
    if (!mounted) return;
    if (_adapterState != BluetoothAdapterState.on) {
      _showErrorSnackbar('Bluetooth is not enabled.');
      return;
    }
    if (_isScanning) {
      await FlutterBluePlus.stopScan();
      debugPrint("Scan stopped.");
    } else {
      if (mounted) {
        setState(() { _processedScanResults = []; });
      }
      try {
        // Consider scanMode: AndroidScanMode.lowLatency for faster discovery, but potentially more battery.
        // FMDN beacons are non-connectable.
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 30), // Scan duration
          // withServices: [Guid("0000FEAA-0000-1000-8000-00805F9B34FB")], // Optional: filter server-side
          // allowDuplicates: true, // Process every advertisement packet
        );
        debugPrint("Scan started...");
      } catch (e) {
        _showErrorSnackbar('Error starting scan: $e');
        debugPrint('!!! Error starting scan: $e');
      }
    }
  }

  Widget _buildScanButton(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: _toggleScan,
      label: Text(_isScanning ? 'STOP SCAN' : 'START SCAN', style: const TextStyle(color: Colors.white)),
      icon: Icon(_isScanning ? Icons.stop : Icons.search, color: Colors.white),
      backgroundColor: _isScanning ? Colors.redAccent : Theme.of(context).primaryColor,
    );
  }
  Widget _buildDeviceList() {
    if (_adapterState != BluetoothAdapterState.on) {
      return const Center(child: Text('Bluetooth is OFF.', style: TextStyle(fontSize: 16, color: Colors.red)));
    }
    if (_isScanning && _processedScanResults.isEmpty) {
      return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        CircularProgressIndicator(), 
        SizedBox(height: 10), 
        Text('Scanning for FMDN Devices...', style: TextStyle(fontSize: 16))
      ]));
    }
    if (!_isScanning && _processedScanResults.isEmpty) {
      return const Center(child: Text('No FMDN devices found.\nPress START SCAN to search.', 
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 16)
      ));
    }
    return ListView.builder(
      itemCount: _processedScanResults.length,
      itemBuilder: (context, index) {
        final Map<String, dynamic> processedResult = _processedScanResults[index];
        final ScanResult scanResult = processedResult['result'] as ScanResult;
        final Map<String, dynamic>? fmdn = processedResult['fmdn'] as Map<String, dynamic>?;

        String deviceName = scanResult.device.platformName.isNotEmpty ? scanResult.device.platformName : 'Unknown Device';        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          color: Colors.deepPurple.shade50, // Highlight FMDN devices
          child: ListTile(
            leading: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.bluetooth_searching, color: Colors.deepPurple),
              Text('${scanResult.rssi}', 
                style: TextStyle(
                  fontSize: 12, 
                  fontWeight: FontWeight.bold,
                  color: scanResult.rssi > -70 ? Colors.green : Colors.orange
                )
              ),
            ]),
            title: Text(deviceName, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(scanResult.device.remoteId.toString(), 
                style: TextStyle(fontSize: 13, color: Colors.grey[600])),
              const SizedBox(height: 4),
              Text('Frame: 0x${fmdn!['frameType'].toRadixString(16).padLeft(2, '0')}',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
              SelectableText('EID: ${fmdn['eid']}',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.deepPurple)),
              Text('Flags: 0x${fmdn['flags'].toRadixString(16).padLeft(2, '0')}',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            ]),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.deepPurple.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text('FMDN', style: TextStyle(fontSize: 10, color: Colors.deepPurple)),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FMDN Scanner (Robust)'),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Adapter: ${_adapterState.toString().split('.').last.toUpperCase()}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _adapterState == BluetoothAdapterState.on ? Colors.green[700] : Colors.red[700])),
            if (_isScanning) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
          ]),
        ),
        if (_isScanning && _processedScanResults.isEmpty) const LinearProgressIndicator(),
        Expanded(child: _buildDeviceList()),
      ]),
      floatingActionButton: _buildScanButton(context),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}
