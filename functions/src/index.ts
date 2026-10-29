import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

initializeApp();
const db = getFirestore();

type Point = { lat: number; lng: number };
type Position = [number, number]; // GeoJSON order: [longitude, latitude]
type PolygonGeometry = { type: "Polygon"; coordinates: Position[][] };
type MultiPolygonGeometry = { type: "MultiPolygon"; coordinates: Position[][][] };
type GeoGeometry = PolygonGeometry | MultiPolygonGeometry;

function pointInRing(point: Point, ring: Position[]): boolean {
  // Ray-casting; ring positions are [lng, lat].
  let inside = false;
  const x = point.lng, y = point.lat;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const xi = ring[i][0], yi = ring[i][1];
    const xj = ring[j][0], yj = ring[j][1];
    const intersects = ((yi > y) !== (yj > y)) &&
      (x < ((xj - xi) * (y - yi)) / ((yj - yi) || Number.EPSILON) + xi);
    if (intersects) inside = !inside;
  }
  return inside;
}

function pointInPolygon(point: Point, rings: Position[][]): boolean {
  if (rings.length === 0 || !pointInRing(point, rings[0])) return false;
  // GeoJSON inner rings are holes.
  for (let i = 1; i < rings.length; i++) {
    if (pointInRing(point, rings[i])) return false;
  }
  return true;
}

function insideGeometry(point: Point, geometry: GeoGeometry): boolean {
  if (geometry.type === "Polygon") return pointInPolygon(point, geometry.coordinates);
  return geometry.coordinates.some((polygon) => pointInPolygon(point, polygon));
}

function haversineKm(a: Point, b: Point): number {
  const rad = (v: number) => v * Math.PI / 180;
  const dLat = rad(b.lat - a.lat), dLng = rad(b.lng - a.lng);
  const s = Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 6371.0088 * 2 * Math.atan2(Math.sqrt(s), Math.sqrt(1 - s));
}

async function getVerifiedBoundary(): Promise<GeoGeometry> {
  const snap = await db.doc("serviceAreas/bacuag").get();
  if (!snap.exists) throw new HttpsError("failed-precondition", "Bacuag boundary is not configured.");
  const data = snap.data()!;
  if (data.verified !== true || !data.geometry) {
    throw new HttpsError("failed-precondition", "Bacuag boundary has not been verified by an administrator.");
  }
  return data.geometry as GeoGeometry;
}

export const createBooking = onCall({ enforceAppCheck: true }, async (request) => {
  // Guest bookings should use a server-issued short-lived guest token / App Check
  // and abuse controls; this first endpoint intentionally requires Firebase Auth.
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in before creating a booking.");
  const { displayName, phone, pickup, photoPath } = request.data ?? {};
  if (typeof displayName !== "string" || displayName.trim().length < 2 ||
      typeof phone !== "string" || phone.trim().length < 7 ||
      !pickup || typeof pickup.lat !== "number" || typeof pickup.lng !== "number") {
    throw new HttpsError("invalid-argument", "Name, phone, and valid pickup coordinates are required.");
  }

  const boundary = await getVerifiedBoundary();
  const passengerPoint: Point = { lat: pickup.lat, lng: pickup.lng };
  if (!insideGeometry(passengerPoint, boundary)) {
    throw new HttpsError("failed-precondition", "Pickup is outside the Bacuag service area.");
  }

  // Validate the photo path belongs to this booking/passenger in a production upload flow.
  if (photoPath !== undefined && typeof photoPath !== "string") {
    throw new HttpsError("invalid-argument", "Invalid pickup photo reference.");
  }

  const booking = {
    passengerUid: request.auth.uid,
    displayName: displayName.trim(),
    phone: phone.trim(),
    pickup: passengerPoint,
    photoPath: photoPath ?? null,
    status: "pending",
    assignedRiderUid: null,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    serviceAreaId: "bac uag".replace(" ", ""),
  };
  const ref = await db.collection("bookings").add(booking);
  return { bookingId: ref.id, status: "pending" };
});

export const acceptBooking = onCall({ enforceAppCheck: true }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  const uid = request.auth.uid;
  const bookingId = request.data?.bookingId;
  if (typeof bookingId !== "string" || bookingId.length < 5) {
    throw new HttpsError("invalid-argument", "A booking ID is required.");
  }

  const userSnap = await db.doc(`users/${uid}`).get();
  const user = userSnap.data();
  if (!user || user.role !== "rider" || user.verificationStatus !== "approved") {
    throw new HttpsError("permission-denied", "Only approved riders may accept bookings.");
  }

  const riderLocSnap = await db.doc(`riderPrivate/${uid}`).get();
  const loc = riderLocSnap.data()?.lastLocation;
  if (!loc || typeof loc.lat !== "number" || typeof loc.lng !== "number" ||
      Date.now() - Number(loc.updatedAtMillis ?? 0) > 120_000) {
    throw new HttpsError("failed-precondition", "Update your location before accepting a booking.");
  }

  const bookingRef = db.doc(`bookings/${bookingId}`);
  await db.runTransaction(async (tx) => {
    const bookingSnap = await tx.get(bookingRef);
    if (!bookingSnap.exists) throw new HttpsError("not-found", "Booking not found.");
    const booking = bookingSnap.data()!;
    if (booking.status !== "pending" || booking.assignedRiderUid) {
      throw new HttpsError("aborted", "This booking is no longer available.");
    }

    const boundary = await getVerifiedBoundary();
    const pickup = booking.pickup as Point;
    if (!insideGeometry(pickup, boundary) || !insideGeometry(loc as Point, boundary)) {
      throw new HttpsError("failed-precondition", "Pickup or rider is outside the Bacuag service area.");
    }
    if (haversineKm(loc as Point, pickup) > 10) {
      throw new HttpsError("failed-precondition", "Pickup is more than 10 km away.");
    }
    tx.update(bookingRef, {
      assignedRiderUid: uid,
      status: "accepted",
      acceptedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  return { bookingId, status: "accepted" };
});
