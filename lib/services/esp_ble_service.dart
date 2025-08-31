import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ESPBLEService {
  // Default UUIDs for ESP devices
  static const String DEFAULT_ESP_SERVICE_UUID = "12345678-1234-1234-1234-123456789abc";
  static const String DEFAULT_BUZZER_CHARACTERISTIC_UUID = "87654321-4321-4321-4321-cba987654321";
  
  static Timer? _buzzerCheckTimer;
  static bool _isProcessingBuzzer = false;

  /// Initialize the peer device to periodically check for buzzer flags
  static void initializePeerDevice() {
    // Start periodic check for buzzer flags every 3 seconds
    _buzzerCheckTimer?.cancel();
    _buzzerCheckTimer = Timer.periodic(Duration(seconds: 3), (timer) {
      _checkAndProcessBuzzerFlags();
    });
    
    debugPrint('ESP BLE: Initialized peer device with buzzer flag monitoring');
  }

  /// Check for buzzer flags and process them
  static Future<void> _checkAndProcessBuzzerFlags() async {
    if (_isProcessingBuzzer) return;
    
    try {
      _isProcessingBuzzer = true;
      
      // Get all trackers with buzzer flag enabled
      final trackersWithBuzzer = await _getTrackersWithBuzzerFlag();
      
      if (trackersWithBuzzer.isNotEmpty) {
        debugPrint('ESP BLE: Found ${trackersWithBuzzer.length} trackers with buzzer flag enabled');
        
        // Send buzzer commands to all flagged trackers
        for (final trackerData in trackersWithBuzzer) {
          await _sendBuzzerCommandToTracker(trackerData);
        }
      }
      
    } catch (e) {
      debugPrint('ESP BLE: Error checking buzzer flags: $e');
    } finally {
      _isProcessingBuzzer = false;
    }
  }

  /// Get all trackers with buzzer flag enabled from Firestore
  static Future<List<Map<String, dynamic>>> _getTrackersWithBuzzerFlag() async {
    try {
      final querySnapshot = await FirebaseFirestore.instance
          .collection('trackers')
          .where('buzzerFlag', isEqualTo: true)
          .get();
      
      return querySnapshot.docs.map((doc) => {
        'eid': doc.id,
        ...doc.data(),
      }).toList();
      
    } catch (e) {
      debugPrint('ESP BLE: Error fetching trackers with buzzer flag: $e');
      return [];
    }
  }

  /// Send buzzer command to a specific tracker
  static Future<void> _sendBuzzerCommandToTracker(Map<String, dynamic> trackerData) async {
    try {
      final eid = trackerData['eid'] as String;
      
      // Find and connect to the ESP device using EID
      final device = await _findESPDeviceByEID(eid);
      if (device == null) {
        debugPrint('ESP BLE: ESP device not found for tracker $eid');
        return;
      }

      // Send buzzer command
      final success = await _sendBuzzerToDevice(device, trackerData);
      
      if (success) {
        // Reset the buzzer flag after successful buzzer
        await _resetBuzzerFlag(eid);
        debugPrint('ESP BLE: Buzzer command sent successfully to tracker $eid');
      }
      
    } catch (e) {
      debugPrint('ESP BLE: Error sending buzzer to tracker: $e');
    }
  }

  /// Find ESP device by EID
  static Future<BluetoothDevice?> _findESPDeviceByEID(String eid) async {
    try {
      // Start scanning if not already scanning
      if (!await FlutterBluePlus.isScanning.first) {
        await FlutterBluePlus.startScan(timeout: Duration(seconds: 10));
      }

      // Listen for scan results
      final completer = Completer<BluetoothDevice?>();
      late StreamSubscription subscription;
      
      subscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final device = result.device;
          
          // Check by device name containing EID
          if (device.platformName.toLowerCase().contains(eid.toLowerCase())) {
            subscription.cancel();
            completer.complete(device);
            return;
          }
          
          // Check by device name patterns (ESP-EID, EID-ESP, etc.)
          final nameLower = device.platformName.toLowerCase();
          final eidLower = eid.toLowerCase();
          if (nameLower.contains('esp') && nameLower.contains(eidLower)) {
            subscription.cancel();
            completer.complete(device);
            return;
          }
          
          // Check manufacturer data for EID
          final manufacturerData = result.advertisementData.manufacturerData;
          for (final data in manufacturerData.values) {
            final dataString = utf8.decode(data, allowMalformed: true);
            if (dataString.toLowerCase().contains(eid.toLowerCase())) {
              subscription.cancel();
              completer.complete(device);
              return;
            }
          }
          
          // Check service data for EID
          final serviceData = result.advertisementData.serviceData;
          for (final data in serviceData.values) {
            final dataString = utf8.decode(data, allowMalformed: true);
            if (dataString.toLowerCase().contains(eid.toLowerCase())) {
              subscription.cancel();
              completer.complete(device);
              return;
            }
          }
        }
      });

      // Timeout after 10 seconds
      Timer(Duration(seconds: 10), () {
        if (!completer.isCompleted) {
          subscription.cancel();
          completer.complete(null);
        }
      });

      return await completer.future;
    } catch (e) {
      debugPrint('ESP BLE: Error finding ESP device by EID: $e');
      return null;
    }
  }

  /// Send buzzer command to the ESP device via BLE
  static Future<bool> _sendBuzzerToDevice(BluetoothDevice device, Map<String, dynamic> trackerData) async {
    try {
      // Connect to device
      await device.connect(timeout: Duration(seconds: 15));
      debugPrint('ESP BLE: Connected to device: ${device.remoteId}');

      // Use default UUIDs or custom ones from tracker data
      final serviceUuid = trackerData['serviceUuid'] ?? DEFAULT_ESP_SERVICE_UUID;
      final buzzerCharUuid = trackerData['buzzerCharacteristicUuid'] ?? DEFAULT_BUZZER_CHARACTERISTIC_UUID;

      // Discover services
      final services = await device.discoverServices();
      final targetService = services.firstWhere(
        (service) => service.uuid.toString().toLowerCase() == serviceUuid.toLowerCase(),
        orElse: () => throw Exception('ESP service not found'),
      );

      // Find buzzer characteristic
      final buzzerCharacteristic = targetService.characteristics.firstWhere(
        (char) => char.uuid.toString().toLowerCase() == buzzerCharUuid.toLowerCase(),
        orElse: () => throw Exception('Buzzer characteristic not found'),
      );

      // Build and send buzzer command with default settings
      final duration = trackerData['buzzerDuration'] ?? 5000; // Default 5 seconds
      final command = _buildBuzzerCommand(duration, trackerData);
      
      await buzzerCharacteristic.write(utf8.encode(command));
      debugPrint('ESP BLE: Buzzer command sent: $command');

      // Update last buzzer timestamp
      await _updateLastBuzzerCommand(trackerData['eid']);

      // Disconnect after a short delay
      await Future.delayed(Duration(milliseconds: 500));
      await device.disconnect();
      return true;
      
    } catch (e) {
      debugPrint('ESP BLE: Error sending buzzer command to device: $e');
      return false;
    }
  }

  /// Build buzzer command with default format
  static String _buildBuzzerCommand(int duration, Map<String, dynamic> config) {
    final format = config['commandFormat'] ?? 'json'; // Default to JSON
    
    switch (format) {
      case 'json':
        return jsonEncode({
          'action': 'buzz',
          'duration': duration,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'eid': config['eid'], // Include EID for identification
        });
      
      case 'simple':
        return 'BUZZ:$duration';
      
      case 'binary':
        return 'B${duration.toString().padLeft(8, '0')}';
      
      default:
        // Default JSON format
        return jsonEncode({
          'action': 'buzz', 
          'duration': duration,
          'eid': config['eid'],
        });
    }
  }

  /// Reset buzzer flag after successful buzzer command
  static Future<void> _resetBuzzerFlag(String eid) async {
    try {
      await FirebaseFirestore.instance
          .collection('trackers')
          .doc(eid)
          .update({
        'buzzerFlag': false,
        'buzzerProcessedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('ESP BLE: Error resetting buzzer flag: $e');
    }
  }

  /// Update last buzzer command timestamp
  static Future<void> _updateLastBuzzerCommand(String eid) async {
    try {
      await FirebaseFirestore.instance
          .collection('trackers')
          .doc(eid)
          .update({
        'lastBuzzerCommand': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('ESP BLE: Error updating last buzzer command: $e');
    }
  }

  /// Manually set buzzer flag for a tracker (called from remote device)
  static Future<bool> setBuzzerFlag({
    required String eid,
    bool enabled = true,
    int duration = 5000,
    String commandFormat = 'json',
  }) async {
    try {
      await FirebaseFirestore.instance
          .collection('trackers')
          .doc(eid)
          .update({
        'buzzerFlag': enabled,
        'buzzerDuration': duration,
        'commandFormat': commandFormat,
        'buzzerRequestedAt': FieldValue.serverTimestamp(),
      });
      
      debugPrint('ESP BLE: Buzzer flag set to $enabled for tracker $eid');
      return true;
    } catch (e) {
      debugPrint('ESP BLE: Error setting buzzer flag: $e');
      return false;
    }
  }

  /// Configure ESP device settings for a tracker
  static Future<bool> configureESPDevice({
    required String eid,
    String? deviceName,
    String? serviceUuid,
    String? buzzerCharacteristicUuid,
    String? commandFormat,
  }) async {
    try {
      await FirebaseFirestore.instance
          .collection('trackers')
          .doc(eid)
          .update({
        'deviceName': deviceName,
        'serviceUuid': serviceUuid ?? DEFAULT_ESP_SERVICE_UUID,
        'buzzerCharacteristicUuid': buzzerCharacteristicUuid ?? DEFAULT_BUZZER_CHARACTERISTIC_UUID,
        'commandFormat': commandFormat ?? 'json',
        'espConfiguredAt': FieldValue.serverTimestamp(),
      });
      
      debugPrint('ESP BLE: ESP device configured for tracker $eid');
      return true;
    } catch (e) {
      debugPrint('ESP BLE: Error configuring ESP device: $e');
      return false;
    }
  }

  /// Check if a tracker has ESP configuration (always true since no config needed)
  static Future<bool> isESPConfigured(String eid) async {
    // No configuration needed - the system works automatically
    // ESP devices are discovered by EID pattern matching
    return true;
  }

  /// Register ESP device configuration for a tracker
  static Future<void> registerESPDevice({
    required String eid,
    required String macAddress,
    required String deviceId,
  }) async {
    try {
      await FirebaseFirestore.instance
          .collection('trackers')
          .doc(eid)
          .update({
        'macAddress': macAddress,
        'deviceId': deviceId,
        'espRegisteredAt': FieldValue.serverTimestamp(),
      });
      
      debugPrint('ESP BLE: Device configuration registered for tracker $eid');
    } catch (e) {
      debugPrint('ESP BLE: Error registering ESP device: $e');
      rethrow;
    }
  }

  /// Get current buzzer flag status for a tracker
  static Future<bool> getBuzzerFlagStatus(String eid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('trackers')
          .doc(eid)
          .get();
      
      if (!doc.exists) return false;
      
      final data = doc.data()!;
      return data['buzzerFlag'] == true;
    } catch (e) {
      debugPrint('ESP BLE: Error getting buzzer flag status: $e');
      return false;
    }
  }

  /// Cancel all active buzzer flags for an owner
  static Future<void> cancelAllBuzzerFlags(String ownerUid) async {
    try {
      // Get user's trackers
      final userDoc = await FirebaseFirestore.instance
          .collection('User')
          .doc(ownerUid)
          .get();
      
      final trackers = userDoc.data()?['trackers'] as Map<String, dynamic>?;
      if (trackers == null || trackers.isEmpty) return;
      
      // Reset buzzer flags for all user's trackers
      final batch = FirebaseFirestore.instance.batch();
      for (final eid in trackers.keys) {
        final trackerRef = FirebaseFirestore.instance.collection('trackers').doc(eid);
        batch.update(trackerRef, {
          'buzzerFlag': false,
          'buzzerCancelledAt': FieldValue.serverTimestamp(),
        });
      }
      
      await batch.commit();
      debugPrint('ESP BLE: Cancelled all buzzer flags for owner $ownerUid');
    } catch (e) {
      debugPrint('ESP BLE: Error cancelling buzzer flags: $e');
    }
  }

  /// Get buzzer statistics
  static Future<Map<String, int>> getBuzzerStatistics() async {
    try {
      final activeQuery = await FirebaseFirestore.instance
          .collection('trackers')
          .where('buzzerFlag', isEqualTo: true)
          .get();
      
      return {
        'active': activeQuery.docs.length,
        'total': activeQuery.docs.length,
      };
    } catch (e) {
      debugPrint('ESP BLE: Error getting buzzer statistics: $e');
      return {'active': 0, 'total': 0};
    }
  }

  /// Cleanup and stop the service
  static void dispose() {
    _buzzerCheckTimer?.cancel();
    _buzzerCheckTimer = null;
    _isProcessingBuzzer = false;
    debugPrint('ESP BLE: Service disposed');
  }
}
