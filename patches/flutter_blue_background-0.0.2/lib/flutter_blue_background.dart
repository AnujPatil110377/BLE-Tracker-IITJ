import 'dart:async';
import 'package:flutter/services.dart';

class FlutterBlueBackground {
  static const MethodChannel _channel = MethodChannel('flutter_blue_background');

  static Future<void> startFlutterBackgroundService(void Function() callback) async {
    try {
      await _channel.invokeMethod('startBackgroundScan');
    } on PlatformException catch (e) {
      print('Error starting background service: ${e.message}');
    }
  }

  static Future<void> stopFlutterBackgroundService() async {
    try {
      await _channel.invokeMethod('stopBackgroundScan');
    } on PlatformException catch (e) {
      print('Error stopping background service: ${e.message}');
    }
  }
}
