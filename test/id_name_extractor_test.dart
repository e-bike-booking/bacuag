import 'package:flutter_test/flutter_test.dart';
import 'package:sakay_bacuag/main.dart';

void main() {
  test('National ID (PhilID): magkahiwalay na linya ang label at halaga', () {
    const ocr = '''
REPUBLIKA NG PILIPINAS
PHILIPPINE IDENTIFICATION CARD
SURNAME
DELA CRUZ
GIVEN NAME
JUAN
MIDDLE NAME
SANTOS
Address: POBLACION, BACUAG, SURIGAO DEL NORTE
''';
    expect(extractNameFromId(ocr), 'Juan Santos Dela Cruz');
  });

  test('National ID: nasa kaparehong linya ang label at halaga', () {
    const ocr = '''
PHILIPPINE IDENTIFICATION CARD
SURNAME: REYES
GIVEN NAME: MARIA CLARA
MIDDLE NAME: GONZALES
POBLACION BACUAG
''';
    expect(extractNameFromId(ocr), 'Maria Clara Gonzales Reyes');
  });

  test("Voter's Certification: NAME: prefix", () {
    const ocr = '''
COMMISSION ON ELECTIONS
VOTER CERTIFICATION
NAME: JUAN M. DELA CRUZ
PRECINCT 001-A
POBLACION, BACUAG
''';
    expect(extractNameFromId(ocr), 'Juan M. Dela Cruz');
  });

  test("COMELEC ID format: APELYIDO, PANGALAN (may gitnit)", () {
    const ocr = '''
COMMISSION ON ELECTIONS
VOTER'S ID
DELA CRUZ, JUAN SANTOS
BACUAG, SURIGAO DEL NORTE
''';
    expect(extractNameFromId(ocr), 'Juan Santos Dela Cruz');
  });

  test('hindi pinipili ang header/address lines bilang pangalan', () {
    const addressOnly = '''
REPUBLIKA NG PILIPINAS
PHILIPPINE IDENTIFICATION CARD
Address: POBLACION, BACUAG, SURIGAO DEL NORTE
''';
    expect(extractNameFromId(addressOnly), isNull);
    expect(extractNameFromId(''), isNull);
    expect(extractNameFromId('   '), isNull);
  });

  test('mga numero/ID codes ay hindi nagiging pangalan', () {
    const withCodes = '''
PCN 1234-5678-9012-3456
1234 5678 9012
''';
    expect(extractNameFromId(withCodes), isNull);
  });
}
