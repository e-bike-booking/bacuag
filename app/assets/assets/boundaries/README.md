# Bacuag boundary input

`bacuag.geojson` is intentionally a placeholder, not a boundary.

Obtain a municipal boundary from Bacuag LGU or an appropriate authoritative mapping authority. Confirm the dataset's authority, projection, geometry, date, and intended use. Convert to WGS84 longitude/latitude GeoJSON, retain attribution/license terms, and have the LGU or authorized reviewer approve it.

Do not use guessed coordinates, a hand-drawn approximate outline, the town center point, or a map screenshot as the production geofence. The app must fail closed while `serviceAreas/bacuag.verified` is false.
