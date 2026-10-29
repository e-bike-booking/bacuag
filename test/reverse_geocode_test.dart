import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sakay_bacuag/main.dart';

void main() {
  group('placeNameFromNominatim', () {
    test('pinipili ang road name kaysa sa ibang address field', () {
      final name = placeNameFromNominatim({
        'address': {'road': 'Rizal Street', 'suburb': 'Poblacion', 'city': 'Bacuag'},
      });
      expect(name, 'Rizal Street');
    });

    test('bumabagsak sa pinakamalapit na lugar kapag walang road name', () {
      final name = placeNameFromNominatim({
        'address': {'suburb': 'Poblacion', 'village': 'Siwata'},
      });
      expect(name, 'Poblacion');
    });

    test('tinitinagg ang whitespace sa napiling value', () {
      final name = placeNameFromNominatim({
        'address': {'road': '  Rizal St  '},
      });
      expect(name, 'Rizal St');
    });

    test('ginagamit ang pedestrian/footway kapag iyon ang ibinigay', () {
      final name = placeNameFromNominatim({
        'address': {'pedestrian': 'Baywalk'},
      });
      expect(name, 'Baywalk');
    });

    test('walang laman, empty, at hindi tamang uri ay nagbibigay ng null', () {
      expect(placeNameFromNominatim(null), isNull);
      expect(placeNameFromNominatim('Rizal Street'), isNull);
      expect(placeNameFromNominatim(<String, dynamic>{}), isNull);
      expect(placeNameFromNominatim({'address': 'Rizal Street'}), isNull);
      expect(placeNameFromNominatim({'address': <String, dynamic>{}}), isNull);
      // Walang anumang mapagpipiliang field.
      expect(
        placeNameFromNominatim({
          'address': <String, dynamic>{'country': 'Philippines'},
        }),
        isNull,
      );
      // Blankong string ay hindi itinuturing na sagot.
      expect(
        placeNameFromNominatim({
          'address': <String, dynamic>{'road': '   '},
        }),
        isNull,
      );
    });

    test('umiikot sa mga pangalan ng Poblacion Bacuag kung wala talagang kalye', () {
      final name = placeNameFromNominatim({
        'address': {'neighbourhood': 'Poblacion', 'city': 'Bacuag'},
      });
      expect(name, 'Poblacion');
    });
  });

  group('routeCacheKey (offline road-route cache)', () {
    test('pareho ang key kapag magkapareho ang mga punto', () {
      const a = LatLng(9.6078, 125.6396);
      const b = LatLng(9.6150, 125.6450);
      expect(
        BookingStore.routeCacheKey(a, b),
        BookingStore.routeCacheKey(a, b),
      );
    });

    test('magkaiba ang key kapag magkaiba ang direction (start→end ≠ end→start)',
        () {
      const a = LatLng(9.6078, 125.6396);
      const b = LatLng(9.6150, 125.6450);
      expect(
        BookingStore.routeCacheKey(a, b),
        isNot(BookingStore.routeCacheKey(b, a)),
      );
    });

    test('magkaiba ang key kapag magkaiba ang lugar', () {
      expect(
        BookingStore.routeCacheKey(
          const LatLng(9.6078, 125.6396),
          const LatLng(9.6150, 125.6450),
        ),
        isNot(
          BookingStore.routeCacheKey(
            const LatLng(9.6078, 125.6396),
            const LatLng(9.6300, 125.6600),
          ),
        ),
      );
    });

    test('nagpapatawad sa ~11 m na pagkakaiba ng GPS (4-decimal rounding)', () {
      // Parehong ruta ito, pero magkaiba nang kaunti ang eksaktong GPS fix ng
      // destination sa dalawang pagkakataong pinili ng pasahero.
      const start = LatLng(9.6000, 125.6300);
      const destFix1 = LatLng(9.61501, 125.64501);
      const destFix2 = LatLng(9.61504, 125.64504);
      expect(
        BookingStore.routeCacheKey(start, destFix1),
        BookingStore.routeCacheKey(start, destFix2),
      );
    });
  });
}
