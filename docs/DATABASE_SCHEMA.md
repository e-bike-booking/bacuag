# Database schema (starter)

## Firestore: `users/{uid}`
Client-safe fields:
```json
{
  "displayName": "string",
  "phone": "string",
  "createdAt": "timestamp"
}
```
Server-controlled fields may be added by trusted Functions/admin tooling:
- `role`: `passenger` or `rider`
- `verificationStatus`: `pending`, `approved`, `rejected`, `suspended`
- `active`: boolean
Never allow clients to set `role`, `verificationStatus`, or admin claims.

## `riderPrivate/{uid}`
Server-controlled/private:
```json
{
  "phone": "string",
  "documents": ["storage path"],
  "lastLocation": { "lat": 0.0, "lng": 0.0, "updatedAtMillis": 0 }
}
```
Do not expose rider documents to passengers.

## `bookings/{bookingId}`
```json
{
  "passengerUid": "auth uid",
  "displayName": "passenger display name",
  "phone": "passenger phone",
  "pickup": { "lat": 0.0, "lng": 0.0 },
  "photoPath": "pickupPhotos/{bookingId}/photo.jpg or null",
  "serviceAreaId": "bacuag",
  "status": "pending",
  "assignedRiderUid": null,
  "createdAt": "server timestamp",
  "updatedAt": "server timestamp"
}
```
Allowed status transitions should be enforced server-side:
`pending -> accepted -> on_the_way -> arrived -> completed`
Cancellation/rejection paths should be explicitly defined and audited.

## `serviceAreas/bacuag`
Server/admin managed only:
```json
{
  "verified": false,
  "sourceName": "must be filled with verified source",
  "sourceDate": "must be filled",
  "approvedBy": "LGU/authorized reviewer reference",
  "geometry": {
    "type": "Polygon",
    "coordinates": []
  },
  "maxPickupRadiusKm": 10,
  "updatedAt": "server timestamp"
}
```
`coordinates` must be replaced with reviewed WGS84 GeoJSON coordinates. Empty geometry is intentionally invalid.

## Realtime Database
Use `riderLocations/{uid}` for active location streaming only, with access controlled so only the rider and the passenger assigned to the active booking can read it. A scheduled cleanup should remove old locations and completed-trip tracking data according to the privacy policy.

## Storage
- `pickupPhotos/{bookingId}/{filename}`: one active booking's pickup image
- `riderDocuments/{uid}/{filename}`: private verification documents
Validate file size and MIME type; use random object names; use short-lived access where possible; avoid public download URLs for sensitive images.
