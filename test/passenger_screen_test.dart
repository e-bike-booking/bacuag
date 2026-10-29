import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sakay_bacuag/main.dart';

Future<void> pumpFrames(WidgetTester tester, {int times = 8}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Finder dialogField(int index) => find
    .descendant(of: find.byType(AlertDialog), matching: find.byType(TextField))
    .at(index);

Future<void> logInPassenger(WidgetTester tester) async {
  // Nasa dulo ng lazy form list ang button at maaaring lampas na sa viewport
  // (may mga bagong section ang form tulad ng measure/satellite), kaya
  // kailangan ng skipOffstage: false para makita at ma-scroll ito paitaas.
  final requestBtn = find.text('Mag-request ng E-Bike', skipOffstage: false);
  await tester.ensureVisible(requestBtn);
  await pumpFrames(tester);
  await tester.tap(requestBtn);
  await pumpFrames(tester);

  await tester.tap(find.text('Mag-log in'));
  await pumpFrames(tester);

  await tester.enterText(dialogField(0), 'test@bacuag.ph');
  await tester.enterText(dialogField(1), 'secret123');
  await pumpFrames(tester);

  await tester.tap(find.text('Mag-log in & I-send ang Booking'));
  await pumpFrames(tester, times: 12);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountStore().reset();
    // Binubuo ang account na ginagamit ng dialog login sa ibaba.
    AccountStore().signUp(
      name: 'Pasahero Uno',
      phone: '09123456789',
      email: 'test@bacuag.ph',
      password: 'secret123',
      role: 'passenger',
      idType: 'National ID',
    );
  });

  testWidgets('switching passenger tabs does not crash', (tester) async {
    // Pixel Tablet: 2560x1600 physical, density 2x -> 1280x800 logical.
    // Dito lumalabas ang map cameraConstraint bug (malaki ang viewport kaysa bounds).
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PassengerScreen())),
    );
    await pumpFrames(tester);

    await logInPassenger(tester);
    expect(find.text('Aking Dashboard'), findsOneWidget,
        reason: 'Dapat lumitaw ang tabs pagkatapos mag-log in');

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Aking Dashboard'));
      await pumpFrames(tester);
      await tester.tap(find.text('Mag-book ng E-Bike'));
      await pumpFrames(tester);
    }

    // Huling pag-switch kasabay ng scroll — dito madalas lumalabas ang bug.
    await tester.tap(find.text('Aking Dashboard'));
    await pumpFrames(tester);
    final dashboard = find.byType(ListView);
    if (dashboard.evaluate().isNotEmpty) {
      await tester.drag(dashboard, const Offset(0, -240));
      await pumpFrames(tester);
    }
  });

  testWidgets('conditional children insert does not crash', (tester) async {
    // Parehong laki ng Pixel Tablet tulad ng unang test.
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PassengerScreen())),
    );
    await pumpFrames(tester);

    final map = find.byType(FlutterMap);
    expect(map, findsOneWidget);

    // PICKUP pin
    await tester.ensureVisible(map);
    await pumpFrames(tester);
    await tester.tap(map);
    await pumpFrames(tester);
    expect(find.textContaining('Pickup:'), findsOneWidget);

    // DESTINATION pin -> mag-iinsert ng bagong child sa gitna ng ListView.
    await tester.tap(find.text('2. Destination Pin'));
    await pumpFrames(tester);
    await tester.tap(map);
    await pumpFrames(tester);

    expect(find.textContaining('Tinatayang Pamasahe'), findsOneWidget);

    // I-scroll habang may bagong child na naka-insert.
    // Gamitin ang fare box bilang drag handle (hindi ang title — maaaring
    // ma-unmount pagkatapos i-scroll palayo, dahil normal 'yon sa ListView).
    final fareBox = find.textContaining('Tinatayang Pamasahe');
    await tester.ensureVisible(fareBox);
    await pumpFrames(tester);
    await tester.drag(fareBox, const Offset(0, -260));
    await pumpFrames(tester);
    expect(fareBox, findsOneWidget);

    // Ibalik sa itaas — naroroon pa rin ang title at fare box.
    await tester.drag(fareBox, const Offset(0, 300));
    await pumpFrames(tester);
    expect(find.text('Maghanap ng E-Bike'), findsOneWidget);
    expect(fareBox, findsOneWidget);
  });
}
