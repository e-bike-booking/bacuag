import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:geolocator/geolocator.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_tiles.dart';

// After running `flutterfire configure`, uncomment these lines:
// import 'package:firebase_core/firebase_core.dart';
// import 'firebase_options.dart';

const emerald = Color(0xFF087F5B);

// Sakop ng mapa: ang eksaktong service area na ibinigay ng LGU (5 hangganan)
// sa Poblacion, Bacuag. Bahagyang parisukat ito — mas mataas sa hilaga at mas
// malayo sa kanluran kaysa sa dating ±0.0103° na bilog sa sentro.
//
// Dahil dito HINDI na makikita sa map ang Boyongan, Pananay-an, Campo, Cabugao
// at ibang lugar na walang kinalaman sa serbisyo — hindi lang ito camera
// constraint, ito rin ang geofence ng GPS auto-pin at ng booking.
//
// Mga hangganan (lat, lng):
//   9.602836630516139, 125.64657650941132
//   9.599719327719372, 125.64461871475464
//   9.605450258590752, 125.63615421842985
//   9.60949587481933,  125.63426418140286
//   9.623381167347054, 125.62649076846351
const _serviceAreaSouth = 9.599719327719372;
const _serviceAreaWest = 125.626490768463512;
const _serviceAreaNorth = 9.623381167347054;
const _serviceAreaEast = 125.646576509411318;

final bacuagBounds = LatLngBounds(
  LatLng(_serviceAreaSouth, _serviceAreaWest),
  LatLng(_serviceAreaNorth, _serviceAreaEast),
);

// URL template ng OSM street tiles (ang "street view" na lansangan ng app).
const osmTileUrlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
// Libreng Esri World Imagery satellite tiles — walang API key na kailangan.
const esriSatelliteUrlTemplate =
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
// Transparentong label overlay (pangalan ng lansangan) para basahin pa rin
// ang kalye kapag naka-satellite view.
const esriLabelsUrlTemplate =
    'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}';
// Ginagamit ng mga FlutterMap ang containCenter() (hindi contain()) dahil ang
// contain() ay bumabalik ng null kapag mas malaki ang map viewport kaysa sa
// bacuagBounds — hal. sa tablet o malaking screen — na nagiging sanhi ng
// "MapCamera is no longer within the cameraConstraint" assertion. Ang pag-throw
// na iyon sa loob ng ListView rebuild ang nagiging sanhi ng pula'ng
// 'child == null || indexOf(child) > index' na render error sa Passenger screen.

List<LatLng> getRoadRoutePoints(LatLng start, LatLng end) {
  // Simulate actual road turns (grid layout along streets in Bacuag Poblacion)
  final corner = LatLng(end.latitude, start.longitude);
  return [start, corner, end];
}

// ---------------------------------------------------------------------------
// Route / arrival helpers (pure functions — tinetest sa unit tests)
// ---------------------------------------------------------------------------

/// Kabuuang haba ng ruta (meters) mula sa listahan ng polyline points.
double routeDistanceMeters(List<LatLng> points) {
  if (points.length < 2) return 0;
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += Geolocator.distanceBetween(
      points[i - 1].latitude,
      points[i - 1].longitude,
      points[i].latitude,
      points[i].longitude,
    );
  }
  return total;
}

/// ETA hanggang sa target, sa SECONDS, batay sa totoong haba ng ruta
/// (kapag wala pang ruta, ang direct distance). E-sikad pace: ~18 km/h.
int estimateEtaSeconds({
  required LatLng from,
  required LatLng to,
  List<LatLng> routePoints = const [],
  double speedKmh = 18,
}) {
  var meters = routeDistanceMeters(routePoints);
  if (meters < 1) {
    meters = Geolocator.distanceBetween(
      from.latitude,
      from.longitude,
      to.latitude,
      to.longitude,
    );
  }
  final hours = (meters / 1000) / speedKmh;
  final seconds = (hours * 3600).round();
  return seconds < 60 ? 60 : seconds; // pinakamababa: 1 minuto
}

/// true kapag nasa loob na ng arrival radius (default 45 m) ang dalawang point.
bool isWithinArrivalRadius(LatLng a, LatLng b, {double meters = 45}) {
  return Geolocator.distanceBetween(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      ) <=
      meters;
}

/// 'HH:mm a' na format ng booking time (hal. 4:32 PM).
String formatBookingTime(DateTime time) {
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final minute = time.minute.toString().padLeft(2, '0');
  final suffix = time.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $suffix';
}

/// mm:ss countdown mula sa natitirang segundo.
String formatCountdown(int totalSeconds) {
  final s = totalSeconds < 0 ? 0 : totalSeconds;
  final m = s ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return '$m:$sec';
}

/// Distansya para sa UI: '850 m' o '1.24 km'.
String formatDistanceMeters(double meters) => meters < 1000
    ? '${meters.round()} m'
    : '${(meters / 1000).toStringAsFixed(2)} km';

/// '📏 1.24 km • ⏱ ~4 min' — sukat ng distansya at estimated travel time
/// (e-sikad pace ~18 km/h; direct distance kapag walang ruta pa).
String measureTravelLabel(LatLng from, LatLng to) {
  final meters = Geolocator.distanceBetween(
    from.latitude,
    from.longitude,
    to.latitude,
    to.longitude,
  );
  final eta = estimateEtaSeconds(from: from, to: to, routePoints: const []);
  final minutes = (eta / 60).ceil();
  return '📏 ${formatDistanceMeters(meters)} • ⏱ ~$minutes min';
}

// ----------------------------------------------------------------------------
// Reverse geocode: pangalan ng kalye para sa pickup pin (Nominatim / OSM)
// ----------------------------------------------------------------------------

/// Minimal na User-Agent na hinihingi ng Nominatim usage policy.
const nominatimUserAgent = 'E-Bike/0.2 (Flutter; openstreetmap.org)';

/// Ini-extract ang pinakamagandang pangalan ng lugar mula sa Nominatim
/// reverse-geocode na sagot. Pure function — tinetest sa unit tests.
///
/// Prayoridad: pangalan ng kalye muna (`road`), tapos ang iba pang lugar na
/// ginagamit bilang patnubay kapag walang road name sa rural na lugar
/// (neighbourhood / suburb / village). `null` kapag walang gamit na laman.
String? placeNameFromNominatim(Object? body) {
  if (body is! Map<String, dynamic>) return null;
  final address = body['address'];
  if (address is! Map) return null;
  const keys = [
    'road',
    'pedestrian',
    'footway',
    'neighbourhood',
    'suburb',
    'village',
    'hamlet',
    'city',
  ];
  for (final k in keys) {
    final v = address[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

/// Pangalan ng kalye sa isang punto. `null` kapag offline, nag-timeout, o
/// walang pangalan ang lugar — HINDI kailanman nagta-throw, kaya ligtas
/// tawagin sa likod ng UI nang walang try/catch.
Future<String?> reverseGeocodeStreet(
  LatLng point, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final url = Uri.parse(
    'https://nominatim.openstreetmap.org/reverse?format=jsonv2'
    '&lat=${point.latitude}&lon=${point.longitude}&zoom=18&addressdetails=1',
  );
  try {
    final resp = await http
        .get(url, headers: {'User-Agent': nominatimUserAgent})
        .timeout(timeout);
    if (resp.statusCode != 200) return null;
    return placeNameFromNominatim(json.decode(resp.body));
  } catch (_) {
    return null;
  }
}

/// Iniisang cache ng street name sa buong app — GAANAP NAGAGAMIT ng PASAHERO
/// at ng RIDER (dating hiwalay ang passenger, kaya hindi nakikita ng rider).
/// Key = 4-decimal na lugar (~11 m), kaya iisang tawag lang bawat lugar.
final Map<String, String?> _streetNameCache = {};

/// Ang na-caching na street name sa pamamagitan ng 4-decimal na key.
String _streetKeyFor(LatLng p) =>
    '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}';

/// Street name sa cache, o kukunin ito kapag wala pa. `null` kapag offline o
/// walang pangalan — HINDI kailanman nagta-throw.
Future<String?> lookupStreetName(LatLng p) async {
  final key = _streetKeyFor(p);
  if (_streetNameCache.containsKey(key)) return _streetNameCache[key];
  final v = await reverseGeocodeStreet(p);
  _streetNameCache[key] = v;
  return v;
}

/// Synchronous na pagbabasa ng cache (walang network) — ginagamit sa panahon
/// ng build para hindi maantala ang UI. `null` kapag hindi pa na-fetch.
String? cachedStreetName(LatLng p) => _streetNameCache[_streetKeyFor(p)];

// ⏱ AUTO-CANCEL: kung walang rider na nagtanggap sa loob ng 10 minuto,
// awtomatikong kinakansela ang pending booking.
const pendingAutoCancelTimeout = Duration(minutes: 10);

/// true kapag dapat nang awtomatikong i-cancel ang booking — pending pa at
/// lampas na sa 10 minutong paghihintay (tinetest sa unit tests).
bool isPendingAutoCancelDue(
  BookingItem b, {
  DateTime? now,
  Duration timeout = pendingAutoCancelTimeout,
}) {
  if (b.status != 'pending') return false;
  return (now ?? DateTime.now()).difference(b.createdAt) >= timeout;
}

/// Natitirang segundo (mm:ss countdown) bago ma-auto-cancel ang booking.
/// 0 kapag hindi pending o lampas na sa timeout.
int pendingAutoCancelRemainingSeconds(BookingItem b, {DateTime? now}) {
  if (b.status != 'pending') return 0;
  final elapsed = (now ?? DateTime.now()).difference(b.createdAt).inSeconds;
  final left = pendingAutoCancelTimeout.inSeconds - elapsed;
  return left < 0 ? 0 : left;
}

/// Mga tile layer ng map ayon sa mode: OSM lansangan (street view), o
/// Esri satellite na may transparentong label overlay.
List<Widget> mapTileLayers({required bool satellite}) => [
      TileLayer(
        urlTemplate: satellite ? esriSatelliteUrlTemplate : osmTileUrlTemplate,
        userAgentPackageName: 'ph.sakaybacuag.app',
        // z19 ang pinakamalalim na totoong tile ng OSM/Esri sa Poblacion —
        // lampas diyan ay i-scale-up na lang ang z19 tile, kaya hindi na
        // naghahanap ng kulang na tile at nawawala ang "Map data not yet
        // available" na mensahe kapag naka-zoom in ang user.
        maxNativeZoom: 19,
      ),
      if (satellite)
        TileLayer(
          urlTemplate: esriLabelsUrlTemplate,
          userAgentPackageName: 'ph.sakaybacuag.app',
          maxNativeZoom: 19,
        ),
    ];

/// Maliit na pindutan sa sulok ng map para lumipat sa satellite view (at
/// balik sa lansangan). Para sa 3D-look: i-rotate lang ang map gamit ang
/// dalawang daliri habang naka-satellite.
Widget mapModeToggle({
  required bool satellite,
  required VoidCallback onPressed,
}) =>
    Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Material(
          color: Colors.white.withValues(alpha: 0.92),
          elevation: 2,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                satellite ? Icons.map_outlined : Icons.satellite_alt,
                size: 20,
                color: emerald,
              ),
            ),
          ),
        ),
      ),
    );

// ---------------------------------------------------------------------------
// ID verification (on-device ML Kit OCR)
//
// Scans the real text printed on the uploaded ID and only approves it when:
//  1. the address field reads POBLACION + BACUAG, and
//  2. the card is recognizable as either a National ID or a Voter's ID.
// ---------------------------------------------------------------------------

class IdScanResult {
  final bool valid;
  final String message;
  final String? detectedIdType;

  /// BuongOCR text ng ID — ginagamit para auto-fill ang pangalan mula sa ID.
  final String rawText;

  const IdScanResult({
    required this.valid,
    required this.message,
    this.detectedIdType,
    this.rawText = '',
  });
}

/// Markers printed on the PhilID (national ID) card header.
const nationalIdMarkers = <String>[
  'PHILIPPINE IDENTIFICATION CARD',
  'PHILIPPINE IDENTIFICATION',
  'PHILSYS',
  'PHIL ID',
  'PHILID',
  'PCN',
];

/// Markers printed on the COMELEC Voter's ID / Voter's Certification.
const voterIdMarkers = <String>[
  'COMMISSION ON ELECTIONS',
  'COMELEC',
  'VOTER S ID',
  'VOTERS ID',
  'VOTER ID',
  'VOTER S IDENTIFICATION',
  'PRECINCT',
];

/// Uppercase, strip punctuation (incl. apostrophes), collapse whitespace.
String normalizeOcr(String input) {
  var text = input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9\s]'), ' ');
  text = text.replaceAll(RegExp(r'\s+'), ' ');
  return text.trim();
}

int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var curr = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var best = curr[j - 1] + 1;
      final del = prev[j] + 1;
      if (del < best) best = del;
      final sub = prev[j - 1] + cost;
      if (sub < best) best = sub;
      curr[j] = best;
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[b.length];
}

/// Looks for [word] in OCR output, tolerating small OCR mistakes
/// (e.g. POBLAC10N, BACUACJ) with up to [tolerance] edits per token.
bool containsWord(String normalizedText, String word, {int tolerance = 2}) {
  if (normalizedText.contains(word)) return true;
  for (final token in normalizedText.split(' ')) {
    if ((token.length - word.length).abs() > tolerance) continue;
    if (levenshtein(token, word) <= tolerance) return true;
  }
  return false;
}

bool hasMarker(String normalizedText, String marker) {
  if (marker.contains(' ')) return normalizedText.contains(marker);
  return containsWord(normalizedText, marker);
}

String textSnippet(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return '(walang nabasang text)';
  return flat.length <= 110 ? flat : '${flat.substring(0, 110)}...';
}

/// Reads the printed address line(s) that mention Poblacion or Bacuag.
String? describeAddress(RecognizedText recognized) {
  final hits = <String>[];
  for (final block in recognized.blocks) {
    for (final line in block.lines) {
      final normalized = normalizeOcr(line.text);
      if (containsWord(normalized, 'POBLACION') || containsWord(normalized, 'BACUAG')) {
        final value = line.text.trim();
        if (value.isNotEmpty && !hits.contains(value)) hits.add(value);
      }
    }
  }
  if (hits.isEmpty) return null;
  return hits.take(2).join(' | ');
}

// ---------------------------------------------------------------------------
// Auto-fill ng pangalan mula sa na-scan na ID (OCR)
//
// Kinukuha ang tunay na pangalan na naka-print sa ID at ibinabalik ito sa
// normal na anyo ("Juan M. Santos") para auto-fill ang Buong Pangalan field —
// para sa mga taong hindi tamang nilalagay ang pangalan nila sa form.
// ---------------------------------------------------------------------------

String _titleCaseName(String s) => s
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .map((w) => w
        .split('-')
        .map((p) => p.isEmpty
            ? p
            : p[0].toUpperCase() + p.substring(1).toLowerCase())
        .join('-'))
    .join(' ');

/// Kinukuha ang tunay na pangalan mula sa OCR text ng ID.
/// Pure logic — walang ML Kit, kaya unit-testable. Null kapag walang mahanap.
String? extractNameFromId(String rawText) {
  if (rawText.trim().isEmpty) return null;
  final lines = rawText
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  String clean(String s) =>
      s.replaceAll(RegExp(r"[^A-Za-z .,'-]"), '').trim();

  // 1–4 salitang purong titik lang (walang numero o ID codes).
  bool looksLikeNameValue(String s, {int minWords = 1}) {
    final c = clean(s);
    if (c.isEmpty) return false;
    final words =
        c.split(RegExp(r'[\s,]+')).where((w) => w.isNotEmpty).toList();
    if (words.length < minWords || words.length > 4) return false;
    return words.every(RegExp(r"^[A-Za-z][A-Za-z.'-]*$").hasMatch);
  }

  // Mga linya na hindi pangalan (header, label, address, atbp.).
  final blocklist = RegExp(
    r'REPUBLIKA|REPUBLIC|PILIPINAS|PHILIPPINES|PHILIPPINE|IDENTIFICATION|IDENTITY|AUTHORITY|STATISTICS|CARD|DATE|BIRTH|SEX|GENDER|CITIZEN|NATIONALITY|ADDRESS|POBLACION|BACUAG|SURIGAO|DEL NORTE|FILIPINO|MALE|FEMALE|PHOTO|SIGNATURE|SPECIMEN|COMMISSION|ELECTION|VOTER|REGISTRATION|PRECINCT|SERIES|FILE NO|SURNAME|GIVEN|FIRST NAME|MIDDLE NAME',
    caseSensitive: false,
  );

  // 1) National ID (PhilID): magkahiwalay na linya ang label at halaga —
  //    SURNAME / GIVEN NAME (FIRST NAME) / MIDDLE NAME.
  String? surname;
  String? given;
  String? middle;
  String? valueAfter(int labelIndex) {
    for (var k = labelIndex + 1;
        k < lines.length && k <= labelIndex + 2;
        k++) {
      if (blocklist.hasMatch(lines[k].toUpperCase())) return null;
      final cand = clean(lines[k]);
      if (cand.isNotEmpty && looksLikeNameValue(cand)) return cand;
    }
    return null;
  }

  // Halaga na nasa KAPAREHONG linya ng label ("SURNAME: DELA CRUZ").
  String? sameLineValue(String u, String labelPattern) {
    final m = RegExp('^$labelPattern\\s*[:\\-]?\\s*(.*)\$').firstMatch(u);
    if (m == null) return null;
    // Ang huling group ang laging halaga (may mga label na may sariling
    // capture group, hal. "(GIVEN|FIRST)\\s*NAME").
    final cand = clean(m.group(m.groupCount) ?? '');
    return (cand.isNotEmpty && looksLikeNameValue(cand)) ? cand : null;
  }

  for (var i = 0; i < lines.length; i++) {
    final u = lines[i].toUpperCase();
    if (RegExp(r'^SURNAME').hasMatch(u)) {
      surname ??= sameLineValue(u, r'SURNAME') ?? valueAfter(i);
    }
    if (RegExp(r'^(GIVEN|FIRST)\s*NAME').hasMatch(u)) {
      given ??= sameLineValue(u, r'(GIVEN|FIRST)\s*NAME') ?? valueAfter(i);
    }
    if (RegExp(r'^MIDDLE\s*NAME').hasMatch(u)) {
      middle ??= sameLineValue(u, r'MIDDLE\s*NAME') ?? valueAfter(i);
    }
  }
  if (given != null && surname != null) {
    final full = [
      given,
      if (middle != null && middle.isNotEmpty) middle,
      surname,
    ].join(' ');
    return _titleCaseName(full);
  }

  // 2) "NAME: JUAN SANTOS DELA CRUZ" (Voter's Certification at iba pang ID).
  for (final l in lines) {
    final m =
        RegExp(r'^NAME\s*[:\-]\s*(.+)$', caseSensitive: false).firstMatch(l);
    if (m != null) {
      final cand = clean(m.group(1)!);
      if (looksLikeNameValue(cand)) return _titleCaseName(cand);
    }
  }

  // 3) Fallback: "DELA CRUZ, JUAN SANTOS" (COMELEC) o simpleng buong pangalan.
  for (final l in lines) {
    if (blocklist.hasMatch(l.toUpperCase())) continue;
    final comma = l.split(',');
    if (comma.length >= 2) {
      final last = clean(comma[0]);
      final rest = clean(comma.sublist(1).join(' '));
      if (looksLikeNameValue(last, minWords: 2) &&
          looksLikeNameValue(rest, minWords: 2)) {
        return _titleCaseName('$rest $last');
      }
    }
    if (looksLikeNameValue(l, minWords: 2)) return _titleCaseName(clean(l));
  }
  return null;
}

/// Decides whether the OCR text of an uploaded ID is acceptable.
/// Pure logic — kept separate from ML Kit so it can be unit tested.
IdScanResult evaluateIdText(String rawText, String selectedIdType, {String? addressLine}) {
  if (rawText.trim().isEmpty) {
    return const IdScanResult(
      valid: false,
      message: '❌ Walang nabasang text sa larawan. Baka malabo o kulang sa liwanag — kunan po ulit ng buo at malinaw na litrato ang ID.',
    );
  }

  final normalized = normalizeOcr(rawText);
  final hasPoblacion = containsWord(normalized, 'POBLACION');
  final hasBacuag = containsWord(normalized, 'BACUAG');

  if (!hasPoblacion || !hasBacuag) {
    final missing = !hasPoblacion && !hasBacuag
        ? "ang 'Poblacion' at 'Bacuag'"
        : (!hasPoblacion ? "ang 'Poblacion'" : "ang 'Bacuag'");
    return IdScanResult(
      valid: false,
      message: '❌ Hindi nababasa $missing sa address ng ID. Residente ng Poblacion, Bacuag lamang ang maaaring mag-sign up. '
          '${addressLine != null ? 'Nabasang address: $addressLine. ' : ''}'
          'Subukang kunan ng mas malinaw na litrato. Nabasang text: ${textSnippet(rawText)}',
    );
  }

  final nationalHits = nationalIdMarkers.where((m) => hasMarker(normalized, m)).length;
  final voterHits = voterIdMarkers.where((m) => hasMarker(normalized, m)).length;
  String? detectedType;
  if (nationalHits > voterHits && nationalHits > 0) {
    detectedType = 'National ID';
  } else if (voterHits > nationalHits) {
    detectedType = 'Voter ID';
  }

  if (detectedType == null) {
    return IdScanResult(
      valid: false,
      message: '❌ Hindi makilala kung National ID o Voter\'s ID ang na-scan, kaya hindi ito maaaring tanggapin. '
          'Pakikita ang buong card (kasama ang header) sa malinaw na litrato. Nabasang text: ${textSnippet(rawText)}',
    );
  }

  if (detectedType != selectedIdType) {
    return IdScanResult(
      valid: false,
      detectedIdType: detectedType,
      message: '❌ Ang nabasang card ay $detectedType, ngunit $selectedIdType ang napili sa dropdown. '
          'Pakiayon ang Uri ng ID at ulitin ang scan.',
    );
  }

  return IdScanResult(
    valid: true,
    detectedIdType: detectedType,
    message: '✅ Beripikado: Na-scan ang $selectedIdType at nakumpirma ang Address: '
        '${addressLine ?? 'POBLACION, BACUAG'} — Poblacion, Bacuag resident. Na-aprubahan na.',
  );
}

/// Scans [imagePath] with ML Kit and decides whether the ID is acceptable.
Future<IdScanResult> scanIdCard(String imagePath, String selectedIdType) async {
  final isMobile = defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  if (!isMobile) {
    return const IdScanResult(
      valid: false,
      message: '❌ Ang ID scanner ay gumagana lamang sa Android/iOS na device.',
    );
  }

  TextRecognizer? recognizer;
  try {
    final inputImage = InputImage.fromFilePath(imagePath);
    recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final recognized = await recognizer.processImage(inputImage);
    final evaluated = evaluateIdText(
      recognized.text,
      selectedIdType,
      addressLine: describeAddress(recognized),
    );
    // Ibalik ang raw OCR text din, para ma-auto-fill ang pangalan sa ID.
    return IdScanResult(
      valid: evaluated.valid,
      message: evaluated.message,
      detectedIdType: evaluated.detectedIdType,
      rawText: recognized.text,
    );
  } catch (e) {
    return IdScanResult(
      valid: false,
      message: '❌ Hindi ma-scan ang ID sa device na ito ($e). Pakisubukang muli o gamitin ang ibang larawan.',
    );
  } finally {
    try {
      await recognizer?.close();
    } catch (_) {}
  }
}

class BookingItem {
  final String id;
  final String name;
  final String phone;
  final LatLng pickup;
  final LatLng? destination;
  final String? photoPath;
  String status; // 'pending', 'accepted', 'on_the_way', 'arrived', 'completed'
  String? riderName;
  LatLng? riderLocation;
  List<LatLng> routePoints = [];
  /// Kailan na-book — ipinapakita sa passenger at rider UI.
  DateTime createdAt;

  BookingItem({
    required this.id,
    required this.name,
    required this.phone,
    required this.pickup,
    this.destination,
    this.photoPath,
    this.status = 'pending',
    this.riderName,
    this.riderLocation,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  static List<double>? _ll(Object? v) =>
      (v is List && v.length >= 2 && v[0] is num && v[1] is num)
          ? [(v[0] as num).toDouble(), (v[1] as num).toDouble()]
          : null;

  static LatLng? _latLng(Object? v) {
    final p = _ll(v);
    return p == null ? null : LatLng(p[0], p[1]);
  }

  /// Para sa SharedPreferences — sa Flutter web, ito ay localStorage, kaya
  /// nababasa ng admin/index.html ang eksaktong parehong data (bug: dati ay
  /// hindi pino-persist ang bookings, kaya laging 0/12 ang dashboard ng admin).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'pickup': _ll([pickup.latitude, pickup.longitude]),
        'destination': destination == null
            ? null
            : _ll([destination!.latitude, destination!.longitude]),
        'photoPath': photoPath,
        'status': status,
        'riderName': riderName,
        'riderLocation': riderLocation == null
            ? null
            : _ll([riderLocation!.latitude, riderLocation!.longitude]),
        // Naka-save rin ang huling alam na ruta (mula sa OSRM) para kapag
        // ni-restart ang app habang offline, ang totoong kalsada pa rin ang
        // ipinapakita kaagad — hindi babalik sa L-shape hangga't may naunang
        // rutang natutunan online.
        'routePoints': [
          for (final p in routePoints) _ll([p.latitude, p.longitude]),
        ],
        'createdAt': createdAt.toIso8601String(),
      };

  factory BookingItem.fromJson(Map<String, dynamic> j) => BookingItem(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        phone: (j['phone'] as String?) ?? '',
        pickup: _latLng(j['pickup']) ?? poblacionBacuagCenter,
        destination: _latLng(j['destination']),
        photoPath: j['photoPath'] as String?,
        status: (j['status'] as String?) ?? 'pending',
        riderName: j['riderName'] as String?,
        riderLocation: _latLng(j['riderLocation']),
        createdAt: DateTime.tryParse((j['createdAt'] ?? '').toString()) ??
            DateTime.now(),
      )..routePoints = [
          for (final e in (j['routePoints'] as List?) ?? const [])
            if (_latLng(e) != null) _latLng(e)!,
        ];
}

class BookingStore {
  static final BookingStore _instance = BookingStore._internal();
  factory BookingStore() => _instance;
  BookingStore._internal();

  final List<BookingItem> bookings = [];
  final List<VoidCallback> _listeners = [];

  void addListener(VoidCallback listener) => _listeners.add(listener);
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void notify() {
    for (var l in _listeners) {
      l();
    }
  }

  // ---------------------------------------------------------------------------
  // Persist ng bookings (sakay_bookings_v1). Sa Flutter web ang SharedPreferences
  // ay localStorage, kaya nababasa ito ng admin/index.html sa parehong browser —
  // dito nanggagaling ang tunay na "naka-sync sa app" na dashboard ng admin.
  // Tinitiyak na hindi nagta-throw kahit walang storage (unit tests).
  // ---------------------------------------------------------------------------
  static const _bookingsKey = 'sakay_bookings_v1';
  bool _bookingsLoaded = false;

  /// I-load ang naka-save na bookings — tinatawag sa `main()` bago ang `runApp`.
  Future<void> load() async {
    if (_bookingsLoaded) return;
    _bookingsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_bookingsKey);
      if (raw == null) return;
      final decoded = json.decode(raw);
      if (decoded is! List) return;
      bookings
        ..clear()
        ..addAll(
          decoded.whereType<Map<String, dynamic>>().map(BookingItem.fromJson),
        );
      notify();
    } catch (_) {
      // Walang storage na magagamit — walang mababasa, pero hindi ito error.
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _bookingsKey,
        json.encode([for (final b in bookings) b.toJson()]),
      );
    } catch (_) {
      // Nasa memory pa rin ang bookings kahit hindi maka-save.
    }
  }

  // ---------------------------------------------------------------------------
  // Offline road-route cache: ang huling alam na TOTOONG kalsada na ruta
  // (mula sa OSRM) ay nakaimbak sa SharedPreferences. Kapag walang internet sa
  // susunod na biyahe, gagamitin pa rin ang tunay na lansangan imbes na ang
  // L-shape na fallback — kaya hindi nagiging pahalang/kurwint ang ruta offline.
  // ---------------------------------------------------------------------------
  static const _routeCachePrefsKey = 'sakay_route_cache_v1';
  static const _routeCacheMaxEntries = 80;

  final Map<String, List<LatLng>> _routeCache = {};
  bool _routeCacheLoaded = false;

  /// Key ng ruta sa pinakamalapit na ~11 m (4-decimal) na lugar — parehong
  /// ruta = parehong key, kaya mababawi ito kahit magkaiba ang eksaktong
  /// GPS na pin sa pagkakataong iyon.
  static String routeCacheKey(LatLng a, LatLng b) =>
      '${a.latitude.toStringAsFixed(4)},${a.longitude.toStringAsFixed(4)}>'
      '${b.latitude.toStringAsFixed(4)},${b.longitude.toStringAsFixed(4)}';

  /// Isang beses lang maglo-load, at HINDI kailanman nagta-throw — kapag walang
  /// SharedPreferences (hal. sa unit tests), walang cache pero gumagana pa rin
  /// ang lahat.
  Future<void> _ensureRouteCacheLoaded() async {
    if (_routeCacheLoaded) return;
    _routeCacheLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_routeCachePrefsKey);
      if (raw == null) return;
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) return;
      for (final e in decoded.entries) {
        final v = e.value;
        if (v is! List || v.length < 4) continue;
        final pts = <LatLng>[];
        for (var i = 0; i + 1 < v.length; i += 2) {
          final la = v[i];
          final lo = v[i + 1];
          if (la is! num || lo is! num) break;
          pts.add(LatLng(la.toDouble(), lo.toDouble()));
        }
        if (pts.length >= 2) _routeCache[e.key] = pts;
      }
    } catch (_) {
      // Walang storage na magagamit — walang cache, pero hindi ito error.
    }
  }

  /// Nagtatabi ng bagong ruta at sina-save ito (fire-and-forget).
  Future<void> _rememberRoute(String key, List<LatLng> points) async {
    _routeCache[key] = points;
    while (_routeCache.length > _routeCacheMaxEntries) {
      _routeCache.remove(_routeCache.keys.first);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = <String, dynamic>{
        for (final e in _routeCache.entries)
          e.key: [
            // Flat na [lat, lng, lat, lng, …] — pareho ng binabasa ng loader.
            for (final p in e.value) ...[p.latitude, p.longitude],
          ],
      };
      await prefs.setString(_routeCachePrefsKey, json.encode(data));
    } catch (_) {
      // Nasa memory pa rin ang cache kahit hindi maka-save — ok pa rin.
    }
  }

  void addBooking(BookingItem item) {
    bookings.insert(0, item);
    if (item.riderLocation != null) {
      updateRoute(item.id, item.riderLocation!, item.pickup);
    }
    unawaited(_persist());
    notify();
  }

  void updateStatus(String id, String newStatus, {String? riderName}) {
    final b = bookings.firstWhere((element) => element.id == id, orElse: () => bookings.first);
    b.status = newStatus;
    if (riderName != null) b.riderName = riderName;
    if (newStatus == 'accepted' && b.riderLocation == null) {
      b.riderLocation = LatLng(b.pickup.latitude + 0.008, b.pickup.longitude + 0.008);
      updateRoute(b.id, b.riderLocation!, b.pickup);
    }
    if (newStatus == 'arrived' && b.destination != null && b.riderLocation != null) {
      updateRoute(b.id, b.riderLocation!, b.destination!);
    }
    unawaited(_persist());
    notify();
  }

  void updateRiderLocation(String id, LatLng location) {
    final b = bookings.firstWhere((element) => element.id == id, orElse: () => bookings.first);
    b.riderLocation = location;
    notify();
  }

  Future<void> updateRoute(String id, LatLng start, LatLng end) async {
    final b = bookings.firstWhere((element) => element.id == id, orElse: () => bookings.first);
    await _ensureRouteCacheLoaded();
    final key = routeCacheKey(start, end);
    try {
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=geojson',
      );
      final response = await http.get(url).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final coords = data['routes'][0]['geometry']['coordinates'] as List;
        final points = coords
            .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
            .toList();
        b.routePoints = points;
        if (points.length >= 2) unawaited(_rememberRoute(key, points));
        notify();
        return;
      }
    } catch (_) {}

    // Offline / naabutan ng timeout: gamitin ang huling ALAM NA totoong ruta.
    final cached = _routeCache[key];
    if (cached != null && cached.length >= 2) {
      b.routePoints = List<LatLng>.of(cached);
      notify();
      return;
    }

    // Fallback road grid turns — wala pang natutunang ruta para sa pares na ito.
    b.routePoints = [
      start,
      LatLng(start.latitude, (start.longitude + end.longitude) / 2),
      LatLng(end.latitude, (start.longitude + end.longitude) / 2),
      end,
    ];
    notify();
  }

  void cancelBooking(String id) {
    final b = bookings.firstWhere((element) => element.id == id, orElse: () => bookings.first);
    b.status = 'cancelled';
    unawaited(_persist());
    notify();
  }

  /// ⏱ Awtomatikong kinansela ang lahat ng pending booking na lampas na sa
  /// 10 minutong walang rider na nagtanggap. Tinatawag tuwing segundo ng
  /// passenger at rider screen. `true` kung may binago.
  bool autoCancelExpired({DateTime? now}) {
    var changed = false;
    for (final b in bookings) {
      if (isPendingAutoCancelDue(b, now: now)) {
        b.status = 'cancelled';
        changed = true;
      }
    }
    if (changed) {
      unawaited(_persist());
      notify();
    }
    return changed;
  }

  static const _activeStatuses = {
    'pending',
    'accepted',
    'on_the_way',
    'arrived',
  };

  /// Ang hindi pa tapos na booking ng isang pasahero (ayon sa phone number),
  /// o null kapag wala. Ginagamit ng passenger para hindi makagawa ng panibagong
  /// booking habang may pending/aktibong biyahe.
  BookingItem? activeForPhone(String phone) {
    // Pinakabago muna — ang bookings list ay newest-first (insert sa unahan).
    for (final b in bookings) {
      if (b.phone == phone && _activeStatuses.contains(b.status)) return b;
    }
    return null;
  }

  bool hasActiveBookingFor(String phone) => activeForPhone(phone) != null;

  /// Ang aktibong biyahe ng isang rider (ayon sa pangalan), o null.
  BookingItem? activeForRider(String riderName) {
    for (final b in bookings) {
      if (b.riderName == riderName &&
          b.status != 'pending' &&
          _activeStatuses.contains(b.status)) {
        return b;
      }
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Lokal na account store (demo). Kapag naka-setup na ang Firebase Auth,
// dito papalitan ng Firebase Authentication ang mga account sa ibaba.
// ---------------------------------------------------------------------------

class Account {
  final String name;
  final String phone;
  final String email;
  final String password;
  final String role; // 'passenger' o 'rider'
  final String idType; // 'National ID' o 'Voter ID'

  const Account({
    required this.name,
    required this.phone,
    required this.email,
    required this.password,
    required this.role,
    required this.idType,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'phone': phone,
        'email': email,
        'password': password,
        'role': role,
        'idType': idType,
      };

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        name: json['name'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        email: json['email'] as String? ?? '',
        password: json['password'] as String? ?? '',
        role: json['role'] as String? ?? 'passenger',
        idType: json['idType'] as String? ?? 'National ID',
      );
}

class AccountStore {
  static final AccountStore _instance = AccountStore._internal();
  factory AccountStore() => _instance;
  AccountStore._internal();

  static const _accountsKey = 'sakay_accounts_v1';
  static const _sessionKey = 'sakay_session_email_v1';

  final List<Account> accounts = [];
  Account? currentUser;

  /// Binabasa ang naka-save na accounts at session mula sa local storage.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_accountsKey);
      if (raw != null) {
        final list = json.decode(raw) as List<dynamic>;
        accounts
          ..clear()
          ..addAll(list.map((e) => Account.fromJson(e as Map<String, dynamic>)));
      }
      final sessionEmail = prefs.getString(_sessionKey);
      if (sessionEmail != null) {
        currentUser = _findByEmail(sessionEmail);
      }
      _seedDemoAccounts();
    } catch (_) {
      // Kapag walang na-save pa, magsisimula sa walang account — hindi fatal.
    }
  }

  /// 🧪 Demo accounts (rider + passenger) para makapag-test agad ng app at
  /// makita rin sa admin portal (parehong email/password ang naka-seed doon).
  /// Idinagdag lang kapag walang account pa sa parehong role — hindi kailanman
  /// tinatanggal ang mga totoong gumagamit.
  void _seedDemoAccounts() {
    var changed = false;
    if (!accounts.any((a) => a.role == 'rider')) {
      accounts.add(Account(
        name: 'Rider Demo',
        phone: '09912345678',
        email: 'rider@sakaybacuag.ph',
        password: 'rider123',
        role: 'rider',
        idType: 'National ID',
      ));
      changed = true;
    }
    if (!accounts.any((a) => a.role == 'passenger')) {
      accounts.add(Account(
        name: 'Pasahero Demo',
        phone: '09987654321',
        email: 'passenger@sakaybacuag.ph',
        password: 'passenger123',
        role: 'passenger',
        idType: 'National ID',
      ));
      changed = true;
    }
    if (changed) _persist();
  }

  Account? _findByEmail(String email) {
    for (final a in accounts) {
      if (a.email.toLowerCase() == email.toLowerCase()) return a;
    }
    return null;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _accountsKey, json.encode(accounts.map((a) => a.toJson()).toList()));
    if (currentUser == null) {
      await prefs.remove(_sessionKey);
    } else {
      await prefs.setString(_sessionKey, currentUser!.email);
    }
  }

  /// Nagre-register ng bagong account.
  /// Bumabalik ng error message, o null kapag tagumpay.
  String? signUp({
    required String name,
    required String phone,
    required String email,
    required String password,
    required String role,
    required String idType,
  }) {
    if (_findByEmail(email) != null) {
      return 'Gumamit ng ibang Email — mayroon nang account na nakarehistro sa email na ito.';
    }
    accounts.add(Account(
      name: name,
      phone: phone,
      email: email,
      password: password,
      role: role,
      idType: idType,
    ));
    _persist();
    return null;
  }

  /// Naglo-login gamit ang email, password, at piniling role.
  /// Bumabalik ng error message, o null kapag tagumpay.
  String? login(String email, String password, String role) {
    final account = _findByEmail(email);
    if (account == null || account.password != password) {
      return 'Maling Email o Password. Subukan ulit o mag-sign up muna.';
    }
    if (account.role != role) {
      final actual = account.role == 'rider' ? 'Rider' : 'Pasahero';
      return 'Ang account na ito ay $actual — piliin ang tamang uri ng account sa itaas.';
    }
    currentUser = account;
    _persist();
    return null;
  }

  Future<void> signOut() async {
    currentUser = null;
    await _persist();
  }

  @visibleForTesting
  void reset() {
    accounts.clear();
    currentUser = null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // I-load ang naka-save na account at session (auto-login kung may laman).
  await AccountStore().load();
  // I-load ang naka-save na bookings — dito nakadepende ang admin dashboard
  // (sa web ay localStorage ito, kaya parehong data ng app ang nakikita).
  await BookingStore().load();
  // I-configure ang persistent tile cache BAGO mag-render ang alin mang mapa
  // (online cache + offline pack ng Poblacion Bacuag).
  await OfflineMapStore.configureCache();
  // 🛰️ Awtomatikong i-download ang buong offline pack kapag online — hindi na
  // kailangang pindutin ang anumang button. Resumable at idine-detect ang
  // koneksyon, kaya sa susunod na pagbubukas ay tuloy-tuloy ito.
  OfflineMapStore.startAutoDownload();
  // After Firebase configuration, initialize Firebase before runApp:
  // await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const SakayBacuagApp());
}

class SakayBacuagApp extends StatelessWidget {
  const SakayBacuagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'E-Bike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: emerald,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F8F6),
        // — AppBar: flat, naka-center, malinis ang dating —
        appBarTheme: const AppBarTheme(
          backgroundColor: emerald,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: 0.2,
          ),
        ),
        // — Cards: puti, malambot na shadow, malaking radius —
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 1.5,
          shadowColor: Colors.black12,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        // — Buttons: pare-parehong hugis at berdeng aksyon —
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: emerald,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              letterSpacing: 0.2,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: emerald,
            side: const BorderSide(color: emerald, width: 1.4),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: emerald,
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        // — Inputs: makinis, may subtle fill at berdeng focus —
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          hintStyle: TextStyle(color: Colors.grey.shade500),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: emerald, width: 1.8),
          ),
        ),
        // — Snackbars: floating at madaling basahin —
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Color(0xFF17231F),
          contentTextStyle: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        // — SegmentedButton (tabs ng passenger): berde kapag aktibo —
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith<Color?>(
              (states) => states.contains(WidgetState.selected)
                  ? emerald
                  : Colors.white,
            ),
            foregroundColor: WidgetStateProperty.resolveWith<Color?>(
              (states) => states.contains(WidgetState.selected)
                  ? Colors.white
                  : emerald,
            ),
            side: WidgetStateProperty.all<BorderSide>(
              const BorderSide(color: Color(0xFFCDE3DA)),
            ),
            textStyle: WidgetStateProperty.all<TextStyle>(
              const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFE1ECE6),
          thickness: 1,
          space: 1,
        ),
        progressIndicatorTheme:
            const ProgressIndicatorThemeData(color: emerald),
      ),
      home: const LocationGate(),
    );
  }
}

class LocationGate extends StatefulWidget {
  const LocationGate({super.key});

  @override
  State<LocationGate> createState() => _LocationGateState();
}

class _LocationGateState extends State<LocationGate> {
  bool _checked = false;
  bool _hasLocation = false;
  String _message = 'Sinusuri ang GPS location at permissions...';

  @override
  void initState() {
    super.initState();
    _checkLocationServices();
  }

  Future<void> _checkLocationServices() async {
    setState(() {
      _checked = false;
      _message = 'Sinusuri ang GPS location...';
    });

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _checked = true;
        _hasLocation = false;
        _message = 'Naka-off ang Location Services (GPS) ng iyong device. Obligadong i-on ito bago magamit ang E-Bike.';
      });
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _checked = true;
          _hasLocation = false;
          _message = 'Kailangan ang Location Permission para magamit ang E-Bike app sa Bacuag.';
        });
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _checked = true;
        _hasLocation = false;
        _message = 'Permanenteng tinanggihan ang Location Permission. '
            'Bubuksan ko ang Settings ng app — pindutin ang button sa ibaba.';
      });
      return;
    }

    setState(() {
      _checked = true;
      _hasLocation = true;
    });
  }

  /// 🔘 Ang "Subukang Muli / I-on ang GPS" button: hindi lang ulit ang pag-check —
  /// awtomatik ring BINUBUKSAN ang tamang system settings page kung saan ito
  /// ma-o-on ng user, tapos muli itong sumusubok pagkatapos:
  ///  • Naka-off ang GPS → Location Settings (hindi pwedeng i-on ng app mismo
  ///    ang GPS — pinagbabawal ito ng Android — kaya diretsong doon na ang user)
  ///  • Permanenteng tinanggihan ang permission → App Settings (toggle ng Location)
  ///  • Naka-prompt pa lang ang permission → requestPermission (auto-dialog)
  Future<void> _retryWithSystemSettings() async {
    final serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) {
      if (!kIsWeb) {
        setState(() => _message = 'Binubuksan ang Location Settings — i-on lang ang GPS doon...');
        try {
          await Geolocator.openLocationSettings();
        } catch (_) {
          // Walang ma-i-open na settings page sa device na ito — tuloy sa check.
        }
      } else {
        setState(() => _message = 'Naka-off ang Location Services sa browser/device. Paki-on ito, tapos pindutin muli.');
      }
      await _checkLocationServices();
      return;
    }

    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.deniedForever) {
      if (!kIsWeb) {
        setState(() => _message = 'Binubuksan ang App Settings — i-on lang ang Location permission doon...');
        try {
          await Geolocator.openAppSettings();
        } catch (_) {
          // Walang ma-i-open na settings — tuloy sa check.
        }
      } else {
        setState(() => _message = 'Tinanggihan ng browser ang Location permission. Paki-enable sa site settings, tapos pindutin muli.');
      }
      await _checkLocationServices();
      return;
    }

    // Naka-off lang nang kaunti o first-time pa lang — ito ang auto-dialog ng OS.
    await _checkLocationServices();
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked || !_hasLocation) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [emerald, Color(0xFF044E37)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.location_on, size: 64, color: emerald),
                    const SizedBox(height: 16),
                    const Text(
                      'Kinakailangan ang GPS Location',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: emerald),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 15, color: Colors.black87),
                    ),
                    const SizedBox(height: 24),
                    if (!_checked)
                      const CircularProgressIndicator(color: emerald)
                    else
                      FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: emerald, foregroundColor: Colors.white),
                        onPressed: _retryWithSystemSettings,
                        icon: const Icon(Icons.settings),
                        label: const Text('Subukang Muli / I-on ang GPS'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return const RoleHome();
  }
}

// ---------------------------------------------------------------------------
// RoleHome: ang home ng app pagkatapos ng GPS gate.
// WALA NANG Passenger/Rider Mode menu — login/account button lang sa top-right
// na nagbubukas ng login popup para sa Pasahero at Rider. Ang login ang
// nagtatakda kung Passenger o Rider screen ang ipapakita.
// ---------------------------------------------------------------------------

class RoleHome extends StatefulWidget {
  const RoleHome({super.key});

  @override
  State<RoleHome> createState() => _RoleHomeState();
}

class _RoleHomeState extends State<RoleHome> {
  /// Login popup (Email + Password + pili ng Pasahero/Rider account).
  /// Kapag naka-log na, ipinapakita ang account at ang logout.
  void _openLoginPopup() {
    final user = AccountStore().currentUser;

    if (user != null) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Aking Account'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pangalan: ${user.name}'),
              Text('Email: ${user.email}'),
              Text('Uri: ${user.role == 'rider' ? 'Rider' : 'Pasahero'}'),
              Text('ID: ${user.idType}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Isara', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                // Kunin ang navigator/messenger BAGO ang async gap.
                final navigator = Navigator.of(context);
                final messenger = ScaffoldMessenger.of(context);
                await AccountStore().signOut();
                if (!mounted) return;
                navigator.pop();
                setState(() {});
                messenger.showSnackBar(
                  const SnackBar(content: Text('Matagumpay na nag-log out.')),
                );
              },
              child: const Text('Mag-log out'),
            ),
          ],
        ),
      );
      return;
    }

    int roleIndex = 0; // 0: Pasahero, 1: Rider
    bool isSignupMode = false; // true = bagong registration (Pasahero O Rider)
    final emailC = TextEditingController();
    final passC = TextEditingController();
    final nameC = TextEditingController();
    final phoneC = TextEditingController();
    String selectedIdType = 'National ID';
    XFile? idFile;
    bool aiScanning = false;
    String aiResult = '';
    bool isIdValid = false;
    String errorMessage = '';
    bool dialogOpen = true;

    void closeDialog() {
      dialogOpen = false;
      Navigator.pop(context);
    }

    // 💳 Kunin ang litrato ng Verified ID (camera/gallery) at i-scan gamit ang
    // on-device ML Kit — pareho ng booking-time signup. Auto-fill ang pangalan
    // mula sa ID at beripika ang Bacuag address.
    Future<void> pickAndScanId(ImageSource source, String sourceLabel, StateSetter updateState) async {
      XFile? picked;
      try {
        picked = await ImagePicker().pickImage(source: source, imageQuality: 90);
      } catch (e) {
        if (!dialogOpen) return;
        updateState(() {
          errorMessage = 'Hindi mabuksan ang $sourceLabel ($e). Paki-grant ang permission sa Settings.';
        });
        return;
      }
      if (!dialogOpen || picked == null) return;
      final pickedId = picked;

      updateState(() {
        idFile = pickedId;
        aiScanning = true;
        aiResult = '';
        isIdValid = false;
        errorMessage = '';
      });

      final result = await scanIdCard(pickedId.path, selectedIdType);
      if (!dialogOpen) return;
      final detectedName = result.valid ? extractNameFromId(result.rawText) : null;
      updateState(() {
        aiScanning = false;
        isIdValid = result.valid;
        aiResult = result.valid && detectedName != null
            ? '${result.message}\n✅ Na-fill ang Buong Pangalan mula sa ID: $detectedName (palitan kung kinakailangan).'
            : result.message;
        if (detectedName != null && detectedName.isNotEmpty) {
          nameC.text = detectedName;
        }
      });
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isSignupMode ? 'Mag-sign up sa E-Bike' : 'Mag-log in sa E-Bike'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Tabs: Mag-log in / Mag-sign up (parehong para sa Pasahero at Rider).
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setDialogState(() => isSignupMode = false),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: !isSignupMode ? emerald : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'Mag-log in',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontWeight: FontWeight.bold, color: !isSignupMode ? Colors.white : Colors.black87),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setDialogState(() => isSignupMode = true),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: isSignupMode ? emerald : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'Mag-sign up',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontWeight: FontWeight.bold, color: isSignupMode ? Colors.white : Colors.black87),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isSignupMode
                      ? 'Pumili ng uri ng account, punan ang detalye, at i-upload ang Verified ID (Bacuag resident).'
                      : 'Piliin ang uri ng iyong account, tapos i-enter ang Email at Password.',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment<int>(value: 0, label: Text('Pasahero'), icon: Icon(Icons.person)),
                    ButtonSegment<int>(value: 1, label: Text('Rider'), icon: Icon(Icons.electric_rickshaw)),
                  ],
                  selected: {roleIndex},
                  onSelectionChanged: (v) => setDialogState(() => roleIndex = v.first),
                ),
                const SizedBox(height: 14),
                if (errorMessage.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Text(errorMessage, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.red)),
                  ),
                  const SizedBox(height: 10),
                ],
                if (isSignupMode) ...[
                  DropdownButtonFormField<String>(
                    initialValue: selectedIdType,
                    decoration: const InputDecoration(labelText: 'Uri ng Verified ID', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'National ID', child: Text('Philippine National ID')),
                      DropdownMenuItem(value: 'Voter ID', child: Text("COMELEC Voter's ID")),
                    ],
                    onChanged: (v) => setDialogState(() {
                      selectedIdType = v!;
                      // Ang na-scan ay para sa dating Uri ng ID — kailangang mag-scan ulit.
                      if (idFile != null) {
                        idFile = null;
                        aiResult = '';
                        isIdValid = false;
                      }
                    }),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => pickAndScanId(ImageSource.camera, 'camera', setDialogState),
                          icon: const Icon(Icons.photo_camera),
                          label: Text(idFile == null ? 'Kunan ng ID' : 'Ulitin'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => pickAndScanId(ImageSource.gallery, 'gallery', setDialogState),
                          icon: const Icon(Icons.photo_library),
                          label: const Text('Gallery'),
                        ),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'Kunan ang ID nang buo at malinaw — dapat mabasa ng scanner ang address na POBLACION, BACUAG.',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (aiScanning)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 8),
                          Text('Sinusuri ang ID at Address...', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                        ],
                      ),
                    ),
                  if (aiResult.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(aiResult, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isIdValid ? emerald : Colors.red)),
                    ),
                  const SizedBox(height: 10),
                  TextField(controller: nameC, decoration: const InputDecoration(labelText: 'Buong Pangalan', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(controller: phoneC, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Contact Number', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: emailC,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email Address', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passC,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: closeDialog,
              child: const Text('Kanselahin', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: emerald),
              onPressed: () {
                if (emailC.text.trim().isEmpty || passC.text.trim().isEmpty) {
                  setDialogState(() => errorMessage = 'Ilagay ang iyong Email Address at Password.');
                  return;
                }
                final selectedRole = roleIndex == 0 ? 'passenger' : 'rider';
                if (!isSignupMode) {
                  final error = AccountStore().login(
                    emailC.text.trim(),
                    passC.text.trim(),
                    selectedRole,
                  );
                  if (error != null) {
                    setDialogState(() => errorMessage = error);
                    return;
                  }
                  closeDialog();
                  setState(() {});
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Naka-log in na bilang ${selectedRole == 'rider' ? 'Rider' : 'Pasahero'}!',
                      ),
                    ),
                  );
                  return;
                }

                // — SIGN UP (Pasahero o Rider) na may Verified ID.
                if (nameC.text.trim().isEmpty ||
                    phoneC.text.trim().isEmpty ||
                    idFile == null) {
                  setDialogState(() =>
                      errorMessage = 'Punan ang lahat ng fields at i-upload ang Verified ID.');
                  return;
                }
                if (passC.text.trim().length < 6) {
                  setDialogState(() =>
                      errorMessage = 'Dapat may 6 o higit pang character ang password.');
                  return;
                }
                if (!isIdValid) {
                  setDialogState(() =>
                      errorMessage = 'Hindi beripikado ang ID. Kailangang may Bacuag address ang ID.');
                  return;
                }
                final signupError = AccountStore().signUp(
                  name: nameC.text.trim(),
                  phone: phoneC.text.trim(),
                  email: emailC.text.trim(),
                  password: passC.text.trim(),
                  role: selectedRole,
                  idType: selectedIdType,
                );
                if (signupError != null) {
                  setDialogState(() => errorMessage = signupError);
                  return;
                }
                AccountStore().login(emailC.text.trim(), passC.text.trim(), selectedRole);
                closeDialog();
                setState(() {});
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                    content: Text(
                      selectedRole == 'rider'
                          ? 'Naisumite ang Rider registration — lumalabas na ito sa admin dashboard, maghintay ng LGU approval bago mag-online.'
                          : 'Welcome! Naka-log in ka na bilang Pasahero.',
                    ),
                  ),
                );
              },
              child: Text(isSignupMode ? 'Mag-sign up' : 'Mag-log in'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = AccountStore().currentUser;
    final loggedIn = user != null;
    // Wala nang mode menu — ang login ang nagtatakda ng mode:
    // rider account → Rider screen, kundi → Passenger (dating flow).
    final mode = user?.role == 'rider' ? 1 : 0;
    return Scaffold(
      appBar: AppBar(
        // 🛺 Opisyal na logo sa kaliwang gilid ng header (bug #10).
        // Naka-`off` kung wala ang asset para hindi mag-crash sa web/tests.
        leading: Padding(
          padding: const EdgeInsets.all(8),
          child: Image.asset(
            'assets/logo.png',
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.electric_rickshaw, color: Colors.white),
          ),
        ),
        title: Text(mode == 0 ? 'E-Bike — Passenger' : 'E-Bike — Rider Dashboard'),
        actions: [
          // Login/account button (pinakakanan sa taas).
          IconButton(
            tooltip: loggedIn ? 'Aking account' : 'Mag-log in',
            icon: const Icon(Icons.account_box, color: Colors.white),
            onPressed: _openLoginPopup,
          ),
        ],
      ),
      body: mode == 0 ? const PassengerScreen() : const RiderScreen(),
    );
  }
}
class PassengerScreen extends StatefulWidget {
  const PassengerScreen({super.key});

  @override
  State<PassengerScreen> createState() => _PassengerScreenState();
}

class _PassengerScreenState extends State<PassengerScreen> {
  final name = TextEditingController();
  final phone = TextEditingController();
  LatLng? pickup;
  LatLng? destination;
  XFile? photo;
  bool selectingDestination = false;
  BookingItem? activeBooking;
  bool _isLoggedIn = false;
  int _passengerTab = 0;
  String loggedEmail = '';
  String loggedIdType = 'National ID';

  // 1s ticker para sa countdown timer at GPS arrival detection.
  Timer? _uiTicker;

  // 🛰️ Satellite/street mode ng map, controller at auto GPS pin.
  bool _satelliteMode = false;
  MapController? _bookingMapController;
  bool _mapReady = false;
  bool _autoPinned = false;
  LatLng? _autoPinCandidate;

  // 🛰️ Live GPS follow ng pasahero: kasabay gumagalaw ang pickup pin sa mapa
  // habang gumagalaw ang pasahero (kada ~3 metro / ilang segundo).
  StreamSubscription<Position>? _gpsFollowSub;
  bool _manualPickupPin = false; // totoo kapag tinap ng pasahero ang mapa
  LatLng? _liveGpsLocation;

  // 🏷️ Pangalan ng kalye ng pickup pin (reverse geocode). Ang cache ay
  // nasa top-level (`_streetNameCache`) para mai-share ng rider at pasahero.
  String? _pickupStreet;
  String? _streetKey;
  DateTime _lastStreetLookup = DateTime.fromMillisecondsSinceEpoch(0);

  // Offline map ng Poblacion Bacuag: awtomatikong dina-download kapag online
  // (na tinatawag sa app start) — wala nang "Handa offline" na button.
  int? _offlinePackCount; // null = hindi pa nalalaman ang status
  bool _offlineDownloading = false;
  int _offlineDone = 0;
  int _offlineTotal = 0;

  bool get _offlinePackComplete {
    final c = _offlinePackCount;
    return c != null && c >= poblacionOfflineTiles().length;
  }

  /// Maliit na linya lang sa ilalim ng map ang status ng offline pack —
  /// tinanggal na ang "Handa offline … pindutin para i-recheck" na button.
  String get _offlineStatusLabel {
    // 🌐 Walang persistent tile cache ang web (naka-disable ito ng flutter_map
    // sa browser), kaya walang offline pack na mada-download dito — sa APK
    // (mobile) lang gumagana ang offline pack. Wag nang magpakita ng
    // mapangakit na "mada-download ito kapag online" na hindi naman talaga
    // nagdo-download sa browser.
    if (kIsWeb) {
      return 'Offline map: nasa mobile app (APK) lang ito — sa browser ay '
          'kailangan lagi ng internet.';
    }
    final c = _offlinePackCount;
    final total = poblacionOfflineTiles().length;
    if (_offlineDownloading && _offlineTotal > 0) {
      return 'Nagda-download ng offline map… $_offlineDone/$_offlineTotal';
    }
    if (c == null) return 'Tinutukoy ang offline map…';
    if (c == 0) return 'Offline map: wala pa — mada-download ito kapag online.';
    if (c >= total) return '✅ Offline map handa: Poblacion Bacuag ($total tiles).';
    return 'Offline map: $c/$total tiles — mada-download ito kapag online.';
  }

  /// 🛰️ Awtomatikong i-download ang buong offline pack kapag online — walang
  /// button na kailangang pindutin; tinatawag lang ito mula sa initState at
  /// kapag bumalik ang koneksyon. Resumable, kaya safe kahit paulit-ulit.
  Future<void> _autoDownloadOfflineMap() async {
    if (_offlineDownloading) return;
    // 🌐 Sa web ay walang lugarang paglagyan ng cache (in-disable ito ng
    // flutter_map sa browser), kaya walang saysay ang pag-download dito.
    if (kIsWeb) return;
    if (!await OfflineMapStore.hasConnectivity()) return; // offline muna — sa susunod na online ay tuloy
    setState(() {
      _offlineDownloading = true;
      _offlineDone = 0;
      _offlineTotal = 0;
    });
    try {
      final result = await OfflineMapStore.downloadPoblacion(
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _offlineDone = done;
            _offlineTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _offlineDownloading = false;
        _offlinePackCount = result.downloaded + result.skipped;
      });
      if (!mounted) return;
      if (result.failed == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '✅ Handa na ang offline map ng Poblacion Bacuag — magagamit kahit walang internet!',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _offlineDownloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Hindi ma-download ang offline map ($e).')),
      );    }
  }

  void _promptSignupBeforeBooking() {
    if (_isLoggedIn) {
      submitBooking();
      return;
    }

    final regName = TextEditingController();
    final regPhone = TextEditingController();
    final regEmail = TextEditingController();
    final regPass = TextEditingController();
    String selectedIdType = 'National ID';
    XFile? regIdFile;
    bool aiScanning = false;
    String aiResult = '';
    bool isIdValid = false;
    String errorMessage = '';
    bool isLoginMode = false;
    bool dialogOpen = true;

    void closeDialog() {
      dialogOpen = false;
      Navigator.pop(context);
    }

    // Picks the ID photo (camera or gallery) and scans it with on-device ML Kit.
    Future<void> pickAndScanId(ImageSource source, String sourceLabel, StateSetter updateState) async {
      XFile? picked;
      try {
        picked = await ImagePicker().pickImage(source: source, imageQuality: 90);
      } catch (e) {
        if (!dialogOpen) return;
        updateState(() {
          errorMessage = 'Hindi mabuksan ang $sourceLabel ($e). Paki-grant ang permission sa Settings.';
        });
        return;
      }
      if (!dialogOpen || picked == null) return;
      final idFile = picked;

      updateState(() {
        regIdFile = idFile;
        aiScanning = true;
        aiResult = '';
        isIdValid = false;
        errorMessage = '';
      });

      final result = await scanIdCard(idFile.path, selectedIdType);
      if (!dialogOpen) return;
      // ✏️ Auto-fill ng tunay na pangalan mula sa ID — para sa mga taong hindi
      // tamang nilalagay ang pangalan nila, ID na ang pinagmumulan ng katotohanan.
      final detectedName =
          result.valid ? extractNameFromId(result.rawText) : null;
      updateState(() {
        aiScanning = false;
        isIdValid = result.valid;
        aiResult = result.valid && detectedName != null
            ? '${result.message}\n✅ Na-fill ang Buong Pangalan mula sa ID: $detectedName (palitan kung kinakailangan).'
            : result.message;
        if (detectedName != null && detectedName.isNotEmpty) {
          regName.text = detectedName;
        }
      });
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(isLoginMode ? 'Mag-log in sa Account' : 'Signup & Verified ID'),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: closeDialog,
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setStateDialog(() => isLoginMode = false),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: !isLoginMode ? emerald : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'Mag-sign Up',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontWeight: FontWeight.bold, color: !isLoginMode ? Colors.white : Colors.black87),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setStateDialog(() => isLoginMode = true),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: isLoginMode ? emerald : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'Mag-log in',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontWeight: FontWeight.bold, color: isLoginMode ? Colors.white : Colors.black87),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (errorMessage.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Text(errorMessage, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.red)),
                  ),
                  const SizedBox(height: 10),
                ],
                if (isLoginMode) ...[
                  const Text('I-enter ang iyong rehistradong Email at Password:', style: TextStyle(fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 10),
                  TextField(controller: regEmail, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email Address', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(controller: regPass, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
                ] else ...[
                  const Text('Punan ang mga detalye, pumili ng Uri ng ID, at i-upload ito para sa Address Verification (Bacuag resident required).', style: TextStyle(fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: selectedIdType,
                    decoration: const InputDecoration(labelText: 'Uri ng ID', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'National ID', child: Text('Philippine National ID')),
                      DropdownMenuItem(value: 'Voter ID', child: Text("COMELEC Voter's ID")),
                    ],
                    onChanged: (v) => setStateDialog(() {
                      selectedIdType = v!;
                      // Ang na-scan ay para sa dating Uri ng ID — kailangang mag-scan ulit.
                      if (regIdFile != null) {
                        regIdFile = null;
                        aiResult = '';
                        isIdValid = false;
                      }
                    }),
                  ),
                  const SizedBox(height: 10),
                  TextField(controller: regName, decoration: const InputDecoration(labelText: 'Buong Pangalan', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(controller: regPhone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Contact Number', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(controller: regEmail, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email Address', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(controller: regPass, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => pickAndScanId(ImageSource.camera, 'camera', setStateDialog),
                          icon: const Icon(Icons.photo_camera),
                          label: Text(regIdFile == null ? 'Kunan ng litrato' : 'Ulitin (Camera)'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => pickAndScanId(ImageSource.gallery, 'gallery', setStateDialog),
                          icon: const Icon(Icons.photo_library),
                          label: const Text('Piliin sa Gallery'),
                        ),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'Kunan ang ID nang buo at malinaw — dapat mabasa ng scanner ang address na POBLACION, BACUAG.',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (aiScanning)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 8),
                          Text('Sinusuri ang ID at Address...', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                        ],
                      ),
                    ),
                  if (aiResult.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(aiResult, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isIdValid ? emerald : Colors.red)),
                    ),
                ],
                if (errorMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(errorMessage, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.red)),
                  ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actionsOverflowAlignment: OverflowBarAlignment.center,
          actions: [
            TextButton(
              onPressed: closeDialog,
              child: const Text('Kanselahin', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: emerald),
              onPressed: () {
                if (isLoginMode) {
                  if (regEmail.text.trim().isEmpty || regPass.text.trim().isEmpty) {
                    setStateDialog(() {
                      errorMessage = 'Ilagay ang iyong Email Address at Password.';
                    });
                    return;
                  }
                  final loginError = AccountStore().login(regEmail.text.trim(), regPass.text.trim(), 'passenger');
                  if (loginError != null) {
                    setStateDialog(() {
                      errorMessage = loginError;
                    });
                    return;
                  }
                  setState(() {
                    _isLoggedIn = true;
                    loggedEmail = regEmail.text.trim();
                    final user = AccountStore().currentUser;
                    if (name.text.trim().isEmpty) {
                      name.text = (user != null && user.name.isNotEmpty) ? user.name : 'Pasahero (Naka-log in)';
                    }
                    if (phone.text.trim().isEmpty) {
                      phone.text = (user != null && user.phone.isNotEmpty) ? user.phone : '09123456789';
                    }
                    if (user != null) loggedIdType = user.idType;
                  });
                  closeDialog();
                  submitBooking();
                } else {
                  if (regName.text.trim().isEmpty || regPhone.text.trim().isEmpty || regEmail.text.trim().isEmpty || regPass.text.trim().isEmpty || regIdFile == null) {
                    setStateDialog(() {
                      errorMessage = 'Punan ang lahat ng fields at i-upload ang Valid ID.';
                    });
                    return;
                  }
                  if (!isIdValid) {
                    setStateDialog(() {
                      errorMessage = 'Hindi beripikado ang ID. Kailangang may Bacuag address ang ID.';
                    });
                    return;
                  }
                  // Itala ang account sa lokal na store (para magamit ng login popup
                  // sa itaas at ma-persist ang session). Best-effort lang ito.
                  AccountStore().signUp(
                    name: regName.text.trim(),
                    phone: regPhone.text.trim(),
                    email: regEmail.text.trim(),
                    password: regPass.text.trim(),
                    role: 'passenger',
                    idType: selectedIdType,
                  );
                  AccountStore().login(regEmail.text.trim(), regPass.text.trim(), 'passenger');
                  setState(() {
                    _isLoggedIn = true;
                    name.text = regName.text.trim();
                    phone.text = regPhone.text.trim();
                    loggedEmail = regEmail.text.trim();
                    loggedIdType = selectedIdType;
                  });
                  closeDialog();
                  submitBooking();
                }
              },
              child: Text(isLoginMode ? 'Mag-log in & I-send ang Booking' : 'Mag-sign Up & I-send ang Booking'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    BookingStore().addListener(_onStoreChanged);
    _bookingMapController = MapController();
    // 📌 Awtomatikong mag-pin sa GPS kung saan nakatayo ang pasahero pagbukas
    // ng booking map (tamang-tama kapag wala pang pin na napili ang pasahero).
    _autoPinFromGps();
    // 🛰️ Live GPS follow: kasabay gumagalaw ang pickup pin sa mapa habang
    // gumagalaw ang pasahero (hangga't hindi pa manu-manong tinak ang pin).
    _startGpsFollow();
    // 📥 Awtomatikong i-download ang offline pack kapag online — walang button
    // na kailangang pindutin (tinatawag SA ISANG BESES lang sa initState).
    _autoDownloadOfflineMap();
    // Kung may naka-save na pasahero sa session, ituloy ang pagka-log in kaagad.
    final user = AccountStore().currentUser;
    if (user != null && user.role == 'passenger') {
      _isLoggedIn = true;
      name.text = user.name;
      phone.text = user.phone;
      loggedEmail = user.email;
      loggedIdType = user.idType;
    }
    // I-reattach ang aktibong booking ng pasahero — ito ang pangunahing
    // hadlang sa panibagong booking habang may pending/aktibong biyahe
    // (kahit pagkatapos ng rebuild o pagbalik sa screen na ito).
    _reattachActiveBooking();
    // Tumatakbo habang buksan ang screen: nag-tick ng countdown at
    // nagde-detect ng pagdating ng rider sa pickup/destination area (GPS).
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) => _onUiTick());
  }

  @override
  void dispose() {
    _uiTicker?.cancel();
    _gpsFollowSub?.cancel();
    _bookingMapController?.dispose();
    BookingStore().removeListener(_onStoreChanged);
    name.dispose();
    phone.dispose();
    super.dispose();
  }

  /// Hanapin ang aktibong booking ng kasalukuyang pasahero sa store.
  void _reattachActiveBooking() {
    if (!_isLoggedIn || phone.text.trim().isEmpty) return;
    activeBooking = BookingStore().activeForPhone(phone.text.trim());
  }

  /// Bawat segundo: nag-tick ng countdown + GPS arrival detection.
  void _onUiTick() {
    if (!mounted) return;
    final b = activeBooking;
    if (b == null) return;

    // ⏱ Auto-cancel: 10 minutong walang rider na nagtanggap → kinakansela.
    if (BookingStore().autoCancelExpired()) {
      _showArrivalNotice(
        '⏱ Na-cancel ang booking ${b.id} — walang rider na nagtanggap sa loob ng 10 minuto.',
      );
      setState(() {});
      return;
    }

    if (b.status == 'completed' || b.status == 'cancelled') return; // static na

    // Arrival detection: kapag nasa loob na ng 45 m ang rider sa target,
    // awtomatikong ia-update ang status — pareho itong ginagawa ng rider side.
    if (b.riderLocation != null) {
      if ((b.status == 'accepted' || b.status == 'on_the_way') &&
          isWithinArrivalRadius(b.riderLocation!, b.pickup)) {
        BookingStore().updateStatus(b.id, 'arrived');
        _showArrivalNotice(
          '✅ Dumating na sa pickup area ang rider ${b.riderName ?? ''} — ikaw ba ang nakikita nila?'.trim(),
        );
        return;
      }
      if (b.status == 'arrived' &&
          b.destination != null &&
          isWithinArrivalRadius(b.riderLocation!, b.destination!)) {
        BookingStore().updateStatus(b.id, 'completed');
        _showArrivalNotice(
          '🎉 Nakarating na kayo sa destination — tapos na ang biyahe!',
        );
        return;
      }
    }
    setState(() {}); // i-tick ang countdown
  }

  void _showArrivalNotice(String message) {
    if (!mounted) return;
    setState(() {});
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 5),
        ),
      );
  }

  void _onStoreChanged() {
    if (activeBooking != null && mounted) {
      final updated = BookingStore().bookings.firstWhere(
            (b) => b.id == activeBooking!.id,
            orElse: () => activeBooking!,
          );
      setState(() => activeBooking = updated);
    }
  }

  Future<void> selectPhoto() async {
    final selected = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 75);
    if (selected != null && mounted) setState(() => photo = selected);
  }

  Future<void> _getCurrentGpsLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Naka-off ang GPS / Location services. Paki-on po.')),
        );
      }
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tinanggihan ang location permission.')),
          );
        }
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permanenteng tinanggihan ang location permissions sa settings.')),
        );
      }
      return;
    }

    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kinukuha ang kasalukuyang GPS location...')),
        );
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      setState(() {
        final currentLatLng = LatLng(position.latitude, position.longitude);
        if (selectingDestination) {
          destination = currentLatLng;
        } else {
          pickup = currentLatLng;
        }
      });
      _refreshPickupStreet();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Nakuha ang GPS: ${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hindi makuha ang GPS location: $e')),
        );
      }
    }
  }

  /// 📌 Awtomatikong mag-pin sa kasalukuyang GPS position (kung saan nakatayo
  /// ang pasahero) pagbukas ng booking map. Tahimik kapag walang permission,
  /// walang GPS, o wala sa sakop ng Poblacion Bacuag.
  Future<void> _autoPinFromGps() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final here = LatLng(position.latitude, position.longitude);
      if (!bacuagBounds.contains(here)) return; // wala sa service area
      _autoPinCandidate = here;
      _applyAutoPin();
    } catch (_) {
      // Walang GPS (hal. sa widget tests) — hindi kritikal, hindi pipilitin.
    }
  }

  /// 🛰️ Live GPS follow ng pasahero: bawat ilang segundo (kada ~3 m na galaw)
  /// ina-update ang asul na "nasaan ako" dot at ang pickup pin — kung saan
  /// man gumalaw ang pasahero, doon din gumagalaw ang pin sa mapa.
  /// Tumitigil sa pagsunod kapag minanu-manong tinap ang pin o may booking na.
  Future<void> _startGpsFollow() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      await _gpsFollowSub?.cancel();
      _gpsFollowSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 3, // bawat ~3 m na galaw ≈ ilang segundo
        ),
      ).listen((pos) {
        if (!mounted) return;
        final here = LatLng(pos.latitude, pos.longitude);
        if (!bacuagBounds.contains(here)) return; // wala sa sakop ng bayan
        _liveGpsLocation = here;
        if (!_manualPickupPin && activeBooking == null) {
          _autoPinned = true;
          _autoPinCandidate = here;
          pickup = here;
          if (_mapReady) _bookingMapController?.move(here, 17);
        }
        setState(() {});
        _refreshPickupStreet();
      });
    } catch (_) {
      // Walang GPS (hal. sa widget tests) — hindi kritikal, hindi pipilitin.
    }
  }

  /// Ilalagay ang auto pin kapag handa na ang map at wala pang pin ang pasahero.
  void _applyAutoPin() {
    if (_autoPinned || !_mapReady || _autoPinCandidate == null || !mounted) {
      return;
    }
    if (pickup != null) return; // may pin nang ginamit ang pasahero
    _autoPinned = true;
    final here = _autoPinCandidate!;
    setState(() => pickup = here);
    _bookingMapController?.move(here, 17);
    _refreshPickupStreet();
  }

  /// 🏷️ Kunin ang pangalan ng kalye ng pickup pin (reverse geocode).
  ///
  /// Ligtas paulit-ulit tawagin: naka-throttle ito sa 3 segundo at iisang tawag
  /// lang bawat ~11 m na lugar (4-decimal key), kaya hindi na-e-exceed ang
  /// Nominatim na 1 req/s na limit habang naka-GPS-follow. Kapag offline o
  /// walang sagot, mananatiling `null` ang [_pickupStreet] — hindi nag-a-error.
  Future<void> _refreshPickupStreet() async {
    final p = pickup;
    if (p == null) {
      if (_pickupStreet != null || _streetKey != null) {
        setState(() {
          _pickupStreet = null;
          _streetKey = null;
        });
      }
      return;
    }
    final key =
        '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}';
    if (key == _streetKey) return; // nakuha na ang lugar na ito
    final now = DateTime.now();
    if (now.difference(_lastStreetLookup) < const Duration(seconds: 3)) {
      return; // throttle — susubukan sa susunod na tick
    }
    _streetKey = key;
    _lastStreetLookup = now;

    final street = await lookupStreetName(p);
    if (!mounted || key != _streetKey) return; // gumalaw na ang pin
    setState(() => _pickupStreet = street);
  }

  double calculateFare() {
    if (pickup == null || destination == null) return 30.0; // Base fare
    const earthRadius = 6371.0;
    final dLat = (destination!.latitude - pickup!.latitude) * pi / 180;
    final dLon = (destination!.longitude - pickup!.longitude) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(pickup!.latitude * pi / 180) * cos(destination!.latitude * pi / 180) *
            sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    final distanceKm = earthRadius * c;
    final fare = 30.0 + (distanceKm * 15.0); // ₱30 base + ₱15 per km
    return fare < 30.0 ? 30.0 : fare;
  }

  void submitBooking() {
    if (name.text.trim().isEmpty || phone.text.trim().isEmpty || pickup == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ilagay ang pangalan, contact number, at i-tap ang pickup pin sa mapa.')),
      );
      return;
    }

    // Hadlang sa panibagong booking: kapag may pending/aktibong biyahe ang
    // numerong ito, ibalik ang user sa aktibong booking (may countdown) sa
    // halip na gumawa ng panibagong request.
    final existing = BookingStore().activeForPhone(phone.text.trim());
    if (existing != null) {
      setState(() => activeBooking = existing);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'May aktibong booking ka pa (${existing.id} — ${existing.status}). '
            'Hintayin matapos o i-kansela muna iyon bago mag-book muli.',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }

    final newBooking = BookingItem(
      id: 'BK-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}',
      name: name.text.trim(),
      phone: phone.text.trim(),
      pickup: pickup!,
      destination: destination,
      photoPath: photo?.path,
      status: 'pending',
    );

    BookingStore().addBooking(newBooking);
    setState(() => activeBooking = newBooking);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Tagumpay na naipadala ang E-Bike booking request! Naghahanap ng malapit na rider...')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_isLoggedIn)
          Container(
            color: emerald.withValues(alpha: 0.1),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment<int>(value: 0, label: Text('Mag-book ng E-Bike'), icon: Icon(Icons.map)),
                      ButtonSegment<int>(value: 1, label: Text('Aking Dashboard'), icon: Icon(Icons.dashboard)),
                    ],
                    selected: {_passengerTab},
                    onSelectionChanged: (v) => setState(() => _passengerTab = v.first),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: _passengerTab == 1 ? _buildPassengerDashboard() : _buildBookingContent(context),
        ),
      ],
    );
  }

  Widget _buildPassengerDashboard() {
    // Sakupin ang LAHAT ng booking ng pasaherong ito. Ang phone number ang
    // pangunahing pagkakakilanlan (ito ang ginagamit ng BookingStore sa
    // activeForPhone), at kasama pa rin ang parehong pangalan bilang fallback.
    //
    // dating: `b.name == name.text` — hindi tumutugma sa `name.text.trim()`
    // na aktwal na naka-save sa booking, kaya MANANATILING BLANKO ang
    // dashboard kahit naka-login na ang pasahero (bug #2).
    final myPhone = phone.text.trim();
    final myName = name.text.trim();
    final myBookings = BookingStore().bookings.where((b) {
      if (myPhone.isNotEmpty && b.phone == myPhone) return true;
      return myName.isNotEmpty && b.name.trim() == myName;
    }).toList();
    return ListView(
      // Ibang key kaysa sa booking list — para hindi pagsamahin ng Flutter ang
      // dalawang magkaibang list sa iisang ListView element (nagiging sanhi ng
      // 'child == null || indexOf(child) > index' na render assertion).
      key: const PageStorageKey<String>('passenger-dashboard-list'),
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Profile ng Pasahero', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: emerald)),
                    Chip(
                      avatar: const Icon(Icons.verified, color: Colors.white, size: 16),
                      label: const Text('Verified Resident', style: TextStyle(color: Colors.white, fontSize: 11)),
                      backgroundColor: emerald,
                    ),
                  ],
                ),
                const Divider(),
                const SizedBox(height: 8),
                Text('Pangalan: ${name.text.isEmpty ? "Hindi pa naka-login" : name.text}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('Contact: ${phone.text.isEmpty ? "—" : phone.text}', style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 4),
                Text('Email: ${loggedEmail.isEmpty ? "—" : loggedEmail}', style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 4),
                Text('Uri ng ID: $loggedIdType (Bacuag Address Verified)', style: const TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () async {
                    await AccountStore().signOut();
                    if (!mounted) return;
                    setState(() {
                      _isLoggedIn = false;
                      _passengerTab = 0;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Naka-log out na ang pasahero.')));
                  },
                  icon: const Icon(Icons.logout, color: Colors.red),
                  label: const Text('Mag-log out', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text('Kasaysayan ng Biyahe (Trip History)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        if (myBookings.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Wala pang nakatalang biyahe o booking.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
            ),
          )
        else
          ...myBookings.map((b) => Card(
                key: ValueKey<String>(b.id),
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: const CircleAvatar(backgroundColor: emerald, child: Icon(Icons.electric_rickshaw, color: Colors.white)),
                  title: Text('Booking ID: ${b.id}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    'Na-book: ${formatBookingTime(b.createdAt)} | Status: ${b.status.toUpperCase()} | Pickup: ${b.pickup.latitude.toStringAsFixed(3)}, ${b.pickup.longitude.toStringAsFixed(3)}',
                  ),
                  trailing: Chip(
                    label: Text(b.status, style: const TextStyle(fontSize: 10, color: Colors.white)),
                    backgroundColor: b.status == 'completed' ? Colors.green : Colors.orange,
                  ),
                ),
              )),
      ],
    );
  }

  Widget _buildBookingContent(BuildContext context) {
    final fare = calculateFare();

    if (activeBooking != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
      child: ListView(
        key: const PageStorageKey<String>('passenger-active-booking-list'),
        children: [
          const Icon(Icons.radar, size: 64, color: emerald),
            const SizedBox(height: 16),
            Text(
              'Booking Status: ${activeBooking!.status.toUpperCase()}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: emerald),
            ),
            const SizedBox(height: 12),
            // ⏱ Countdown hero card — nag-tick tuwing segundo habang may
            // aktibong biyahe; nagpapakita rin kung kailan na-book.
            Builder(
              builder: (context) {
                final b = activeBooking!;
                final eta = switch (b.status) {
                  'accepted' || 'on_the_way' => estimateEtaSeconds(
                      from: b.riderLocation ?? b.pickup,
                      to: b.pickup,
                      routePoints: b.routePoints,
                    ),
                  'arrived' => b.destination == null
                      ? 0
                      : estimateEtaSeconds(
                          from: b.riderLocation ?? b.pickup,
                          to: b.destination!,
                          routePoints: b.routePoints,
                        ),
                  _ => 0,
                };
                final label = switch (b.status) {
                  'pending' => 'Naghahanap ng rider…',
                  'accepted' || 'on_the_way' => 'Rider papunta sa pickup',
                  'arrived' => b.destination == null
                      ? 'Nasa pickup area na — sumakay na!'
                      : 'Papunta sa destination',
                  'completed' => 'Tapos na ang biyahe 🎉',
                  _ => 'Kinansela',
                };
                return Card(
                  color: emerald.withValues(alpha: 0.08),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.timer_outlined, size: 40, color: emerald),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                eta > 0
                                    ? '⏱ ETA: ${formatCountdown(eta)}'
                                    : b.status == 'pending'
                                        ? '⏱ Auto-cancel sa ${formatCountdown(pendingAutoCancelRemainingSeconds(b))}'
                                        : '⏱ Waiting…',
                                style: const TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w800,
                                  color: emerald,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                              Text(
                                label,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Na-book: ${formatBookingTime(b.createdAt)}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                              // 📏 Sukat: distansya at travel time sa target
                              // (o ng buong biyahe kapag pending pa).
                              if (b.status == 'pending' &&
                                  b.destination != null)
                                Text(
                                  '📏 ${measureTravelLabel(b.pickup, b.destination!)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                )
                              else if (b.status != 'pending' &&
                                  b.riderLocation != null)
                                Text(
                                  '📏 ${measureTravelLabel(
                                    b.riderLocation!,
                                    (b.status == 'arrived' &&
                                            b.destination != null)
                                        ? b.destination!
                                        : b.pickup,
                                  )}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 4),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Booking ID: ${activeBooking!.id}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const Divider(),
                    Text('Pangalan: ${activeBooking!.name}'),
                    Text('Contact: ${activeBooking!.phone}'),
                    Text('Pickup: ${activeBooking!.pickup.latitude.toStringAsFixed(4)}, ${activeBooking!.pickup.longitude.toStringAsFixed(4)}${_pickupStreet != null ? ' • 📍 $_pickupStreet' : ''}'),
                    if (activeBooking!.destination != null)
                      Text('Destination: ${activeBooking!.destination!.latitude.toStringAsFixed(4)}, ${activeBooking!.destination!.longitude.toStringAsFixed(4)}'),
                    if (activeBooking!.riderName != null) ...[
                      const SizedBox(height: 8),
                      Text('Assigned Rider: ${activeBooking!.riderName}', style: const TextStyle(color: emerald, fontWeight: FontWeight.bold)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (activeBooking!.status != 'pending' && activeBooking!.riderLocation != null) ...[
              const Text('Live Rider Tracking Map', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Builder(
                builder: (context) {
                  final targetPoint = (activeBooking!.status == 'arrived' && activeBooking!.destination != null)
                      ? activeBooking!.destination!
                      : activeBooking!.pickup;
                  return SizedBox(
                    height: 250,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: activeBooking!.pickup,
                          initialZoom: 15,
                          cameraConstraint: CameraConstraint.containCenter(bounds: bacuagBounds),
                          minZoom: 14,
                          maxZoom: 20, // z19+ = scale-up ng totoong tile, walang "data not available"
                        ),
                        children: [
                          ...mapTileLayers(satellite: _satelliteMode),
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: activeBooking!.routePoints.isNotEmpty
                                    ? activeBooking!.routePoints
                                    : getRoadRoutePoints(activeBooking!.riderLocation!, targetPoint),
                                color: Colors.blue,
                                strokeWidth: 4.0,
                              ),
                            ],
                          ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: activeBooking!.pickup,
                                width: 44,
                                height: 44,
                                child: const Icon(Icons.location_pin, color: Colors.red, size: 42),
                              ),
                              if (activeBooking!.destination != null)
                                Marker(
                                  point: activeBooking!.destination!,
                                  width: 44,
                                  height: 44,
                                  child: const Icon(Icons.flag, color: Colors.blue, size: 42),
                                ),
                              Marker(
                                point: activeBooking!.riderLocation!,
                                width: 44,
                                height: 44,                                  child: const Icon(Icons.electric_rickshaw, color: emerald, size: 42),
                              ),
                            ],
                          ),
                          mapModeToggle(
                            satellite: _satelliteMode,
                            onPressed: () =>
                                setState(() => _satelliteMode = !_satelliteMode),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              const Text(' pulang pin = Pickup | asul na watawat = Destination | berde = Rider', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
            const SizedBox(height: 16),
            if (activeBooking!.status == 'pending')
              const Center(child: CircularProgressIndicator(color: emerald))
            else
              Card(
                color: Colors.green.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    activeBooking!.status == 'accepted'
                        ? 'Tinanggap na ng rider ang iyong booking at papunta na sa pickup location!'
                        : activeBooking!.status == 'on_the_way'
                            ? 'Malapit na ang rider sa iyong kinaroroonan.'
                            : activeBooking!.status == 'arrived'
                                ? 'Dumating na ang e-sikad sa iyong pickup location!'
                                : activeBooking!.status == 'cancelled'
                                    ? 'Na-cancel ang booking — walang rider na nagtanggap sa loob ng 10 minuto. Puwede kang gumawa ng bagong booking.'
                                    : 'Natapos na ang iyong biyahe. Salamat sa pagsakay sa E-Bike!',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () => setState(() => activeBooking = null),
              child: const Text('Gumawa ng Bagong Booking'),
            ),
          ],
        ),
      );
    }

    return ListView(
      // Hiwalay na key para sa booking form list (tingnan ang dashboard list sa itaas).
      key: const PageStorageKey<String>('passenger-booking-form-list'),
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Maghanap ng E-Bike', style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('Bacuag Municipal Service Area Only', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: ChoiceChip(
                label: const Text('1. Pickup Pin'),
                selected: !selectingDestination,
                onSelected: (val) => setState(() => selectingDestination = false),
                selectedColor: emerald.withValues(alpha: 0.2),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ChoiceChip(
                label: const Text('2. Destination Pin'),
                selected: selectingDestination,
                onSelected: (val) => setState(() => selectingDestination = true),
                selectedColor: emerald.withValues(alpha: 0.2),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: _getCurrentGpsLocation,
          icon: const Icon(Icons.my_location, color: emerald),
          label: Text(selectingDestination ? 'Gamitin ang GPS para sa Destination' : 'Kunin ang kasalukuyang GPS ko para sa Pickup'),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 270,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: FlutterMap(
              mapController: _bookingMapController,
              options: MapOptions(
                initialCenter: poblacionBacuagCenter,
                initialZoom: 15,
                cameraConstraint: CameraConstraint.containCenter(bounds: bacuagBounds),
                minZoom: 14,
                maxZoom: 20, // z19+ = scale-up ng totoong tile, walang "data not available"
                onMapReady: () {
                  _mapReady = true;
                  _applyAutoPin();
                },                onTap: (_, point) {
                  setState(() {
                    if (selectingDestination) {
                      destination = point;
                    } else {
                      pickup = point;
                      // Ginusto ng pasahero ang pin — huwag nang sundan ng GPS.
                      _manualPickupPin = true;
                    }
                  });
                  _refreshPickupStreet();
                },
              ),
              children: [
                ...mapTileLayers(satellite: _satelliteMode),
                MarkerLayer(markers: [
                  if (_liveGpsLocation != null)
                    Marker(
                      point: _liveGpsLocation!,
                      width: 28,
                      height: 28,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.30),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.my_location, color: Colors.blue, size: 18),
                      ),
                    ),
                  if (pickup != null)
                    Marker(
                      point: pickup!,
                      width: 44,
                      height: 44,
                      child: const Icon(Icons.location_pin, color: Colors.red, size: 42),
                    ),
                  if (destination != null)
                    Marker(
                      point: destination!,
                      width: 44,
                      height: 44,
                      child: const Icon(Icons.flag, color: Colors.blue, size: 42),
                    ),
                ]),
                mapModeToggle(
                  satellite: _satelliteMode,
                  onPressed: () =>
                      setState(() => _satelliteMode = !_satelliteMode),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        // 📏 Measure + travel time ng biyahe (pickup → destination).
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            (pickup != null && destination != null)
                ? '📏 ${measureTravelLabel(pickup!, destination!)}'
                : '📏 I-tap ang pickup at destination sa map para sukatin ang distansya at travel time.',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 6),
        // 📥 Offline map status — text-only (tinanggal na ang "Handa offline"
        // na button); awtomatikong dina-download kapag online sa background.
        Row(
          children: [
            if (_offlineDownloading)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: emerald),
              )
            else
              Icon(
                _offlinePackComplete ? Icons.cloud_done : Icons.cloud_off,
                size: 14,
                color: emerald,
              ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _offlineStatusLabel,
                maxLines: 2,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(selectingDestination
            ? (destination == null ? 'I-tap ang mapa para ilagay ang DESTINATION.' : 'Destination: ${destination!.latitude.toStringAsFixed(4)}, ${destination!.longitude.toStringAsFixed(4)}')
            : (pickup == null ? 'I-tap ang mapa para ilagay ang PICKUP pin.' : 'Pickup: ${pickup!.latitude.toStringAsFixed(4)}, ${pickup!.longitude.toStringAsFixed(4)}${_pickupStreet != null ? '\n📍 $_pickupStreet' : ''}')),
        const SizedBox(height: 12),
        if (destination != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.teal.shade50, borderRadius: BorderRadius.circular(10)),
            child: Text('Tinatayang Pamasahe (Fare Estimate): ₱${fare.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, color: emerald)),
          ),
        const SizedBox(height: 12),
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Pangalan', border: OutlineInputBorder())),
        const SizedBox(height: 10),
        TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Contact number', border: OutlineInputBorder())),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: selectPhoto,
          icon: const Icon(Icons.camera_alt),
          label: Text(photo == null ? 'Kunan ng larawan ang pickup area (optional)' : 'Pickup photo selected'),
        ),
        if (photo != null) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: kIsWeb
                ? Image.network(photo!.path, height: 130, fit: BoxFit.cover)
                : Image.file(File(photo!.path), height: 130, fit: BoxFit.cover),
          ),
        ],
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _promptSignupBeforeBooking,
          icon: const Icon(Icons.local_taxi),
          label: const Text('Mag-request ng E-Bike'),
        ),
      ],
    );
  }
}

class RiderScreen extends StatefulWidget {
  const RiderScreen({super.key});

  @override
  State<RiderScreen> createState() => _RiderScreenState();
}

class _RiderScreenState extends State<RiderScreen> {
  bool isOnline = true;
  String riderName = 'Kuya Juan (Verified)';

  // 🛰️ Satellite mode ng tracking map.
  bool _satelliteMode = false;
  // ⏱ 1s ticker ng auto-cancel (10 minutong walang nag-accept na rider).
  Timer? _autoCancelTicker;

  // Real-time GPS sync: sinusubaybayan ang totoong posisyon ng rider habang
  // may aktibong biyahe para makita ng pasahero ang live na galaw at
  // awtomatikong ma-detect ang pagdating sa pickup/destination area (45 m).
  StreamSubscription<Position>? _gpsSub;
  bool _gpsStarting = false;
  Timer? _gpsRetryTimer;
  DateTime? _lastRouteFetch;
  String? _lastRouteTargetKey;

  // 🏷️ Street name ng pickup — GAANAP NAKIKITA NG RIDER (dating pasahero lang
  // ang may ganito). Synchronous na basasa mula sa shared na cache, at
  // ni-fetch nang background para hindi huminto ang UI.
  final Set<String> _streetFetches = {};

  // 🔔 Sound notification kapag may bagong booking request habang online.
  final AudioPlayer _bookingAlert = AudioPlayer();
  final Set<String> _chimedPendingIds = <String>{};

  @override
  void initState() {
    super.initState();
    BookingStore().addListener(_onStoreChanged);
    // Kung may naka-log in na rider sa session, gamitin ang pangalan nito.
    final user = AccountStore().currentUser;
    if (user != null && user.role == 'rider') {
      riderName = '${user.name} (Verified)';
    }
    _checkNewPendingAlerts();
    _syncGpsStream();
    // ⏱ Awtomatikong kinansela ang pending booking na lampas na sa 10 minuto
    // kahit nasa rider screen lang ang naka-bukas (hindi lang passenger side).
    _autoCancelTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (BookingStore().autoCancelExpired()) setState(() {});
    });
  }

  @override
  void dispose() {
    _gpsRetryTimer?.cancel();
    _autoCancelTicker?.cancel();
    _gpsSub?.cancel();
    _bookingAlert.dispose();
    BookingStore().removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    _refreshPickupStreets();
    setState(() {});
    _checkNewPendingAlerts();
    _syncGpsStream(); // simulan/ipitil ang GPS stream ayon sa estado ng biyahe
  }

  /// Kukunin (nang background) ang street name ng bawat pickup sa listahan.
  /// Isang tawag lang bawat lugar — pinoprotektahan ito ng [_streetFetches]
  /// para hindi paulit-ulit habang nagre-rebuild ang UI.
  void _refreshPickupStreets() {
    for (final b in BookingStore().bookings) {
      final key = _streetKeyFor(b.pickup);
      if (_streetNameCache.containsKey(key)) continue;
      if (!_streetFetches.add(key)) continue;
      lookupStreetName(b.pickup).then((_) {
        _streetFetches.remove(key);
        if (mounted) setState(() {});
      }).catchError((_) {
        _streetFetches.remove(key);
      });
    }
  }

  /// Tumutugtog ng alert sound para sa bawat bagong pending booking kapag
  /// naka-ONLINE ang rider account (isang beses bawat booking ID).
  void _checkNewPendingAlerts() {
    if (!isOnline) return;
    for (final b in BookingStore().bookings) {
      if (b.status == 'pending' && _chimedPendingIds.add(b.id)) {
        _playBookingAlert();
      }
    }
  }

  Future<void> _playBookingAlert() async {
    try {
      await _bookingAlert.stop();
      await _bookingAlert.play(AssetSource('sounds/new_booking.wav'));
    } catch (_) {
      // Walang audio output sa device/test — hindi mahalaga ang tunog.
    }
  }

  /// Ang aktibong biyahe ng riders na ito (accepted/on_the_way/arrived).
  BookingItem? get _myActiveTrip {
    for (final b in BookingStore().bookings) {
      if (b.riderName == riderName &&
          (b.status == 'accepted' ||
              b.status == 'on_the_way' ||
              b.status == 'arrived')) {
        return b;
      }
    }
    return null;
  }

  /// Nagsisimulang makinig sa totoong GPS kapag online AT may aktibong
  /// biyahe; tumitigil kapag wala nang biyahe o naka-offline ang rider.
  Future<void> _syncGpsStream() async {
    final shouldTrack = isOnline && _myActiveTrip != null;
    if (!shouldTrack) {
      _gpsRetryTimer?.cancel();
      _gpsRetryTimer = null;
      await _gpsSub?.cancel();
      _gpsSub = null;
      _lastRouteFetch = null;
      _lastRouteTargetKey = null;
      return;
    }
    if (_gpsSub != null || _gpsStarting) return;
    _gpsStarting = true;
    try {
      var permission = await Geolocator.checkPermission();
      debugPrint('[gps] checkPermission -> $permission');
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        debugPrint('[gps] requestPermission -> $permission');
      }
      final usable = permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
      // Muling suriin — maaaring nabago ang estado habang nag-aantay.
      if (!usable ||
          !mounted ||
          !isOnline ||
          _myActiveTrip == null) {
        debugPrint(
          '[gps] hindi simulan: usable=$usable mounted=$mounted '
          'online=$isOnline trip=${_myActiveTrip != null}',
        );
        _scheduleGpsRetry();
        return;
      }
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 8,
        ),
      ).listen(
        _onRiderGpsFix,
        onError: (Object error) {
          // hal. walang GPS signal — subukan ulit, manatili sa manual mode
          debugPrint('[gps] stream error: $error');
          _gpsSub = null;
          _scheduleGpsRetry();
        },
        onDone: () {
          debugPrint('[gps] stream done (natapos)');
          _gpsSub = null;
          _scheduleGpsRetry();
        },
      );
      debugPrint('[gps] stream started ✓');
    } catch (error) {
      // Walang GPS/location service — magagamit pa rin ang manual na
      // "Simulahin ang Pag-usad" button sa Tracking Map.
      debugPrint('[gps] start failed: $error');
      _scheduleGpsRetry();
    } finally {
      _gpsStarting = false;
    }
  }

  /// Awtomatikong subukan ulit ang GPS stream pagkalipas ng 5 segundo
  /// hangga\'t kailangan ito ng aktibong biyahe (transient failures).
  void _scheduleGpsRetry() {
    if (_gpsRetryTimer != null || !mounted) return;
    _gpsRetryTimer = Timer(const Duration(seconds: 5), () {
      _gpsRetryTimer = null;
      _syncGpsStream();
    });
  }

  /// Bawat bagong totoong GPS fix ng rider: live sync + arrival detection.
  void _onRiderGpsFix(Position position) {
    if (!mounted) return;
    final loc = LatLng(position.latitude, position.longitude);
    debugPrint(
      '[gps] fix lat=${position.latitude.toStringAsFixed(5)} '
      'lon=${position.longitude.toStringAsFixed(5)}',
    );
    // Iwasan ang fix na wala sa Bacuag (hal. default na GPS location ng
    // emulator) — hindi iyon totoong posisyon ng rider sa biyahe.
    if (!bacuagBounds.contains(loc)) return;

    final trip = _myActiveTrip;
    if (trip == null) return;

    final prev = trip.riderLocation;
    if (prev == null ||
        Geolocator.distanceBetween(
              prev.latitude,
              prev.longitude,
              loc.latitude,
              loc.longitude,
            ) >=
            2) {
      // Live na sync ng posisyon — nakikita ito ng pasahero real-time.
      BookingStore().updateRiderLocation(trip.id, loc);
    }

    // Arrival detection (kapareho ng panig ng pasahero): 45 m radius.
    if ((trip.status == 'accepted' || trip.status == 'on_the_way') &&
        isWithinArrivalRadius(loc, trip.pickup)) {
      BookingStore().updateStatus(trip.id, 'arrived');
      _notifyArrival(
        '✅ Dumating na kayo sa pickup area — awtomatikong naka-set ang status ng biyahe.',
      );
      return;
    }
    if (trip.status == 'arrived' &&
        trip.destination != null &&
        isWithinArrivalRadius(loc, trip.destination!)) {
      BookingStore().updateStatus(trip.id, 'completed');
      _notifyArrival(
        '🎉 Nakarating na sa destination — tapos na ang biyahe!',
      );
      return;
    }

    // I-refresh ang OSRM road route nang may throttle (hindi na-e-exceed
    // ang rate limit ng demo server) at kapag nagbago ang target.
    final target =
        trip.status == 'arrived' && trip.destination != null
            ? trip.destination!
            : trip.pickup;
    final targetKey = '${trip.id}:${trip.status}';
    final now = DateTime.now();
    final stale = _lastRouteFetch == null ||
        now.difference(_lastRouteFetch!) > const Duration(seconds: 12);
    if (stale || _lastRouteTargetKey != targetKey) {
      _lastRouteFetch = now;
      _lastRouteTargetKey = targetKey;
      BookingStore().updateRoute(trip.id, loc, target);
    }
    setState(() {}); // i-refresh ang marker/dialog
  }

  void _notifyArrival(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 5),
        ),
      );
    setState(() {});
  }

  void _openTrackingMap(BuildContext context, BookingItem booking) {
    final targetPoint = (booking.status == 'arrived' && booking.destination != null)
        ? booking.destination!
        : booking.pickup;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text('Auto-Map Guidance — ${booking.name} (${booking.status == 'arrived' ? 'Papuntang Destination' : 'Papuntang Pickup'})'),
            content: SizedBox(
              width: 480,
              height: 480,
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.teal.shade50, borderRadius: BorderRadius.circular(8)),
                    child: Text(
                      booking.status == 'arrived' && booking.destination != null
                          ? 'Gabay sa Daan (Destinasyon): Sundan ang mga lansangan patungo sa asul na destination flag.'
                          : 'Gabay sa Daan (Pickup): Sundan ang mga lansangan patungo sa pulang pickup pin.',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: emerald, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: targetPoint,
                          initialZoom: 16,
                          cameraConstraint: CameraConstraint.containCenter(bounds: bacuagBounds),
                          minZoom: 14,
                          maxZoom: 20, // z19+ = scale-up ng totoong tile, walang "data not available"
                        ),
                        children: [
                          ...mapTileLayers(satellite: _satelliteMode),
                          if (booking.riderLocation != null)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: booking.routePoints.isNotEmpty
                                      ? booking.routePoints
                                      : getRoadRoutePoints(booking.riderLocation!, targetPoint),
                                  color: Colors.blue,
                                  strokeWidth: 4.0,
                                ),
                              ],
                            ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: booking.pickup,
                                width: 50,
                                height: 50,
                                child: const Icon(Icons.location_pin, color: Colors.red, size: 44),
                              ),
                              if (booking.destination != null)
                                Marker(
                                  point: booking.destination!,
                                  width: 50,
                                  height: 50,
                                  child: const Icon(Icons.flag, color: Colors.blue, size: 44),
                                ),
                              if (booking.riderLocation != null)
                                Marker(
                                  point: booking.riderLocation!,
                                  width: 50,
                                  height: 50,
                                  child: const Icon(Icons.electric_rickshaw, color: emerald, size: 44),
                                ),
                            ],
                          ),
                          mapModeToggle(
                            satellite: _satelliteMode,
                            onPressed: () =>
                                setDialogState(() => _satelliteMode = !_satelliteMode),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (booking.riderLocation != null)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: emerald, foregroundColor: Colors.white),
                      onPressed: () async {
                        final distance = Geolocator.distanceBetween(
                          booking.riderLocation!.latitude,
                          booking.riderLocation!.longitude,
                          targetPoint.latitude,
                          targetPoint.longitude,
                        );

                        if (booking.status == 'arrived' && distance < 45) {
                          BookingStore().updateStatus(booking.id, 'completed');
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Nakarating na sa Destination Pin! Awtomatikong natapos ang biyahe.')),
                          );
                          return;
                        }

                        if (booking.status != 'arrived' && distance < 45) {
                          BookingStore().updateStatus(booking.id, 'arrived');
                          setDialogState(() {});
                          return;
                        }

                        // Move 40% closer to target point
                        final lat = booking.riderLocation!.latitude + (targetPoint.latitude - booking.riderLocation!.latitude) * 0.4;
                        final lng = booking.riderLocation!.longitude + (targetPoint.longitude - booking.riderLocation!.longitude) * 0.4;
                        final newLoc = LatLng(lat, lng);
                        BookingStore().updateRiderLocation(booking.id, newLoc);
                        await BookingStore().updateRoute(booking.id, newLoc, targetPoint);
                        setDialogState(() {});
                      },
                      icon: const Icon(Icons.navigation),
                      label: Text(booking.status == 'arrived' ? 'Simulahin ang Pag-usad patungong Destination' : 'Simulahin ang Pag-usad patungong Pickup'),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    booking.riderLocation != null
                        ? '${measureTravelLabel(booking.riderLocation!, targetPoint)}  •  Target: ${targetPoint.latitude.toStringAsFixed(5)}, ${targetPoint.longitude.toStringAsFixed(5)}'
                        : 'Target: ${targetPoint.latitude.toStringAsFixed(5)}, ${targetPoint.longitude.toStringAsFixed(5)}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Isara'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _zoomPhoto(BuildContext context, String photoPath) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: kIsWeb
                    ? Image.network(photoPath)
                    : Image.file(File(photoPath)),
              ),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 30),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allBookings = BookingStore().bookings;
    final pendingOrActive = allBookings.where((b) => b.status != 'completed' && b.status != 'cancelled').toList();
    final completedTrips = allBookings.where((b) => b.riderName == riderName && b.status == 'completed').toList();

    final hasActiveBooking = pendingOrActive.any(
      (b) => b.riderName == riderName && (b.status == 'accepted' || b.status == 'on_the_way' || b.status == 'arrived'),
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Rider Dashboard', style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
            Switch(
              value: isOnline,
              activeThumbColor: emerald,
              onChanged: (val) => setState(() {
                isOnline = val;
                _syncGpsStream(); // simulan/ipitil ang GPS sync ayon sa online state
              }),
            ),
          ],
        ),
        Text(isOnline ? 'Online - Ready for bookings' : 'Offline', style: TextStyle(color: isOnline ? emerald : Colors.red, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(
                children: [
                  Icon(Icons.verified_user, color: emerald, size: 28),
                  SizedBox(width: 8),
                  Text('Rider Verified', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
              const SizedBox(height: 4),
              Text('Driver: $riderName'),
              const Text('Service Area: Bacuag, Surigao del Norte'),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          color: Colors.teal.shade50,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(
                  children: [
                    const Text('Kabuuang Pickup / Biyahe', style: TextStyle(color: Colors.black54, fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text('${completedTrips.length}', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: emerald)),
                  ],
                ),
                const SizedBox(height: 30, child: VerticalDivider(color: Colors.teal)),
                Column(
                  children: [
                    const Text('Rider Status', style: TextStyle(color: Colors.black54, fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(isOnline ? 'Aktibo (Online)' : 'Offline', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: isOnline ? emerald : Colors.red)),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (hasActiveBooking) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(8)),
            child: const Text(
              '⚠️ Mayroon kang kasalukuyang aktibong biyahe. Hindi ka maaaring tumanggap ng bagong booking hangga\'t hindi mo ito tinatapos o ikinakansela.',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.brown),
            ),
          ),
        ],
        const SizedBox(height: 12),
        const Text('Mga Papasok na Booking Requests', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (!isOnline)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('Kailangan mong maging ONLINE para makatanggap ng mga booking requests.')),
          )
        else if (pendingOrActive.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('Walang kasalukuyang booking request sa Bacuag area.')),
          )
        else
          ...pendingOrActive.map((booking) {
            final isAssignedToMe = booking.riderName == riderName;
            final isMineActive = isAssignedToMe && (booking.status == 'accepted' || booking.status == 'on_the_way' || booking.status == 'arrived');

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(booking.id, style: const TextStyle(fontWeight: FontWeight.bold, color: emerald)),
                        Chip(
                          label: Text(booking.status.toUpperCase()),
                          backgroundColor: booking.status == 'pending' ? Colors.orange.shade100 : Colors.green.shade100,
                        ),
                      ],
                    ),
                    const Divider(),
                    Text('Pangalan: ${booking.name}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    Text('Contact: ${booking.phone}'),
                    // Oras ng pag-book ng pasahero — nakikita ng rider.
                    Text(
                      'Na-book: ${formatBookingTime(booking.createdAt)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: emerald,
                      ),
                    ),
                    // ⏱ Countdown bago ma-auto-cancel kung walang magtanggap.
                    if (booking.status == 'pending') ...[
                      const SizedBox(height: 2),
                      Text(
                        '⏱ Mag-a-auto-cancel sa ${formatCountdown(pendingAutoCancelRemainingSeconds(booking))} kung walang magtanggap',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.orange.shade700,
                        ),
                      ),
                    ],
                    Text('Pickup: ${booking.pickup.latitude.toStringAsFixed(4)}, ${booking.pickup.longitude.toStringAsFixed(4)}${cachedStreetName(booking.pickup) != null ? '\n📍 ${cachedStreetName(booking.pickup)}' : ''}'),
                    if (booking.destination != null)
                      Text('Destination: ${booking.destination!.latitude.toStringAsFixed(4)}, ${booking.destination!.longitude.toStringAsFixed(4)}'),
                    if (booking.riderName != null)
                      Text('Rider: ${booking.riderName}', style: const TextStyle(color: emerald, fontWeight: FontWeight.bold)),
                    if (booking.photoPath != null) ...[
                      const SizedBox(height: 8),
                      const Text('Larawan ng Pickup Area (I-click para i-zoom):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blueGrey)),
                      const SizedBox(height: 4),
                      GestureDetector(
                        onTap: () => _zoomPhoto(context, booking.photoPath!),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              kIsWeb
                                  ? Image.network(booking.photoPath!, height: 120, width: double.infinity, fit: BoxFit.cover)
                                  : Image.file(File(booking.photoPath!), height: 120, width: double.infinity, fit: BoxFit.cover),
                              Container(
                                color: Colors.black26,
                                padding: const EdgeInsets.all(6),
                                child: const Icon(Icons.zoom_in, color: Colors.white, size: 30),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _openTrackingMap(context, booking),
                          icon: const Icon(Icons.map, color: emerald),
                          label: const Text('Tracking Map'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Wrap (hindi Row) — kung Row, napuputol sa kanan ang
                    // mahabang label tulad ng "I-cancel (Wala ang Pasahero)"
                    // at "Tapusin ang Biyahe" sa masikip na telepono.
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (booking.status == 'pending')
                          if (hasActiveBooking)
                            const Text('May aktibo kang biyahe', style: TextStyle(color: Colors.grey, fontSize: 12))
                          else
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(backgroundColor: emerald, foregroundColor: Colors.white),
                              onPressed: () {
                                // ⏱ Hindi na puwedeng tanggapin kapag lampas na
                                // sa 10 minutong paghihintay (auto-cancel na ito).
                                if (isPendingAutoCancelDue(booking)) {
                                  BookingStore().autoCancelExpired();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Na-expire na ang booking na ito — lampas sa 10 minutong walang rider na nagtanggap.'),
                                    ),
                                  );
                                  return;
                                }
                                BookingStore().updateStatus(booking.id, 'accepted', riderName: riderName);
                              },
                              icon: const Icon(Icons.check),
                              label: const Text('Tanggapin'),
                            ),
                        if (isMineActive && booking.status == 'accepted')
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                            onPressed: () => BookingStore().updateStatus(booking.id, 'on_the_way'),
                            icon: const Icon(Icons.directions_bike),
                            label: const Text('Papunta Na'),
                          ),
                        if (isMineActive && booking.status == 'on_the_way')
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                            onPressed: () => BookingStore().updateStatus(booking.id, 'arrived'),
                            icon: const Icon(Icons.location_on),
                            label: const Text('Dumating Na'),
                          ),
                        if (isMineActive && booking.status == 'arrived') ...[
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, foregroundColor: Colors.white),
                            onPressed: () => BookingStore().cancelBooking(booking.id),
                            icon: const Icon(Icons.cancel),
                            label: const Text('I-cancel (Wala ang Pasahero)'),
                          ),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                            onPressed: () => BookingStore().updateStatus(booking.id, 'completed'),
                            icon: const Icon(Icons.done_all),
                            label: const Text('Tapusin ang Biyahe'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
        const SizedBox(height: 16),
        const Text('Kasaysayan ng mga Natapos na Biyahe (Recent Trips)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (completedTrips.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Wala pang natatapos na biyahe o pickup ngayong araw.', style: TextStyle(color: Colors.grey)),
          )
        else
          ...completedTrips.map((trip) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const CircleAvatar(backgroundColor: emerald, child: Icon(Icons.check, color: Colors.white)),
                  title: Text('${trip.name} (${trip.id})', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('Pickup: ${trip.pickup.latitude.toStringAsFixed(4)}, ${trip.pickup.longitude.toStringAsFixed(4)}'),
                  trailing: const Chip(label: Text('COMPLETED', style: TextStyle(fontSize: 10, color: Colors.white)), backgroundColor: emerald),
                ),
              )),
      ],
    );
  }
}

