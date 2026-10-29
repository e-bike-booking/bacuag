# E-Sikad — Start Here

**Current state:** the old FlyTicket demo API (which expired and showed
"FlyTicket demo expired!") is **gone**. Routing now runs on the public OSRM router
with a geometric straight-line ETA fallback, so trips always get a route and an
estimate — offline or online.

## What's in this repo

| Path | Purpose |
| --- | --- |
| `lib/main.dart` | Entire Flutter app (~3.3k lines): Passenger screen, Rider screen, Login/Signup (with ID-scan auto-fill), BookingStore, AccountStore, GPS following, geofence, offline map status line |
| `lib/offline_tiles.dart` | `OfflineMapStore` — pre-computes and downloads the Poblacion Bacuag tile pack; `configureCache()` runs before `runApp`, `startAutoDownload()` kicks off once online. **No button in UI** — status shows as text under the map. |
| `index.html` (root) | Landing page: hero, features, APK download, app preview, sign-up, contact |
| `admin/index.html` | Admin portal — same landing content + admin console (riders, passengers, bookings, boundary tabs) |
| `docs/index.html` | Duplicate of landing page for GitHub Pages `/docs` path |
| `web/` | Flutter Web build output (base href `/Sakay_Bacuag_App/`) |
| `assets/boundaries/bacuag.geojson` | **Placeholder** — swap with official LGU GeoJSON before enforcing the geofence |
| `firestore.rules`, `storage.rules`, `database.rules.json` | Firebase security rules (Firestore, Storage, Realtime DB) |
| `functions/` | Firebase Cloud Functions (TypeScript) |
| `test/` | 8 Flutter test files: booking flow, GPS arrival (45 m), auto-cancel (10 min), ID scan OCR, ID name extractor, offline tiles, login screen, passenger screen, widget smoke test |

## How routing / ETA works (post-repair)

1. `BookingStore.updateRoute()` → calls OSRM public API
   (`router.project-osrm.org/route/v1/driving/...`, 8 s timeout) for a real road polyline.
2. The polyline is stored in `Booking.routePoints`; `FlutterMap` draws it as a `Polyline`,
   and every successful result is saved to the **offline route cache**
   (`sakay_route_cache_v1` in SharedPreferences, capped at 80 routes).
3. `routeDistanceMeters()` sums the polyline segments (haversine);
   `estimateEtaSeconds(from, to, routePoints)` divides distance by an assumed speed —
   this is the trigonometric "geometric ETA" fallback and needs **no network**.
4. If OSRM fails (offline / rate-limited), the code first reuses the **cached real road
   polyline** for that same pickup→destination pair (rounded to ~11 m), so repeat trips
   still follow actual streets while offline.
5. Only when there is no cached route yet does it synthesise the L-shaped fallback
   (`getRoadRoutePoints()` / the grid-corner list) — so the polyline is never empty and
   **no "expired" dialog can appear**.

## Things to know

- **Offline map:** automatic, resumable, per-tile. The old "Handa offline" button was
  removed; you'll see a status line under the booking map instead
  (`✅ Offline map handa: Poblacion Bacuag (N tiles).`).
- **ID verification:** `scanIdCard()` OCRs the uploaded ID, then `extractNameFromId()`
  parses `SURNAME` / `GIVEN|FIRST NAME` lines and **auto-fills the Full Name** field.
- **Pickup street name:** the pickup pin is reverse-geocoded through Nominatim and the
  street name is shown next to the pin coordinates. Lookups are throttled to one per 3 s
  and memoised per ~11 m cell, so GPS follow does not hammer the API; offline or with no
  result it simply shows no street (`placeNameFromNominatim()` is a pure, tested parser).
- **Demo accounts** (seeded in both app & admin portal):

  | Email | Password | Role |
  | --- | --- | --- |
  | `rider@sakaybacuag.ph` | `rider123` | Rider |
  | `passenger@sakaybacuag.ph` | `passenger123` | Passenger |

- **Geofence:** bounds derived from `assets/boundaries/bacuag.geojson` — currently a
  placeholder polygon; replace with the official municipal boundary before relying on
  it for service-area enforcement.
- **Map layers:** OSM street + Esri satellite (toggle via `mapModeToggle`); tiles cached
  offline via `flutter_map_tile_caching`.

## Run it

```bash
flutter pub get
flutter test        # all 8 test files, offline-safe
flutter run         # device/emulator
flutter build web   # regenerates web/ (base href already set to /Sakay_Bacuag_App/)
```

Static pages (`index.html`, `admin/index.html`, `docs/index.html`) need no build —
open them directly or serve via GitHub Pages.

## Known gaps (pre-existing, not blockers)

1. `assets/boundaries/bacuag.geojson` is fabricated — get official LGU data.
2. Landing-page APK download button triggers `downloadApk()`, which currently just
   `alert()`s (no real APK committed). Point it at a real release or host the file.
3. Admin portal and docs page duplicate the landing page copy — keep them in sync or
   generate from one source.
4. Demo credentials are exposed in the landing page footer (by design for testing;
   disable before production).
5. Firebase config (demo project) — replace `web/firebase-config.js` values and
   `firestore.rules` before deploying the backend.