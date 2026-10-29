import 'package:flutter_test/flutter_test.dart';
import 'package:sakay_bacuag/offline_tiles.dart';

void main() {
  test('tile math: kilala ang tile ng Poblacion center sa bawat zoom', () {
    for (var z = offlineMinZoom; z <= offlineMaxZoom; z++) {
      final x = tileXFromLongitude(poblacionBacuagCenter.longitude, z);
      final y = tileYFromLatitude(poblacionBacuagCenter.latitude, z);
      expect(
        poblacionOfflineTiles().contains((z, x, y)),
        isTrue,
        reason: 'Ang tile ng Poblacion center ($z/$x/$y) ay dapat kasama sa pack',
      );
    }
  });

  test('tile math: edge cases ng Web Mercator', () {
    expect(tileXFromLongitude(0, 0), 0);
    expect(tileYFromLatitude(0, 0), 0);
    // z1: kanan/kaliwang hemisperyo at hilaga/timog.
    expect(tileXFromLongitude(-90, 1), 0);
    expect(tileXFromLongitude(90, 1), 1);
    expect(tileYFromLatitude(45, 1), 0);
    expect(tileYFromLatitude(-45, 1), 1);
    // Out-of-range ay iki-clamp sa loob ng mundo.
    expect(tileXFromLongitude(190, 5), (1 << 5) - 1);
    expect(tileYFromLatitude(89.9, 5), 0);
  });

  test('offline pack: makatwiran ang laki at walang duplicate', () {
    final tiles = poblacionOfflineTiles();
    // Kasalukuyang sakop: z12–z13 ±0.014°, z14–z15 ±0.012°, z16–z17 ±0.0103°
    // = 111 tile (1+2+4+12+20+72). Sinisiguro ng range na hindi bumalik sa
    // dating mas malawak na ±0.018° (306 tiles) at hindi rin mangulang.
    expect(tiles.length, inInclusiveRange(100, 200));
    expect(tiles.toSet().length, tiles.length, reason: 'Walang duplicate tile');
    expect(
      tiles.every((t) => t.$1 >= offlineMinZoom && t.$1 <= offlineMaxZoom),
      isTrue,
    );
    // Lahat ng tile ay nasa loob ng bbox (±offlineHalfExtentDegrees) sa pinakamataas na zoom.
    final z = offlineMaxZoom;
    final minTileX = tileXFromLongitude(
        poblacionBacuagCenter.longitude - offlineHalfExtentDegrees, z);
    final maxTileX = tileXFromLongitude(
        poblacionBacuagCenter.longitude + offlineHalfExtentDegrees, z);
    expect(
      tiles.where((t) => t.$1 == z).every((t) => t.$2 >= minTileX && t.$2 <= maxTileX),
      isTrue,
    );
  });

  test('OSM tile URL format', () {
    expect(
      osmTileUrl(15, 12345, 14392),
      'https://tile.openstreetmap.org/15/12345/14392.png',
    );
  });
}
