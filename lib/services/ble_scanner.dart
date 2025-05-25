import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';

class BleDevice {
  final BluetoothDevice device;
  final int rssi;
  final List<int>? eidData; // Encrypted Identity Data for FMDN
  final DateTime lastSeen;
  Position? location;

  BleDevice(this.device, this.rssi, this.eidData, this.lastSeen, this.location);
}

class BleScanner {
  static const int DEVICE_CACHE_SIZE = 1000;
  static const Duration SCAN_TIMEOUT = Duration(seconds: 30);

  final _deviceStreamController = StreamController<List<BleDevice>>.broadcast();
  final Map<String, BleDevice> _deviceCache = {};
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  Timer? _scanTimer;
  bool _isScanning = false;

  Stream<List<BleDevice>> get deviceStream => _deviceStreamController.stream;

  BleScanner() {
    // Monitor Bluetooth adapter state
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      print('Bluetooth state changed: $state');
      if (state == BluetoothAdapterState.on) {
        _startScanIfNotRunning();
      } else {
        _stopScan();
      }
    });
  }

  Future<void> startScanning() async {
    if (_isScanning) return;
    
    try {
      print('Attempting to start BLE scan...');
      
      // Request location permission since it's required for BLE scanning
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('Location services are disabled');
        throw Exception('Location services are disabled');
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('Location permission denied');
          throw Exception('Location permission denied');
        }
      }

      if (permission == LocationPermission.deniedForever) {
        print('Location permissions permanently denied');
        throw Exception('Location permissions permanently denied');
      }

      // Check Bluetooth state
      if (await FlutterBluePlus.isSupported == false) {
        print('Bluetooth not supported on this device');
        throw Exception('Bluetooth not supported');
      }

      await FlutterBluePlus.turnOn();
      _startScanIfNotRunning();
    } catch (e) {
      print('Error starting scan: $e');
      _deviceStreamController.addError(e);
    }
  }

  void _startScanIfNotRunning() async {
    if (_isScanning) return;
    _isScanning = true;

    try {
      print('Starting BLE scan...');
      
      // Listen for scan results
      _scanSubscription = FlutterBluePlus.scanResults.listen(
        (results) {
          print('Raw scan results received: ${results.length} devices');
          for (var result in results) {
            print('Device: ${result.device.remoteId}, RSSI: ${result.rssi}, '
                'Name: ${result.device.localName}');
            if (result.advertisementData.manufacturerData.isNotEmpty) {
              print('Manufacturer Data: ${result.advertisementData.manufacturerData}');
            }
            if (result.advertisementData.serviceUuids.isNotEmpty) {
              print('Service UUIDs: ${result.advertisementData.serviceUuids}');
            }
          }
          _handleScanResults(results);
        },
        onError: (e) {
          print('Scan subscription error: $e');
          _deviceStreamController.addError(e);
          _restartScan();
        },
      );

      // Start the actual scan
      await FlutterBluePlus.startScan(
        timeout: SCAN_TIMEOUT,
        oneByOne: false, // Process results immediately
        androidScanMode: AndroidScanMode.lowLatency,
      );

      print('Scan started successfully');

      // Set scan timeout
      _scanTimer = Timer(SCAN_TIMEOUT, () {
        print('Scan timeout reached');
        _stopScan();
        _startScanIfNotRunning(); // Restart scan after timeout
      });
    } catch (e) {
      print('Error in _startScanIfNotRunning: $e');
      _deviceStreamController.addError(e);
      _restartScan();
    }
  }
  Future<void> _handleScanResults(List<ScanResult> results) async {
    // Get current location
    Position? currentLocation;
    try {
      currentLocation = await Geolocator.getCurrentPosition();
    } catch (e) {
      print('Error getting location: $e');
    }

    for (ScanResult r in results) {
      // Cache management - remove oldest devices if cache is full
      if (_deviceCache.length >= DEVICE_CACHE_SIZE) {
        var oldestDevice = _deviceCache.entries
            .reduce((a, b) => a.value.lastSeen.isBefore(b.value.lastSeen) ? a : b);
        _deviceCache.remove(oldestDevice.key);
      }

      // Update or add device to cache
      _deviceCache[r.device.remoteId.str] = BleDevice(
        r.device,
        r.rssi,
        _extractEidData(r.advertisementData), // Still extract EID if present, but don't filter on it
        DateTime.now(),
        currentLocation,
      );
    }
    
    // Emit updated device list after processing all results
    _deviceStreamController.add(_deviceCache.values.toList());
  }

  List<int>? _extractEidData(AdvertisementData adv) {
    // Extract EID (Encrypted Identity Data) from manufacturer specific data
    // For Find My beacons, look for Apple's company identifier (0x004C)
    // and specific data format
    final manufacturerData = adv.manufacturerData;
    if (manufacturerData.containsKey(0x004C)) {
      var data = manufacturerData[0x004C];
      // Validate data format and return EID bytes
      // Note: This is a simplified check - implement actual FMDN beacon validation
      if (data != null && data.length >= 25) {
        return data.sublist(0, 25); // First 25 bytes contain the EID
      }
    }
    return null;
  }

  void _restartScan() {
    _stopScan();
    Future.delayed(const Duration(seconds: 2), _startScanIfNotRunning);
  }

  void _stopScan() {
    _isScanning = false;
    _scanSubscription?.cancel();
    _scanTimer?.cancel();
    _scanSubscription = null;
    _scanTimer = null;
  }

  void dispose() {
    _stopScan();
    _adapterStateSubscription?.cancel();
    _deviceStreamController.close();
    _deviceCache.clear();
  }
}
