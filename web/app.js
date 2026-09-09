// ─────────────────────────────────────────────────────────────
// XS-CriminalTablet NUI controller. Talks to client/device.lua via fetch callbacks.
// All gang logic lives server-side; this only renders + relays actions.
// ─────────────────────────────────────────────────────────────
const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'XS-CriminalTablet';
const $ = (s) => document.querySelector(s);
const el = (s) => document.querySelectorAll(s);

let state = { snapshot: null, apps: [], activeApp: null };

// POST to a registered NUI callback.
async function nui(cb, body = {}) {
    try {
        const r = await fetch(`https://${RES}/${cb}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(body),
        });
        return await r.json().catch(() => ({}));
    } catch (e) {
        return {};
    }
}

// Relay a server callback through the generic 'call' bridge.
const call = (name, ...args) => nui('call', { name, args });

// ── window protocol ──
window.addEventListener('message', (ev) => {
    const { action, data } = ev.data || {};
    if (action === 'open') openUI(data);
    else if (action === 'close') closeUI();
    else if (action === 'openAdmin' && window.openAdminUI) window.openAdminUI();
    else if (action === 'invite') showInvite(data);
    else if (action === 'refresh') refreshActiveApp();
    else if (action === 'chatWorldMessage') onWorldMessage(data);
    else if (action === 'chatDM') onDMReceived(data);
});

document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    if (!document.getElementById('adminRoot').classList.contains('hidden')) nui('admin:close');
    else nui('escape');
});

const BOOT_LINES = [
    'INITIALIZING SECURE LINK...',
    'DECRYPTING HANDSHAKE...',
    'LOADING MODULES <span class="ok">[OK]</span>',
    'ACCESS GRANTED',
];

function playBootSequence(onDone) {
    const screen = $('#bootScreen');
    const linesEl = $('#bootLines');
    if (!screen || !linesEl) { onDone && onDone(); return; }
    linesEl.innerHTML = '';
    screen.classList.remove('is-hidden');

    let i = 0;
    function next() {
        if (i >= BOOT_LINES.length) {
            setTimeout(() => { screen.classList.add('is-hidden'); onDone && onDone(); }, 280);
            return;
        }
        const div = document.createElement('div');
        div.className = 'boot-line';
        div.innerHTML = BOOT_LINES[i] + (i === BOOT_LINES.length - 1 ? '<span class="boot-cursor"></span>' : '');
        linesEl.appendChild(div);
        requestAnimationFrame(() => div.classList.add('is-shown'));
        i++;
        setTimeout(next, 220);
    }
    next();
}

function openUI(snapshot) {
    state.snapshot = snapshot;
    $('#root').classList.remove('hidden');
    renderApps(snapshot.apps || []);
    tickClock();
    switchApp(state.activeApp || (state.apps[0] && state.apps[0].id));
    playBootSequence();
}

function closeUI() {
    $('#root').classList.add('hidden');
    $('#adminRoot').classList.add('hidden');
    hideInvite();
}

// ── incoming invites (banner inside the device) ──
let inviteTimer = null;
function showInvite(inv) {
    const b = $('#inviteBanner');
    if (!b || !inv) return;
    $('#inviteTitle').textContent = inv.title || 'Invite';
    $('#inviteBody').textContent = `${inv.from || 'Someone'} ${inv.detail || 'sent you an invite'}.`;
    b.classList.remove('hidden');
    clearTimeout(inviteTimer);
    inviteTimer = setTimeout(() => respondInvite(false), 45000);
}
function hideInvite() {
    clearTimeout(inviteTimer);
    const b = $('#inviteBanner');
    if (b) b.classList.add('hidden');
}
function respondInvite(accept) {
    const b = $('#inviteBanner');
    if (!b || b.classList.contains('hidden')) return;
    hideInvite();
    nui('inviteRespond', { accept });
}
$('#inviteAccept').onclick = () => respondInvite(true);
$('#inviteDecline').onclick = () => respondInvite(false);

// Server-pushed refresh (someone joined your crew, etc.) — re-render the
// app that's showing without resetting which tab is active.
async function refreshActiveApp() {
    if ($('#root').classList.contains('hidden')) return;
    if (state.activeApp === 'boosting') await renderBoosting();
    else if (state.activeApp === 'blackmarket') return;
    else await refresh();
}

$('#powerBtn').onclick = () => nui('close');

// ── clock ──
function tickClock() {
    const c = $('#clock');
    const update = () => {
        const d = new Date();
        c.textContent = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
    };
    update();
    clearInterval(window.__clock);
    window.__clock = setInterval(update, 15000);
}

// ── app rail ──
function renderApps(apps) {
    state.apps = apps;
    const rail = $('#appRail');
    rail.innerHTML = '';
    apps.forEach((app) => {
        const b = document.createElement('button');
        b.className = 'app-btn' + (app.id === state.activeApp ? ' is-active' : '');
        b.innerHTML = `<i class="fas fa-${app.icon || 'square'}"></i><span>${escapeHtml(app.label)}</span>`;
        b.title = app.label;
        b.onclick = () => switchApp(app.id);
        rail.appendChild(b);
    });
}

// ── app routing ──
function switchApp(appId) {
    state.activeApp = appId;
    el('.app-btn').forEach((b, i) => b.classList.toggle('is-active', state.apps[i] && state.apps[i].id === appId));
    el('.view').forEach((v) => v.classList.add('hidden'));

    if (appId === 'blackmarket') {
        showView('viewBlackmarket');
        renderBlackmarket();
    } else if (appId === 'boosting') {
        showView('viewBoosting');
        renderBoosting();
    } else {
        render(); // gangops decides viewFound vs viewGang itself
    }
}

// ── main render (Gang Ops) ──
function render() {
    const g = state.snapshot.gang;
    if (!g) {
        showView('viewFound');
        $('#gangName').textContent = 'No affiliation';
        $('#gangTier').textContent = '—';
        return;
    }
    showView('viewGang');
    $('#gangName').textContent = g.label;
    $('#gangTier').textContent = g.tier;

    renderOverview(g);
    renderRoster(g);
    renderTerritory();
    renderBank(g);
    renderLogs(g.logs || []);
    renderTasks();
    renderTaskBadges();
    renderTaskLeaderboard();
    renderUnlocks();
    renderDealer();
    renderGangPerks();
}

// Animates a stat from its current displayed value to a new one — a
// cheap "premium dashboard" touch for the Main overview cards.
function countUp(el, target, prefix = '') {
    const start = Number((el.textContent || '').replace(/[^0-9.-]/g, '')) || 0;
    if (start === target) { el.textContent = prefix + target.toLocaleString(); return; }
    const duration = 500;
    const startTime = performance.now();
    function step(now) {
        const t = Math.min(1, (now - startTime) / duration);
        const eased = 1 - Math.pow(1 - t, 3);
        const value = Math.round(start + (target - start) * eased);
        el.textContent = prefix + value.toLocaleString();
        if (t < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
}

// ── main overview ──
function renderOverview(g) {
    $('#overviewName').textContent = g.label;
    $('#overviewTier').textContent = g.tier;
    countUp($('#overviewBank'), Number(g.bank), '$');
    countUp($('#overviewRep'), Number(g.notoriety));
    countUp($('#overviewMembers'), g.members.length);
    countUp($('#overviewOnline'), g.members.filter((m) => m.online).length);
    countUp($('#overviewTerritories'), (state.snapshot.territories || []).filter((t) => t.holderId === g.id).length);
    const myRank = g.ranks[g.myGrade] ? g.ranks[g.myGrade].name : '?';
    $('#overviewMyRank').textContent = myRank;
    renderLogList($('#overviewLogs'), (g.logs || []).slice(0, 8));

    $('#overviewLevelBadge').textContent = 'LV ' + (g.gangLevel || 1);
    $('#overviewLevelTitle').textContent = g.gangLevelTitle || 'Crew';

    if (g.nextTierMin == null) {
        $('#overviewProgressFill').style.width = '100%';
        $('#overviewProgressLabel').textContent = `${Number(g.notoriety).toLocaleString()} rep — max tier`;
    } else {
        const span = g.nextTierMin - g.tierMin;
        const into = Math.max(0, g.notoriety - g.tierMin);
        const pct = span > 0 ? Math.min(100, (into / span) * 100) : 0;
        $('#overviewProgressFill').style.width = pct + '%';
        $('#overviewProgressLabel').textContent =
            `${Number(g.notoriety).toLocaleString()} / ${Number(g.nextTierMin).toLocaleString()} rep to next tier`;
    }
}

function showView(id) {
    el('.view').forEach((v) => v.classList.add('hidden'));
    const target = $('#' + id);
    target.classList.remove('hidden');
    playGlitch(target);
}

// Re-triggers the glitch-in animation reliably even if the class is
// already present (force a reflow between remove/add).
function playGlitch(el) {
    el.classList.remove('glitch-in');
    void el.offsetWidth;
    el.classList.add('glitch-in');
}

// ── roster ──
function canManage(g) { return g.myGrade >= 2; } // simple UI gate; server is authoritative

function lastSeenLabel(ms) {
    if (!ms) return 'Never';
    const mins = Math.floor((Date.now() - ms) / 60000);
    if (mins < 2) return 'Just now';
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    return `${Math.floor(hrs / 24)}d ago`;
}

function renderRoster(g) {
    $('#memberCount').textContent = g.members.length;
    $('#myRep').textContent = g.myRep || 0;
    const inactivityMs = (g.inactivityDays || 7) * 86400000;

    const list = $('#memberList');
    list.innerHTML = '';
    g.members.forEach((m) => {
        const wrap = document.createElement('div');
        wrap.className = 'member-wrap';

        const inactive = !m.online && m.lastSeen && (Date.now() - m.lastSeen) > inactivityMs;
        const row = document.createElement('div');
        row.className = 'member member-row' + (inactive ? ' is-inactive' : '');
        row.innerHTML = `
            <span class="online-dot ${m.online ? 'online' : ''}" title="${m.online ? 'Online' : 'Offline'}"></span>
            <span class="member-grade">${m.grade}</span>
            <span class="member-name">${escapeHtml(m.name)}</span>
            <span class="member-rank ${m.isOwner ? 'member-boss' : ''}">${escapeHtml(m.rank)}</span>
            <span class="muted member-lastseen">${m.online ? 'Online' : lastSeenLabel(m.lastSeen)}</span>
            <span class="chevron">▾</span>`;

        const detail = document.createElement('div');
        detail.className = 'member-detail hidden';
        const actions = (!m.isOwner && canManage(g)) ? `
            <button class="icon-btn" data-act="promote" data-cid="${m.citizenid}" data-grade="${m.grade + 1}" title="Promote">▲</button>
            <button class="icon-btn" data-act="demote" data-cid="${m.citizenid}" data-grade="${m.grade - 1}" title="Demote">▼</button>
            <button class="icon-btn danger" data-act="kick" data-cid="${m.citizenid}" title="Remove">✕</button>` : '';
        detail.innerHTML = `
            <span class="muted">Personal rep: <strong>${m.rep || 0}</strong></span>
            <span class="muted">Last seen: <strong>${lastSeenLabel(m.lastSeen)}</strong></span>
            <div class="member-actions">${actions}</div>`;

        row.onclick = () => detail.classList.toggle('hidden');

        wrap.appendChild(row);
        wrap.appendChild(detail);
        list.appendChild(wrap);
    });

    list.querySelectorAll('[data-act]').forEach((btn) => {
        btn.onclick = async (e) => {
            e.stopPropagation();
            const { act, cid, grade } = btn.dataset;
            if (act === 'kick') await call('XS-CriminalTablet:kick', cid);
            else await call('XS-CriminalTablet:setGrade', cid, Number(grade));
            await refresh();
        };
    });

    renderTopContributors(g);
}

function renderTopContributors(g) {
    const list = $('#topContributors');
    if (!list) return;
    list.innerHTML = '';
    const top = [...g.members].sort((a, b) => (b.rep || 0) - (a.rep || 0)).slice(0, 5);
    if (!top.length) { list.innerHTML = '<div class="log-empty">No contributions yet.</div>'; return; }
    top.forEach((m, i) => {
        const row = document.createElement('div');
        row.className = 'member contributor-row';
        row.innerHTML = `
            <span class="contributor-rank">#${i + 1}</span>
            <span class="member-name">${escapeHtml(m.name)}</span>
            <span class="member-rank">${m.rep || 0} rep</span>`;
        list.appendChild(row);
    });
}

// ── player search (shared by every invite box) ──
function attachPlayerSearch(input) {
    const wrap = input.closest('.player-search');
    const results = wrap ? wrap.querySelector('.player-search-results') : null;
    const ps = { picked: null, matches: [] };
    let timer = null;
    let seq = 0;

    const hide = () => { if (results) { results.classList.add('hidden'); results.innerHTML = ''; } };
    const show = (list) => {
        if (!results) return;
        results.innerHTML = '';
        if (!list.length) {
            results.innerHTML = '<div class="player-search-empty">No one online matches</div>';
        } else {
            list.forEach((p) => {
                const row = document.createElement('div');
                row.className = 'player-search-row';
                row.innerHTML = `<span class="player-search-name">${escapeHtml(p.name)}</span><span class="player-search-id">ID ${p.id}</span>`;
                row.onmousedown = (e) => {
                    e.preventDefault();
                    ps.picked = p;
                    input.value = `${p.name} [${p.id}]`;
                    hide();
                };
                results.appendChild(row);
            });
        }
        results.classList.remove('hidden');
    };
    const search = async () => {
        const mine = ++seq;
        const list = await call('XS-CriminalTablet:players:search', input.value.trim());
        if (mine !== seq) return;
        ps.matches = Array.isArray(list) ? list : [];
        if (document.activeElement === input) show(ps.matches);
    };

    input.oninput = () => { ps.picked = null; clearTimeout(timer); timer = setTimeout(search, 180); };
    input.onfocus = () => { if (!ps.picked) search(); };
    input.onblur = () => setTimeout(hide, 120);
    input.onkeydown = (e) => { if (e.key === 'Escape') { hide(); input.blur(); } };

    ps.target = () => {
        if (ps.picked) return ps.picked.id;
        const q = input.value.trim();
        if (/^\d+$/.test(q)) return Number(q);
        if (ps.matches.length === 1) return ps.matches[0].id;
        return null;
    };
    ps.reset = () => { ps.picked = null; ps.matches = []; input.value = ''; hide(); };
    return ps;
}

const invitePS = attachPlayerSearch($('#inviteId'));
$('#inviteBtn').onclick = async () => {
    const id = invitePS.target();
    if (!id) { flash('Pick a player from the list', 'error'); return; }
    const res = await call('XS-CriminalTablet:invite', id);
    invitePS.reset();
    if (res.ok) flash('Invite sent', 'success');
    else flash(res.error || 'Failed', 'error');
};

// ── territory ──
// The real satellite render, shared with the rest of the line. Leaflet is
// vendored because NUI has no reliable internet; the tile pyramid ships in
// assets/maps/tiles.
const TMAP = {
    imageW: 4096, imageH: 6144, tileSize: 512, nativeZoom: 4, maxZoom: 6,
    // Calibrated against landmarks with known coordinates — the depot on
    // Terminal Island, Sandy Shores airfield, Mount Chiliad, Paleto Bay. The
    // old numbers put the trucking depot in the sea.
    world: { minX: -4508, maxX: 5086, minY: -4891, maxY: 8317 },
};

let _tmap = null;
let _tmapZones = null;
let _tmapBounds = null;
let _tmapFitted = false;

// Leaflet measures its container once at construction. The territory tab
// is display:none when the device opens, so the map starts at 0x0 and has
// to be re-measured (and fitted for the first time) once it's visible.
function tmapRefit() {
    if (!_tmap) return;
    const c = _tmap.getContainer();
    if (!c.clientWidth || !c.clientHeight) return;
    _tmap.invalidateSize({ animate: false });
    if (!_tmapFitted) {
        _tmap.fitBounds(_tmapBounds, { animate: false });
        _tmapFitted = true;
    }
}

function tmapLatLng(wx, wy) {
    const W = TMAP.world;
    const px = ((wx - W.minX) / (W.maxX - W.minX)) * TMAP.imageW;
    const py = ((W.maxY - wy) / (W.maxY - W.minY)) * TMAP.imageH;
    return _tmap.unproject([px, py], TMAP.nativeZoom);
}

function ensureTerritoryMap() {
    const el = document.getElementById('territoryMap');
    if (!el || typeof L === 'undefined') return false;
    if (_tmap) return true;

    _tmap = L.map(el, {
        crs: L.CRS.Simple,
        minZoom: 0, maxZoom: TMAP.maxZoom,
        zoomControl: true, attributionControl: false,
        zoomSnap: 0.25, wheelPxPerZoomLevel: 90,
    });

    const sw = _tmap.unproject([0, TMAP.imageH], TMAP.nativeZoom);
    const ne = _tmap.unproject([TMAP.imageW, 0], TMAP.nativeZoom);
    const bounds = new L.LatLngBounds(sw, ne);

    L.tileLayer('assets/maps/tiles/{z}_{x}_{y}.webp', {
        tileSize: TMAP.tileSize, minZoom: 0, maxZoom: TMAP.maxZoom,
        maxNativeZoom: TMAP.nativeZoom, noWrap: true, bounds,
    }).addTo(_tmap);

    _tmapBounds = bounds;
    _tmap.setView(bounds.getCenter(), 1, { animate: false });
    _tmap.setMaxBounds(bounds.pad(0.1));
    _tmapZones = L.layerGroup().addTo(_tmap);

    tmapRefit();
    if (typeof ResizeObserver !== 'undefined') new ResizeObserver(tmapRefit).observe(el);
    return true;
}

function renderTerritory() {
    const grid = $('#turfGrid');
    const terr = state.snapshot.territories || [];
    const myId = state.snapshot.gang ? state.snapshot.gang.id : null;
    grid.innerHTML = '';
    const hasMap = ensureTerritoryMap();
    if (hasMap) _tmapZones.clearLayers();
    $('#territoryDetail').classList.add('hidden');

    terr.forEach((t) => {
        const mine = t.holderId && t.holderId === myId;
        const held = !!t.holderId;
        const cls = mine ? 'mine' : (held ? 'held' : '');
        const status = mine ? 'Controlled' : (held ? 'Rival turf' : 'Unassigned');
        const holderCls = mine ? 'mine' : (held ? 'held' : 'unclaimed');
        const holderTxt = t.holder || 'Unassigned';
        const card = document.createElement('div');
        card.className = 'turf ' + cls;
        card.innerHTML = `
            <span class="turf-status">${status}</span>
            <div>
                <div class="turf-label">${escapeHtml(t.label)}</div>
                <div class="turf-zone">${escapeHtml(t.zone)}</div>
            </div>
            <div class="turf-holder ${holderCls}">${escapeHtml(holderTxt)}</div>`;
        grid.appendChild(card);

        if (hasMap && t.coords) {
            const dotColor = mine ? '#f5a524' : (held ? '#ff5a5f' : '#6b7280');

            // Two circles like before: a soft claim radius and a hard centre.
            // circleMarker keeps its pixel size across zoom, which reads
            // better for territory dots than a world-sized circle would.
            const ring = L.circleMarker(tmapLatLng(t.coords.x, t.coords.y), {
                radius: mine ? 16 : 12,
                color: dotColor, weight: 1.5,
                fillColor: dotColor, fillOpacity: 0.18,
            });
            const core = L.circleMarker(tmapLatLng(t.coords.x, t.coords.y), {
                radius: 4, color: dotColor, weight: 0, fillColor: dotColor, fillOpacity: 1,
            });

            const show = () => {
                const detail = $('#territoryDetail');
                detail.classList.remove('hidden');
                detail.innerHTML = `
                    <span class="member-name">${escapeHtml(t.label)}</span>
                    <span class="member-rank ${holderCls}">${escapeHtml(holderTxt)}</span>`;
            };
            ring.on('click', show);
            core.on('click', show);
            ring.bindTooltip(t.label, { direction: 'top' });

            ring.addTo(_tmapZones);
            core.addTo(_tmapZones);
        }
    });
    if (!terr.length) grid.innerHTML = '<div class="log-empty">No territories configured.</div>';
}

// ── treasury (bank-statement feel) ──
function renderBank(g) {
    $('#bankBalance').textContent = '$' + Number(g.bank).toLocaleString();
    $('#treasuryTier').textContent = g.tier;
    $('#treasuryRep').textContent = `${Number(g.notoriety).toLocaleString()} rep`;
    renderLedger();
}

$('#depositBtn').onclick = () => bankAction('XS-CriminalTablet:bankDeposit');
$('#withdrawBtn').onclick = () => bankAction('XS-CriminalTablet:bankWithdraw');
async function bankAction(name) {
    const amt = Number($('#bankAmount').value);
    if (!amt || amt <= 0) return;
    const res = await call(name, amt);
    $('#bankAmount').value = '';
    if (res.ok) {
        state.snapshot.gang.bank = res.balance;
        renderBank(state.snapshot.gang);
        flash('Done', 'success');
    } else flash(res.error || 'Failed', 'error');
}

async function renderLedger() {
    const rows = await call('XS-CriminalTablet:bankGetLedger');
    const list = $('#bankLedger');
    if (!list) return;
    list.innerHTML = '';
    if (!rows || !rows.length) { list.innerHTML = '<div class="log-empty">No transactions yet.</div>'; return; }
    rows.forEach((r) => {
        const row = document.createElement('div');
        row.className = 'ledger-row ' + (r.kind === 'deposit' ? 'is-deposit' : 'is-withdraw');
        const sign = r.kind === 'deposit' ? '+' : '-';
        row.innerHTML = `
            <span class="ledger-icon">${r.kind === 'deposit' ? '↓' : '↑'}</span>
            <div class="ledger-info">
                <span class="ledger-name">${escapeHtml(r.name)}</span>
                <span class="ledger-time muted">${formatTime(r.created_at)}</span>
            </div>
            <span class="ledger-amount">${sign}$${Number(r.amount).toLocaleString()}</span>`;
        list.appendChild(row);
    });
}

// ── activity ──
function renderLogList(list, logs) {
    list.innerHTML = '';
    if (!logs.length) { list.innerHTML = '<div class="log-empty">No recent activity.</div>'; return; }
    logs.forEach((l) => {
        const item = document.createElement('div');
        item.className = 'log-item';
        item.innerHTML = `<span class="log-time">${formatTime(l.created_at)}</span><span>${escapeHtml(l.message)}</span>`;
        list.appendChild(item);
    });
}
function renderLogs(logs) { renderLogList($('#logList'), logs); }

// ── unlocks (benches/peds/vault placement) ──
async function renderUnlocks() {
    const items = await call('XS-CriminalTablet:placeables:getAvailable');
    const list = $('#unlockList');
    list.innerHTML = '';
    if (!Array.isArray(items) || !items.length) {
        list.innerHTML = '<div class="log-empty">Nothing unlocked yet — raise notoriety.</div>';
        return;
    }
    items.forEach((it) => {
        const row = document.createElement('div');
        row.className = 'member' + (it.locked ? ' is-locked' : '');
        const status = it.locked
            ? `<span class="member-rank locked">Requires ${escapeHtml(it.tierName)} (${Number(it.tierRep).toLocaleString()} rep)</span>`
            : `<span class="member-rank">${it.placed ? 'Placed' : 'Not placed'}</span>`;
        const actions = it.locked ? '' : `
            <button class="btn btn-ghost" data-place-kind="${it.kind}" data-place-id="${it.id}">${it.placed ? 'Move' : 'Place'}</button>
            ${it.placed ? `<button class="icon-btn danger" data-remove-kind="${it.kind}" data-remove-id="${it.id}" title="Remove">✕</button>` : ''}`;
        row.innerHTML = `
            <span class="member-name">${escapeHtml(it.label)}</span>
            ${status}
            <div class="member-actions">${actions}</div>`;
        list.appendChild(row);
    });

    list.querySelectorAll('[data-place-kind]').forEach((btn) => {
        btn.onclick = () => nui('placeObject', { kind: btn.dataset.placeKind, id: btn.dataset.placeId });
    });
    list.querySelectorAll('[data-remove-kind]').forEach((btn) => {
        btn.onclick = async () => {
            const res = await call('XS-CriminalTablet:placeables:remove', btn.dataset.removeKind, btn.dataset.removeId);
            if (res.ok) flash('Removed', 'success'); else flash(res.error || 'Failed', 'error');
            await renderUnlocks();
        };
    });
}

// ── tasks (shared rendering for both the Gang Ops Tasks tab and the
// standalone Boosting app — they just show different subsets) ──
function taskRewardLabel(t) {
    const parts = [];
    if (t.cashReward) parts.push(`+$${t.cashReward}`);
    if (t.reward) parts.push(`+${t.reward} rep`);
    return parts.join(', ') || '—';
}

async function renderTaskList(listEl, cancelBtnEl, typeFilter) {
    const res = await call('XS-CriminalTablet:tasks:getAvailable');
    const allTasks = (res && res.tasks) || [];
    const tasks = allTasks.filter((t) => typeFilter(t.type));
    const activeJob = res && res.active;
    listEl.innerHTML = '';

    const activeMatchesThisList = activeJob && allTasks.some((t) => t.id === activeJob.id && typeFilter(t.type));
    cancelBtnEl.classList.toggle('hidden', !activeMatchesThisList);

    if (activeJob) {
        if (!activeMatchesThisList) {
            listEl.innerHTML = '<div class="log-empty">You\'re busy with a job elsewhere on the tablet.</div>';
            return;
        }
        const row = document.createElement('div');
        row.className = 'member';
        row.innerHTML = `<span class="member-name">On the job — ${escapeHtml(activeJob.stage)}</span>`;
        listEl.appendChild(row);
        return;
    }

    if (!tasks.length) { listEl.innerHTML = '<div class="log-empty">No jobs configured.</div>'; return; }

    tasks.forEach((t) => {
        const onCooldown = t.cooldownMs > 0;
        const row = document.createElement('div');
        row.className = 'member' + (t.locked ? ' is-inactive' : '');
        const mins = Math.ceil(t.cooldownMs / 60000);
        const btnLabel = t.locked ? `Rank ${t.minLevel} required` : (onCooldown ? `Cooldown ${mins}m` : 'Accept');
        row.innerHTML = `
            <span class="member-name">${escapeHtml(t.label)}</span>
            <span class="member-rank">${taskRewardLabel(t)}</span>
            <div class="member-actions">
                <button class="btn btn-ghost" data-task="${t.id}" ${(onCooldown || t.locked) ? 'disabled' : ''}>
                    ${btnLabel}
                </button>
            </div>`;
        listEl.appendChild(row);
    });

    listEl.querySelectorAll('[data-task]').forEach((btn) => {
        btn.onclick = async () => {
            const res = await call('XS-CriminalTablet:tasks:accept', btn.dataset.task);
            if (res.ok) { flash('Job accepted — check your map.', 'success'); nui('close'); }
            else flash(res.error || 'Failed', 'error');
            await renderTaskList(listEl, cancelBtnEl, typeFilter);
        };
    });
}

async function renderTasks() {
    const status = await call('XS-CriminalTablet:tasks:getStatus');
    if (status) {
        $('#taskRankNum').textContent = status.level;
        $('#taskRankTitle').textContent = status.title;
        $('#taskTotalCompleted').textContent = status.totalCompleted;
        const xp = status.xp || 0;
        if (status.xpNeeded == null) {
            $('#taskXpFill').style.width = '100%';
            $('#taskXpLabel').textContent = `${xp.toLocaleString()} XP — max rank`;
        } else {
            const pct = Math.min(100, (xp / status.xpNeeded) * 100);
            $('#taskXpFill').style.width = pct + '%';
            $('#taskXpLabel').textContent = `${xp.toLocaleString()} / ${status.xpNeeded.toLocaleString()} XP to next rank`;
        }
    }
    await renderTaskList($('#taskList'), $('#cancelTaskBtn'), () => true);
    await renderTaskCrew(status);
}
$('#cancelTaskBtn').onclick = async () => {
    await call('XS-CriminalTablet:tasks:cancel');
    await renderTasks();
};

// ── task co-op crew ──
async function renderTaskCrew(status) {
    const crew = await call('XS-CriminalTablet:tasks:getCrewStatus');
    const list = $('#taskCrewList');
    const cancelBtn = $('#taskCancelCrewBtn');
    const inviteBtn = $('#taskInviteBtn');
    const picker = $('#taskCoopPicker');
    list.innerHTML = '';
    picker.innerHTML = '';
    picker.classList.add('hidden');

    const busy = !!(status && status.active);

    if (!crew || !crew.size) {
        list.innerHTML = '<div class="log-empty">No crew yet — invite someone to start a co-op job.</div>';
        cancelBtn.classList.add('hidden');
        inviteBtn.disabled = busy;
        return;
    }

    Object.values(crew.members || {}).forEach((name) => {
        const row = document.createElement('div');
        row.className = 'member';
        row.innerHTML = `<span class="member-name">${escapeHtml(name)}</span>`;
        list.appendChild(row);
    });

    if (crew.isLeader) {
        cancelBtn.classList.remove('hidden');
        inviteBtn.disabled = crew.size >= crew.maxSize || busy;
        if (crew.size >= 2 && !busy) {
            const coopTasks = (await call('XS-CriminalTablet:tasks:getCoopTasks')) || [];
            picker.classList.remove('hidden');
            picker.innerHTML = '<div class="log-empty" style="text-align:left;padding:4px 0;">Pick a job to run together:</div>';
            coopTasks.forEach((t) => {
                const row = document.createElement('div');
                row.className = 'member';
                row.innerHTML = `
                    <span class="member-name">${escapeHtml(t.label)}${t.coopOnly ? ' <span class="wanted-flag">CO-OP ONLY</span>' : ''}</span>
                    <span class="member-rank">${taskRewardLabel(t)}</span>
                    <div class="member-actions"><button class="btn btn-accent" data-coop-task="${t.id}">Start</button></div>`;
                picker.appendChild(row);
            });
            picker.querySelectorAll('[data-coop-task]').forEach((btn) => {
                btn.onclick = async () => {
                    const res = await call('XS-CriminalTablet:tasks:acceptCoop', btn.dataset.coopTask);
                    if (res.ok) { flash('Crew job started — check your map.', 'success'); nui('close'); }
                    else flash(res.error || 'Failed', 'error');
                    await renderTasks();
                };
            });
        }
    } else {
        cancelBtn.classList.add('hidden');
        inviteBtn.disabled = true;
    }
}

const taskInvitePS = attachPlayerSearch($('#taskInviteId'));
$('#taskInviteBtn').onclick = async () => {
    const id = taskInvitePS.target();
    if (!id) { flash('Pick a player from the list', 'error'); return; }
    const res = await call('XS-CriminalTablet:tasks:inviteCoop', id);
    taskInvitePS.reset();
    if (res.ok) flash('Invite sent', 'success');
    else flash(res.error || 'Failed', 'error');
    await renderTasks();
};
$('#taskCancelCrewBtn').onclick = async () => {
    await call('XS-CriminalTablet:tasks:cancelCrew');
    await renderTasks();
};

// ── task badges + leaderboard ──
async function renderTaskBadges() {
    const list = $('#taskBadgeList');
    const achievements = (await call('XS-CriminalTablet:tasks:getAchievements')) || [];
    list.innerHTML = '';
    if (!achievements.length) { list.innerHTML = '<div class="log-empty">No badges configured.</div>'; return; }
    achievements.forEach((a) => {
        const row = document.createElement('div');
        row.className = 'member' + (a.earned ? '' : ' is-locked');
        row.innerHTML = `
            <span class="member-name">${a.earned ? '🏅' : '🔒'} ${escapeHtml(a.label)}</span>
            <span class="member-rank">${escapeHtml(a.description)}</span>`;
        list.appendChild(row);
    });
}

async function renderTaskLeaderboard() {
    const list = $('#taskLeaderboard');
    const rows = (await call('XS-CriminalTablet:tasks:getLeaderboard')) || [];
    list.innerHTML = '';
    if (!rows.length) { list.innerHTML = '<div class="log-empty">No completed jobs yet.</div>'; return; }
    rows.forEach((r, i) => {
        const row = document.createElement('div');
        row.className = 'member contributor-row';
        row.innerHTML = `
            <span class="contributor-rank">#${i + 1}</span>
            <span class="member-name">${escapeHtml(r.name)}</span>
            <span class="member-rank">Lv.${r.level} — ${r.total_completed} jobs, ${r.badges} badges</span>`;
        list.appendChild(row);
    });
}

// ── Car boosting (fully standalone — no gang tie-in) ──
async function renderBoosting() {
    const status = await call('XS-CriminalTablet:boosting:getStatus');
    if (!status) return;

    $('#boostLevelNum').textContent = status.level;
    $('#boostLevelLabel').textContent = status.label;
    $('#boostTotalCount').textContent = status.totalBoosted;
    $('#boostTotalCash').textContent = '$' + Number(status.totalCash).toLocaleString();

    if (status.xpNeeded == null) {
        $('#boostXpFill').style.width = '100%';
        $('#boostXpLabel').textContent = `${status.xp.toLocaleString()} XP — max level`;
    } else {
        const pct = Math.min(100, (status.xp / status.xpNeeded) * 100);
        $('#boostXpFill').style.width = pct + '%';
        $('#boostXpLabel').textContent = `${status.xp.toLocaleString()} / ${status.xpNeeded.toLocaleString()} XP to next level`;
    }

    const btn = $('#boostActionBtn');
    const cancelBtn = $('#cancelBoostBtn');
    const activeEl = $('#boostActiveStatus');

    if (status.active) {
        const job = status.active;
        const coopTag = job.coop ? ' [CO-OP]' : '';
        if (job.stage === 'theft' && job.vehicleDef) {
            activeEl.innerHTML = `BOLO${coopTag} — <strong>${escapeHtml(job.vehicleDef.label || job.vehicleDef.model)}</strong>, plate <strong>${escapeHtml(job.plate || '?')}</strong>. Search the marked zone.`;
        } else {
            activeEl.textContent = `On the job${coopTag} — ${job.stage}`;
        }
        activeEl.classList.remove('hidden');
        btn.classList.add('hidden');
        cancelBtn.classList.remove('hidden');
    } else {
        activeEl.classList.add('hidden');
        cancelBtn.classList.add('hidden');
        btn.classList.remove('hidden');
        if (status.cooldownMs > 0) {
            const mins = Math.ceil(status.cooldownMs / 60000);
            btn.textContent = `Cooldown ${mins}m`;
            btn.disabled = true;
        } else {
            btn.textContent = 'Start Job';
            btn.disabled = false;
        }
    }

    await renderBoostLeaderboard();
    await renderBoostVehiclePreview();
    await renderBoostActivity();
    await renderBoostWanted(status);
    await renderBoostBadges();
    await renderBoostPerks();
    await renderBoostCrew(status);
}

async function renderBoostCrew(status) {
    const crew = await call('XS-CriminalTablet:boosting:getCrewStatus');
    const list = $('#boostCrewList');
    const startBtn = $('#boostStartCoopBtn');
    const cancelBtn = $('#boostCancelCrewBtn');
    const inviteBtn = $('#boostInviteBtn');
    list.innerHTML = '';

    if (!crew || !crew.size) {
        list.innerHTML = '<div class="log-empty">No crew yet — invite someone to start a co-op job.</div>';
        startBtn.classList.add('hidden');
        cancelBtn.classList.add('hidden');
        inviteBtn.disabled = !!status.active;
        return;
    }

    Object.values(crew.members || {}).forEach((name) => {
        const row = document.createElement('div');
        row.className = 'member';
        row.innerHTML = `<span class="member-name">${escapeHtml(name)}</span>`;
        list.appendChild(row);
    });

    if (crew.isLeader) {
        startBtn.classList.toggle('hidden', crew.size < 2 || !!status.active);
        cancelBtn.classList.remove('hidden');
        inviteBtn.disabled = crew.size >= crew.maxSize || !!status.active;
    } else {
        startBtn.classList.add('hidden');
        cancelBtn.classList.add('hidden');
        inviteBtn.disabled = true;
    }
}

const boostInvitePS = attachPlayerSearch($('#boostInviteId'));
$('#boostInviteBtn').onclick = async () => {
    const id = boostInvitePS.target();
    if (!id) { flash('Pick a player from the list', 'error'); return; }
    const res = await call('XS-CriminalTablet:boosting:inviteCoop', id);
    boostInvitePS.reset();
    if (res.ok) flash('Invite sent', 'success');
    else flash(res.error || 'Failed', 'error');
    await renderBoosting();
};
$('#boostCancelCrewBtn').onclick = async () => {
    await call('XS-CriminalTablet:boosting:cancelCrew');
    await renderBoosting();
};
$('#boostStartCoopBtn').onclick = async () => {
    const res = await call('XS-CriminalTablet:boosting:acceptCoop');
    if (res.ok) { flash('Co-op job started — check your map.', 'success'); nui('close'); }
    else flash(res.error || 'Failed', 'error');
    await renderBoosting();
};

async function renderBoostPerks() {
    const res = await call('XS-CriminalTablet:boosting:getPerks');
    const perks = (res && res.perks) || [];
    $('#boostPerkPoints').textContent = (res && res.perkPoints) || 0;
    const list = $('#boostPerkList');
    list.innerHTML = '';
    if (!perks.length) { list.innerHTML = '<div class="log-empty">No perks configured.</div>'; return; }

    perks.forEach((p) => {
        const row = document.createElement('div');
        row.className = 'member' + (p.owned ? '' : !p.affordable ? ' is-locked' : '');
        const action = p.owned
            ? '<span class="member-rank">Owned</span>'
            : `<button class="btn btn-ghost" data-perk="${p.id}" ${p.affordable ? '' : 'disabled'}>Buy (${p.cost})</button>`;
        row.innerHTML = `
            <span class="member-name">${escapeHtml(p.label)}</span>
            <span class="member-rank">${escapeHtml(p.description)}</span>
            <div class="member-actions">${action}</div>`;
        list.appendChild(row);
    });

    list.querySelectorAll('[data-perk]').forEach((btn) => {
        btn.onclick = async () => {
            const res2 = await call('XS-CriminalTablet:boosting:buyPerk', btn.dataset.perk);
            if (res2.ok) flash('Perk bought', 'success');
            else flash(res2.error || 'Failed', 'error');
            await renderBoostPerks();
        };
    });
}

async function renderBoostWanted(status) {
    const wanted = await call('XS-CriminalTablet:boosting:getWanted');
    const section = $('#boostWantedSection');
    const list = $('#boostWantedList');
    list.innerHTML = '';

    if (!wanted || !wanted.length) { section.classList.add('hidden'); return; }
    section.classList.remove('hidden');

    const blocked = !!status.active || status.cooldownMs > 0;
    wanted.forEach((w) => {
        const row = document.createElement('div');
        row.className = 'member is-wanted';
        row.innerHTML = `
            <span class="member-name">${escapeHtml(w.label)}</span>
            <span class="member-rank">+$${Number(w.cash).toLocaleString()}, +${w.xp} XP</span>
            <div class="member-actions">
                <button class="btn btn-accent" data-wanted="${w.id}" ${blocked ? 'disabled' : ''}>Steal</button>
            </div>`;
        list.appendChild(row);
    });

    list.querySelectorAll('[data-wanted]').forEach((btn) => {
        btn.onclick = async () => {
            const res = await call('XS-CriminalTablet:boosting:accept', btn.dataset.wanted);
            if (res.ok) { flash('Job started — check your map.', 'success'); nui('close'); }
            else flash(res.error || 'Failed', 'error');
            await renderBoosting();
        };
    });
}

async function renderBoostBadges() {
    const badges = await call('XS-CriminalTablet:boosting:getAchievements');
    const list = $('#boostBadgeList');
    list.innerHTML = '';
    if (!badges || !badges.length) { list.innerHTML = '<div class="log-empty">No badges configured.</div>'; return; }
    badges.forEach((b) => {
        const row = document.createElement('div');
        row.className = 'member' + (b.earned ? '' : ' is-locked');
        row.innerHTML = `
            <span class="member-name">${b.earned ? '🏆' : '🔒'} ${escapeHtml(b.label)}</span>
            <span class="member-rank">${escapeHtml(b.description)}</span>`;
        list.appendChild(row);
    });
}

async function renderBoostVehiclePreview() {
    const vehicles = await call('XS-CriminalTablet:boosting:getAvailableVehicles');
    const list = $('#boostVehiclePreview');
    list.innerHTML = '';
    if (!vehicles || !vehicles.length) { list.innerHTML = '<div class="log-empty">Nothing unlocked yet.</div>'; return; }
    vehicles.forEach((v) => {
        const row = document.createElement('div');
        row.className = 'member';
        row.innerHTML = `
            <span class="member-name">${escapeHtml(v.label)}</span>
            <span class="member-rank">+$${Number(v.cash).toLocaleString()}, +${v.xp} XP</span>`;
        list.appendChild(row);
    });
}

async function renderBoostActivity() {
    const rows = await call('XS-CriminalTablet:boosting:getRecentActivity');
    const list = $('#boostActivityFeed');
    list.innerHTML = '';
    if (!rows || !rows.length) { list.innerHTML = '<div class="log-empty">No sells yet.</div>'; return; }
    rows.forEach((r) => {
        const item = document.createElement('div');
        item.className = 'log-item';
        item.innerHTML = `<span class="log-time">${formatTime(r.created_at)}</span><span>${escapeHtml(r.name)} sold a ${escapeHtml(r.vehicle_label)} for $${Number(r.cash).toLocaleString()}</span>`;
        list.appendChild(item);
    });
}

$('#boostActionBtn').onclick = async () => {
    const res = await call('XS-CriminalTablet:boosting:accept');
    if (res.ok) { flash('Job started — check your map.', 'success'); nui('close'); }
    else flash(res.error || 'Failed', 'error');
    await renderBoosting();
};
$('#cancelBoostBtn').onclick = async () => {
    await call('XS-CriminalTablet:boosting:cancel');
    await renderBoosting();
};

async function renderBoostLeaderboard() {
    const rows = await call('XS-CriminalTablet:boosting:getLeaderboard');
    const list = $('#boostLeaderboard');
    list.innerHTML = '';
    if (!rows || !rows.length) { list.innerHTML = '<div class="log-empty">No one\'s boosted anything yet.</div>'; return; }
    rows.forEach((r, i) => {
        const row = document.createElement('div');
        row.className = 'member';
        row.innerHTML = `
            <span class="member-grade">#${i + 1}</span>
            <span class="member-name">${escapeHtml(r.name)}</span>
            <span class="member-rank">Lvl ${r.level}</span>
            <span class="member-rank">${r.total_boosted} boosted</span>
            <span class="member-rank" title="Badges earned">🏆 ${r.badges || 0}</span>`;
        list.appendChild(row);
    });
}

// ── dealer ──
async function renderDealer() {
    const status = await call('XS-CriminalTablet:dealer:getStatus');
    const btn = $('#callDealerBtn');
    if (status && status.cooldownMs > 0) {
        const hrs = (status.cooldownMs / 3600000).toFixed(1);
        $('#dealerStatus').textContent = `On cooldown — ${hrs}h`;
        btn.disabled = true;
    } else {
        $('#dealerStatus').textContent = 'Available';
        btn.disabled = false;
    }
}
$('#callDealerBtn').onclick = async () => {
    const res = await call('XS-CriminalTablet:dealer:contact');
    if (res.ok) { flash('Dealer is en route — check your map.', 'success'); nui('close'); }
    else flash(res.error || 'Failed', 'error');
    await renderDealer();
};

// ── gang perks: a real branching tree, not a flat list ──
async function renderGangPerks() {
    const res = await call('XS-CriminalTablet:gangperks:getTree');
    const branches = (res && res.branches) || [];
    const points = (res && res.perkPoints) || 0;
    $('#gangPerkPoints').textContent = points;

    const wrap = $('#perkTree');
    if (!wrap) return;
    wrap.innerHTML = '';
    if (!branches.length) { wrap.innerHTML = '<div class="log-empty">No perks configured.</div>'; return; }

    branches.forEach((b) => {
        const col = document.createElement('div');
        col.className = 'perk-branch';
        col.innerHTML = `<div class="perk-branch-title">${escapeHtml(b.label)}</div>`;

        const chain = document.createElement('div');
        chain.className = 'perk-chain';

        b.tiers.forEach((t, i) => {
            if (i > 0) {
                const line = document.createElement('div');
                line.className = 'perk-line' + (t.owned || (b.tiers[i - 1].owned) ? ' is-active' : '');
                chain.appendChild(line);
            }

            const node = document.createElement('div');
            const stateCls = t.owned ? 'is-owned' : (t.locked ? 'is-locked' : (t.affordable ? 'is-affordable' : 'is-unaffordable'));
            node.className = 'perk-node ' + stateCls;
            node.innerHTML = `
                <div class="perk-node-icon">${t.owned ? '✓' : (t.locked ? '🔒' : t.tier)}</div>
                <div class="perk-node-body">
                    <div class="perk-node-label">${escapeHtml(t.label)}</div>
                    <div class="perk-node-desc">${escapeHtml(t.description)}</div>
                    ${t.owned ? '' : `<button class="perk-buy-btn" data-buy-perk="${t.id}" ${(t.locked || !t.affordable) ? 'disabled' : ''}>${t.cost} pt${t.cost > 1 ? 's' : ''}</button>`}
                </div>`;
            chain.appendChild(node);
        });

        col.appendChild(chain);
        wrap.appendChild(col);
    });

    wrap.querySelectorAll('[data-buy-perk]').forEach((btn) => {
        btn.onclick = async () => {
            const res = await call('XS-CriminalTablet:gangperks:buyPerk', btn.dataset.buyPerk);
            if (res.ok) flash('Perk purchased', 'success'); else flash(res.error || 'Failed', 'error');
            await renderGangPerks();
        };
    });
}

// ── tabs ── (scoped to the enclosing .view so two apps' tabs never collide)
el('.tab').forEach((tab) => {
    tab.onclick = () => {
        const scope = tab.closest('.view, .admin-surface') || document;
        scope.querySelectorAll('.tab').forEach((t) => t.classList.remove('is-active'));
        scope.querySelectorAll('.tabview').forEach((v) => v.classList.remove('is-active'));
        scope.querySelectorAll('.tab-more').forEach((m) => { m.classList.remove('has-active', 'is-open'); m.querySelector('.tab-more-menu').classList.add('hidden'); });
        tab.classList.add('is-active');
        const targetView = scope.querySelector(`[data-tabview="${tab.dataset.tab}"]`);
        targetView.classList.add('is-active');
        playGlitch(targetView);
        if (targetView.querySelector('#territoryMap')) tmapRefit();
        const moreParent = tab.closest('.tab-more');
        if (moreParent) moreParent.classList.add('has-active');
    };
});

// ── "More" tab dropdowns ──
el('.tab-more-btn').forEach((btn) => {
    btn.onclick = (e) => {
        e.stopPropagation();
        const wrap = btn.closest('.tab-more');
        const isOpen = wrap.classList.contains('is-open');
        document.querySelectorAll('.tab-more').forEach((m) => { m.classList.remove('is-open'); m.querySelector('.tab-more-menu').classList.add('hidden'); });
        if (!isOpen) {
            wrap.classList.add('is-open');
            wrap.querySelector('.tab-more-menu').classList.remove('hidden');
        }
    };
});
document.addEventListener('click', () => {
    document.querySelectorAll('.tab-more.is-open').forEach((m) => { m.classList.remove('is-open'); m.querySelector('.tab-more-menu').classList.add('hidden'); });
});

// ── helpers ──
async function refresh() {
    const snap = await call('XS-CriminalTablet:getSnapshot');
    // getSnapshot returns the snapshot object directly (not wrapped)
    state.snapshot = snap.gang !== undefined ? snap : state.snapshot;
    render();
}
function flash(msg, type = 'info') {
    const stack = $('#toastStack');
    if (!stack) return;
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.textContent = msg;
    stack.appendChild(toast);
    setTimeout(() => toast.classList.add('toast-out'), 2600);
    setTimeout(() => toast.remove(), 3000);
}
function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function formatTime(ts) {
    if (!ts) return '';
    const d = new Date(ts.replace ? ts.replace(' ', 'T') : ts);
    if (isNaN(d)) return '';
    return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

// ── Blackmarket ──
let blackmarketLoaded = false;
let dmActiveHandle = null;

async function renderBlackmarket() {
    if (!blackmarketLoaded) {
        blackmarketLoaded = true;
        const handle = await call('XS-CriminalTablet:chat:getMyHandle');
        $('#myHandle').textContent = handle || '—';
    }
    await renderWorldFeed();
    await renderDMThreads();
}

$('#editHandleBtn').onclick = () => {
    $('#handleInput').value = $('#myHandle').textContent;
    $('#handleEditRow').classList.remove('hidden');
};
$('#cancelHandleBtn').onclick = () => $('#handleEditRow').classList.add('hidden');
$('#saveHandleBtn').onclick = async () => {
    const desired = $('#handleInput').value.trim();
    if (!desired) return;
    const res = await call('XS-CriminalTablet:chat:setHandle', desired);
    if (res.ok) {
        $('#myHandle').textContent = res.handle;
        $('#handleEditRow').classList.add('hidden');
        flash('Handle updated', 'success');
    } else {
        flash(res.error || 'Failed to update handle', 'error');
    }
};
$('#handleInput').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('#saveHandleBtn').click(); });

function appendChatBubble(container, handle, message, mine) {
    const row = document.createElement('div');
    row.className = 'chat-bubble' + (mine ? ' mine' : '');
    row.innerHTML = `<span class="chat-handle">${escapeHtml(handle)}</span><span class="chat-text">${escapeHtml(message)}</span>`;
    container.appendChild(row);
    container.scrollTop = container.scrollHeight;
}

async function renderWorldFeed() {
    const history = await call('XS-CriminalTablet:chat:getWorldHistory');
    const feed = $('#worldFeed');
    feed.innerHTML = '';
    const myHandle = $('#myHandle').textContent;
    (history || []).forEach((m) => appendChatBubble(feed, m.handle, m.message, m.handle === myHandle));
    if (!history || !history.length) feed.innerHTML = '<div class="log-empty">No chatter yet.</div>';
}

function onWorldMessage(m) {
    if (state.activeApp !== 'blackmarket') return;
    const myHandle = $('#myHandle').textContent;
    appendChatBubble($('#worldFeed'), m.handle, m.message, m.handle === myHandle);
}

$('#worldSendBtn').onclick = async () => {
    const input = $('#worldInput');
    const msg = input.value.trim();
    if (!msg) return;
    input.value = '';
    const res = await call('XS-CriminalTablet:chat:postWorld', msg);
    if (!res.ok) flash(res.error || 'Failed to post', 'error');
};
$('#worldInput').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('#worldSendBtn').click(); });

async function renderDMThreads() {
    const threads = await call('XS-CriminalTablet:chat:getThreads');
    const list = $('#dmThreadList');
    list.innerHTML = '';
    if (!threads || !threads.length) {
        list.innerHTML = '<div class="log-empty">No conversations yet.</div>';
    } else {
        threads.forEach((t) => {
            const row = document.createElement('div');
            row.className = 'member';
            row.innerHTML = `
                <span class="member-name">${escapeHtml(t.handle)}${t.unread ? ' <span class="unread-dot"></span>' : ''}</span>
                <span class="member-rank">${escapeHtml((t.lastMessage || '').slice(0, 40))}</span>`;
            row.onclick = () => openDMThread(t.handle);
            list.appendChild(row);
        });
    }
    $('#dmConversation').classList.add('hidden');
    list.classList.remove('hidden');
}

async function openDMThread(handle) {
    dmActiveHandle = handle;
    $('#dmThreadList').classList.add('hidden');
    $('#dmConversation').classList.remove('hidden');
    const feed = $('#dmFeed');
    feed.innerHTML = '';
    const myHandle = $('#myHandle').textContent;
    const messages = await call('XS-CriminalTablet:chat:getThread', handle);
    (messages || []).forEach((m) => appendChatBubble(feed, m.from_handle, m.message, m.from_handle === myHandle));
    if (!messages || !messages.length) feed.innerHTML = '<div class="log-empty">No messages yet — say hi.</div>';
}

$('#dmBackBtn').onclick = () => { dmActiveHandle = null; renderDMThreads(); };

$('#dmSendBtn').onclick = async () => {
    if (!dmActiveHandle) return;
    const input = $('#dmInput');
    const msg = input.value.trim();
    if (!msg) return;
    input.value = '';
    const res = await call('XS-CriminalTablet:chat:sendDM', dmActiveHandle, msg);
    if (res.ok) {
        const myHandle = $('#myHandle').textContent;
        appendChatBubble($('#dmFeed'), myHandle, msg, true);
    } else {
        flash(res.error || 'Failed to send', 'error');
    }
};
$('#dmInput').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('#dmSendBtn').click(); });

$('#dmNewBtn').onclick = () => {
    const handle = $('#dmNewHandle').value.trim();
    if (!handle) return;
    $('#dmNewHandle').value = '';
    openDMThread(handle);
};

function onDMReceived(m) {
    if (state.activeApp === 'blackmarket' && dmActiveHandle === m.handle) {
        appendChatBubble($('#dmFeed'), m.handle, m.message, false);
    } else {
        flash(`New message from ${m.handle}`, 'info');
    }
    if (state.activeApp === 'blackmarket' && !dmActiveHandle) renderDMThreads();
}

// dev preview outside FiveM
if (!window.invokeNative) {
    // no-op: in browser you can call openUI(mockSnapshot) to preview
}
