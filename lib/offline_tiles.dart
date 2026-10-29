// ---------------------------------------------------------------------------
// Offline map para sa Poblacion, Bacuag.
//
// Ang app ay gumagamit ng built-in persistent tile cache ng flutter_map
// (BuiltInMapCachingProvider) — lahat ng tatlong FlutterMap ay awtomatikong
// sumusuri sa cache MUNO bago mag-network, at ang mga fresh na naka-cache na
// tile ay ibinibigay kahit walang internet.
//
// Ang module na ito:
//  1. Ini-configure ang cache sa app SUPPORT directory (hindi basta-basta
//     nila-clear ng OS, kagaya ng default na cache directory) sa main().
//  2. Nagda-download ng tiles para sa Poblacion Bacuag + Siwata (z12–z17)
//     papunta sa
//     cache na iyon, na may staleAt = taon 2100 — kaya ang mga tile ng
//     offline pack ay HINDI NA MAGIGING STALE at makukuha mula sa cache
//     magpakailanman kahit walang internet.
//
// Online: ang mga tile na wala pa sa cache ay dinadownload mula sa
// tile.openstreetmap.org at awtomatikong nai-save sa cache (default na
// ugali ng flutter_map) — kaya pagbalik mo sa lugar, mula sa cache na.
// Offline: ang nasa cache at hindi pa stale ay ibinibigay nang walang
// network request — gumagana ang mapa kahit naka-airplane mode.
// ---------------------------------------------------------------------------

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

/// Sentro ng service area ng Bacuag — gitna ng opisyal na 5 hangganan
/// (tingnan ang `bacuagBounds` sa main.dart).  Dati itong 9.6078, 125.6396.
const poblacionBacuagCenter = LatLng(9.611550247533213, 125.636533638937408);

/// Zoom levels na kasama sa offline pack.
const offlineMinZoom = 12;
const offlineMaxZoom = 17;

/// Serbisyo-sakop ng mapa: OPISYAL NA 5 HANGGANAN NG BACUAG.
/// ~2.6 km bawat panig ng center — sapat na matakpan ang kabuuan ng bbox ng
/// mga hangganan (kailangan ng 0.011831° sa lat at 0.010043° sa lng), kaya
/// may offline tile sa buong nakikitang area at WALA nang labas nito.
/// Ginagamit sa z16–z17 (malalalim na zoom ng bayan).
const offlineHalfExtentDegrees = 0.0119;

/// Bawat zoom may sariling cover ng Poblacion pack:
///  - z12–z13: ±0.014° — sapat na konteksto, hindi sakop ang malalayong barangay;
///  - z14–z15: ±0.012°;
///  - z16–z17: [offlineHalfExtentDegrees] — Poblacion lang.
/// Kung bakit hindi iisang extent: ang malalalim na zoom ay maraming tile;
/// dito, malalim na zoom ay para sa sentro ng bayan lang.
///
/// Lahat ng extent ay masikip kaysa sa lat/lon ng Boyongan, Pananay-an,
/// Campo at Cabugao — hindi sila kasama sa map o sa offline pack.
double halfExtentDegreesFor(int zoom) => switch (zoom) {
      <= 13 => 0.014,
      14 || 15 => 0.012,
      _ => offlineHalfExtentDegrees,
    };

/// URL ng OpenStreetMap tile.
String osmTileUrl(int z, int x, int y) => 'https://tile.openstreetmap.org/$z/$x/$y.png';

/// Tile X mula sa longitude (Web Mercator).
int tileXFromLongitude(double lon, int zoom) {
  final n = 1 << zoom;
  final x = ((lon + 180.0) / 360.0 * n).floor();
  return x.clamp(0, n - 1);
}

/// Tile Y mula sa latitude (Web Mercator, north = maliit na Y).
int tileYFromLatitude(double lat, int zoom) {
  final n = 1 << zoom;
  final r = lat * math.pi / 180.0;
  final y = (1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) / 2.0 * n;
  return y.floor().clamp(0, n - 1);
}

/// Lahat ng (zoom, x, y) tile na sakop ng Poblacion offline pack.
List<(int, int, int)> poblacionOfflineTiles() {
  final tiles = <(int, int, int)>[];
  for (var z = offlineMinZoom; z <= offlineMaxZoom; z++) {
    final half = halfExtentDegreesFor(z);
    final minLon = poblacionBacuagCenter.longitude - half;
    final maxLon = poblacionBacuagCenter.longitude + half;
    final minLat = poblacionBacuagCenter.latitude - half;
    final maxLat = poblacionBacuagCenter.latitude + half;
    final x0 = tileXFromLongitude(minLon, z);
    final x1 = tileXFromLongitude(maxLon, z);
    final y0 = tileYFromLatitude(maxLat, z); // hilaga → mas maliit na Y
    final y1 = tileYFromLatitude(minLat, z);
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        tiles.add((z, x, y));
      }
    }
  }
  return tiles;
}

/// Tagapamahala ng offline tile pack ng Poblacion Bacuag.
class OfflineMapStore {
  OfflineMapStore._();

  /// Taon 2100: praktikal na "walang katapusan" ang freshness ng offline pack.
  static final DateTime _packStaleAt = DateTime.utc(2100);

  static bool _cacheConfigured = false;

  /// Awtomatik na nag-download ng buong Poblacion pack (resumable, may
  /// progress). Tawagin sa app start kapag online — KAILANGAN munang ma-configure
  /// ang cache [configureCache] bago ito tawagin, kung hindi ay walang mapupuntahan
  /// ang mga tile.
  static Future<void>? _prewarm;

  static void startAutoDownload() {
    if (kIsWeb) return;
    _prewarm ??= _autoDownload();
  }

  static Future<void> _autoDownload() async {
    try {
      await configureCache();
      await downloadPoblacion();
      debugPrint(
        'Offline map: Poblacion pack handa na — kahit walang internet.',
      );
    } catch (e) {
      // Hal. walang internet sa sandaling ito — susubukan sa susunod na launch.
      debugPrint('Offline map: hindi na-download ang pack ($e)');
      _prewarm = null;
    }
  }

  /// Tawagin sa main() BAGO ang runApp, bago pa mag-render ang alin mang mapa,
  /// para ang buong app ay gumamit ng parehong cache directory.
  static Future<void> configureCache() async {
    if (kIsWeb || _cacheConfigured) return;
    try {
      final dir = await getApplicationSupportDirectory();
      // Ang kanyang 'fm_cache' child directory ang lahat ng tile ng app.
      // Support dir (hindi OS-cleared) + 500 MB para hindi maubos agad.
      BuiltInMapCachingProvider.getOrCreateInstance(
        cacheDirectory: dir.path,
        maxCacheSize: 500 * 1000 * 1000,
      );
      _cacheConfigured = true;
    } catch (e) {
      // Kapag walang path_provider (hal. widget tests): hayaang bumuo ng
      // default instance ang flutter_map gaya ng dati — hindi nakakamatay.
      debugPrint('Offline map: hindi na-configure ang cache ($e)');
    }
  }

  static MapCachingProvider get _cache => BuiltInMapCachingProvider.getOrCreateInstance();

  /// Kung ilan sa mga pack tile ang nasa cache na (para sa status display).
  static Future<int> downloadedTileCount() async {
    const concurrency = 8;
    final tiles = poblacionOfflineTiles();
    var count = 0;
    for (var i = 0; i < tiles.length; i += concurrency) {
      final batch = tiles.sublist(
        i,
        math.min(i + concurrency, tiles.length),
      );
      final results = await Future.wait(batch.map((t) async {
        final (z, x, y) = t;
        try {
          return await _cache.getTile(osmTileUrl(z, x, y)) != null;
        } catch (_) {
          // Basura/korap na entry — itinuturing na hindi pa naka-download.
          return false;
        }
      }));
      count += results.where((present) => present).length;
    }
    debugPrint('Offline map: cached pack tiles = $count/${tiles.length}');
    return count;
  }

  /// Mabilis na pagsusuri kung may internet BAGO simulan ang pack download —
  /// isang tunay na OSM tile request (z12 center tile ng pack: maliit, ~1 KB).
  ///
  /// `false` kapag offline, nag-timeout, o tinanggihan ng server, kaya HINDI
  /// kailanman nagta-throw — ligtas tawagin mula sa initState ng screen.
  /// Kapag offline, simpleng babalik ito at susubukin muli sa susunod na
  /// pagbubukas ng app (resumable pa rin ang download sa oras na iyon).
  static Future<bool> hasConnectivity({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    const z = offlineMinZoom;
    final url = osmTileUrl(
      z,
      tileXFromLongitude(poblacionBacuagCenter.longitude, z),
      tileYFromLatitude(poblacionBacuagCenter.latitude, z),
    );
    final client = http.Client();
    try {
      final resp = await client
          .get(
            Uri.parse(url),
            headers: {'User-Agent': 'flutter_map (ph.sakaybacuag.app)'},
          )
          .timeout(timeout);
      return resp.statusCode == 200 && resp.bodyBytes.isNotEmpty;
    } catch (_) {
      // Walang internet / timeout / DNS failure — itinuturing na offline.
      return false;
    } finally {
      client.close();
    }
  }

  /// Nag-iisang pack download sa buong app (single-flight). Dati ay sabay na
  /// tumatakbo ang download mula sa `main()` (walang UI) at mula sa
  /// PassengerScreen (may status line) — pareho silang humihiling sa OSM para
  /// sa parehong 111 tile. Ngayon ang ikalawang tawag ay SUMASALI sa
  /// tumatakbong future imbis na magbukas ng bagong hiling.
  static Future<({int total, int downloaded, int failed, int skipped})>?
      _inFlight;

  /// Mga tagamasid ng progreso/finish ng kasalukuyang takbo (hal. ang status
  /// line ng passenger map). Nila-clear sa pagtatapos ng bawat takbo.
  static final List<void Function(int done, int total)> _progressListeners = [];
  static final List<void Function()> _finishListeners = [];

  /// Nagda-download ng Poblacion pack — o sumasali sa kasalukuyang takbo.
  /// Ang [onProgress] / [onFinish] ay tinatawag nang live kahit sumali ka lang
  /// sa gitna ng pag-download.
  static Future<({int total, int downloaded, int failed, int skipped})>
      downloadPoblacion({
    void Function(int done, int total)? onProgress,
    void Function()? onFinish,
  }) {
    if (onProgress != null) _progressListeners.add(onProgress);
    if (onFinish != null) _finishListeners.add(onFinish);
    return _inFlight ??= _runDownloadPoblacion().whenComplete(() {
      _inFlight = null;
      _progressListeners.clear();
      _finishListeners.clear();
    });
  }

  /// Nagda-download ng lahat ng Poblacion pack tile papunta sa cache.
  ///
  /// Resumable: ang mga tile na nasa cache na ay nilalaktawan.
  /// Magalang sa OSM tile server: 3 magkakasabay na hiling lang.
  static Future<({int total, int downloaded, int failed, int skipped})>
      _runDownloadPoblacion() async {
    final tiles = poblacionOfflineTiles();
    final total = tiles.length;
    var done = 0;
    var downloaded = 0;
    var failed = 0;
    var skipped = 0;

    final client = http.Client();
    try {
      const concurrency = 3;
      for (var i = 0; i < tiles.length; i += concurrency) {
        final end = math.min(i + concurrency, tiles.length);
        await Future.wait(tiles.sublist(i, end).map((t) async {
          final (z, x, y) = t;
          final url = osmTileUrl(z, x, y);
          try {
            final existing = await _cache.getTile(url);
            if (existing != null) {
              if (existing.metadata.staleAt.isBefore(_packStaleAt)) {
                // Na-cache na habang online (HTTP freshness — maagang magiging
                // stale). I-re-stamp gamit ang parehong bytes — walang network —
                // para maging offline-forever ang pack tile na ito.
                await _cache.putTile(
                  url: url,
                  metadata: CachedMapTileMetadata(
                    staleAt: _packStaleAt,
                    lastModified: null,
                    etag: null,
                  ),
                  bytes: existing.bytes,
                );
              }
              skipped++; // kasama na sa pack (na-cache na o na-re-stamp)
            } else {
              final resp = await client.get(
                Uri.parse(url),
                headers: {'User-Agent': 'flutter_map (ph.sakaybacuag.app)'},
              );
              if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
                await _cache.putTile(
                  url: url,
                  metadata: CachedMapTileMetadata(
                    staleAt: _packStaleAt,
                    lastModified: null,
                    etag: null,
                  ),
                  bytes: resp.bodyBytes,
                );
                downloaded++;
              } else {
                failed++;
              }
            }
          } catch (_) {
            failed++;
          }
          done++;
          for (final l in List.of(_progressListeners)) {
            l.call(done, total);
          }
        }));
      }
    } finally {
      client.close();
    }

    for (final l in List.of(_finishListeners)) {
      l.call();
    }

    return (
      total: total,
      downloaded: downloaded,
      failed: failed,
      skipped: skipped,
    );
  }
}
