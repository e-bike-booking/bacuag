# E-Sikad — Flutter + Firebase starter

This is a **starter source project**, not a finished production APK. It provides:
- Flutter app shell with Passenger / Rider modes and emerald-green theme
- OpenStreetMap-based map view via `flutter_map`
- Booking form UI with location pin selection and optional pickup photo
- Firestore schema, conservative security rules, and Firebase Cloud Functions starter
- A deliberate placeholder for the verified Bacuag boundary polygon

## Important: boundary is not fabricated
`assets/boundaries/bacuag.geojson` is a placeholder and intentionally contains no coordinates.
Do not enable production booking until the Bacuag municipal boundary polygon has been obtained from Bacuag LGU / an appropriate authoritative mapping authority, checked, and reviewed.
A 10 km pickup radius is a second rule; it does not define Bacuag's municipal boundary.

## Requirements
- Flutter SDK (stable), Android Studio / Android SDK, Git
- Node.js LTS and Firebase CLI
- A Firebase project with Authentication, Firestore, Realtime Database, Storage, and Cloud Functions enabled
- A verified Bacuag boundary GeoJSON file
- Internet/mobile data on passenger and rider devices

## 1. Create the Flutter platform folders
From this directory:
```bash
flutter create --platforms=android,web .
flutter pub get
```
This starter includes a `pubspec.yaml`. If Flutter asks to overwrite existing files, preserve `lib/`, `assets/`, and the provided configuration.

## 2. Connect Firebase
```bash
dart pub global activate flutterfire_cli
flutterfire configure
```
Choose your Firebase project and Android package ID. This generates `lib/firebase_options.dart`.
Uncomment the Firebase initialization lines in `lib/main.dart` after configuration, and add:
```dart
import 'firebase_options.dart';
```
Then run:
```bash
flutter pub get
flutter run
```

## 3. Configure Android permissions
Check `android/app/src/main/AndroidManifest.xml` and ensure it includes:
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.CAMERA"/>
```
Request permissions at runtime before accessing GPS or camera. Do not track riders in the background unless the rider explicitly enables it and Android background-location requirements are implemented.

## 4. Boundary setup
Replace `assets/boundaries/bacuag.geojson` with a reviewed GeoJSON `Feature` or `FeatureCollection` containing the municipal polygon in WGS84 coordinates (longitude, latitude).
- Record source, date, version, and who approved it in `assets/boundaries/README.md`.
- Do not trace the boundary by guessing from a screenshot.
- Add server-side point-in-polygon validation in the Cloud Function before a booking is accepted.
- Client-side boundary checks are only for user feedback and must never be the security control.

## 5. Firebase rules and Functions
Install Firebase CLI, log in, and initialize Functions if needed:
```bash
npm install -g firebase-tools
firebase login
firebase use --add
cd functions
npm install
cd ..
firebase deploy --only firestore:rules,database,storage,functions
```
Review `firebase.json` and the Firebase console settings before deployment. The rules intentionally deny direct client writes to bookings and rider location. Implement writes through callable/HTTPS Cloud Functions with authentication and validation. Do not deploy placeholder boundary data.

## 6. Suggested Firestore collections
See `docs/DATABASE_SCHEMA.md`. Keep private phone numbers and photo paths out of public profile documents. Use role claims or server-controlled user profiles; never let a client grant itself the `admin` or `verified` role.

## 7. Build APK
After Firebase setup, Android package ID, boundary, rules, and functions are configured:
```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```
APK output:
`build/app/outputs/flutter-apk/app-release.apk`

For separate Passenger and Rider APKs, use Flutter flavors or separate entrypoints/build configurations. This starter uses a single shell with role modes to make the first prototype easier; production should enforce roles on the backend.

## 8. Production-readiness checklist
- [ ] Verify Bacuag boundary with LGU / appropriate authority
- [ ] Test geofence on edge locations and GPS inaccuracy
- [ ] Configure Firebase App Check, Auth, least-privilege rules, and abuse limits
- [ ] Add SMS/phone verification and manual rider approval workflow
- [ ] Add secure photo uploads with content limits and restricted access
- [ ] Add atomic booking assignment to prevent double acceptance
- [ ] Add location freshness / stale-location handling
- [ ] Add privacy notice, consent, retention/deletion policy, and incident contact
- [ ] Test low signal, revoked permissions, duplicate requests, and two riders accepting simultaneously
- [ ] Test on actual Android phones and tablets

## OpenStreetMap note
OpenStreetMap data is open, but tile servers have usage policies. For a public promotional app, select a tile provider whose terms and capacity fit the expected traffic; display required attribution. Do not assume the community tile server is a free unlimited production CDN.
