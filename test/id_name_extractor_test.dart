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
    // Walang middle name (SANTOS) — given + apelyido lang ang Buong Pangalan.
    expect(extractNameFromId(ocr), 'Juan Dela Cruz');
  });

  test('National ID: nasa kaparehong linya ang label at halaga', () {
    const ocr = '''
PHILIPPINE IDENTIFICATION CARD
SURNAME: REYES
GIVEN NAME: MARIA CLARA
MIDDLE NAME: GONZALES
POBLACION BACUAG
''';
    expect(extractNameFromId(ocr), 'Maria Clara Reyes');
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
    expect(extractNameFromId(ocr), 'Arnold Paglinawan');
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
    expect(extractNameFromId(ocr), 'Arnold Paglinawan');
  });

  test('PhilID na nasa kaparehong linya ang label at halaga', () {
    const ocr = '''
APELYIDO / LAST NAME PAGLINAWAN
MGA PANGALAN / GIVEN NAMES ARNOLD
GITNANG APELYIDO / MIDDLE NAME GORGONIO
POBLACION, BACUAG
''';
    expect(extractNameFromId(ocr), 'Arnold Paglinawan');
  });

  test('OCR garbage ay hindi nagiging pangalan (all-caps lamang)', () {
    // Ito ang aktwal na maling output bago ang fix.
    expect(extractNameFromId('Bd Raveansanc Ckakakiialay Y.'), isNull);
  });

  test('Aktwal na OCR ng PhilID photo (may guhit/noise) — hindi na basura', () {
    // Eksaktong kopya ng nabasa ng OCR sa totoong litrato ng ID. Bago ang fix
    // ay "Wl I Srsa Names No X." ang na-fill — basura mula sa linyang
    // "No x , Wl i SRSA NAMES : >" na hindi all-caps.
    const ocr = '''
Seo] REPUBLIKA NG PILIPINAS =u
Bd raveansanc ckakakiiAlay  (@Y
9259-0897-62364- od i APELYIDO/LAST NAME | i il i . n
Re BRAT) 0 PAGLINAWAN Hi j [m] [m]
Ned i Re ER |
No x , Wl i SRSA NAMES : >
NER . //1& ARNOLD il "Le, 7 oJ
NZS J of
NS X 4 GITNANG APELYIDO/MIDDLE NAME [mu] n
NEON i y
Vo _ Ii, CORGONID TL
TIRAHAN/ADDRESS
P-MACAPAGAL, POBLACION, BACUAG,SURIGAO DEL
NORTE, PHILIPPINES, 8408
''';
    // Kahit maling basa ng OCR ang apelyido (CORGONID), given + apelyido lang
    // ang ibinabalik — walang middle name.
    expect(extractNameFromId(ocr), 'Arnold Paglinawan');
  });

  group('namesMatchId — given name + apelyido lang ang hinihinging tugma', () {
    test('tumutugma kahit may middle name ang naka-type', () {
      expect(namesMatchId('Arnold C. Paglinawan', 'Arnold Paglinawan'), isTrue);
      expect(namesMatchId('Arnold Gorgonio Paglinawan', 'Arnold Paglinawan'), isTrue);
    });

    test('tumutugma kahit iba ang case / tuldok', () {
      expect(namesMatchId('ARNOLD  paglinawan', 'Arnold Paglinawan'), isTrue);
      expect(namesMatchId("Juan Dela-Cruz", "Juan Dela Cruz"), isTrue);
    });

    test('hindi tumutugma kapag iba ang apelyido o given name', () {
      expect(namesMatchId('Arnold Reyes', 'Arnold Paglinawan'), isFalse);
      expect(namesMatchId('Maria Paglinawan', 'Arnold Paglinawan'), isFalse);
      expect(namesMatchId('Paglinawan', 'Arnold Paglinawan'), isFalse); // kulang
      expect(namesMatchId('', 'Arnold Paglinawan'), isFalse);
    });
  });
}
