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

  test('Makabagong PhilID: APELYIDO / MGA PANGALAN / GITNANG APELYIDO', () {
    // Eksaktong layout ng bagong PhilID — walang SURNAME/GIVEN NAME na label,
    // kaya dating bumabagsak ito sa fallback at napipili ang OCR garbage.
    const ocr = '''
REPUBLIKA NG PILIPINAS
Republic of the Philippines
PAMBANSANG PAGKAKAKILANLAN
Philippine National ID
APELYIDO / LAST NAME
PAGLINAWAN
MGA PANGALAN / GIVEN NAMES
ARNOLD
GITNANG APELYIDO / MIDDLE NAME
GORGONIO
PETSA NG KAPANGANAKAN / DATE OF BIRTH
April 01, 1989
TIRAHAN/ADDRESS
P-MACAPAGAL, POBLACION, BACUAG, SURIGAO DEL NORTE, PHILIPPINES, 8408
''';
    expect(extractNameFromId(ocr), 'Arnold Gorgonio Paglinawan');
  });

  test('PhilID na may OCR noise sa label (APELYDO, PANGALAN)', () {
    const ocr = '''
APELYDO / LAST NAME
PAGLINAWAN
MGA PANGALAN / GIVEN NAMES
ARNOLD
GITNANG APELYDO / MIDDLE NAME
GORGONIO
POBLACION, BACUAG
''';
    expect(extractNameFromId(ocr), 'Arnold Gorgonio Paglinawan');
  });

  test('PhilID na nasa kaparehong linya ang label at halaga', () {
    const ocr = '''
APELYIDO / LAST NAME PAGLINAWAN
MGA PANGALAN / GIVEN NAMES ARNOLD
GITNANG APELYIDO / MIDDLE NAME GORGONIO
POBLACION, BACUAG
''';
    expect(extractNameFromId(ocr), 'Arnold Gorgonio Paglinawan');
  });

  test('OCR garbage ay hindi nagiging pangalan (all-caps lamang)', () {
    // Ito ang aktwal na maling output bago ang fix.
    expect(extractNameFromId('Bd Raveansanc Ckakakiialay Y.'), isNull);
  });
}
