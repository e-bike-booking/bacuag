import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakay_bacuag/main.dart';

void main() {
  testWidgets('shows E-Bike home screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RoleHome()));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('E-Bike — Passenger'), findsOneWidget);
    expect(find.text('Maghanap ng E-Bike'), findsOneWidget);
  });
}
