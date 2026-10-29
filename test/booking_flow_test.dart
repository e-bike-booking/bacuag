import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sakay_bacuag/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Nagpe-persist na ng bookings ang BookingStore — kailangan ng mock na
    // storage sa tests (kapareho ng ginagawa ng login/passenger tests).
    SharedPreferences.setMockInitialValues({});
    BookingStore().bookings.clear();
  });

  BookingItem makeBooking({
    String id = 'BK-1',
    String phone = '09171234567',
    String status = 'pending',
    String? riderName,
    DateTime? createdAt,
  }) {
    return BookingItem(
      id: id,
      name: 'Juan Dela Cruz',
      phone: phone,
      pickup: const LatLng(9.6087, 125.6374),
      destination: const LatLng(9.6150, 125.6450),
      status: status,
      riderName: riderName,
      createdAt: createdAt,
    );
  }

  group('Pending-booking guard (bawal ang panibagong booking)', () {
    test('activeForPhone ay bumabalik sa pending booking', () {
      BookingStore().addBooking(makeBooking());
      final active = BookingStore().activeForPhone('09171234567');
      expect(active, isNotNull);
      expect(active!.status, 'pending');
      expect(BookingStore().hasActiveBookingFor('09171234567'), isTrue);
    });

    test('lahat ng aktibong status ay nagba-block, completed/cancelled ay hindi', () {
      for (final status in ['pending', 'accepted', 'on_the_way', 'arrived']) {
        BookingStore().bookings.clear();
        BookingStore().addBooking(makeBooking(status: status));
        expect(
          BookingStore().activeForPhone('09171234567'),
          isNotNull,
          reason: "'$status' ay dapat mag-block ng bagong booking",
        );
      }
      for (final status in ['completed', 'cancelled']) {
        BookingStore().bookings.clear();
        BookingStore().addBooking(makeBooking(status: status));
        expect(
          BookingStore().activeForPhone('09171234567'),
          isNull,
          reason: "'$status' ay dapat payagan ang bagong booking",
        );
      }
    });

    test('hindi naaapektuhan ang ibang numero ng telepono', () {
      BookingStore().addBooking(makeBooking());
      expect(BookingStore().activeForPhone('09999999999'), isNull);
    });

    test('pinakabago muna ang tinitignan kapag dalawa ang aktibo', () {
      BookingStore()
        ..addBooking(makeBooking(id: 'BK-old'))
        ..addBooking(makeBooking(id: 'BK-new'));
      expect(BookingStore().activeForPhone('09171234567')!.id, 'BK-new');
    });
  });

  group('Countdown at oras ng pag-book', () {
    test('formatCountdown: mm:ss', () {
      expect(formatCountdown(0), '0:00');
      expect(formatCountdown(59), '0:59');
      expect(formatCountdown(65), '1:05');
      expect(formatCountdown(600), '10:00');
      expect(formatCountdown(-3), '0:00');
    });

    test('formatBookingTime: 12-oras na oras', () {
      expect(formatBookingTime(DateTime(2026, 10, 26, 16, 5)), '4:05 PM');
      expect(formatBookingTime(DateTime(2026, 10, 26, 0, 0)), '12:00 AM');
      expect(formatBookingTime(DateTime(2026, 10, 26, 12, 0)), '12:00 PM');
      expect(formatBookingTime(DateTime(2026, 10, 26, 9, 30)), '9:30 AM');
    });

    test('BookingItem: createdAt awtomatiko kapag hindi ibinigay', () {
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      final b = makeBooking();
      final after = DateTime.now().add(const Duration(seconds: 1));
      expect(b.createdAt.isAfter(before), isTrue);
      expect(b.createdAt.isBefore(after), isTrue);
    });
  });

  group('GPS arrival detection at ETA', () {
    test('isWithinArrivalRadius: 45 m na radius', () {
      const pickup = LatLng(9.6087, 125.6374);
      // ~44 m sa hilaga (1 degree lat ≈ 111 km)
      const almostThere = LatLng(9.6091, 125.6374);
      // ~111 m sa hilaga
      const tooFar = LatLng(9.6097, 125.6374);
      expect(isWithinArrivalRadius(pickup, pickup), isTrue);
      expect(isWithinArrivalRadius(pickup, almostThere), isTrue);
      expect(isWithinArrivalRadius(pickup, tooFar), isFalse);
    });

    test('estimateEtaSeconds: skala sa layo at may 1-minutong minimum', () {
      const pickup = LatLng(9.6087, 125.6374);
      // Saglit na lakad → naka-clamp sa 60 s
      final short = estimateEtaSeconds(
        from: pickup,
        to: const LatLng(9.6088, 125.6374),
      );
      expect(short, 60);
      // ~1 km pataas sa 18 km/h → ~3.3 min
      final longer = estimateEtaSeconds(
        from: pickup,
        to: const LatLng(9.6177, 125.6374),
        speedKmh: 18,
      );
      expect(longer, greaterThan(short));
      expect(longer, greaterThanOrEqualTo(180));
      expect(longer, lessThanOrEqualTo(260));
    });

    test('routeDistanceMeters: 0 kapag kulang sa 2 puntos', () {
      expect(routeDistanceMeters([]), 0);
      expect(routeDistanceMeters([const LatLng(9.6087, 125.6374)]), 0);
      final d = routeDistanceMeters([
        const LatLng(9.6087, 125.6374),
        const LatLng(9.6177, 125.6374),
      ]);
      expect(d, greaterThan(900));
      expect(d, lessThan(1100));
    });
  });

  group('Rider tracking helpers', () {
    test('activeForRider: hindi kasama ang pending na wala pang rider', () {
      BookingStore()
        ..addBooking(makeBooking(id: 'BK-1')) // pending, walang rider
        ..addBooking(makeBooking(
          id: 'BK-2',
          status: 'accepted',
          riderName: 'Kuya Juan (Verified)',
        ));
      final trip = BookingStore().activeForRider('Kuya Juan (Verified)');
      expect(trip, isNotNull);
      expect(trip!.id, 'BK-2');
      expect(BookingStore().activeForRider('Iba Pang Rider'), isNull);
    });

    test('updateStatus: nagse-set ng riderLocation at rider', () {
      BookingStore().addBooking(makeBooking());
      BookingStore().updateStatus(
        'BK-1',
        'accepted',
        riderName: 'Kuya Juan (Verified)',
      );
      final b = BookingStore().bookings.first;
      expect(b.status, 'accepted');
      expect(b.riderName, 'Kuya Juan (Verified)');
      expect(b.riderLocation, isNotNull);
      // Tinitiyak na nasa loob ng Bacuag ang placehold na posisyon
      // (pickup + ~0.008°) para hindi maligaw ang marker ng pasahero.
      expect(bacuagBounds.contains(b.riderLocation!), isTrue);
      // Hindi namin inaasertan ang routePoints dito: asinkrono iyon at
      // umaasa sa network (OSRM) — sakop iyon ng E2E verification.
    });
  });

  group('Route persistence (ang natutunang kalsada ay nababawi offline)', () {
    test('toJson/fromJson roundtrip: nasa buong ruta, pati ang hindi pa tapos', () {
      final b = makeBooking(status: 'on_the_way')
        ..riderLocation = const LatLng(9.6100, 125.6400)
        ..routePoints = const [
          LatLng(9.6100, 125.6400),
          LatLng(9.6112, 125.6421),
          LatLng(9.6150, 125.6450),
        ];
      final restored = BookingItem.fromJson(b.toJson());
      expect(restored.routePoints, hasLength(3));
      expect(restored.routePoints.first.latitude, closeTo(9.6100, 1e-9));
      expect(restored.routePoints.last.longitude, closeTo(125.6450, 1e-9));
      // Walang ibang field ang naapektuhan ng bagong serialization.
      expect(restored.id, b.id);
      expect(restored.status, 'on_the_way');
      expect(restored.riderLocation, isNotNull);
    });

    test('luma na JSON (walang routePoints key) ay hindi nagta-throw', () {
      final old = makeBooking().toJson()..remove('routePoints');
      final restored = BookingItem.fromJson(old);
      expect(restored.routePoints, isEmpty);
      expect(restored.pickup.latitude, closeTo(9.6087, 1e-9));
    });

    test('muling nai-save at nababasa ang store: buhay pa rin ang ruta offline', () async {
      BookingStore().bookings.clear();
      final b = makeBooking(status: 'arrived')
        ..routePoints = const [LatLng(9.6087, 125.6374), LatLng(9.6150, 125.6450)];
      BookingStore().addBooking(b);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('sakay_bookings_v1');
      expect(raw, isNotNull, reason: 'dapat naka-save ang bookings');
      final decoded = (jsonDecode(raw!) as List).cast<Map<String, dynamic>>();
      final restored = BookingItem.fromJson(decoded.first);
      expect(restored.routePoints, hasLength(2));
      expect(restored.routePoints.last.latitude, closeTo(9.6150, 1e-9));
    });
  });
}
