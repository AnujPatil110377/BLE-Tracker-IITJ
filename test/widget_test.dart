import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ble_beacon_tracker/main.dart';

void main() {
  testWidgets('App initializes and shows title', (WidgetTester tester) async {
    await tester.pumpWidget(const BLEScannerApp());

    expect(find.text('BLE Scanner'), findsOneWidget);

    expect(
      find.text('Press START BACKGROUND to begin scanning'),
      findsOneWidget,
    );
  });
}
