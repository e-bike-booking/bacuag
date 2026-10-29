        function riderStatusOf(user) {
            let overlay = {};
            try { overlay = JSON.parse(localStorage.getItem(RIDER_STATUS_KEY) || '{}'); } catch (_) {}
            if (overlay[user.email]) return overlay[user.email];
            return user.status || 'pending';
        }

        function loadAdminUsers() {
            const users = getAppAccounts();
            const riders = users.filter(u => u.role === 'rider');
            const passengers = users.filter(u => u.role === 'passenger');

            // — Rider Registrations (Pending & Approved): totoong data ng app,
            //   walang hardcoded na mock row (dating: Juan Dela Cruz / Pedro Penduko).
            const ridersBody = document.getElementById('riders-table-body');
            if (ridersBody) {
                ridersBody.innerHTML = riders.length === 0
                    ? '<tr><td colspan="5" class="px-6 py-6 text-center text-gray-400 text-sm">Wala pang rehistradong rider — lumalabas dito ang mga naka-sign up sa app.</td></tr>'
                    : riders.map(r => {
                        const st = riderStatusOf(r);
                        const tone = st === 'approved' ? 'green' : (st === 'rejected' ? 'red' : 'yellow');
                        return `
                    <tr>
                        <td class="px-6 py-4 font-bold">${escapeHtml(r.name)}</td>
                        <td class="px-6 py-4 text-gray-600">${escapeHtml(r.phone || '—')}</td>
                        <td class="px-6 py-4 text-gray-600">${escapeHtml(r.email)}</td>
                        <td class="px-6 py-4"><span class="bg-${tone}-100 text-${tone}-800 text-xs px-2 py-0.5 rounded font-bold">${st.toUpperCase()}</span></td>
                        <td class="px-6 py-4 text-right space-x-2">
                            <button data-email="${escapeHtml(r.email)}" onclick="updateRiderStatus(this.dataset.email, 'approved')" class="bg-emerald-600 hover:bg-emerald-700 text-white px-3 py-1.5 rounded-lg text-xs font-bold">Approve</button>
                            <button data-email="${escapeHtml(r.email)}" onclick="updateRiderStatus(this.dataset.email, 'rejected')" class="bg-red-500 hover:bg-red-600 text-white px-3 py-1.5 rounded-lg text-xs font-bold">Reject</button>
                        </td>
                    </tr>
                `;
                    }).join('');
            }

            // — Registered Passengers: totoong data, walang mock row.
            const passengersBody = document.getElementById('passengers-table-body');
            if (passengersBody) {
                passengersBody.innerHTML = passengers.length === 0
                    ? '<tr><td colspan="4" class="px-6 py-6 text-center text-gray-400 text-sm">Wala pang rehistradong pasahero.</td></tr>'
                    : passengers.map(p => `
                    <tr>
                        <td class="px-6 py-4 font-bold">${escapeHtml(p.name)}</td>
                        <td class="px-6 py-4 text-gray-600">${escapeHtml(p.phone || '—')}</td>
                        <td class="px-6 py-4 text-gray-600">${escapeHtml(p.email)}</td>
                        <td class="px-6 py-4 text-gray-500">${escapeHtml(p.date || '—')}</td>
                    </tr>
                `).join('');
            }

            // — Pending Riders stat mula sa totoong data (dating hardcoded na 3).
            setText('stat-riders-count', riders.filter(r => riderStatusOf(r) === 'pending').length);
        }

        // — Live Bookings: ang totoong bookings ng app (sakay_bookings_v1), na
        //   ngayon ay pino-persist na ng BookingStore kaya nakikita rito.
        function loadBookings() {
            const bookings = getAppBookings();
            const body = document.getElementById('bookings-table-body');
            if (body) {
                body.innerHTML = bookings.length === 0
                    ? '<tr><td colspan="5" class="px-6 py-6 text-center text-gray-400 text-sm">Wala pang booking — lumalabas dito ang totoong biyahe mula sa app.</td></tr>'
                    : bookings.map(b => {
                        const st = String(b.status || 'pending');
                        const tone = st === 'completed' ? 'green'
                            : st === 'cancelled' ? 'red'
                                : st === 'pending' ? 'yellow' : 'blue';
                        const pu = Array.isArray(b.pickup) && b.pickup.length >= 2
                            ? `${Number(b.pickup[0]).toFixed(4)}, ${Number(b.pickup[1]).toFixed(4)}`
                            : '—';
                        let created = '—';
                        if (b.createdAt) {
                            const d = new Date(b.createdAt);
                            if (!isNaN(d)) created = d.toLocaleString();
                        }
                        return `
                    <tr>
                        <td class="px-6 py-4 font-bold text-emerald-700">${escapeHtml(b.id)}</td>
                        <td class="px-6 py-4">${escapeHtml(b.name)}<div class="text-xs text-gray-400">${escapeHtml(created)}</div></td>
                        <td class="px-6 py-4 text-gray-600">${escapeHtml(pu)}</td>
                        <td class="px-6 py-4">${escapeHtml(b.riderName || '—')}</td>
                        <td class="px-6 py-4"><span class="bg-${tone}-100 text-${tone}-800 px-2 py-0.5 rounded text-xs font-bold">${escapeHtml(st)}</span></td>
                    </tr>
                `;
                    }).join('');
            }
            setText('stat-bookings-count', bookings.length);
            setText('stat-active-count',
                bookings.filter(b => ACTIVE_BOOKING_STATUSES.includes(b.status)).length);
            return bookings;
        }

        // — Boundary Status: ang opisyal na 5 hangganan, kapareho ng bacuagBounds.
        function renderBoundary() {
            const body = document.getElementById('boundary-table-body');
            if (body) {
                body.innerHTML = SERVICE_AREA.map((p, i) => `
                    <tr>
                        <td class="px-4 py-2 font-bold">${i + 1}</td>
                        <td class="px-4 py-2 text-gray-600">${p[0].toFixed(7)}</td>
                        <td class="px-4 py-2 text-gray-600">${p[1].toFixed(7)}</td>
                    </tr>
                `).join('');
            }
            const lats = SERVICE_AREA.map(p => p[0]);
            const lngs = SERVICE_AREA.map(p => p[1]);
            const minLat = Math.min(...lats), maxLat = Math.max(...lats);
            const minLng = Math.min(...lngs), maxLng = Math.max(...lngs);
            const latSpan = maxLat - minLat;
            const lngSpan = maxLng - minLng;
            setText('boundary-span-lat',
                latSpan.toFixed(4) + '° (~' + Math.round(latSpan * 111) + ' km)');
            setText('boundary-span-lng',
                lngSpan.toFixed(4) + '° (~' +
                Math.round(lngSpan * 111 * Math.cos(9.61 * Math.PI / 180)) + ' km)');
            const bookings = getAppBookings();
            const inside = bookings.filter(b => {
                const p = b.pickup;
                return Array.isArray(p) && p.length >= 2 &&
                    p[0] >= minLat && p[0] <= maxLat && p[1] >= minLng && p[1] <= maxLng;
            }).length;
            setText('boundary-inside-count', inside + ' / ' + bookings.length);
        }

        // — Isang tawag lang: lahat ng stat at tab ay mula sa parehong data ng app.
        function refreshDashboard() {
            loadAdminUsers();
            loadBookings();
            renderBoundary();
        }
