import 'package:flutter_test/flutter_test.dart';
import 'package:sakay_bacuag/main.dart';

void main() {
  const nationalId = 'National ID';
  const voterId = 'Voter ID';

  // Roughly what ML Kit reads from the front of a PhilID.
  const philIdText = '''
REPUBLIC OF THE PHILIPPINES
PHILIPPINE IDENTIFICATION CARD
PCN 1234 5678 9012
SURNAME: DELA CRUZ
GIVEN NAME: MARIA
MIDDLE NAME: SANTOS
DATE OF BIRTH: 01 JAN 1990
ADDRESS: BRGY. POBLACION, BACUAG, SURIGAO DEL NORTE
''';

  // Roughly what ML Kit reads from a COMELEC Voter's ID.
  const voterIdText = '''
COMMISSION ON ELECTIONS
VOTER'S ID
VIN 12345678
PRECINCT: 001A
ADDRESS: POBLACION, BACUAG, SURIGAO DEL NORTE
''';

  group('evaluateIdText', () {
    test('approves a National ID whose address is Poblacion, Bacuag', () {
      final result = evaluateIdText(philIdText, nationalId);
      expect(result.valid, isTrue);
      expect(result.detectedIdType, nationalId);
      expect(result.message, contains('Beripikado'));
    });

    test('approves a Voter ID whose address is Poblacion, Bacuag', () {
      final result = evaluateIdText(voterIdText, voterId);
      expect(result.valid, isTrue);
      expect(result.detectedIdType, voterId);
    });

    test('rejects an ID whose address is outside Bacuag', () {
      const other = '''
REPUBLIC OF THE PHILIPPINES
PHILIPPINE IDENTIFICATION CARD
ADDRESS: BRGY. MAHAYAHAY, CEBU CITY
''';
      final result = evaluateIdText(other, nationalId);
      expect(result.valid, isFalse);
      expect(result.message, contains("'Bacuag'"));
    });

    test('rejects a Bacuag address that is not Poblacion', () {
      const other = '''
COMMISSION ON ELECTIONS
VOTER'S ID
ADDRESS: BRGY. SAN ROQUE, BACUAG, SURIGAO DEL NORTE
''';
      final result = evaluateIdText(other, voterId);
      expect(result.valid, isFalse);
      expect(result.message, contains("ang 'Poblacion'"));
    });

    test('rejects a document that mentions Bacuag but is not an ID', () {
      const other = '''
BARANGAY CLEARANCE
This is to certify that the above named is a resident of
POBLACION, BACUAG, SURIGAO DEL NORTE
''';
      final result = evaluateIdText(other, nationalId);
      expect(result.valid, isFalse);
      expect(result.message, contains('Hindi makilala'));
    });

    test('rejects a real ID when the selected ID type does not match', () {
      final result = evaluateIdText(philIdText, voterId);
      expect(result.valid, isFalse);
      expect(result.message, contains(nationalId));
    });

    test('tolerates common OCR mistakes in the address', () {
      const noisy = '''
PHILIPPINE IDENTIFICATION CARD
ADDRESS: POBLAC10N, BACUACJ, SURIGAO DEL NORTE
''';
      final result = evaluateIdText(noisy, nationalId);
      expect(result.valid, isTrue);
    });

    test('rejects an empty scan', () {
      final result = evaluateIdText('', nationalId);
      expect(result.valid, isFalse);
      expect(result.message, contains('Walang nabasang text'));
    });
  });
}
