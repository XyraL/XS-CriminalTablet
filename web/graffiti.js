// ─────────────────────────────────────────────────────────────
// Graffiti Studio.
//
// Three ways to put a tag up:
//   Library  — art the crew already has. Staff-issued images live here.
//   Text     — a styled word, rendered the same way in the studio preview
//              and on the wall, so what you see is what goes up.
//   Freehand — draw it, and the canvas becomes the tag.
//
// A member can save text and drawings into the crew library, but never a
// remote image URL — those are staff-issued only, because the URL loads
// inside every nearby player's game.
// ─────────────────────────────────────────────────────────────
(function () {
    const { call, nui, flash, report, escapeHtml, formatTime } = window.XS;
    const $ = window.XS.$;
    const $$ = window.XS.$$;

    let library = null;
    let fonts = [];

    // ── art preview ──
    // The same four preset looks the in-world renderer draws, so the
    // studio thumbnail and the wall agree.
    const PRESETS = {
        classic: { font: "'Permanent Marker', cursive", text: 'TAG', skew: -6 },
        bubble: { font: "'Archivo Black', sans-serif", text: 'THROW', skew: 0 },
        stencil: { font: "'Oswald', sans-serif", text: 'STENCIL', skew: 0 },
        drip: { font: "'Bungee Shade', cursive", text: 'DRIP', skew: -3 },
    };

    // Renders whatever an `art` string represents into a thumbnail node.
    function artThumb(art, tint) {
        if (typeof art !== 'string') return '<span class="art-fallback">?</span>';

        if (art.startsWith('url:')) {
            const url = art.slice(4);
            return `<img src="${escapeHtml(url)}" alt="" loading="lazy"
                onerror="this.replaceWith(Object.assign(document.createElement('span'),{className:'art-fallback',textContent:'BROKEN'}))" />`;
        }
        if (art.startsWith('draw:')) {
            return `<img src="${escapeHtml(art.slice(5))}" alt="" />`;
        }
        if (art.startsWith('text:')) {
            try {
                const d = JSON.parse(art.slice(5));
                const font = (fonts.find((f) => f.id === d.font) || {}).css || "'Permanent Marker', cursive";
                return `<span class="art-fallback" style="font-family:${escapeHtml(font)};color:${escapeHtml(d.fill)};
                    -webkit-text-stroke:1.5px ${escapeHtml(d.outline)};font-size:26px">${escapeHtml(d.text)}</span>`;
            } catch (e) {
                return '<span class="art-fallback">TEXT</span>';
            }
        }
        if (art.startsWith('preset:')) {
            const p = PRESETS[art.slice(7)] || PRESETS.classic;
            return `<span class="art-fallback" style="font-family:${p.font};transform:skewX(${p.skew}deg);
                color:${escapeHtml(tint || 'var(--accent)')}">${escapeHtml(p.text)}</span>`;
        }
        return '<span class="art-fallback">?</span>';
    }
    window.XS.artThumb = artThumb;

    // ── main render ──
    window.renderGraffiti = async function renderGraffiti() {
        library = await call('XS-CriminalTablet:graffiti:getLibrary');
        if (!library) return;

        fonts = library.fonts || [];
        populateFonts();
        renderLibrary();
        renderTags();
    };

    function populateFonts() {
        const sel = $('#tagFont');
        if (sel.options.length === fonts.length && fonts.length) return;
        sel.innerHTML = fonts.map((f) => `<option value="${escapeHtml(f.id)}">${escapeHtml(f.label)}</option>`).join('');
        updateTextPreview();
    }

    function renderLibrary() {
        const grid = $('#artGrid');
        const items = library.library || [];

        if (!items.length) {
            grid.innerHTML = `<div class="empty" style="grid-column:1/-1">
                <i class="fas fa-spray-can"></i>
                Your crew has no art yet. Staff can add custom images, or make your own in the Text and Freehand tabs.
            </div>`;
            return;
        }

        grid.innerHTML = items.map((a, i) => `
            <div class="art-card rise" style="--i:${i}">
                <div class="art-thumb">${artThumb(a.art, library.color)}</div>
                <div class="art-meta">
                    <div class="art-name">${escapeHtml(a.label || 'Untitled')}</div>
                    <div class="art-source">${escapeHtml(a.source === 'admin' ? 'Staff-issued' : a.source)}</div>
                    <div class="art-actions">
                        <button class="btn btn-accent btn-sm" data-spray="${a.id}" data-art="${escapeHtml(a.art || '')}" ${library.canSpray ? '' : 'disabled'}>
                            <i class="fas fa-spray-can"></i> Spray
                        </button>
                        ${a.source !== 'admin' && library.canManage
                            ? `<button class="btn btn-danger btn-sm" data-delart="${a.id}" title="Remove"><i class="fas fa-trash"></i></button>`
                            : ''}
                    </div>
                </div>
            </div>`).join('');

        grid.querySelectorAll('[data-spray]').forEach((b) => {
            b.onclick = () => nui('spray', {
                kind: 'library',
                artId: Number(b.dataset.spray),
                // Preview only — the server resolves the real art from artId.
                previewArt: b.dataset.art || '',
            });
        });
        grid.querySelectorAll('[data-delart]').forEach((b) => {
            b.onclick = async () => {
                const res = await call('XS-CriminalTablet:graffiti:deleteArt', Number(b.dataset.delart));
                if (report(res, 'Removed from the library.')) window.renderGraffiti();
            };
        });
    }

    function renderTags() {
        const list = $('#tagList');
        const tags = library.tags || [];
        $('#tagCount').textContent = `${tags.length} / ${library.maxPerGang}`;

        if (!tags.length) {
            list.innerHTML = '<div class="empty"><i class="fas fa-map-pin"></i>Nothing up right now.</div>';
            return;
        }

        list.innerHTML = tags.map((t) => `
            <div class="tile">
                <span class="tile-avatar"><i class="fas fa-spray-can"></i></span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(t.sprayed_name || 'Someone')}</span>
                    <span class="tile-sub">${escapeHtml(formatTime(t.created_at))}</span>
                </div>
                <div class="tile-actions">
                    <button class="btn btn-ghost btn-sm" data-tagwp='${escapeHtml(JSON.stringify({ x: t.x, y: t.y, z: t.z }))}'>
                        <i class="fas fa-map-pin"></i>
                    </button>
                    ${library.canManage
                        ? `<button class="btn btn-danger btn-sm" data-deltag="${t.id}"><i class="fas fa-eraser"></i></button>`
                        : ''}
                </div>
            </div>`).join('');

        list.querySelectorAll('[data-tagwp]').forEach((b) => {
            b.onclick = () => {
                try { nui('setWaypoint', JSON.parse(b.dataset.tagwp)); } catch (e) { /* malformed, ignore */ }
            };
        });
        list.querySelectorAll('[data-deltag]').forEach((b) => {
            b.onclick = async () => {
                const res = await call('XS-CriminalTablet:graffiti:remove', Number(b.dataset.deltag));
                if (report(res, 'Scrubbed.')) window.renderGraffiti();
            };
        });
    }

    // ── text composer ──
    // Named sliderVal, not num: window.XS.num is a number FORMATTER and
    // having both in scope under one name is how you read the wrong one.
    const sliderVal = (sel, fallback) => {
        const el = $(sel);
        const n = el ? Number(el.value) : NaN;
        return Number.isFinite(n) ? n : fallback;
    };

    function textPayload() {
        return {
            kind: 'text',
            text: $('#tagText').value.slice(0, 24),
            font: $('#tagFont').value || 'marker',
            fill: $('#tagFill').value,
            outline: $('#tagOutline').value,
            stroke: sliderVal('#tagStroke', 8),
            spacing: sliderVal('#tagSpacing', 0),
            skew: sliderVal('#tagSkew', 0),
            rotate: sliderVal('#tagRotate', 0),
            textCase: ($('#tagCase') || {}).value || 'as',
            glow: ($('#tagGlow') || {}).value || 'none',
        };
    }

    // The same recipe the wall uses, so the studio is a real preview and
    // not an approximation of one.
    const GLOW = {
        none: 'none',
        soft: 'drop-shadow(0 6px 14px rgba(0,0,0,.55))',
        neon: null,   // built from the fill colour below
        hard: 'drop-shadow(5px 6px 0 rgba(0,0,0,.85))',
    };

    function applyTextStyle(el, d) {
        el.textContent = d.textCase === 'upper' ? d.text.toUpperCase()
            : d.textCase === 'lower' ? d.text.toLowerCase() : d.text;
        el.style.fontFamily = (fonts.find((f) => f.id === d.font) || {}).css
            || "'Permanent Marker', cursive";
        el.style.color = d.fill;
        el.style.webkitTextStroke = `${d.stroke}px ${d.outline}`;
        el.style.paintOrder = 'stroke fill';
        el.style.letterSpacing = `${d.spacing}px`;
        el.style.transform = `skewX(${-d.skew}deg) rotate(${d.rotate}deg)`;
        el.style.filter = d.glow === 'neon'
            ? `drop-shadow(0 0 6px ${d.fill}) drop-shadow(0 0 18px ${d.fill})`
            : (GLOW[d.glow] || 'none');
    }

    function updateTextPreview() {
        const d = textPayload();
        const el = $('#textPreviewInner');
        if (!d.text) d.text = 'CREW';
        applyTextStyle(el, d);

        const label = (id, text) => { const e = $(id); if (e) e.textContent = text; };
        label('#tagStrokeVal', d.stroke + 'px');
        label('#tagSpacingVal', d.spacing + 'px');
        label('#tagSkewVal', d.skew + '\u00b0');
        label('#tagRotateVal', d.rotate + '\u00b0');
    }

    ['#tagText', '#tagFont', '#tagFill', '#tagOutline', '#tagStroke',
     '#tagSpacing', '#tagSkew', '#tagRotate', '#tagCase', '#tagGlow'].forEach((sel) => {
        const el = $(sel);
        if (el) el.addEventListener('input', updateTextPreview);
        if (el) el.addEventListener('change', updateTextPreview);
    });

    $('#sprayTextBtn').onclick = () => {
        const p = textPayload();
        if (!p.text.trim()) return flash('Type something first.', 'error');
        nui('spray', p);
    };

    $('#saveTextBtn').onclick = async () => {
        const p = textPayload();
        if (!p.text.trim()) return flash('Type something first.', 'error');
        const res = await call('XS-CriminalTablet:graffiti:saveArt', p.text, p);
        if (report(res, 'Saved to the crew library.')) window.renderGraffiti();
    };

    // ── freehand canvas ──
    const canvas = $('#drawCanvas');
    const ctx = canvas ? canvas.getContext('2d') : null;
    let drawing = false;
    let strokes = [];      // kept so undo doesn't need a pixel buffer per step
    let current = null;

    const SWATCHES = ['#f5a524', '#e5484d', '#30d158', '#2dd4bf', '#38bdf8', '#8b5cf6', '#ec4899', '#ffffff', '#101216'];

    function paintSwatches() {
        const row = $('#drawSwatches');
        if (!row) return;
        row.innerHTML = SWATCHES.map((c) =>
            `<span class="swatch" data-swatch="${c}" style="background:${c}"></span>`).join('');
        row.querySelectorAll('[data-swatch]').forEach((s) => {
            s.onclick = () => {
                $('#drawColor').value = s.dataset.swatch;
                row.querySelectorAll('.swatch').forEach((x) => x.classList.toggle('is-active', x === s));
            };
        });
    }
    paintSwatches();

    function redraw() {
        if (!ctx) return;
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        ctx.lineCap = 'round';
        ctx.lineJoin = 'round';
        strokes.forEach((s) => {
            ctx.strokeStyle = s.color;
            ctx.lineWidth = s.size;
            ctx.beginPath();
            s.points.forEach((p, i) => (i === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y)));
            ctx.stroke();
        });
    }

    // The canvas is displayed at a different size than its backing store,
    // so every pointer position has to be scaled into canvas space.
    function pos(e) {
        const r = canvas.getBoundingClientRect();
        return {
            x: ((e.clientX - r.left) / r.width) * canvas.width,
            y: ((e.clientY - r.top) / r.height) * canvas.height,
        };
    }

    if (canvas) {
        canvas.addEventListener('pointerdown', (e) => {
            drawing = true;
            canvas.setPointerCapture(e.pointerId);
            current = { color: $('#drawColor').value, size: Number($('#drawSize').value), points: [pos(e)] };
            strokes.push(current);
            redraw();
        });
        canvas.addEventListener('pointermove', (e) => {
            if (!drawing || !current) return;
            current.points.push(pos(e));
            redraw();
        });
        const stop = () => { drawing = false; current = null; };
        canvas.addEventListener('pointerup', stop);
        canvas.addEventListener('pointerleave', stop);
        canvas.addEventListener('pointercancel', stop);
    }

    $('#drawUndoBtn').onclick = () => { strokes.pop(); redraw(); };
    $('#drawClearBtn').onclick = () => { strokes = []; redraw(); };

    // Exported as a transparent PNG. The server caps the size, so a very
    // busy drawing gets refused rather than silently truncated.
    function drawPayload() {
        if (!strokes.length) return null;
        return { kind: 'draw', data: canvas.toDataURL('image/png') };
    }

    $('#sprayDrawBtn').onclick = () => {
        const p = drawPayload();
        if (!p) return flash('Draw something first.', 'error');
        nui('spray', p);
    };

    $('#saveDrawBtn').onclick = async () => {
        const p = drawPayload();
        if (!p) return flash('Draw something first.', 'error');
        const res = await call('XS-CriminalTablet:graffiti:saveArt', 'Freehand', p);
        if (report(res, 'Saved to the crew library.')) window.renderGraffiti();
    };
})();
