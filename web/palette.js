// Ctrl+K in the builder: one box that finds any page, crew, block,
// setting or action and takes you straight to it.
(function () {
    const esc = (v) => window.XS.escapeHtml(v);
    const $ = (s) => document.querySelector(s);
    let open = false;
    let hl = 0;
    let results = [];

    function entries() {
        const out = [];
        document.querySelectorAll('#adminRail .bx-navitem').forEach((b) => {
            out.push({ group: 'Pages', icon: b.querySelector('i').className.replace('fas ', ''), title: b.dataset.title, sub: b.dataset.desc, run: () => window.XSAdmin.go(b.dataset.tab) });
        });
        out.push({ group: 'Actions', icon: 'fa-plus', title: 'New crew', sub: 'Name it, pick a boss and give it a block', run: () => window.XSAdmin.go('admin-setup') });
        out.push({ group: 'Actions', icon: 'fa-draw-polygon', title: 'Draw a block', sub: 'Open the turf map', run: () => window.XSAdmin.go('admin-zones') });
        const data = window.XSAdmin.data();
        ((data.overview && data.overview.gangs) || []).forEach((g) => {
            out.push({ group: 'Crews', icon: 'fa-users', color: g.color, title: g.label, sub: `${g.memberCount || 0} members${g.ownerName ? ` · boss ${g.ownerName}` : ''}`, run: () => window.XSAdmin.openGang(g.id) });
        });
        ((data.overview && data.overview.territories) || []).forEach((t) => {
            out.push({ group: 'Turf', icon: 'fa-flag', title: t.label || t.zone, sub: t.holder ? `Held by ${t.holder}` : 'Nobody holds it', run: () => window.XSAdmin.findZone(t.zone) });
        });
        const bs = window.XS.BuilderSettings;
        if (bs) bs.fields().forEach((f) => {
            out.push({ group: 'Settings', icon: 'fa-sliders', title: f.label, sub: f.sectionLabel, extra: f.key.replace(/[._]/g, ' '), run: () => { window.XSAdmin.go('admin-settings'); bs.focus(f.key); } });
        });
        return out;
    }

    function search(q) {
        const all = entries();
        if (!q) return all.filter((e) => e.group === 'Pages' || e.group === 'Actions');
        const words = q.toLowerCase().split(/\s+/).filter(Boolean);
        return all
            .map((e) => {
                const title = String(e.title || '').toLowerCase();
                const hay = `${title} ${String(e.sub || '').toLowerCase()} ${e.group.toLowerCase()} ${String(e.extra || '').toLowerCase()}`;
                if (!words.every((w) => hay.includes(w))) return null;
                return { e, score: (title.startsWith(words[0]) ? 0 : 1) + (title.includes(words[0]) ? 0 : 1) };
            })
            .filter(Boolean)
            .sort((a, b) => a.score - b.score)
            .slice(0, 40)
            .map((x) => x.e);
    }

    function paint() {
        const box = $('.bx-palres');
        if (!box) return;
        let group = null;
        box.innerHTML = results.length ? results.map((r, i) => {
            const head = r.group !== group ? `<div class="bx-palgroup">${esc(r.group)}</div>` : '';
            group = r.group;
            return `${head}<button class="bx-palitem ${i === hl ? 'hl' : ''}" data-i="${i}">
                <span class="bx-kindico"${r.color ? ` style="color:${esc(r.color)}"` : ''}><i class="fas ${esc(r.icon)}"></i></span>
                <div><b>${esc(r.title)}</b>${r.sub ? `<small>${esc(r.sub)}</small>` : ''}</div>
                ${i === hl ? '<kbd>Enter</kbd>' : ''}
            </button>`;
        }).join('') : '<div class="bx-palgroup">Nothing found</div>';
        box.querySelectorAll('[data-i]').forEach((b) => {
            b.addEventListener('mousemove', () => { if (hl !== Number(b.dataset.i)) { hl = Number(b.dataset.i); paint(); } });
            b.addEventListener('click', () => pick(Number(b.dataset.i)));
        });
        const on = box.querySelector('.hl');
        if (on) on.scrollIntoView({ block: 'nearest' });
    }

    function pick(i) {
        const r = results[i];
        close();
        if (r) r.run();
    }

    function show() {
        if ($('#adminRoot').classList.contains('hidden')) return;
        open = true;
        hl = 0;
        $('#bxOverlay').innerHTML = `<div class="bx-overlay" data-palshade><div class="bx-palette">
            <div class="bx-palin"><i class="fas fa-magnifying-glass"></i><input id="bxPalQ" placeholder="Search crews, turf, settings and actions"><span class="bx-kbd">Esc</span></div>
            <div class="bx-palres"></div>
            <div class="bx-palfoot"><span>↑ ↓ to move</span><span>Enter to open</span><span>Esc to close</span></div>
        </div></div>`;
        const input = $('#bxPalQ');
        results = search('');
        paint();
        input.focus();
        input.addEventListener('input', () => { hl = 0; results = search(input.value.trim()); paint(); });
        $('[data-palshade]').addEventListener('mousedown', (e) => { if (e.target.hasAttribute('data-palshade')) close(); });
    }

    function close() {
        open = false;
        $('#bxOverlay').innerHTML = '';
    }

    // Capture phase, so Esc closes the palette before the page-wide Esc
    // handler closes the whole builder.
    document.addEventListener('keydown', (e) => {
        if ($('#adminRoot').classList.contains('hidden')) return;
        if (e.ctrlKey && (e.key === 'k' || e.key === 'K')) {
            e.preventDefault();
            e.stopPropagation();
            if (open) close(); else show();
            return;
        }
        if (!open) return;
        if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
        else if (e.key === 'ArrowDown') { e.preventDefault(); hl = Math.min(results.length - 1, hl + 1); paint(); }
        else if (e.key === 'ArrowUp') { e.preventDefault(); hl = Math.max(0, hl - 1); paint(); }
        else if (e.key === 'Enter') { e.preventDefault(); pick(hl); }
    }, true);

    document.getElementById('bxSearch').addEventListener('click', show);
    window.XSPalette = { show, close, isOpen: () => open };
})();
