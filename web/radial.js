// F6 field wheel. Drawn the same way as the police wheel; the builder's
// Radial page uses XS.radialRing for its live preview.
(function () {
    const R_OUT = 138;
    const R_IN = 72;
    const GAP = 2.2;
    const esc = (v) => window.XS.escapeHtml(v);
    const rad = (deg) => (deg - 90) * Math.PI / 180;
    const pt = (r, deg) => [150 + r * Math.cos(rad(deg)), 150 + r * Math.sin(rad(deg))];

    function slice(a0, a1) {
        const [x0, y0] = pt(R_OUT, a0);
        const [x1, y1] = pt(R_OUT, a1);
        const [x2, y2] = pt(R_IN, a1);
        const [x3, y3] = pt(R_IN, a0);
        const large = a1 - a0 > 180 ? 1 : 0;
        return `M${x0} ${y0} A${R_OUT} ${R_OUT} 0 ${large} 1 ${x1} ${y1} L${x2} ${y2} A${R_IN} ${R_IN} 0 ${large} 0 ${x3} ${y3}Z`;
    }

    function ring(items, selected) {
        const n = Math.max(items.length, 1);
        const span = 360 / n;
        const segs = items.map((item, i) => {
            const a0 = i * span - span / 2 + GAP / 2;
            const a1 = (i + 1) * span - span / 2 - GAP / 2;
            const [ix, iy] = pt((R_OUT + R_IN) / 2 - 2, i * span);
            const [nx, ny] = pt(R_OUT - 8, i * span);
            return `<g class="ws ${item.disabled ? 'ws-off' : ''} ${i === selected ? 'ws-on' : ''}" data-i="${i}">
                <path d="${slice(a0, a1)}"/>
                <foreignObject x="${ix - 32}" y="${iy - 32}" width="64" height="64"><div class="ws-ico"><i class="fas ${esc(item.icon)}"></i></div></foreignObject>
                ${i < 9 ? `<text x="${nx}" y="${ny + 3.5}" class="ws-num">${i + 1}</text>` : ''}
            </g>`;
        }).join('');
        return `<svg class="wh-ring" viewBox="0 0 300 300" width="300" height="300">
            <circle cx="150" cy="150" r="${R_OUT + 6}" class="wh-halo"/>${segs}
        </svg>`;
    }
    window.XS.radialRing = ring;

    const root = document.getElementById('radialRoot');
    let items = [];
    let sel = -1;
    let gang = '';

    function paint() {
        root.querySelectorAll('.ws').forEach((g) => g.classList.toggle('ws-on', Number(g.dataset.i) === sel));
        const item = items[sel];
        root.querySelector('.wh-crumb').textContent = gang || 'Field';
        root.querySelector('.wh-name').textContent = item ? item.label : 'Field';
        const target = root.querySelector('.wh-target');
        target.textContent = item ? (item.note || '') : `${items.length} actions`;
        target.classList.toggle('bad', !!(item && item.disabled));
    }

    function use(i) {
        const item = items[i];
        if (!item) return;
        sel = i;
        paint();
        if (item.disabled) {
            const g = root.querySelector(`.ws[data-i="${i}"]`);
            if (g) { g.classList.remove('ws-shake'); void g.getBoundingClientRect(); g.classList.add('ws-shake'); }
            return;
        }
        window.XS.nui('radial:select', { id: item.id });
    }

    window.openRadial = function (data) {
        items = (data && data.items) || [];
        gang = (data && data.gang) || '';
        sel = -1;
        window.XS.applyTheme(data && data.color);
        root.innerHTML = `<div class="wh-scrim"></div><div class="wh">
            ${ring(items, -1)}
            <div class="wh-hub"><div class="wh-crumb"></div><div class="wh-name"></div><div class="wh-target"></div></div>
            <div class="wh-hints">
                <span><i class="kbd">Click</i>use</span>
                <span><i class="kbd">1-${Math.min(9, Math.max(items.length, 1))}</i>jump</span>
                <span><i class="kbd">Scroll</i>pick</span>
                <span><i class="kbd">Right</i>close</span>
            </div>
        </div>`;
        root.querySelectorAll('.ws').forEach((g) => {
            const i = Number(g.dataset.i);
            g.addEventListener('mouseenter', () => { sel = i; paint(); });
            g.addEventListener('click', () => use(i));
        });
        root.querySelector('.wh-scrim').addEventListener('mousedown', (e) => { if (e.button === 0) window.XS.nui('radial:close'); });
        paint();
        root.classList.remove('hidden');
        const wh = root.querySelector('.wh');
        wh.classList.remove('wh-in');
        void wh.offsetWidth;
        wh.classList.add('wh-in');
    };

    window.closeRadial = function () {
        root.classList.add('hidden');
        root.innerHTML = '';
        items = [];
    };

    root.addEventListener('wheel', (e) => {
        if (!items.length) return;
        e.preventDefault();
        const step = e.deltaY > 0 ? 1 : -1;
        sel = sel < 0 ? (step > 0 ? 0 : items.length - 1) : (sel + step + items.length) % items.length;
        paint();
    }, { passive: false });
    root.addEventListener('contextmenu', (e) => { e.preventDefault(); window.XS.nui('radial:close'); });
    document.addEventListener('keydown', (e) => {
        if (root.classList.contains('hidden')) return;
        const n = Number(e.key);
        if (n >= 1 && n <= 9) { e.preventDefault(); use(n - 1); }
        else if (e.key === 'Enter' && sel >= 0) { e.preventDefault(); use(sel); }
    });
})();
