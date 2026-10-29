import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sakay_bacuag/main.dart';

BookingItem pendingBooking({
  String id = 'BK-AC-1',
  String phone = '09170000009',
  DateTime? createdAt,
  bool withDestination = true,
}) =>
    BookingItem(
      id: id,
      name: 'Test Passenger',
      phone: phone,
      pickup: const LatLng(9.6058, 125.6387),
      destination: withDestination ? const LatLng(9.6210, 125.6143) : null,
      createdAt: createdAt ?? DateTime.now(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Auto-cancel: 10 minuto bago awtomatikong kanselahin', () {
    test('hindi kinakansela bago mag-10 minuto', () {
      final now = DateTime.now();
      expect(
        isPendingAutoCancelDue(pendingBooking(createdAt: now), now: now),
        isFalse,
      );
      expect(
        isPendingAutoCancelDue(
          pendingBooking(createdAt: now.subtract(const Duration(minutes: 9, seconds: 59))),
          now: now,
        ),
        isFalse,
      );
    });

    test('kinakansela kapag lampas na sa 10 minuto', () {
      final now = DateTime.now();
      expect(
        isPendingAutoCancelDue(
          pendingBooking(createdAt: now.subtract(const Duration(minutes: 10))),
          now: now,
        ),
        isTrue,
      );
      // Hindi pending ang status → hindi na binibilang kahit matagal na.
      final accepted = pendingBooking(
        createdAt: now.subtract(const Duration(hours: 1)),
      )..status = 'accepted';
      expect(isPendingAutoCancelDue(accepted, now: now), isFalse);
    });

    test('countdown: natitirang segundo bago mag-auto-cancel', () {
      final now = DateTime.now();
      expect(
        pendingAutoCancelRemainingSeconds(pendingBooking(createdAt: now), now: now),
        600,
      );
      expect(
        pendingAutoCancelRemainingSeconds(
          pendingBooking(createdAt: now.subtract(const Duration(minutes: 4))),
          now: now,
        ),
        360,
      );
      expect(
        pendingAutoCancelRemainingSeconds(
          pendingBooking(createdAt: now.subtract(const Duration(minutes: 11))),
          now: now,
        ),
        0,
      );
    });

    test('BookingStore.autoCancelExpired: expired lang ang tinatanggal', () {
      final store = BookingStore();
      store.bookings.clear();
      final expired = pendingBooking(
        id: 'BK-AC-OLD',
        createdAt: DateTime.now().subtract(const Duration(minutes: 11)),
      );
      final fresh = pendingBooking(id: 'BK-AC-NEW');
      store.bookings
        ..add(expired)
        ..add(fresh);

      expect(store.autoCancelExpired(now: DateTime.now()), isTrue);
      expect(expired.status, 'cancelled');
      expect(fresh.status, 'pending');
      // Pangalawang tawag: wala nang babaguhin.
      expect(store.autoCancelExpired(now: DateTime.now()), isFalse);
      store.bookings.clear();
    });
  });

  group('Measure + travel time', () {
    test('formatDistanceMeters: m sa maliliit, km sa malalayo', () {
      expect(formatDistanceMeters(0), '0 m');
      expect(formatDistanceMeters(849.6), '850 m');
      expect(formatDistanceMeters(1240), '1.24 km');
    });

    test('measureTravelLabel: distansya + estimated travel time', () {
      const a = LatLng(9.6058, 125.6387);
      const far = LatLng(9.6210, 125.6143); // ~2.3 km
      final label = measureTravelLabel(a, far);
      expect(label, contains('📏'));
      expect(label, contains('km'));
      expect(label, contains('⏱'));
      expect(label, contains('min'));

      // Malapit (~11 m) → min 1 minuto ang ETA.
      const near = LatLng(9.6059, 125.6387);
      final short = measureTravelLabel(a, near);
      expect(short, contains('m'));
      expect(short, contains('~1 min'));
    });
  });

  group('Passenger UI', () {
    setUp(() {
      BookingStore().bookings.clear();
      AccountStore().reset();
      AccountStore().currentUser = const Account(
        name: 'Test Passenger',
        phone: '09170000009',
        email: 'ac@test.ph',
        password: 'pass123',
        role: 'passenger',
        idType: 'National ID',
      );
    });

    testWidgets('countdown card: pinapakita ang oras bago mag-auto-cancel',
        (tester) async {
      BookingStore().addBooking(pendingBooking(id: 'BK-AC-UI1'));

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: PassengerScreen())),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Auto-cancel sa'), findsOneWidget);
      expect(find.textContaining('Naghahanap ng rider'), findsOneWidget);
      // 📏 Measure ng pickup → destination.
      expect(find.textContaining('📏'), findsOneWidget);

      // Itigil ang 1s ticker bago matapos ang test.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets(
      'awtomatik na kinakansela + may abiso pagkalipas ng 10 minuto',
      (tester) async {
        BookingStore().addBooking(
          pendingBooking(
            id: 'BK-AC-UI2',
            createdAt: DateTime.now().subtract(const Duration(minutes: 11)),
          ),
        );

        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: PassengerScreen())),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(seconds: 1)); // unang tick
        await tester.pump(const Duration(milliseconds: 300));

        expect(BookingStore().bookings.first.status, 'cancelled');
        expect(
          find.textContaining('Na-cancel ang booking BK-AC-UI2'),
          findsOneWidget,
          reason: 'Dapat may abiso ang pasahero tungkol sa auto-cancel',
        );

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      },
    );
  });
}
