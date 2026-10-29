import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

Finder loginSubmit() => find.widgetWithText(FilledButton, 'Mag-log in');

Future<void> openLoginPopup(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.account_box));
  await pumpFrames(tester);
  expect(find.text('Mag-log in sa E-Bike'), findsOneWidget);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountStore().reset();
  });

  testWidgets('may account/login button sa taas at bukas ang login popup', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RoleHome()));
    await pumpFrames(tester);

    // Nasa taas lang ang login/account button — tinanggal na ang Passenger/Rider Mode menu.
    expect(find.byIcon(Icons.account_box), findsOneWidget);
    expect(find.byIcon(Icons.switch_account), findsNothing);
    expect(find.text('Passenger Mode'), findsNothing);
    expect(find.text('Rider Mode'), findsNothing);
    expect(find.text('Maghanap ng E-Bike'), findsOneWidget);

    await openLoginPopup(tester);
    expect(find.text('Pasahero'), findsOneWidget);
    expect(find.text('Rider'), findsOneWidget);
    expect(dialogField(0), findsOneWidget);
    expect(dialogField(1), findsOneWidget);
  });

  testWidgets('nag-e-error sa maling password', (tester) async {
    AccountStore().signUp(
      name: 'Juan Dela Cruz',
      phone: '09123456789',
      email: 'juan@bacuag.ph',
      password: 'tama123',
      role: 'passenger',
      idType: 'National ID',
    );

    await tester.pumpWidget(const MaterialApp(home: RoleHome()));
    await pumpFrames(tester);
    await openLoginPopup(tester);

    await tester.enterText(dialogField(0), 'juan@bacuag.ph');
    await tester.enterText(dialogField(1), 'mali');
    await tester.tap(loginSubmit());
    await pumpFrames(tester);

    expect(find.textContaining('Maling Email o Password'), findsOneWidget);
    expect(AccountStore().currentUser, isNull);
  });

  testWidgets('matagumpay na login bilang Pasahero at makikita ang account', (tester) async {
    AccountStore().signUp(
      name: 'Juan Dela Cruz',
      phone: '09123456789',
      email: 'juan@bacuag.ph',
      password: 'tama123',
      role: 'passenger',
      idType: 'National ID',
    );

    await tester.pumpWidget(const MaterialApp(home: RoleHome()));
    await pumpFrames(tester);
    await openLoginPopup(tester);

    await tester.enterText(dialogField(0), 'juan@bacuag.ph');
    await tester.enterText(dialogField(1), 'tama123');
    await tester.tap(loginSubmit());
    await pumpFrames(tester, times: 12);

    expect(find.text('Mag-log in sa E-Bike'), findsNothing);
    expect(AccountStore().currentUser?.role, 'passenger');
    // Ang login ang nagtatakda ng mode: passenger → Passenger screen.
    expect(find.byType(PassengerScreen), findsOneWidget);
    expect(find.text('E-Bike — Passenger'), findsOneWidget);

    // Muling tinutukan ang account icon → lalabas ang account at logout.
    await tester.tap(find.byIcon(Icons.account_box));
    await pumpFrames(tester);
    expect(find.text('Aking Account'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Mag-log out'), findsOneWidget);
  });

  testWidgets('matagumpay na login bilang Rider', (tester) async {
    AccountStore().signUp(
      name: 'Pedro Rider',
      phone: '09187654321',
      email: 'pedro@bacuag.ph',
      password: 'rider123',
      role: 'rider',
      idType: 'Voter ID',
    );

    await tester.pumpWidget(const MaterialApp(home: RoleHome()));
    await pumpFrames(tester);
    await openLoginPopup(tester);

    await tester.tap(find.text('Rider'));
    await pumpFrames(tester);
    await tester.enterText(dialogField(0), 'pedro@bacuag.ph');
    await tester.enterText(dialogField(1), 'rider123');
    await tester.tap(loginSubmit());
    await pumpFrames(tester, times: 12);

    expect(find.text('Mag-log in sa E-Bike'), findsNothing);
    expect(AccountStore().currentUser?.role, 'rider');
    // Ang login ang nagtatakda ng mode: rider → Rider screen.
    expect(find.byType(RiderScreen), findsOneWidget);
    expect(find.text('E-Bike — Rider Dashboard'), findsOneWidget);
  });

  testWidgets('nag-e-error kapag maling uri ng account ang pinili', (tester) async {
    AccountStore().signUp(
      name: 'Juan Dela Cruz',
      phone: '09123456789',
      email: 'juan@bacuag.ph',
      password: 'tama123',
      role: 'passenger',
      idType: 'National ID',
    );

    await tester.pumpWidget(const MaterialApp(home: RoleHome()));
    await pumpFrames(tester);
    await openLoginPopup(tester);

    // Rider ang pinili ngunit Pasahero ang account.
    await tester.tap(find.text('Rider'));
    await pumpFrames(tester);
    await tester.enterText(dialogField(0), 'juan@bacuag.ph');
    await tester.enterText(dialogField(1), 'tama123');
    await tester.tap(loginSubmit());
    await pumpFrames(tester);

    expect(find.textContaining('piliin ang tamang uri'), findsOneWidget);
    expect(AccountStore().currentUser, isNull);
  });

  testWidgets('makapag-lo-log out sa pamamagitan ng account popup', (tester) async {
    AccountStore().signUp(
      name: 'Juan Dela Cruz',
      phone: '09123456789',
      email: 'juan@bacuag.ph',
      password: 'tama123',
      role: 'passenger',
      idType: 'National ID',
    );

    await tester.pumpWidget(const MaterialApp(home: RoleHome()));
    await pumpFrames(tester);
    await openLoginPopup(tester);
    await tester.enterText(dialogField(0), 'juan@bacuag.ph');
    await tester.enterText(dialogField(1), 'tama123');
    await tester.tap(loginSubmit());
    await pumpFrames(tester, times: 12);
    expect(AccountStore().currentUser, isNotNull);

    await tester.tap(find.byIcon(Icons.account_box));
    await pumpFrames(tester);
    expect(find.text('Aking Account'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Mag-log out'));
    await pumpFrames(tester, times: 12);

    expect(AccountStore().currentUser, isNull);
    expect(find.text('Mag-log in sa E-Bike'), findsNothing);
  });
}
