import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sakay_bacuag/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// E2E-style na pagsubok ng GPS arrival detection sa passenger side:
/// habang may aktibong biyahe, tinutukoy ng 1s ticker na nasa 45 m radius
/// na ang rider sa pickup/destination at awtomatikong ina-update ang status
/// (kapareho ng ginagawa ng totoong GPS fix ng rider sa biyahe).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pickup = LatLng(9.6058, 125.6387);
  const destination = LatLng(9.6210, 125.6143);

  setUp(() {
    // Ngayon ay nagpe-persist na ng bookings ang BookingStore — kailangan ng
    // mock na storage, kung hindi ay MissingPluginException ang mumura.
    SharedPreferences.setMockInitialValues({});
    BookingStore().bookings.clear();
    AccountStore().reset();
    // Naka-login bilang pasahero na may parehong numero ng booking.
    AccountStore().currentUser = const Account(
      name: 'Test Passenger',
      phone: '09171234567',
      email: 'gps@test.ph',
      password: 'pass123',
      role: 'passenger',
      idType: 'National ID',
    );
    BookingStore().addBooking(
      BookingItem(
        id: 'BK-GPS-1',
        name: 'Test Passenger',
        phone: '09171234567',
        pickup: pickup,
        destination: destination,
        status: 'accepted',
        riderName: 'Test Rider (Verified)',
        // ~270 m sa hilaga — wala pa sa arrival radius.
        riderLocation: const LatLng(9.6082, 125.6387),
      ),
    );
  });

  Future<void> pumpPassenger(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PassengerScreen())),
    );
    // I-reattach ang aktibong booking + mag-start ng ticker.
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
    'auto-ARRIVED kapag pumasok ang rider sa 45 m ng pickup, '
    'auto-COMPLETED kapag nasa destination',
    (tester) async {
      await pumpPassenger(tester);

      // Aktibong booking na may countdown card at oras ng pag-book.
      expect(find.textContaining('Booking Status: ACCEPTED'), findsOneWidget);
      expect(find.textContaining('Na-book:'), findsOneWidget);
      expect(find.textContaining('ETA:'), findsOneWidget);

      // Wala pang arrival — nasa ~270 m pa ang rider.
      await tester.pump(const Duration(seconds: 1));
      expect(BookingStore().bookings.first.status, 'accepted');

      // Lumapit ang rider sa pickup (~11 m) — katumbas ng GPS fix
      // ng rider na nasa loob na ng arrival radius.
      BookingStore().updateRiderLocation(
        'BK-GPS-1',
        const LatLng(9.6059, 125.6387),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));

      expect(BookingStore().bookings.first.status, 'arrived');
      expect(find.textContaining('Booking Status: ARRIVED'), findsOneWidget);
      expect(
        find.textContaining('Dumating na sa pickup area'),
        findsOneWidget,
        reason: 'Dapat may notification ang pasahero sa pagdating ng rider',
      );

      // Pumunta sa destination (~22 m mula sa destination pin).
      BookingStore().updateRiderLocation(
        'BK-GPS-1',
        const LatLng(9.6212, 125.6143),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));

      expect(BookingStore().bookings.first.status, 'completed');
      expect(find.textContaining('Booking Status: COMPLETED'), findsOneWidget);
      expect(
        find.textContaining('Nakarating na kayo sa destination'),
        findsOneWidget,
      );

      // Itigil ang 1s ticker bago matapos ang test (walang pending timer).
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('countdown card: ETA ay nagbabago habang lumalapit ang rider',
      (tester) async {
    await pumpPassenger(tester);
    expect(find.textContaining('ETA:'), findsOneWidget);
    expect(find.textContaining('⏱ ETA:'), findsOneWidget);

    final store = BookingStore();
    // ~890 m pa ang rider → malayong ETA (~2:58).
    store.updateRiderLocation('BK-GPS-1', const LatLng(9.6138, 125.6387));
    final farEta = estimateEtaSeconds(
      from: store.bookings.first.riderLocation!,
      to: pickup,
      routePoints: const [],
    );
    expect(farEta, greaterThan(120), reason: 'Malayo pa ang rider');

    // Papalapit sa pickup → mas maikling ETA.
    store.updateRiderLocation('BK-GPS-1', const LatLng(9.6059, 125.6387));
    await tester.pump(const Duration(seconds: 1));

    final nearEta = estimateEtaSeconds(
      from: store.bookings.first.riderLocation!,
      to: pickup,
      routePoints: const [],
    );
    expect(nearEta, lessThan(farEta));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
