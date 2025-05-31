// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ble_beacon_tracker/main.dart';

void main() {
  testWidgets('App initializes and shows title', (WidgetTester tester) async {
    // Build our app and trigger a frame
    await tester.pumpWidget(const BLEScannerApp());

    // Verify that app title is displayed
    expect(find.text('BLE Scanner'), findsOneWidget);

    // Verify that initial scanning state message is shown
    expect(
      find.text('Press START BACKGROUND to begin scanning'),
      findsOneWidget,
    );
  });
}
