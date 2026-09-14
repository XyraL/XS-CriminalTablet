// ─────────────────────────────────────────────────────────────
// Admin map editor, crew setup wizard and blip creator.
//
// Everything here draws on the same satellite pyramid the player tablet
// uses, so what staff draw is exactly what players end up seeing. The
// map core (tile layer, world<->pixel calibration) is shared from app.js
// rather than duplicated, because two copies of a calibration table is
// two chances to drift.
// ─────────────────────────────────────────────────────────────
(function () {
    const { nui, escapeHtml, money, initials } = window.XS;
    const $ = window.XS.$;
    const $$ = window.XS.$$;
    const { ensureMap, mapLatLng, mapWorld, mapOf } = window.XS;

    const acall = (name, ...args) => nui('admin:call', { name, args });

    let data = { zones: [], gangs: [], placements: [], catalogue: [], blips: [], capture: {} };

    function toast(msg, type = 'info') {
        const stack = $('#adminToastStack');
        if (!stack) return;
        const el = document.createElement('div');
        el.className = 'toast toast-' + type;
        el.textContent = msg;
        stack.appendChild(el);
        setTimeout(() => el.remove(), 3200);
    }

    function report(res, okMsg) {
        if (res && res.ok) { if (okMsg) toast(okMsg, 'success'); return true; }
        toast((res && res.error) || 'That did not work', 'error');
        return false;
    }

    const gangById = (id) => data.gangs.find((g) => String(g.id) === String(id)) || null;

    async function refresh() {
        data = await acall('XS-CriminalTablet:admin:getMapData') || data;
        fillGangSelects();
        fillZoneSelect();
        fillCatalogueSelect();
        drawAll();
        renderBlipList();
        renderWizPlacements();
    }

    // ── shared painting ─────────────────────────────────────
    // One routine paints every map in the panel: the turf editor, the
    // wizard's zone step and the blip map all want the same picture.
    function paint(key, opts = {}) {
        const entry = mapOf(key);
        if (!entry) return null;
        const { map, layer } = entry;
        layer.clearLayers();

        (data.zones || []).forEach((z) => {
            const color = z.holderColor || '#5a6577';
            const assigned = !!z.holderId;
            let shape = null;

            if (z.points && z.points.length >= 3) {
                shape = L.polygon(z.points.map((p) => mapLatLng(map, p.x, p.y)), {
                    color, weight: 2, fillColor: color,
                    fillOpacity: assigned ? 0.18 : 0.07,
                    dashArray: assigned ? null : '5,5',
                });
            } else if (z.coords) {
                shape = L.circle(mapLatLng(map, z.coords.x, z.coords.y), {
                    radius: 8, color, weight: 2, fillColor: color,
                    fillOpacity: assigned ? 0.18 : 0.07,
                    dashArray: assigned ? null : '5,5',
                });
            }
            if (!shape) return;

            shape.bindTooltip(
                `<div class="map-tip"><div class="mt-head">${escapeHtml(z.label)}</div>` +
                `<div class="mt-sub">${z.holder ? escapeHtml(z.holder) : 'unassigned'}` +
                `${z.points ? ` · ${z.points.length} corners` : (z.coords ? ' · circle' : ' · no shape')}</div></div>`,
                { direction: 'top', className: 'map-tip-wrap' });

            if (opts.onZone) shape.on('click', () => opts.onZone(z));
            shape.addTo(layer);
        });

        if (opts.placements !== false) {
            (data.placements || []).forEach((pl) => {
                const gang = gangById(pl.gang_id);
                L.circleMarker(mapLatLng(map, pl.x, pl.y), {
                    radius: 4, weight: 2,
                    color: (gang && gang.color) || '#9aa6bb',
                    fillColor: '#0a0f1c', fillOpacity: 1,
                }).bindTooltip(
                    `<div class="map-tip"><div class="mt-head">${escapeHtml(pl.label || pl.unlock_id)}</div>` +
                    `<div class="mt-sub">${escapeHtml((gang && gang.label) || 'crew #' + pl.gang_id)} · ${escapeHtml(pl.kind)}</div></div>`,
                    { direction: 'top', className: 'map-tip-wrap' }).addTo(layer);
            });
        }

        if (opts.blips !== false) {
            (data.blips || []).forEach((b) => {
                L.circleMarker(mapLatLng(map, b.coords.x, b.coords.y), {
                    radius: 5, weight: 2, color: b.gangColor || '#9aa6bb',
                    fillColor: b.gangColor || '#9aa6bb', fillOpacity: 0.5,
                }).bindTooltip(
                    `<div class="map-tip"><div class="mt-head">${escapeHtml(b.label)}</div>` +
                    `<div class="mt-sub">${escapeHtml(b.gangLabel)} · ${b.visibility === 'all' ? 'everyone' : 'crew only'}</div></div>`,
                    { direction: 'top', className: 'map-tip-wrap' }).addTo(layer);
            });
        }

        return entry;
    }

    function drawAll() {
        if (ensureMap('adminZoneMap', 'admzone')) paint('admzone', { onZone: selectZone });
        if (ensureMap('wizMap', 'wizzone')) paint('wizzone', { placements: false, blips: false });
        if (ensureMap('wizPlaceMap', 'wizplace')) paint('wizplace');
        if (ensureMap('blipMap', 'admblip')) paint('admblip');
        redrawDraft('admzone', draft, '#3d7dff');
        redrawDraft('wizzone', wiz.points, '#3d7dff');
    }

    // ── a polygon being drawn ───────────────────────────────
    // The draft lives in its own layer so re-painting the world underneath
    // never wipes the corners somebody is halfway through placing.
    const draftLayers = {};

    function redrawDraft(key, points, color) {
        const entry = mapOf(key);
        if (!entry) return;
        if (!draftLayers[key]) draftLayers[key] = L.layerGroup().addTo(entry.map);
        const layer = draftLayers[key];
        layer.clearLayers();
        if (!points || !points.length) return;

        const latlngs = points.map((p) => mapLatLng(entry.map, p.x, p.y));
        if (points.length >= 3) {
            L.polygon(latlngs, { color, weight: 2, fillColor: color, fillOpacity: 0.2 }).addTo(layer);
        } else if (points.length === 2) {
            L.polyline(latlngs, { color, weight: 2, dashArray: '4,4' }).addTo(layer);
        }
        latlngs.forEach((ll, i) => {
            L.circleMarker(ll, { radius: 5, weight: 2, color, fillColor: '#04060c', fillOpacity: 1 })
                .bindTooltip(String(i + 1), { permanent: true, direction: 'center', className: 'corner-num' })
                .addTo(layer);
        });
    }

    // ═══ TURF MAP EDITOR ═══
    let draft = [];
    let drawing = false;

    function fillZoneSelect() {
        const sel = $('#mapZoneTarget');
        if (!sel) return;
        const prev = sel.value;
        sel.innerHTML = '<option value="">— pick a zone —</option>' + (data.zones || []).map((z) =>
            `<option value="${escapeHtml(z.zone)}">${escapeHtml(z.label)}${z.points || z.coords ? '' : ' (no shape)'}</option>`).join('');
        if (prev) sel.value = prev;
    }

    function selectZone(z) {
        const sel = $('#mapZoneTarget');
        if (sel) sel.value = z.zone;
        if (!drawing) toast(`${z.label} selected.`, 'info');
    }

    function setDrawing(on) {
        drawing = on;
        $('#mapDrawStart').classList.toggle('hidden', on);
        $('#mapDrawEdit').classList.toggle('hidden', on);
        $('#mapDrawUndo').classList.toggle('hidden', !on);
        $('#mapDrawSave').classList.toggle('hidden', !on);
        $('#mapDrawCancel').classList.toggle('hidden', !on);
        $('#mapDrawHint').classList.toggle('hidden', !on);
        updateDraftCount();
    }

    function updateDraftCount() {
        const el = $('#mapDrawCount');
        if (el) el.textContent = drawing ? `${draft.length} corner${draft.length === 1 ? '' : 's'}` : '';
    }

    function wireZoneMap() {
        const entry = mapOf('admzone');
        if (!entry || entry.wired) return;
        entry.wired = true;
        entry.map.on('click', (ev) => {
            if (!drawing) return;
            draft.push(mapWorld(entry.map, ev.latlng));
            redrawDraft('admzone', draft, '#3d7dff');
            updateDraftCount();
        });
    }

    $('#mapDrawStart').onclick = () => {
        if (!$('#mapZoneTarget').value) return toast('Pick the zone you are drawing first.', 'error');
        draft = [];
        redrawDraft('admzone', draft, '#3d7dff');
        wireZoneMap();
        setDrawing(true);
    };

    $('#mapDrawUndo').onclick = () => {
        draft.pop();
        redrawDraft('admzone', draft, '#3d7dff');
        updateDraftCount();
    };

    $('#mapDrawCancel').onclick = () => {
        draft = [];
        redrawDraft('admzone', draft, '#3d7dff');
        setDrawing(false);
    };

    $('#mapDrawSave').onclick = async () => {
        const zone = $('#mapZoneTarget').value;
        if (!zone) return toast('Pick a zone.', 'error');
        if (draft.length < 3) return toast('A block needs at least three corners.', 'error');

        const z = Number($('#mapDrawZ').value) || 30;
        const res = await acall('XS-CriminalTablet:admin:setZonePolygon', zone, draft, z);
        if (report(res, 'Shape saved.')) {
            draft = [];
            setDrawing(false);
            await refresh();
        }
    };

    $('#mapZFromMe').onclick = async () => {
        const me = await acall('XS-CriminalTablet:admin:whereAmI');
        if (me && me.z) {
            $('#mapDrawZ').value = Math.round(me.z);
            toast('Height taken from where you are stood.', 'success');
        }
    };

    // ═══ BLIPS ═══
    let blipArmed = false;

    function fillGangSelects() {
        const opts = (data.gangs || []).map((g) =>
            `<option value="${g.id}">${escapeHtml(g.label)}</option>`).join('');
        ['#blipGang'].forEach((sel) => {
            const el = $(sel);
            if (!el) return;
            const prev = el.value;
            el.innerHTML = '<option value="">— pick a crew —</option>' + opts;
            if (prev) el.value = prev;
        });
    }

    function wireBlipMap() {
        const entry = mapOf('admblip');
        if (!entry || entry.wired) return;
        entry.wired = true;
        entry.map.on('click', async (ev) => {
            if (!blipArmed) return;
            const gangId = Number($('#blipGang').value);
            if (!gangId) { toast('Pick a crew first.', 'error'); return; }

            const world = mapWorld(entry.map, ev.latlng);
            const res = await acall('XS-CriminalTablet:admin:createBlip', gangId, {
                label: $('#blipLabel').value.trim(),
                sprite: Number($('#blipSprite').value) || 84,
                color: Number($('#blipColor').value) || 0,
                scale: Number($('#blipScale').value) || 0.8,
                visibility: $('#blipVis').value,
                shortRange: $('#blipShort').checked,
                coords: { x: world.x, y: world.y, z: 30 },
            });
            if (report(res, 'Blip placed.')) {
                blipArmed = false;
                $('#blipHint').classList.add('hidden');
                await refresh();
            }
        });
    }

    $('#blipArm').onclick = () => {
        if (!$('#blipGang').value) return toast('Pick a crew first.', 'error');
        blipArmed = true;
        wireBlipMap();
        $('#blipHint').classList.remove('hidden');
        toast('Click the map where it goes.', 'info');
    };

    function renderBlipList() {
        const list = $('#blipList');
        if (!list) return;
        const blips = data.blips || [];
        if (!blips.length) {
            list.innerHTML = '<div class="empty"><i class="fas fa-location-dot"></i>No crew blips yet.</div>';
            return;
        }
        list.innerHTML = blips.map((b) => `
            <div class="tile">
                <span class="tile-avatar" style="border-color:${escapeHtml(b.gangColor)};color:${escapeHtml(b.gangColor)}">${escapeHtml(initials(b.gangLabel))}</span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(b.label)}</span>
                    <span class="tile-sub">${escapeHtml(b.gangLabel)} · sprite ${b.sprite} · ${b.visibility === 'all' ? 'everyone' : 'crew only'}</span>
                </div>
                <div class="tile-actions">
                    <button class="btn btn-danger btn-sm" data-blipdel="${b.id}"><i class="fas fa-trash"></i></button>
                </div>
            </div>`).join('');

        list.querySelectorAll('[data-blipdel]').forEach((btn) => {
            btn.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:deleteBlip', Number(btn.dataset.blipdel));
                if (report(res, 'Blip removed.')) await refresh();
            };
        });
    }

    // ═══ SETUP WIZARD ═══
    const STEPS = [
        { n: 1, label: 'Identity' },
        { n: 2, label: 'Boss' },
        { n: 3, label: 'Size' },
        { n: 4, label: 'Turf' },
        { n: 5, label: 'Property' },
        { n: 6, label: 'Review' },
    ];

    const wiz = { step: 1, points: [], placements: [], gangId: null, zoneKey: null, armed: null };

    function renderSteps() {
        $('#wizSteps').innerHTML = STEPS.map((s) => {
            const cls = s.n < wiz.step ? 'done' : (s.n === wiz.step ? 'now' : '');
            return `<li class="wiz-step ${cls}" data-step="${s.n}">
                <span class="wiz-dot">${s.n < wiz.step ? '<i class="fas fa-check"></i>' : s.n}</span>
                <span class="wiz-label">${escapeHtml(s.label)}</span>
            </li>`;
        }).join('');

        $$('#wizSteps .wiz-step').forEach((li) => {
            li.onclick = () => {
                const n = Number(li.dataset.step);
                if (n < wiz.step) showStep(n);
            };
        });
    }

    function showStep(n) {
        wiz.step = Math.max(1, Math.min(STEPS.length, n));
        renderSteps();
        $$('.wiz-pane').forEach((pane) => {
            pane.classList.toggle('is-active', Number(pane.dataset.step) === wiz.step);
        });
        $('#wizBack').disabled = wiz.step === 1;
        $('#wizNext').classList.toggle('hidden', wiz.step === STEPS.length);
        $('#wizFinish').classList.toggle('hidden', wiz.step !== STEPS.length);

        if (wiz.step === 4) { drawAll(); wireWizZoneMap(); }
        if (wiz.step === 5) { drawAll(); wireWizPlaceMap(); }
        if (wiz.step === 6) renderSummary();
    }

    // Steps 1-3 are the only ones that can be wrong before the crew
    // exists, so validation lives with them rather than at the end.
    function validateStep(n) {
        if (n === 1) {
            if (!$('#wizLabel').value.trim()) return 'Give the crew a display name.';
            const internal = $('#wizName').value.trim();
            if (internal.length < 3) return 'The internal name needs at least 3 characters.';
            if (!/^[a-z0-9_]+$/.test(internal)) return 'Internal name: lowercase letters, numbers and underscores only.';
        }
        if (n === 4 && wiz.points.length && wiz.points.length < 3) {
            return 'A block needs three corners, or clear it and skip this step.';
        }
        if (n === 4 && wiz.points.length >= 3 && !$('#wizZoneKey').value.trim()) {
            return 'Give the zone a key so it can be referenced later.';
        }
        return null;
    }

    function syncIdentityPreview() {
        const label = $('#wizLabel').value.trim();
        const color = $('#wizColor').value;
        $('#wizCrest').textContent = initials(label || '—');
        $('#wizCrest').style.background = `linear-gradient(145deg, ${color}, ${color}88)`;
        $('#wizCrestName').textContent = label || 'New crew';

        // Offer a sane internal name, but stop the moment they type one.
        const nameEl = $('#wizName');
        if (!nameEl.dataset.touched) {
            nameEl.value = label.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 32);
        }
    }

    function fillSwatches() {
        const box = $('#wizSwatches');
        if (!box) return;
        const colors = ['#e5484d', '#f5a524', '#ffd60a', '#30d158', '#2dd4bf',
            '#38bdf8', '#3d7dff', '#6366f1', '#8b5cf6', '#ec4899', '#f97316', '#94a3b8'];
        box.innerHTML = colors.map((c) =>
            `<button type="button" class="swatch" data-color="${c}" style="background:${c}"></button>`).join('');
        box.querySelectorAll('.swatch').forEach((b) => {
            b.onclick = () => { $('#wizColor').value = b.dataset.color; syncIdentityPreview(); };
        });
    }

    function wireWizZoneMap() {
        const entry = mapOf('wizzone');
        if (!entry || entry.wired) return;
        entry.wired = true;
        entry.map.on('click', (ev) => {
            wiz.points.push(mapWorld(entry.map, ev.latlng));
            redrawDraft('wizzone', wiz.points, $('#wizColor').value || '#3d7dff');
            $('#wizZoneCount').textContent = `${wiz.points.length} corner${wiz.points.length === 1 ? '' : 's'}`;
        });
    }

    $('#wizZoneUndo').onclick = () => {
        wiz.points.pop();
        redrawDraft('wizzone', wiz.points, $('#wizColor').value || '#3d7dff');
        $('#wizZoneCount').textContent = `${wiz.points.length} corner${wiz.points.length === 1 ? '' : 's'}`;
    };
    $('#wizZoneClear').onclick = () => {
        wiz.points = [];
        redrawDraft('wizzone', wiz.points, '#3d7dff');
        $('#wizZoneCount').textContent = '0 corners';
    };

    function fillCatalogueSelect() {
        const sel = $('#wizPlaceKind');
        if (!sel) return;
        const prev = sel.value;
        sel.innerHTML = (data.catalogue || []).map((c) =>
            `<option value="${escapeHtml(c.id)}">${escapeHtml(c.label)} — ${escapeHtml(c.kind)}</option>`).join('');
        if (prev) sel.value = prev;
    }

    function wireWizPlaceMap() {
        const entry = mapOf('wizplace');
        if (!entry || entry.wired) return;
        entry.wired = true;
        entry.map.on('click', (ev) => {
            if (!wiz.armed) return;
            const world = mapWorld(entry.map, ev.latlng);
            const def = (data.catalogue || []).find((c) => c.id === wiz.armed);
            wiz.placements = wiz.placements.filter((pl) => pl.id !== wiz.armed);
            wiz.placements.push({
                id: wiz.armed,
                label: def ? def.label : wiz.armed,
                kind: def ? def.kind : '?',
                coords: { x: world.x, y: world.y, z: 30 },
            });
            wiz.armed = null;
            $('#wizPlaceHint').classList.add('hidden');
            renderWizPlacements();
        });
    }

    $('#wizPlaceArm').onclick = () => {
        const id = $('#wizPlaceKind').value;
        if (!id) return toast('Pick something to place.', 'error');
        wiz.armed = id;
        wireWizPlaceMap();
        $('#wizPlaceHint').classList.remove('hidden');
    };

    function renderWizPlacements() {
        const list = $('#wizPlaceList');
        if (!list) return;
        if (!wiz.placements.length) {
            list.innerHTML = '<div class="empty"><i class="fas fa-cubes"></i>Nothing placed yet — this step is optional.</div>';
            return;
        }
        list.innerHTML = wiz.placements.map((pl) => `
            <div class="tile compact">
                <span class="tile-avatar"><i class="fas fa-cube"></i></span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(pl.label)}</span>
                    <span class="tile-sub">${escapeHtml(pl.kind)} · ${Math.round(pl.coords.x)}, ${Math.round(pl.coords.y)}</span>
                </div>
                <div class="tile-actions">
                    <button class="btn btn-danger btn-sm" data-wizdel="${escapeHtml(pl.id)}"><i class="fas fa-trash"></i></button>
                </div>
            </div>`).join('');
        list.querySelectorAll('[data-wizdel]').forEach((b) => {
            b.onclick = () => {
                wiz.placements = wiz.placements.filter((pl) => pl.id !== b.dataset.wizdel);
                renderWizPlacements();
            };
        });
    }

    // ── boss search ──
    let bossTimer = null;
    $('#wizBossSearch').oninput = () => {
        clearTimeout(bossTimer);
        bossTimer = setTimeout(async () => {
            const results = await window.XS.call('XS-CriminalTablet:players:search', $('#wizBossSearch').value) || [];
            const box = $('#wizBossResults');
            if (!results.length) {
                box.innerHTML = '<div class="empty"><i class="fas fa-user-slash"></i>Nobody matches.</div>';
                return;
            }
            box.innerHTML = results.map((r) => `
                <div class="tile compact">
                    <span class="tile-avatar">${escapeHtml(initials(r.name))}</span>
                    <div class="tile-main">
                        <span class="tile-name">${escapeHtml(r.name)}</span>
                        <span class="tile-sub">server id ${r.id}</span>
                    </div>
                    <div class="tile-actions">
                        <button class="btn btn-ghost btn-sm" data-boss="${r.id}">Pick</button>
                    </div>
                </div>`).join('');
            box.querySelectorAll('[data-boss]').forEach((b) => {
                b.onclick = async () => {
                    const res = await acall('XS-CriminalTablet:admin:resolveCitizenId', Number(b.dataset.boss));
                    if (res && res.citizenid) {
                        $('#wizBoss').value = res.citizenid;
                        toast(`Boss set to ${res.name || res.citizenid}.`, 'success');
                    } else {
                        toast('Could not read that player.', 'error');
                    }
                };
            });
        }, 220);
    };

    function renderSummary() {
        const rows = [
            ['Crew', $('#wizLabel').value.trim() || '—'],
            ['Internal name', $('#wizName').value.trim() || '—'],
            ['Colour', $('#wizColor').value],
            ['Boss', $('#wizBoss').value.trim() || 'none yet'],
            ['Member cap', Number($('#wizCap').value) || 'server default'],
            ['Starting treasury', money(Number($('#wizBank').value) || 0)],
            ['Notice', $('#wizMotd').value.trim() || 'none'],
            ['Turf', wiz.points.length >= 3
                ? `${$('#wizZoneLabel').value.trim() || $('#wizZoneKey').value.trim()} — ${wiz.points.length} corners`
                : 'none yet'],
            ['Property', wiz.placements.length
                ? wiz.placements.map((p) => p.label).join(', ')
                : 'none yet'],
        ];
        $('#wizSummary').innerHTML = rows.map(([k, v]) => `
            <div class="wiz-row">
                <span class="wiz-k">${escapeHtml(k)}</span>
                <span class="wiz-v">${escapeHtml(String(v))}</span>
            </div>`).join('');
        $('#wizError').textContent = '';
    }

    $('#wizBack').onclick = () => showStep(wiz.step - 1);
    $('#wizNext').onclick = () => {
        const err = validateStep(wiz.step);
        if (err) return toast(err, 'error');
        showStep(wiz.step + 1);
    };

    $('#wizReset').onclick = () => {
        ['#wizLabel', '#wizName', '#wizBoss', '#wizBossSearch', '#wizMotd', '#wizZoneKey', '#wizZoneLabel']
            .forEach((sel) => { const el = $(sel); if (el) el.value = ''; });
        $('#wizCap').value = 0;
        $('#wizBank').value = 0;
        $('#wizColor').value = '#3d7dff';
        $('#wizName').dataset.touched = '';
        wiz.points = [];
        wiz.placements = [];
        wiz.armed = null;
        wiz.gangId = null;
        $('#wizBossResults').innerHTML = '';
        $('#wizZoneCount').textContent = '0 corners';
        redrawDraft('wizzone', [], '#3d7dff');
        renderWizPlacements();
        syncIdentityPreview();
        showStep(1);
    };

    // The finish button is the only place that writes. Everything before
    // it is local, so backing out of the wizard leaves nothing behind.
    $('#wizFinish').onclick = async () => {
        const err = validateStep(1) || validateStep(4);
        if (err) { $('#wizError').textContent = err; return; }

        const btn = $('#wizFinish');
        btn.disabled = true;
        try {
            const created = await acall('XS-CriminalTablet:admin:createGang', {
                label: $('#wizLabel').value.trim(),
                name: $('#wizName').value.trim(),
                boss: $('#wizBoss').value.trim(),
                color: $('#wizColor').value,
                maxMembers: Number($('#wizCap').value) || 0,
                bank: Number($('#wizBank').value) || 0,
                motd: $('#wizMotd').value.trim(),
            });
            if (!created || !created.ok) {
                $('#wizError').textContent = (created && created.error) || 'Could not create the crew.';
                return;
            }
            const gangId = created.gangId;
            wiz.gangId = gangId;

            // Zone, then shape, then owner — a zone with no crew is
            // invisible to players, so the assignment is not optional.
            if (wiz.points.length >= 3) {
                const key = $('#wizZoneKey').value.trim();
                const label = $('#wizZoneLabel').value.trim() || key;
                const zoneRes = await acall('XS-CriminalTablet:admin:createZone', key, label, 0, gangId);
                if (zoneRes && zoneRes.ok) {
                    await acall('XS-CriminalTablet:admin:setZonePolygon', zoneRes.zone || key, wiz.points, 30);
                } else {
                    toast((zoneRes && zoneRes.error) || 'Crew made, but the zone failed.', 'error');
                }
            }

            for (const pl of wiz.placements) {
                await acall('XS-CriminalTablet:admin:placeFor', gangId, pl.id, pl.coords, 0);
            }

            toast(`${$('#wizLabel').value.trim()} is set up.`, 'success');
            $('#wizReset').click();
            await refresh();
            if (window.XSAdmin && window.XSAdmin.refresh) window.XSAdmin.refresh();
        } finally {
            btn.disabled = false;
        }
    };

    $('#wizLabel').oninput = syncIdentityPreview;
    $('#wizColor').oninput = syncIdentityPreview;
    $('#wizName').oninput = () => { $('#wizName').dataset.touched = '1'; };


    $('#mapDrawEdit').onclick = () => {
        const zone = $('#mapZoneTarget').value;
        if (!zone) return toast('Pick the zone you want to change first.', 'error');
        const z = (data.zones || []).find((x) => x.zone === zone);
        if (!z || !z.points || z.points.length < 3) {
            return toast('That zone has no polygon yet — use Draw shape.', 'error');
        }
        // Load the current corners as the draft so staff nudge what is
        // there rather than re-walking the whole block.
        draft = z.points.map((p) => ({ x: p.x, y: p.y }));
        if (z.coords && z.coords.z) $('#mapDrawZ').value = Math.round(z.coords.z);
        redrawDraft('admzone', draft, '#3d7dff');
        wireZoneMap();
        setDrawing(true);
        toast(`Editing ${z.label} — click to add corners, Undo to take them back off.`, 'info');
    };

    // ═══ DEALER SETUP ═══
    let dealer = { pool: [], spawns: [], settings: {}, stock: [] };
    let dealerArmed = false;

    async function refreshDealer() {
        dealer = await acall('XS-CriminalTablet:admin:dealerState') || dealer;

        $('#dealerPoolNote').textContent = dealer.poolFromConfig
            ? 'still reading config.lua — adding one here takes over' : '';
        $('#dealerSpawnNote').textContent = dealer.spawnsFromConfig
            ? 'still reading config.lua — adding one here takes over' : '';

        const st = dealer.settings || {};
        $$('#adminRoot [data-setting]').forEach((el) => {
            const v = st[el.dataset.setting];
            if (v !== undefined && v !== null) el.value = v;
        });

        renderDealerPool();
        renderDealerSpawns();
        if (ensureMap('dealerMap', 'dealer')) paintDealerMap();
    }

    function paintDealerMap() {
        const entry = mapOf('dealer');
        if (!entry) return;
        entry.layer.clearLayers();
        (dealer.spawns || []).forEach((sp, i) => {
            L.circleMarker(mapLatLng(entry.map, sp.coords.x, sp.coords.y), {
                radius: 6, weight: 2, color: '#2fe08a', fillColor: '#04060c', fillOpacity: 1,
            }).bindTooltip(
                `<div class="map-tip"><div class="mt-head">${escapeHtml(sp.label || 'Spot ' + (i + 1))}</div>` +
                `<div class="mt-sub">${Math.round(sp.coords.x)}, ${Math.round(sp.coords.y)}</div></div>`,
                { direction: 'top', className: 'map-tip-wrap' }).addTo(entry.layer);
        });
    }

    function renderDealerPool() {
        const list = $('#dealerPoolList');
        if (!list) return;
        const pool = dealer.pool || [];
        if (!pool.length) {
            list.innerHTML = '<div class="empty"><i class="fas fa-box-open"></i>Nothing in the pool — he turns up empty-handed.</div>';
            return;
        }
        list.innerHTML = pool.map((e) => `
            <div class="tile compact">
                <span class="tile-avatar"><i class="fas fa-box"></i></span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(e.label || e.item)}</span>
                    <span class="tile-sub" style="font-family:var(--mono)">${escapeHtml(e.item)}</span>
                </div>
                <div class="tile-stat">${money(e.priceMin)} – ${money(e.priceMax)}</div>
                <div class="tile-actions">
                    ${e.id ? `<button class="btn btn-danger btn-sm" data-dlrm="${e.id}"><i class="fas fa-trash"></i></button>` : ''}
                </div>
            </div>`).join('');

        list.querySelectorAll('[data-dlrm]').forEach((b) => {
            b.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:dealerRemoveItem', Number(b.dataset.dlrm));
                if (report(res, 'Taken off the list.')) refreshDealer();
            };
        });
    }

    function renderDealerSpawns() {
        const list = $('#dealerSpawnList');
        if (!list) return;
        const spawns = dealer.spawns || [];
        if (!spawns.length) {
            list.innerHTML = '<div class="empty"><i class="fas fa-map-pin"></i>No spots yet — calling him will fail until there is one.</div>';
            return;
        }
        list.innerHTML = spawns.map((sp, i) => `
            <div class="tile compact">
                <span class="tile-avatar"><i class="fas fa-map-pin"></i></span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(sp.label || 'Spot ' + (i + 1))}</span>
                    <span class="tile-sub" style="font-family:var(--mono)">${Math.round(sp.coords.x)}, ${Math.round(sp.coords.y)}, ${Math.round(sp.coords.z)}</span>
                </div>
                <div class="tile-actions">
                    ${sp.id ? `<button class="btn btn-danger btn-sm" data-dlsp="${sp.id}"><i class="fas fa-trash"></i></button>` : ''}
                </div>
            </div>`).join('');

        list.querySelectorAll('[data-dlsp]').forEach((b) => {
            b.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:dealerRemoveSpawn', Number(b.dataset.dlsp));
                if (report(res, 'Spot removed.')) refreshDealer();
            };
        });
    }

    $('#dlAddItem').onclick = async () => {
        const item = $('#dlItem').value.trim();
        if (!item) return toast('Needs an item name.', 'error');
        const res = await acall('XS-CriminalTablet:admin:dealerAddItem', item,
            $('#dlLabel').value.trim(), Number($('#dlMin').value) || 0, Number($('#dlMax').value) || 0);
        if (report(res, 'Added to the pool.')) {
            $('#dlItem').value = '';
            $('#dlLabel').value = '';
            refreshDealer();
        }
    };

    $('#dlSpawnHere').onclick = async () => {
        const res = await acall('XS-CriminalTablet:admin:dealerAddSpawnHere', $('#dlSpawnLabel').value.trim());
        if (report(res, 'Spot added where you are stood.')) {
            $('#dlSpawnLabel').value = '';
            refreshDealer();
        }
    };

    $('#dlSpawnArm').onclick = () => {
        dealerArmed = true;
        wireDealerMap();
        $('#dealerMapHint').classList.remove('hidden');
        toast('Click the map.', 'info');
    };

    function wireDealerMap() {
        const entry = mapOf('dealer');
        if (!entry || entry.wiredDealer) return;
        entry.wiredDealer = true;
        entry.map.on('click', async (ev) => {
            if (!dealerArmed) return;
            const world = mapWorld(entry.map, ev.latlng);
            const res = await acall('XS-CriminalTablet:admin:dealerAddSpawn',
                $('#dlSpawnLabel').value.trim(), { x: world.x, y: world.y, z: 30 }, 0);
            dealerArmed = false;
            $('#dealerMapHint').classList.add('hidden');
            if (report(res, 'Spot added.')) {
                $('#dlSpawnLabel').value = '';
                refreshDealer();
            }
        });
    }

    $('#dlSaveSettings').onclick = async () => {
        for (const el of $$('#adminRoot [data-setting]')) {
            await acall('XS-CriminalTablet:admin:dealerSetSetting', el.dataset.setting, el.value);
        }
        toast('Settings saved.', 'success');
        refreshDealer();
    };

    $('#dlResetSettings').onclick = async () => {
        for (const el of $$('#adminRoot [data-setting]')) {
            await acall('XS-CriminalTablet:admin:dealerResetSetting', el.dataset.setting);
        }
        toast('Back to config.lua.', 'success');
        refreshDealer();
    };

    // ── entry points admin.js calls when its tabs open ──
    window.XSMapEdit = {
        refresh,
        onTab(tab) {
            if (tab === 'admin-zones') { refresh(); }
            if (tab === 'admin-blips') { refresh(); }
            if (tab === 'admin-setup') { refresh(); renderSteps(); showStep(wiz.step); }
            if (tab === 'admin-dealer-setup') { refreshDealer(); }
        },
        init() {
            fillSwatches();
            syncIdentityPreview();
            renderSteps();
            showStep(1);
            renderWizPlacements();
        },
    };
})();
