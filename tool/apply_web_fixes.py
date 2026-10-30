#!/usr/bin/env python3
"""Isang beses na pagpapalit ng index.html (lahat ng hiling sa bug batch na ito).

Ginagawa sa LF-normalized na kopya, tapos ibinabalik ang CRLF — kaya hindi
nagiging sirain ang mga linya ng file.
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

REPLACEMENTS = [
    # -----------------------------------------------------------------------
    # 1) "Buong Pangalan" — WALANG middle name (given + apelyido lang).
    # -----------------------------------------------------------------------
    (
        """            let surname = null, given = null, middle = null;
""",
        """            let surname = null, given = null;
""",
    ),
    (
        """                if (kind === 'middle') middle = middle || v;
""",
        "",
    ),
    (
        """            if (given && surname) {
                return titleCaseName([given, (middle || ''), surname].filter(Boolean).join(' '));
            }
""",
        """            // Walang middle name sa "Buong Pangalan" — given name + apelyido
            // lang ang binubuo, gaya ng hiling ng LGU.
            if (given && surname) {
                return titleCaseName([given, surname].join(' '));
            }
""",
    ),
    # -----------------------------------------------------------------------
    # 2) Bagong helper: eksaktong paghahambing ng given name + apelyido.
    # -----------------------------------------------------------------------
    (
        """        // Kapareho ng evaluateIdText() sa lib/main.dart.
""",
        """        // Hinahambing ang naka-type na pangalan sa pangalan mula sa ID.
        // Dapat pareho ang UNANG salita (given name) at HULING salita
        // (apelyido) — hindi tinitingnan ang gitnang salita (middle name),
        // kaya tumatanggap pa rin ng may nakasulat na middle ang user basta
        // eksakto ang given name at apelyido sa ID.
        function namesMatch(typedName, idName) {
            const norm = s => String(s || '').toLowerCase().replace(/[^a-z\\s]/g, ' ').replace(/\\s+/g, ' ').trim();
            const t = norm(typedName).split(' ').filter(Boolean);
            const i = norm(idName).split(' ').filter(Boolean);
            if (t.length < 2 || i.length < 2) return false;
            return t[0] === i[0] && t[t.length - 1] === i[i.length - 1];
        }

        // Kapareho ng evaluateIdText() sa lib/main.dart.
""",
    ),
    # -----------------------------------------------------------------------
    # 3) Scan: itala kung hindi tugma ang naka-type na pangalan sa ID.
    # -----------------------------------------------------------------------
    (
        """                idScanState = { valid: !!result.valid, name: detectedName || '', busy: false, message: result.message };
""",
        """                const typedNow = (document.getElementById('su-name') || {}).value || '';
                const nameMismatch = !!(result.valid && detectedName && typedNow.trim() && !namesMatch(typedNow, detectedName));
                idScanState = { valid: !!result.valid, name: detectedName || '', busy: false, message: result.message, mismatch: nameMismatch };
""",
    ),
    (
        """                    (result.valid && detectedName ? '<br>Na-fill ang Buong Pangalan mula sa ID: ' + escapeHtml(detectedName) + '.' : '') +
""",
        """                    (result.valid && detectedName ? '<br>Na-fill ang Buong Pangalan mula sa ID: ' + escapeHtml(detectedName) + '.' : '') +
                    (idScanState.mismatch ? '<br><span style="color:#b91c1c;font-weight:700">&#9888; Hindi tugma ang naka-type na pangalan (' + escapeHtml(typedNow.trim()) + ') sa pangalan ng ID (' + escapeHtml(detectedName) + ') — palitan ito bago mag-sign up.</span>' : '') +
""",
    ),
    # -----------------------------------------------------------------------
    # 4) Signup: hindi itutuloy kapag hindi tugma ang given name / apelyido.
    # -----------------------------------------------------------------------
    (
        """            if (!idScanState.valid) {
                alert(idScanState.message ||
                    'Hindi pa na-verify ang Verified ID. I-scan muna ito (OCR) — dapat nababasa ang POBLACION, BACUAG sa litrato.');
                return;
            }
""",
        """            if (!idScanState.valid) {
                alert(idScanState.message ||
                    'Hindi pa na-verify ang Verified ID. I-scan muna ito (OCR) — dapat nababasa ang POBLACION, BACUAG sa litrato.');
                return;
            }
            if (idScanState.name && !namesMatch(name, idScanState.name)) {
                alert('Hindi tugma ang Buong Pangalan sa Verified ID — hindi maaaring mag-sign up.\\n\\n' +
                    'Naka-type: "' + name + '"\\n' +
                    'Sa ID: "' + idScanState.name + '"\\n\\n' +
                    'Dapat eksaktong tugma ang Given Name at Apelyido sa ID na in-upload.');
                return;
            }
""",
    ),
    # -----------------------------------------------------------------------
    # 5) Live Dispatch: pinakabagong aktibong booking + tamang textContent.
    # -----------------------------------------------------------------------
    (
        """            const live = bookings.filter(b => DISPATCH_ACTIVE.includes(String(b.status || 'pending')));
            const b = live[0] || null;
""",
        """            const live = bookings.filter(b => DISPATCH_ACTIVE.includes(String(b.status || 'pending')));
            // Pinakabago muna — laging ang huling aktibong booking ang ipinapakita
            // (dating: pinakalumang nasa listahan kaya mukhang hindi gumagalaw).
            live.sort((a, z) => new Date(z.createdAt || 0) - new Date(a.createdAt || 0));
            const b = live[0] || null;
""",
    ),
    (
        """            idEl.textContent = 'E-Bike #' + escapeHtml(String(b.id || '-'));
""",
        """            idEl.textContent = 'E-Bike #' + String(b.id || '-'); // textContent: walang entity
""",
    ),
    # -----------------------------------------------------------------------
    # 6) Live refresh: storage event + 3s polling + focus/visibility.
    # -----------------------------------------------------------------------
    (
        """        renderDispatch(); // initial na laman ng Live Bacuag Dispatch card
""",
        """        renderDispatch(); // initial na laman ng Live Bacuag Dispatch card
        // LIVE REFRESH — hindi lang sa "storage" event ng ibang tab: nagre-refresh
        // din tuwing 3 segundo at pagbalik sa tab, kaya kaagad nakikita ang bagong
        // booking at ang pag-accept ng rider (maging sa parehong dokumento).
        setInterval(() => {
            renderDispatch();
            const dash = document.getElementById('dashboard-section');
            if (dash && !dash.classList.contains('hidden')) refreshDashboard();
        }, 3000);
        window.addEventListener('focus', renderDispatch);
        document.addEventListener('visibilitychange', () => { if (!document.hidden) renderDispatch(); });
""",
    ),
    # -----------------------------------------------------------------------
    # 7) Download card -> QR code + Facebook / X share links.
    # -----------------------------------------------------------------------
    (
        """                <div class="flex justify-center gap-4">
                    <button onclick="downloadApk()" class="bg-emerald-700 hover:bg-emerald-800 text-white font-bold px-8 py-4 rounded-xl shadow-lg transition text-sm flex items-center space-x-2">
                        <i class="fa-solid fa-download text-lg"></i>
                        <span>I-download ang APK v0.1.0</span>
                    </button>
                </div>
""",
        """                <div class="space-y-4">
                    <div class="bg-white p-3 rounded-2xl shadow-md border border-emerald-100 inline-block">
                        <div id="apk-qr" class="w-[184px] h-[184px] flex items-center justify-center rounded-xl overflow-hidden"></div>
                        <div id="apk-qr-fallback" class="hidden w-[184px] text-xs text-gray-500 text-center py-10 px-2">Hindi ma-generate ang QR code — gamitin ang direktang link sa ibaba.</div>
                    </div>
                    <p class="text-xs text-gray-500">I-scan ang QR code gamit ang camera ng phone para i-download ang E-Bike APK.</p>
                    <div class="flex justify-center gap-3 flex-wrap">
                        <a id="share-facebook" href="#" target="_blank" rel="noopener" class="bg-[#1877F2] hover:bg-[#145dbf] text-white font-bold px-5 py-3 rounded-xl text-sm transition flex items-center gap-2">
                            <i class="fa-brands fa-facebook-f"></i><span>I-share sa Facebook</span>
                        </a>
                        <a id="share-x" href="#" target="_blank" rel="noopener" class="bg-black hover:bg-gray-800 text-white font-bold px-5 py-3 rounded-xl text-sm transition flex items-center gap-2">
                            <i class="fa-brands fa-x-twitter"></i><span>I-share sa X.com</span>
                        </a>
                    </div>
                    <a href="app-release.apk" download class="inline-flex items-center gap-2 text-emerald-700 font-bold text-sm hover:text-emerald-800">
                        <i class="fa-solid fa-download"></i><span>O i-download nang direkta ang APK</span>
                    </a>
                </div>
""",
    ),
    # -----------------------------------------------------------------------
    # 8) QR library (cdnjs) kasunod ng Tesseract.
    # -----------------------------------------------------------------------
    (
        """    <script src="https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js"></script>
""",
        """    <script src="https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js"></script>

    <!-- QR code para sa "I-scan para i-download" na APK -->
    <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
""",
    ),
    # -----------------------------------------------------------------------
    # 9) Alisin ang lumang downloadApk() at magdagdag ng QR/share setup.
    # -----------------------------------------------------------------------
    (
        """        function downloadApk() {
            alert('Simula na ang pag-download ng Sakay_Bacuag_v0.1.0.apk (Starter APK package). Para sa production build, i-run ang "flutter build apk --release".');
        }

""",
        "",
    ),
    (
        """        boot();
""",
        """        // ---------------------------------------------------------------------------
        // QR CODE PARA SA APK + SHARE (Facebook / X.com) — pinalitan ang dating
        // button ng download: ang QR ay naka-point sa aktwal na APK file, kaya
        // nasi-scan ito ng camera ng phone para makapag-download kaagad.
        // ---------------------------------------------------------------------------
        const APK_HREF = 'app-release.apk';

        function setupDownloadQr() {
            const apk = new URL(APK_HREF, window.location.href).href;
            const page = window.location.origin + window.location.pathname;
            const fb = document.getElementById('share-facebook');
            const x = document.getElementById('share-x');
            if (fb) fb.href = 'https://www.facebook.com/sharer/sharer.php?u=' + encodeURIComponent(page);
            if (x) x.href = 'https://twitter.com/intent/tweet?text=' +
                encodeURIComponent('I-download ang E-Bike — opisyal na LGU transport platform ng Bacuag!') +
                '&url=' + encodeURIComponent(page);

            const box = document.getElementById('apk-qr');
            if (!box) return;
            const fallback = document.getElementById('apk-qr-fallback');
            const fail = () => {
                box.classList.add('hidden');
                if (fallback) fallback.classList.remove('hidden');
            };
            if (typeof QRCode === 'undefined') { fail(); return; }
            try {
                new QRCode(box, {
                    text: apk,
                    width: 184,
                    height: 184,
                    colorDark: '#064e3b',
                    colorLight: '#ffffff',
                    correctLevel: QRCode.CorrectLevel.M
                });
            } catch (_) { fail(); }
        }
        window.addEventListener('load', setupDownloadQr);

        boot();
""",
    ),
]


def apply(path):
    with io.open(path, newline='', encoding='utf-8') as fh:
        raw = fh.read()
    if '\r\n' not in raw:
        sys.exit('%s: walang CRLF — tumigil' % path)
    text = raw.replace('\r\n', '\n')
    for old, new in REPLACEMENTS:
        n = text.count(old)
        if n != 1:
            sys.exit('%s: %d na tugma (dapat 1) para sa: %r' % (path, n, old[:80]))
        text = text.replace(old, new)
    with io.open(path, 'w', newline='', encoding='utf-8') as fh:
        fh.write(text.replace('\n', '\r\n'))
    print('ok:', path)


if __name__ == '__main__':
    for rel in ['index.html', os.path.join('admin', 'index.html')]:
        apply(os.path.join(ROOT, rel))
    # Ang admin copy ay nasa /admin/ kaya iba ang relasyon ng APK.
    for rel in ['index.html', os.path.join('admin', 'index.html')]:
        p = os.path.join(ROOT, rel)
        with io.open(p, newline='', encoding='utf-8') as fh:
            t = fh.read()
        if rel.startswith('admin'):
            t = t.replace("href=\"app-release.apk\"", "href=\"../app-release.apk\"")
            t = t.replace("const APK_HREF = 'app-release.apk';", "const APK_HREF = '../app-release.apk';")
        with io.open(p, 'w', newline='', encoding='utf-8') as fh:
            fh.write(t)
    print('ok: admin APK path')
