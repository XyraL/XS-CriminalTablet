// ─────────────────────────────────────────────────────────────
// XS-CriminalTablet NUI controller. Talks to client/device.lua via fetch
// callbacks. All gang logic lives server-side; this renders + relays.
// ─────────────────────────────────────────────────────────────
const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'XS-CriminalTablet';
const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));

let state = {
    snapshot: null,
    gang: null,
    apps: [],
    activeApp: null,
    territories: [],
    capture: {},
    war: null,
    stash: null,
    testMode: null,
    turfFilter: 'all',
    contractFilter: 'all',
    logFilter: 'all',
};

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

const call = (name, ...args) => nui('call', { name, args });

// ── helpers ──
function escapeHtml(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) =>
        ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
const money = (n) => '$' + Number(n || 0).toLocaleString();
const num = (n) => Number(n || 0).toLocaleString();

function formatTime(ts) {
    if (!ts) return '';
    const d = new Date(typeof ts === 'number' ? ts : ts.replace(' ', 'T') + 'Z');
    if (isNaN(d)) return '';
    return d.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function relative(ms) {
    if (!ms) return 'never';
    const diff = Date.now() - ms;
    if (diff < 60000) return 'just now';
    const mins = Math.floor(diff / 60000);
    if (mins < 60) return `${mins}m ago`;
    const hours = Math.floor(mins / 60);
    if (hours < 24) return `${hours}h ago`;
    return `${Math.floor(hours / 24)}d ago`;
}

function countdown(target) {
    const secs = Math.max(0, Math.floor((target - Date.now()) / 1000));
    const m = Math.floor(secs / 60);
    const s = secs % 60;
    return `${m}:${String(s).padStart(2, '0')}`;
}

function initials(label) {
    return String(label || '?').trim().split(/\s+/).slice(0, 2).map((w) => w[0]).join('').toUpperCase() || '?';
}

// One stat card shape, used by the hub overview, the war room and the
// admin dashboard. `bar` is a 0-100 fill for stats that are really a ratio.
function statCard(s, i = 0) {
    return `<div class="stat rise" style="--i:${i}">
        <div class="stat-head">
            ${s.icon ? `<span class="stat-icon"><i class="fas ${escapeHtml(s.icon)}"></i></span>` : ''}
            <span class="stat-label">${escapeHtml(s.label)}</span>
        </div>
        <span class="stat-value">${escapeHtml(String(s.value))}</span>
        ${s.bar !== undefined ? `<div class="stat-bar"><span style="width:${Math.max(0, Math.min(100, s.bar))}%"></span></div>` : ''}
        ${s.sub ? `<span class="stat-sub">${escapeHtml(s.sub)}</span>` : ''}
    </div>`;
}

function statGrid(stats) {
    return stats.map((s, i) => statCard(s, i)).join('');
}

function flash(msg, type = 'info') {
    const stack = $('#toastStack');
    if (!stack) return;
    const el = document.createElement('div');
    el.className = `toast ${type}`;
    el.textContent = msg;
    stack.appendChild(el);
    setTimeout(() => el.remove(), 4200);
}

// A failed server call always says WHY — the server sends a plain-English
// reason, and swallowing it is how you get "nothing happened" bug reports.
function report(res, okMsg) {
    if (res && res.ok) {
        if (okMsg) flash(okMsg, 'success');
        return true;
    }
    flash((res && res.error) || 'That did not work', 'error');
    return false;
}

const can = (perm) => !!(state.gang && state.gang.perms && state.gang.perms[perm]);

// ── theme ──
// The whole device re-themes to the gang's own colour.
function applyTheme(hex) {
    if (!hex || !/^#[0-9a-f]{6}$/i.test(hex)) hex = '#3d7dff';
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    const root = document.documentElement;
    root.style.setProperty('--accent', hex);
    root.style.setProperty('--accent-soft', `rgba(${r}, ${g}, ${b}, .14)`);
    root.style.setProperty('--accent-line', `rgba(${r}, ${g}, ${b}, .34)`);
    // Dark text on a light accent, light text on a dark one.
    const luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    root.style.setProperty('--accent-ink', luma > 0.6 ? '#04060c' : '#ffffff');
}

// ── window protocol ──
window.addEventListener('message', (ev) => {
    const { action, data } = ev.data || {};
    if (action === 'open') openUI(data, ev.data.app);
    else if (action === 'close') closeUI();
    else if (action === 'openAdmin' && window.openAdminUI) window.openAdminUI();
    else if (action === 'invite') showInvite(data);
    else if (action === 'refresh') refreshAll();
    else if (action === 'sync') onSync(ev.data.event, data);
    else if (action === 'capture') { state.capture = data || {}; if (state.activeApp === 'turf') renderTurf(); }
    else if (action === 'testMode') { state.testMode = data; renderTestChip(); }
    else if (action === 'chatWorldMessage') onWorldMessage(data);
    else if (action === 'chatDM') onDMReceived(data);
    else if (action === 'radialOpen') openRadial(data);
    else if (action === 'radialClose') closeRadial();
});

document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    if (!$('#radialRoot').classList.contains('hidden')) { nui('radial:close'); return; }
    if (!$('#adminRoot').classList.contains('hidden')) nui('admin:close');
    else nui('escape');
});

// Live pushes from the server. Each one re-renders only what changed, so
// a turf flip mid-conversation doesn't wipe a half-typed message.
function onSync(event, data) {
    switch (event) {
        case 'roster':
        case 'ranks':
        case 'gang':
        case 'rep':
            refreshAll();
            break;
        case 'treasury':
        case 'upgrades':
        case 'perks':
            if (state.activeApp === 'treasury') renderTreasury();
            refreshSnapshotQuiet();
            break;
        case 'turf':
            refreshTerritories();
            break;
        case 'war':
            state.war = data;
            renderWarChip();
            if (state.activeApp === 'war') renderWar();
            break;
        case 'stash':
            state.stash = data;
            if (state.activeApp === 'war') renderWar();
            break;
        case 'garage':
            if (state.activeApp === 'garage') renderGarage();
            break;
        case 'graffiti':
            if (state.activeApp === 'graffiti') renderGraffiti();
            break;
        case 'placements':
            if (state.activeApp === 'hub') renderUnlocks();
            break;
        case 'motd':
            if (state.gang) state.gang.motd = data && data.motd;
            renderMotd();
            break;
        case 'contracts':
            if (state.activeApp === 'contracts') renderContracts();
            break;
        case 'log':
            refreshSnapshotQuiet();
            break;
    }
}

// ── boot ──
const BOOT_LINES = [
    'ESTABLISHING SECURE LINK...',
    'DECRYPTING HANDSHAKE...',
    'LOADING CREW MODULES <span class="ok">[OK]</span>',
    'ACCESS GRANTED',
];

function playBootSequence(onDone) {
    const screen = $('#bootScreen');
    const linesEl = $('#bootLines');
    if (!screen || !linesEl) { onDone && onDone(); return; }
    linesEl.innerHTML = '';
    screen.classList.remove('is-hidden');

    let i = 0;
    (function next() {
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
        setTimeout(next, 200);
    })();
}

// ── open / close ──
function openUI(snapshot, wantApp) {
    applySnapshot(snapshot);
    $('#root').classList.remove('hidden');
    tickClock();
    playBootSequence();

    if (!state.gang) {
        $('#appRail').innerHTML = '';
        showView('viewLocked');
        $('#lockedMessage').textContent = snapshot.noGangMessage || 'Gangs are formed by staff.';
        return;
    }

    renderApps(state.apps);
    const target = wantApp && state.apps.some((a) => a.id === wantApp)
        ? wantApp
        : (state.activeApp && state.apps.some((a) => a.id === state.activeApp) ? state.activeApp : state.apps[0] && state.apps[0].id);
    switchApp(target);
}

function closeUI() {
    $('#root').classList.add('hidden');
    $('#adminRoot').classList.add('hidden');
    hideInvite();
    closeRadial();
}

function applySnapshot(snapshot) {
    state.snapshot = snapshot || {};
    state.gang = state.snapshot.gang || null;
    state.apps = state.snapshot.apps || [];
    state.territories = state.snapshot.territories || [];
    state.capture = state.snapshot.capture || {};
    state.war = state.snapshot.war || null;
    state.stash = state.snapshot.stash || null;
    state.testMode = state.snapshot.testMode || null;

    applyTheme(state.gang && state.gang.color);
    renderStatusbar();
    renderWarChip();
    renderTestChip();
    updateRailBadges();
}

async function refreshAll() {
    const snapshot = await call('XS-CriminalTablet:getSnapshot');
    if (!snapshot) return;
    applySnapshot(snapshot);
    if (!state.gang) { $('#appRail').innerHTML = ''; showView('viewLocked'); return; }
    renderApps(state.apps);
    renderActiveApp();
}

// Same, but never repaints the current view — for background nudges.
async function refreshSnapshotQuiet() {
    const snapshot = await call('XS-CriminalTablet:getSnapshot');
    if (!snapshot || !snapshot.gang) return;
    state.snapshot = snapshot;
    state.gang = snapshot.gang;
    renderStatusbar();
}

$('#powerBtn').onclick = () => nui('close');

// ── clock ──
let clockTimer = null;
function tickClock() {
    const update = () => {
        const d = new Date();
        const t = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
        const c = $('#clock'); if (c) c.textContent = t;
        const ac = $('#adminClock'); if (ac) ac.textContent = t;
    };
    update();
    if (!clockTimer) clockTimer = setInterval(update, 15000);
}

// ── statusbar ──
function renderStatusbar() {
    const g = state.gang;
    $('#gangName').textContent = g ? g.label : 'No affiliation';
    $('#gangTier').textContent = g ? g.tier : '—';
    $('#gangLevelChip').textContent = g ? `LV ${g.gangLevel}` : 'LV —';
    $('#railCrest').textContent = g ? initials(g.label) : '—';
    $('#railGang').textContent = g ? g.label : 'No crew';
    $('#railRank').textContent = g ? g.myRank : '—';
    $('#gangTier').classList.toggle('hidden', !g);
    $('#gangLevelChip').classList.toggle('hidden', !g);
}

function renderWarChip() {
    const chip = $('#warChip');
    if (!state.war) { chip.classList.add('hidden'); return; }
    chip.classList.remove('hidden');
    $('#warChipText').textContent = state.war.kind === 'raid'
        ? (state.war.phase === 'prep' ? 'RAID INCOMING' : 'RAID LIVE')
        : 'AT WAR';
}

function renderTestChip() {
    const tm = state.testMode;
    const live = tm && ((tm.zones && tm.zones.length) || (tm.wars && tm.wars.length));
    $('#testModeChip').classList.toggle('hidden', !live);
}

// ── app rail ──
// Grouped by what each app is FOR, with a live badge on the ones that have
// something waiting. Ten flat rows is a wall; four short sections isn't.
function railBadge(appId) {
    const g = state.gang;
    if (!g) return null;
    switch (appId) {
        case 'war':
            if (!state.war) return null;
            return { text: state.war.phase === 'prep' ? 'PREP' : 'LIVE', kind: 'hot' };
        case 'roster':
            return g.onlineCount ? { text: String(g.onlineCount), kind: 'dim' } : null;
        case 'treasury':
            return g.perkPoints ? { text: String(g.perkPoints), kind: 'accent' } : null;
        case 'turf': {
            const held = (g.territories || []).length;
            return held ? { text: String(held), kind: 'dim' } : null;
        }
        default:
            return null;
    }
}

function badgeHtml(badge) {
    return badge ? `<span class="rail-badge ${badge.kind}">${escapeHtml(badge.text)}</span>` : '';
}

function appButton(app, i) {
    const btn = document.createElement('button');
    btn.className = 'rail-app rise' + (app.id === state.activeApp ? ' is-active' : '');
    btn.dataset.app = app.id;
    btn.style.setProperty('--i', i);
    btn.innerHTML =
        `<span class="rail-tile"><i class="fas ${escapeHtml(app.icon)}"></i></span>` +
        `<span class="rail-label">${escapeHtml(app.label)}</span>` +
        badgeHtml(railBadge(app.id));
    btn.onclick = () => switchApp(app.id);
    return btn;
}

function renderApps(apps) {
    const rail = $('#appRail');
    rail.innerHTML = '';

    const groups = (state.snapshot && state.snapshot.appGroups) || [];
    const placed = new Set();
    let i = 0;

    const section = (label, list) => {
        const sec = document.createElement('div');
        sec.className = 'rail-group';
        sec.innerHTML = `<div class="rail-group-head"><span>${escapeHtml(label)}</span></div>`;
        list.forEach((app) => sec.appendChild(appButton(app, i++)));
        rail.appendChild(sec);
    };

    groups.forEach((group) => {
        const mine = apps.filter((a) => (a.group || 'crew') === group.id);
        if (!mine.length) return;
        mine.forEach((a) => placed.add(a.id));
        section(group.label, mine);
    });

    // An app registered under a group the server doesn't list would be
    // unreachable otherwise, so it still gets a home.
    const rest = apps.filter((a) => !placed.has(a.id));
    if (rest.length) section(groups.length ? 'More' : 'Apps', rest);
}

// Badges move constantly (wars, people logging in). Repaint them in place
// rather than rebuilding the rail and restarting every entrance animation.
function updateRailBadges() {
    $$('#appRail .rail-app').forEach((btn) => {
        const old = btn.querySelector('.rail-badge');
        if (old) old.remove();
        const badge = railBadge(btn.dataset.app);
        if (badge) btn.insertAdjacentHTML('beforeend', badgeHtml(badge));
    });
}

const VIEW_BY_APP = {
    hub: 'viewHub',
    roster: 'viewRoster',
    turf: 'viewTurf',
    war: 'viewWar',
    contracts: 'viewContracts',
    garage: 'viewGarage',
    graffiti: 'viewGraffiti',
    treasury: 'viewTreasury',
    standing: 'viewStanding',
    blackmarket: 'viewBlackmarket',
};

function showView(id) {
    $$('.surface > .view').forEach((v) => v.classList.add('hidden'));
    const el = document.getElementById(id);
    if (el) el.classList.remove('hidden');
}

function switchApp(appId) {
    if (!appId) return;
    state.activeApp = appId;
    $$('#appRail .rail-app').forEach((b) => b.classList.toggle('is-active', b.dataset.app === appId));
    showView(VIEW_BY_APP[appId] || 'viewHub');
    renderActiveApp();
}

function renderActiveApp() {
    switch (state.activeApp) {
        case 'hub': renderHub(); break;
        case 'roster': renderRoster(); break;
        case 'turf': renderTurf(); break;
        case 'war': renderWar(); break;
        case 'contracts': renderContracts(); break;
        case 'garage': renderGarage(); break;
        case 'graffiti': renderGraffiti(); break;
        case 'treasury': renderTreasury(); break;
        case 'standing': renderStanding(); break;
        case 'blackmarket': renderBlackmarket(); break;
    }
}

// ── tabs (scoped to the enclosing view so two apps never collide) ──
document.addEventListener('click', (e) => {
    const tab = e.target.closest('.tab');
    if (!tab || !tab.dataset.tab) return;
    const scope = tab.closest('.view') || tab.closest('.admin-surface') || document;
    scope.querySelectorAll(':scope .tab').forEach((t) => t.classList.toggle('is-active', t === tab));
    scope.querySelectorAll(':scope .tabview').forEach((v) =>
        v.classList.toggle('is-active', v.dataset.tabview === tab.dataset.tab));
    onTabShown(tab.dataset.tab);
});

// Some tabs only load their data when actually opened.
function onTabShown(tabId) {
    switch (tabId) {
        case 'hub-map': renderLiveMap(); break;
        case 'hub-property': renderUnlocks(); break;
        case 'ros-ranks': renderRanks(); break;
        case 'tre-upgrades': renderUpgrades(); break;
        case 'tre-perks': renderPerks(); break;
        case 'con-badges': renderTaskBadges(); break;
        case 'con-leaderboard': renderTaskLeaderboard(); break;
        case 'con-crew': renderTaskCrew(); break;
        case 'gf-tags': renderGraffiti(); break;
    }
}

// ── count-up ──
function countUp(el, target, fmt = num) {
    if (!el) return;
    const start = 0;
    const dur = 620;
    const t0 = performance.now();
    function step(t) {
        const p = Math.min(1, (t - t0) / dur);
        const eased = 1 - Math.pow(1 - p, 3);
        el.textContent = fmt(Math.round(start + (target - start) * eased));
        if (p < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
}

// ═══════════════════════════════════════════════════════════
// HUB — the crew's homepage
// ═══════════════════════════════════════════════════════════
function renderHub() {
    const g = state.gang;
    if (!g) return;

    $('#heroName').textContent = g.label;
    $('#heroLevelTitle').textContent = g.gangLevelTitle;
    $('#heroLevelNum').textContent = g.gangLevel;

    const floor = g.gangLevelRep || 0;
    const ceil = g.nextGangLevelRep;
    const pct = ceil ? Math.min(100, Math.max(0, ((g.rep - floor) / (ceil - floor)) * 100)) : 100;
    $('#heroRepFill').style.width = pct + '%';
    $('#heroRepLabel').textContent = ceil
        ? `${num(g.rep)} / ${num(ceil)}`
        : `${num(g.rep)} — maxed`;

    const ring = $('#heroRing');
    const circ = 2 * Math.PI * 52;
    ring.style.strokeDasharray = circ;
    ring.style.strokeDashoffset = circ - (circ * pct) / 100;

    renderTierRail(g);
    renderMotd();
    renderHubAlerts(g);
    renderHeroFacts(g);
    renderHubCards(g);
    renderHubOnline(g);

    renderLogs($('#overviewLogs'), (g.logs || []).slice(0, 6));
    renderLogFilters();
}

// Jump straight to an app, optionally landing on one of its tabs.
function jumpTo(appId, tabId) {
    switchApp(appId);
    if (!tabId) return;
    const tab = document.querySelector(`.tab[data-tab="${tabId}"]`);
    if (tab) tab.click();
}

// ── banner: only shows up when something actually needs a decision ──
function renderHubAlerts(g) {
    const box = $('#hubAlerts');
    if (!box) return;
    const alerts = [];

    if (state.war) {
        const prep = state.war.phase === 'prep';
        alerts.push({
            kind: 'hot', icon: 'fa-crosshairs',
            title: state.war.kind === 'raid'
                ? (prep ? 'Raid incoming' : 'Raid in progress')
                : (prep ? 'War starts soon' : 'War is live'),
            body: prep ? 'Get everyone on before it opens.' : 'Your crew is in it right now.',
            cta: 'War Room', app: 'war',
        });
    }

    const contested = (state.territories || []).filter((t) =>
        t.mine && (t.influence || []).some((i) => i.gangId !== g.id && i.influence > 0));
    if (contested.length) {
        alerts.push({
            kind: 'warn', icon: 'fa-tower-broadcast',
            title: contested.length === 1
                ? `${contested[0].label} is being worked`
                : `${contested.length} blocks being worked`,
            body: 'A rival is building influence on turf you hold.',
            cta: 'See turf', app: 'turf',
        });
    }

    if (g.perkPoints > 0) {
        alerts.push({
            kind: 'good', icon: 'fa-star',
            title: `${g.perkPoints} perk point${g.perkPoints === 1 ? '' : 's'} unspent`,
            body: 'Perks apply to the whole crew the moment you buy them.',
            cta: 'Spend', app: 'treasury', tab: 'tre-perks',
        });
    }

    if (!alerts.length) { box.innerHTML = ''; box.classList.add('hidden'); return; }
    box.classList.remove('hidden');
    box.innerHTML = alerts.map((a, i) => `
        <div class="alert alert-${a.kind} rise" style="--i:${i}">
            <span class="alert-icon"><i class="fas ${a.icon}"></i></span>
            <div class="alert-main">
                <span class="alert-title">${escapeHtml(a.title)}</span>
                <span class="alert-body">${escapeHtml(a.body)}</span>
            </div>
            <button class="btn btn-ghost btn-sm" data-jump="${escapeHtml(a.app)}" data-jump-tab="${escapeHtml(a.tab || '')}">
                ${escapeHtml(a.cta)} <i class="fas fa-arrow-right"></i>
            </button>
        </div>`).join('');

    $$('#hubAlerts [data-jump]').forEach((btn) => {
        btn.onclick = () => jumpTo(btn.dataset.jump, btn.dataset.jumpTab || null);
    });
}

// ── the numbers that belong next to the crest, not in a grid ──
function renderHeroFacts(g) {
    const el = $('#heroFacts');
    if (!el) return;
    const facts = [
        { icon: 'fa-sack-dollar', value: money(g.bank), label: 'Treasury' },
        { icon: 'fa-users', value: `${g.memberCount}/${g.maxMembers}`, label: 'Crew' },
        { icon: 'fa-map-location-dot', value: (g.territories || []).length, label: 'Turf' },
        { icon: 'fa-crosshairs', value: `${g.warWins}–${g.warLosses}`, label: 'Record' },
        { icon: 'fa-id-badge', value: g.myRank, label: 'Your rank' },
    ];
    el.innerHTML = facts.map((f, i) => `
        <div class="fact rise" style="--i:${i}">
            <i class="fas ${f.icon}"></i>
            <span class="fact-value">${escapeHtml(String(f.value))}</span>
            <span class="fact-label">${escapeHtml(f.label)}</span>
        </div>`).join('');
}

// ── clickable cards: every app one tap away, each with its own live line ──
function renderHubCards(g) {
    const grid = $('#hubCards');
    if (!grid) return;
    const has = (id) => state.apps.some((a) => a.id === id);
    const held = (g.territories || []).length;
    const pushing = (state.territories || []).filter((t) => !t.mine && (t.myInfluence || 0) > 0).length;

    const cards = [];

    cards.push({
        app: 'hub', tab: 'hub-map', icon: 'fa-satellite-dish', title: 'Live Map',
        body: 'Where every crew member is standing right now.',
        stat: g.onlineCount ? `${g.onlineCount} online` : 'nobody on',
    });

    if (has('turf')) cards.push({
        app: 'turf', icon: 'fa-map-location-dot', title: 'Turf',
        body: 'Work rival blocks and hold what you took.',
        stat: pushing ? `${held} held · ${pushing} pushing` : `${held} held`,
    });

    if (has('war')) cards.push({
        app: 'war', icon: 'fa-crosshairs', title: 'War Room', hot: !!state.war,
        body: state.war ? 'Your crew is in a fight right now.' : 'Declare on a rival or guard the stash.',
        stat: state.war ? 'ACTIVE' : `${g.warWins}–${g.warLosses}`,
    });

    if (has('contracts')) cards.push({
        app: 'contracts', icon: 'fa-file-signature', title: 'Contracts',
        body: 'Jobs that pay the crew and move rep.',
        stat: 'Board open',
    });

    if (has('treasury')) cards.push({
        app: 'treasury', icon: 'fa-vault', title: 'Treasury',
        body: 'Bank, upgrades and crew-wide perks.',
        stat: money(g.bank),
    });

    cards.push({
        app: 'hub', tab: 'hub-property', icon: 'fa-cubes', title: 'Property',
        body: 'Place your HQ, stash, garage and the rest.',
        stat: can('manage_upgrades') ? 'Place & buy' : 'View only',
    });

    if (has('garage')) cards.push({
        app: 'garage', icon: 'fa-warehouse', title: 'Garage',
        body: 'Pull crew vehicles out at the garage point.',
        stat: 'Crew fleet',
    });

    if (has('graffiti')) cards.push({
        app: 'graffiti', icon: 'fa-spray-can', title: 'Studio',
        body: 'Put the crew tag up on somebody else’s wall.',
        stat: 'Tag up',
    });

    if (has('roster')) cards.push({
        app: 'roster', icon: 'fa-users', title: 'Roster',
        body: 'Ranks, permissions, invites and kicks.',
        stat: `${g.memberCount}/${g.maxMembers} slots`,
    });

    if (has('blackmarket')) cards.push({
        app: 'blackmarket', icon: 'fa-comments', title: 'Blackmarket',
        body: 'Crew-only channel, off the city radio.',
        stat: 'Secure line',
    });

    grid.innerHTML = cards.map((c, i) => `
        <button class="hub-card rise${c.hot ? ' is-hot' : ''}" style="--i:${i}"
            data-jump="${escapeHtml(c.app)}" data-jump-tab="${escapeHtml(c.tab || '')}">
            <span class="hub-card-glow"></span>
            <span class="hub-card-icon"><i class="fas ${escapeHtml(c.icon)}"></i></span>
            <span class="hub-card-title">${escapeHtml(c.title)}</span>
            <span class="hub-card-body">${escapeHtml(c.body)}</span>
            <span class="hub-card-foot">
                <span class="hub-card-stat">${escapeHtml(c.stat)}</span>
                <i class="fas fa-arrow-right"></i>
            </span>
        </button>`).join('');

    $$('#hubCards .hub-card').forEach((btn) => {
        btn.onclick = () => jumpTo(btn.dataset.jump, btn.dataset.jumpTab || null);
    });
}

function renderHubOnline(g) {
    const box = $('#hubOnline');
    if (!box) return;
    const online = (g.members || []).filter((m) => m.online);
    $('#hubOnlineCount').textContent = online.length;

    if (!online.length) {
        box.innerHTML = '<div class="empty"><i class="fas fa-user-slash"></i>Nobody else is on right now.</div>';
        return;
    }

    box.innerHTML = online.slice(0, 6).map((m, i) => `
        <div class="tile compact rise ${m.citizenid === g.myCitizenId ? 'is-mine' : ''}" style="--i:${i}">
            <span class="tile-avatar">${escapeHtml(initials(m.name))}</span>
            <div class="tile-main">
                <span class="tile-name">${escapeHtml(m.name)}${m.isOwner ? ' <span class="tag-owner">BOSS</span>' : ''}</span>
                <span class="tile-sub">${escapeHtml(m.rank)}</span>
            </div>
            <div class="tile-stat">${num(m.rep)} rep</div>
        </div>`).join('');
}

// Where the crew sits across the whole tier ladder, not just which tier
// they're on. The names come from the snapshot's own tier fields so this
// never drifts from Config.Rep.
const TIER_NAMES = ['Unknown', 'Local', 'Feared', 'Notorious', 'Untouchable'];

function renderTierRail(g) {
    const rail = $('#tierRail');
    if (!rail) return;
    const current = TIER_NAMES.indexOf(g.tier);
    rail.innerHTML = TIER_NAMES.map((name, i) => {
        const cls = i < current ? 'done' : (i === current ? 'now' : '');
        return `<div class="tier-step ${cls}"><span>${escapeHtml(name)}</span></div>`;
    }).join('');
}

function renderMotd() {
    const g = state.gang;
    const card = $('#motdCard');
    const hasMotd = g && g.motd && g.motd.length;
    card.classList.toggle('hidden', !hasMotd && !(g && (g.isOwner || can('manage_motd'))));
    $('#motdText').textContent = hasMotd ? g.motd : 'No crew notice set.';
    $('#motdEditBtn').classList.toggle('hidden', !(g && (g.isOwner || can('manage_motd'))));
}

$('#motdEditBtn').onclick = () => {
    $('#motdEditRow').classList.remove('hidden');
    $('#motdInput').value = (state.gang && state.gang.motd) || '';
    $('#motdInput').focus();
};
$('#motdCancelBtn').onclick = () => $('#motdEditRow').classList.add('hidden');
$('#motdSaveBtn').onclick = async () => {
    const res = await call('XS-CriminalTablet:setMotd', $('#motdInput').value);
    if (report(res, 'Notice updated.')) {
        $('#motdEditRow').classList.add('hidden');
        refreshAll();
    }
};

const LOG_CATS = {
    general: 'fa-circle-info', roster: 'fa-users', economy: 'fa-sack-dollar',
    war: 'fa-crosshairs', property: 'fa-cubes', garage: 'fa-warehouse',
    graffiti: 'fa-spray-can', storage: 'fa-vault', medic: 'fa-kit-medical',
    contract: 'fa-file-signature',
};

function renderLogs(container, logs) {
    if (!container) return;
    if (!logs || !logs.length) {
        container.innerHTML = '<div class="log-empty">Nothing logged yet.</div>';
        return;
    }
    container.innerHTML = logs.map((l) => {
        const cat = l.category || 'general';
        return `<div class="log">
            <span class="log-cat ${escapeHtml(cat)}"><i class="fas ${LOG_CATS[cat] || 'fa-circle-info'}"></i></span>
            <span class="log-msg">${escapeHtml(l.message)}</span>
            <span class="log-time">${escapeHtml(formatTime(l.created_at))}</span>
        </div>`;
    }).join('');
}

function renderLogFilters() {
    const g = state.gang;
    if (!g) return;
    const cats = ['all', ...new Set((g.logs || []).map((l) => l.category || 'general'))];
    $('#logFilters').innerHTML = cats.map((c) =>
        `<button class="pill ${state.logFilter === c ? 'is-active' : ''}" data-log="${escapeHtml(c)}">${escapeHtml(c === 'all' ? 'Everything' : c)}</button>`).join('');
    $$('#logFilters .pill').forEach((p) => {
        p.onclick = () => { state.logFilter = p.dataset.log; renderLogFilters(); renderFilteredLogs(); };
    });
    renderFilteredLogs();
}

function renderFilteredLogs() {
    const g = state.gang;
    if (!g) return;
    const logs = state.logFilter === 'all'
        ? g.logs
        : (g.logs || []).filter((l) => (l.category || 'general') === state.logFilter);
    renderLogs($('#logList'), logs);
}

// ── unlocks / property ──
const KIND_ICONS = {
    hq: 'fa-satellite-dish', vault: 'fa-vault', safe: 'fa-sack-dollar',
    garage: 'fa-warehouse', medic: 'fa-kit-medical', bench: 'fa-screwdriver-wrench',
    task: 'fa-box', prop: 'fa-cube',
};

async function renderUnlocks() {
    const data = await call('XS-CriminalTablet:placeables:getAvailable');
    const grid = $('#unlockGrid');
    const list = (data && data.unlocks) || [];

    $('#propertyTierNote').textContent = data
        ? `${data.tier} tier${data.tierBoost ? ` (+${data.tierBoost} from perks)` : ''} · ${num(data.rep)} rep · ${money(data.bank)} banked`
        : '';
    $('#propertyHint').textContent = data && data.hasHq
        ? `Reaching a tier makes an unlock buyable; the crew bank pays for it. Anything other than the HQ then has to go on turf you hold, or within ${Math.round(data.buildRadius)}m of your HQ.`
        : 'Place the Crew HQ first — everything else builds around it or on turf you hold.';

    if (!list.length) {
        grid.innerHTML = '<div class="empty"><i class="fas fa-cubes"></i>Nothing configured to unlock.</div>';
        return;
    }

    grid.innerHTML = list.map((u, i) => {
        // Anything not yet paid for shows its price, tier-locked included —
        // a disabled "Place" tells you nothing about what it will cost.
        const needsBuying = !u.owned;
        return `<div class="unlock ${u.placed ? 'placed' : ''} ${u.locked ? 'locked' : ''} rise" style="--i:${i}">
            <div class="unlock-top">
                <span class="unlock-icon"><i class="fas ${KIND_ICONS[u.kind] || 'fa-cube'}"></i></span>
                <div>
                    <div class="unlock-name">${escapeHtml(u.label)}</div>
                    <div class="unlock-kind">${escapeHtml(u.kind)}${u.placed ? ' · placed' : (u.owned ? ' · owned' : '')}</div>
                </div>
                ${u.price > 0 && !u.owned ? `<span class="unlock-price">${money(u.price)}</span>` : ''}
            </div>
            ${u.locked ? `<div class="unlock-req">Needs ${escapeHtml(u.tierName)} · ${num(u.tierRep)} rep</div>` : ''}
            ${needsBuying && !u.locked && !u.affordable ? '<div class="unlock-req">The bank is short</div>' : ''}
            <div class="unlock-actions">
                ${needsBuying ? `
                    <button class="btn btn-accent btn-sm" data-buy="${escapeHtml(u.id)}"
                        ${!data.canBuy || !u.affordable || u.locked ? 'disabled' : ''}>
                        <i class="fas fa-cart-shopping"></i> Buy
                    </button>` : `
                    <button class="btn btn-accent btn-sm" data-place="${escapeHtml(u.id)}"
                        ${u.locked || !data.canPlace ? 'disabled' : ''}>
                        <i class="fas fa-location-dot"></i> ${u.placed ? 'Move' : 'Place'}
                    </button>`}
                ${u.placed ? `
                    <button class="btn btn-ghost btn-sm" data-waypoint="${escapeHtml(u.id)}" title="Set waypoint"><i class="fas fa-map-pin"></i></button>
                    <button class="btn btn-danger btn-sm" data-remove="${escapeHtml(u.id)}" ${data.canRemove ? '' : 'disabled'}><i class="fas fa-trash"></i></button>
                ` : ''}
            </div>
        </div>`;
    }).join('');

    grid.querySelectorAll('[data-place]').forEach((b) => {
        b.onclick = () => nui('placeObject', { id: b.dataset.place });
    });
    grid.querySelectorAll('[data-buy]').forEach((b) => {
        b.onclick = async () => {
            const res = await call('XS-CriminalTablet:placeables:buy', b.dataset.buy);
            if (report(res, 'Unlocked — you can place it now.')) {
                renderUnlocks();
                refreshSnapshotQuiet();
            }
        };
    });
    grid.querySelectorAll('[data-remove]').forEach((b) => {
        b.onclick = async () => {
            const res = await call('XS-CriminalTablet:placeables:remove', b.dataset.remove);
            if (report(res, 'Picked it back up.')) renderUnlocks();
        };
    });
    grid.querySelectorAll('[data-waypoint]').forEach((b) => {
        b.onclick = () => {
            const u = list.find((x) => x.id === b.dataset.waypoint);
            if (u && u.coords) nui('setWaypoint', u.coords);
        };
    });
}

// ── live map ──
let _liveMap = null, _liveLayer = null;

async function renderLiveMap() {
    const data = await call('XS-CriminalTablet:gang:getLiveMap');
    const members = (data && data.members) || [];

    if (ensureMap('hubMap', 'live')) {
        _liveLayer.clearLayers();

        ((data && data.territories) || []).forEach((t) => plotZone(_liveMap, _liveLayer, t));

        if (data && data.hq) {
            L.circleMarker(mapLatLng(_liveMap, data.hq.x, data.hq.y), {
                radius: 7, color: '#ffffff', weight: 2, fillColor: '#ffffff', fillOpacity: .9,
            }).bindTooltip('Crew HQ', { direction: 'top' }).addTo(_liveLayer);
        }

        members.forEach((m) => {
            const color = m.dead ? '#e5484d' : (m.isMe ? '#2dd4bf' : (state.gang && state.gang.color) || '#f5a524');
            L.circleMarker(mapLatLng(_liveMap, m.coords.x, m.coords.y), {
                radius: m.isMe ? 7 : 5, color, weight: 2, fillColor: color, fillOpacity: .85,
            }).bindTooltip(
                `${escapeHtml(m.name)} — ${escapeHtml(m.rank)}${m.zoneLabel ? ` · ${escapeHtml(m.zoneLabel)}` : ''}`,
                { direction: 'top' })
              .addTo(_liveLayer);
        });
    }

    const list = $('#livePlayerList');
    if (!members.length) {
        list.innerHTML = '<div class="empty"><i class="fas fa-users-slash"></i>Nobody else is on right now.</div>';
        return;
    }
    list.innerHTML = members.map((m) => `
        <div class="tile ${m.isMe ? 'is-mine' : ''} ${m.dead ? 'is-danger' : ''}">
            <span class="tile-avatar">${escapeHtml(initials(m.name))}</span>
            <div class="tile-main">
                <span class="tile-name">${escapeHtml(m.name)}${m.isMe ? ' <span class="tag-owner">YOU</span>' : ''}</span>
                <span class="tile-sub">
                    ${escapeHtml(m.rank)}
                    ${m.zoneLabel ? `· ${escapeHtml(m.zoneLabel)}` : '· off turf'}
                    ${m.inVehicle ? '· <i class="fas fa-car"></i> driving' : ''}
                    ${m.dead ? '· <span style="color:var(--danger)">down</span>' : ''}
                </span>
            </div>
            <div class="tile-actions">
                <button class="btn btn-ghost btn-sm" data-locate='${escapeHtml(JSON.stringify(m.coords))}'><i class="fas fa-map-pin"></i></button>
            </div>
        </div>`).join('');

    list.querySelectorAll('[data-locate]').forEach((b) => {
        b.onclick = () => {
            try { nui('setWaypoint', JSON.parse(b.dataset.locate)); } catch (e) { /* malformed, ignore */ }
        };
    });
}

$('#mapRefreshBtn').onclick = () => renderLiveMap();

// ═══════════════════════════════════════════════════════════
// MAP CORE (shared by the hub + turf maps)
// The real satellite render, shared with the rest of the line. Leaflet is
// vendored because NUI has no reliable internet; the tile pyramid ships in
// assets/maps/tiles.
// ═══════════════════════════════════════════════════════════
const TMAP = {
    imageW: 4096, imageH: 6144, tileSize: 512, nativeZoom: 4, maxZoom: 6,
    // The GTA world rectangle this render covers. Fitted against the postal
    // set that is drawn on the render itself — six postals from the north
    // tip to LSIA, both coasts and dead centre, all land within two pixels.
    //
    // 9000 x 13500 is exactly 2:3, like the 4096 x 6144 image, so the pixels
    // are square. Never nudge one axis on its own — doing that is what put
    // players up to 300m out before.
    world: { minX: -4140, maxX: 4860, minY: -5100, maxY: 8400 },
};

const _maps = {};

function mapLatLng(map, wx, wy) {
    const W = TMAP.world;
    const px = ((wx - W.minX) / (W.maxX - W.minX)) * TMAP.imageW;
    const py = ((W.maxY - wy) / (W.maxY - W.minY)) * TMAP.imageH;
    return map.unproject([px, py], TMAP.nativeZoom);
}

// The way back: a point clicked on the map to a world x/y. Drawing turf
// on the satellite view is only possible because this is exact.
function mapWorld(map, latlng) {
    const W = TMAP.world;
    const p = map.project(latlng, TMAP.nativeZoom);
    return {
        x: W.minX + (p.x / TMAP.imageW) * (W.maxX - W.minX),
        y: W.maxY - (p.y / TMAP.imageH) * (W.maxY - W.minY),
    };
}


// Leaflet measures its container once at construction, and these tabs are
// display:none when the device opens — so the map starts at 0x0 and has to
// be re-measured (and fitted for the first time) once it's visible.
function refitMap(key) {
    const entry = _maps[key];
    if (!entry) return;
    const c = entry.map.getContainer();
    if (!c.clientWidth || !c.clientHeight) return;
    entry.map.invalidateSize({ animate: false });
    if (!entry.fitted) {
        entry.map.fitBounds(entry.bounds, { animate: false });
        entry.fitted = true;
    }
}

function ensureMap(elementId, key) {
    const el = document.getElementById(elementId);
    if (!el || typeof L === 'undefined') return false;

    if (_maps[key]) {
        refitMap(key);
        if (key === 'live') { _liveMap = _maps[key].map; _liveLayer = _maps[key].layer; }
        if (key === 'turf') { _turfMap = _maps[key].map; _turfLayer = _maps[key].layer; }
        return true;
    }

    const map = L.map(el, {
        crs: L.CRS.Simple,
        minZoom: 0, maxZoom: TMAP.maxZoom,
        zoomControl: true, attributionControl: false,
        zoomSnap: 0.25, wheelPxPerZoomLevel: 90,
    });

    const sw = map.unproject([0, TMAP.imageH], TMAP.nativeZoom);
    const ne = map.unproject([TMAP.imageW, 0], TMAP.nativeZoom);
    const bounds = new L.LatLngBounds(sw, ne);

    L.tileLayer('assets/maps/tiles/{z}_{x}_{y}.webp', {
        tileSize: TMAP.tileSize, minZoom: 0, maxZoom: TMAP.maxZoom,
        maxNativeZoom: TMAP.nativeZoom, noWrap: true, bounds,
    }).addTo(map);

    map.setView(bounds.getCenter(), 1, { animate: false });
    map.setMaxBounds(bounds.pad(0.1));

    const layer = L.layerGroup().addTo(map);
    _maps[key] = { map, layer, bounds, fitted: false };

    if (key === 'live') { _liveMap = map; _liveLayer = layer; }
    if (key === 'turf') { _turfMap = map; _turfLayer = layer; }

    refitMap(key);
    if (typeof ResizeObserver !== 'undefined') new ResizeObserver(() => refitMap(key)).observe(el);
    return true;
}

// Draws a zone as its real polygon when it has one, falling back to a
// circle for radius-only zones.
function plotZone(map, layer, t) {
    const mine = t.holderId && state.gang && t.holderId === state.gang.id;
    const color = mine ? ((state.gang && state.gang.color) || '#f5a524')
        : (t.holderColor || '#e5484d');

    let shape;
    if (t.points && t.points.length >= 3) {
        shape = L.polygon(t.points.map((p) => mapLatLng(map, p.x, p.y)), {
            color, weight: 2, fillColor: color, fillOpacity: mine ? .22 : .13,
        });
    } else if (t.coords) {
        shape = L.circleMarker(mapLatLng(map, t.coords.x, t.coords.y), {
            radius: mine ? 15 : 11, color, weight: 2, fillColor: color, fillOpacity: .18,
        });
    } else {
        return null;
    }

    // Leaflet renders tooltip content as HTML, so every gang-supplied
    // string has to be escaped here just like anywhere else.
    const split = (t.influence || [])
        .map((i) => `<span class="mt-row"><i style="background:${escapeHtml(i.gangColor || '#6b7280')}"></i>` +
                    `${escapeHtml(i.gangLabel)} <b>${Math.round(i.influence)}%</b></span>`)
        .join('');
    shape.bindTooltip(
        `<div class="map-tip">
            <div class="mt-head">${escapeHtml(t.label)}</div>
            <div class="mt-sub">${t.holder ? escapeHtml(t.holder) : 'unassigned'}` +
            `${t.holderTier ? ` · ${escapeHtml(t.holderTier)}` : ''}${t.capturable ? '' : ' · locked'}</div>
            ${split ? `<div class="mt-split">${split}</div>` : ''}
        </div>`,
        { direction: 'top', className: 'map-tip-wrap' });

    // A standing label so the map reads as a map rather than a set of
    // coloured blobs you have to hover one at a time.
    if (t.center || t.coords) {
        const c = t.center || t.coords;
        const top = (t.influence || [])[0];
        L.tooltip({ permanent: true, direction: 'center', className: 'zone-label', interactive: false })
            .setLatLng(mapLatLng(map, c.x, c.y))
            .setContent(`<span>${escapeHtml(t.label)}</span>` +
                (top ? `<em>${Math.round(top.influence)}%</em>` : ''))
            .addTo(layer);
    }

    shape.addTo(layer);

    if (t.center || t.coords) {
        const c = t.center || t.coords;
        L.circleMarker(mapLatLng(map, c.x, c.y), {
            radius: 3, color, weight: 0, fillColor: color, fillOpacity: 1,
        }).addTo(layer);
    }
    return shape;
}

// ═══════════════════════════════════════════════════════════
// ROSTER
// ═══════════════════════════════════════════════════════════
function renderRoster() {
    const g = state.gang;
    if (!g) return;

    $('#memberCount').textContent = `${g.memberCount} / ${g.maxMembers}`;
    $('#myRep').textContent = num(g.myRep);
    $('#inviteBtn').disabled = !can('invite');

    renderContributors(g);
    renderMemberList(g);
}

function renderContributors(g) {
    const top = [...(g.members || [])].sort((a, b) => b.rep - a.rep).slice(0, 3);
    if (!top.length) { $('#topContributors').innerHTML = ''; return; }
    $('#topContributors').innerHTML = top.map((m, i) => `
        <div class="podium-card rank-${i + 1}">
            <div class="podium-pos">#${i + 1}</div>
            <div class="podium-name">${escapeHtml(m.name)}</div>
            <div class="podium-rep">${num(m.rep)}</div>
            <div class="muted">${escapeHtml(m.rank)}</div>
        </div>`).join('');
}

function renderMemberList(g) {
    const filter = ($('#memberFilter').value || '').toLowerCase();
    const members = (g.members || []).filter((m) =>
        !filter || m.name.toLowerCase().includes(filter) || m.rank.toLowerCase().includes(filter));

    const inactiveMs = (g.inactivityDays || 7) * 86400000;
    const ranks = g.ranks || [];

    if (!members.length) {
        $('#memberList').innerHTML = '<div class="empty"><i class="fas fa-user-slash"></i>Nobody matches that.</div>';
        return;
    }

    $('#memberList').innerHTML = members.map((m) => {
        const inactive = !m.online && m.lastSeen && (Date.now() - m.lastSeen > inactiveMs);
        const isMe = m.citizenid === g.myCitizenId;
        // You can never act on yourself, the boss, or anyone at/above your rank.
        const actionable = !isMe && !m.isOwner && (g.isOwner || m.grade < g.myGrade);

        const rankOptions = ranks
            .filter((r) => !r.isTop || g.isOwner)
            .map((r) => `<option value="${r.grade}" ${r.grade === m.grade ? 'selected' : ''}>${escapeHtml(r.name)}</option>`)
            .join('');

        return `<div class="tile ${isMe ? 'is-mine' : ''}">
            <span class="tile-avatar">${escapeHtml(initials(m.name))}</span>
            <div class="tile-main">
                <span class="tile-name">
                    <i class="${m.online ? 'dot-online' : 'dot-offline'}"></i>
                    ${escapeHtml(m.name)}
                    ${m.isOwner ? '<span class="tag-owner">BOSS</span>' : ''}
                    ${isMe ? '<span class="tag-owner">YOU</span>' : ''}
                </span>
                <span class="tile-sub">
                    ${escapeHtml(m.rank)} · ${num(m.rep)} rep
                    ${m.online ? '· online' : `· ${relative(m.lastSeen)}`}
                    ${inactive ? '· <span class="tag-inactive">INACTIVE</span>' : ''}
                </span>
            </div>
            <div class="tile-actions">
                ${actionable && (can('promote') || can('demote')) ? `
                    <select data-grade="${escapeHtml(m.citizenid)}">${rankOptions}</select>` : ''}
                ${actionable && can('kick') ? `
                    <button class="btn btn-danger btn-sm" data-kick="${escapeHtml(m.citizenid)}" title="Remove"><i class="fas fa-user-minus"></i></button>` : ''}
                ${g.isOwner && !isMe && can('transfer_leadership') ? `
                    <button class="btn btn-ghost btn-sm" data-boss="${escapeHtml(m.citizenid)}" title="Hand over the crew"><i class="fas fa-crown"></i></button>` : ''}
            </div>
        </div>`;
    }).join('');

    $$('#memberList [data-grade]').forEach((sel) => {
        sel.onchange = async () => {
            const res = await call('XS-CriminalTablet:setGrade', sel.dataset.grade, Number(sel.value));
            if (report(res, 'Rank updated.')) refreshAll();
            else renderRoster();
        };
    });
    $$('#memberList [data-kick]').forEach((b) => {
        b.onclick = async () => {
            const res = await call('XS-CriminalTablet:kick', b.dataset.kick);
            if (report(res, 'Removed.')) refreshAll();
        };
    });
    $$('#memberList [data-boss]').forEach((b) => {
        b.onclick = async () => {
            const res = await call('XS-CriminalTablet:transferLeadership', b.dataset.boss);
            if (report(res, 'They run the crew now.')) refreshAll();
        };
    });
}

$('#memberFilter').oninput = () => state.gang && renderMemberList(state.gang);

$('#leaveGangBtn').onclick = async () => {
    const res = await call('XS-CriminalTablet:leaveGang');
    if (report(res, 'You walked away.')) refreshAll();
};

// ── player search (shared by every invite box) ──
function attachPlayerSearch(input) {
    if (!input) return { selected: () => null };
    const box = input.parentElement.querySelector('.player-search-results');
    let selected = null;
    let timer = null;

    const hide = () => { box.classList.add('hidden'); box.innerHTML = ''; };

    input.addEventListener('input', () => {
        selected = null;
        clearTimeout(timer);
        timer = setTimeout(async () => {
            const results = await call('XS-CriminalTablet:players:search', input.value);
            if (!Array.isArray(results) || !results.length) return hide();
            box.innerHTML = results.map((r) =>
                `<div class="player-result" data-id="${r.id}">${escapeHtml(r.name)}<span>#${r.id}</span></div>`).join('');
            box.classList.remove('hidden');
            box.querySelectorAll('.player-result').forEach((row) => {
                row.onclick = () => {
                    selected = Number(row.dataset.id);
                    input.value = row.childNodes[0].textContent.trim();
                    hide();
                };
            });
        }, 220);
    });

    input.addEventListener('blur', () => setTimeout(hide, 180));
    return {
        selected: () => selected !== null ? selected : (Number(input.value) || null),
        clear: () => { input.value = ''; selected = null; hide(); },
    };
}

const invitePS = attachPlayerSearch($('#inviteId'));
$('#inviteBtn').onclick = async () => {
    const id = invitePS.selected();
    if (!id) return flash('Pick someone from the list first.', 'error');
    const res = await call('XS-CriminalTablet:invite', id);
    if (report(res, 'Invite sent.')) invitePS.clear();
};

// ── rank ladder ──
let rankData = null;

async function renderRanks() {
    rankData = await call('XS-CriminalTablet:ranks:list');
    const list = $('#rankList');
    const ranks = (rankData && rankData.ranks) || [];
    const canEdit = rankData && rankData.canEdit;

    $('#rankAddRow').classList.toggle('hidden', !canEdit);

    if (!ranks.length) {
        list.innerHTML = '<div class="empty"><i class="fas fa-layer-group"></i>No ranks yet.</div>';
        return;
    }

    list.innerHTML = ranks.map((r) => {
        const all = r.permissions === '*';
        const owned = all ? [] : r.permissions;
        const permCount = all ? 'every permission' : `${owned.length} permission${owned.length === 1 ? '' : 's'}`;

        const groups = (rankData.groups || []).map((grp) => `
            <div class="perm-group">
                <div class="perm-group-head">${escapeHtml(grp.label)}</div>
                <div class="perm-grid">
                    ${grp.permissions.map((p) => {
                        const on = all || owned.includes(p.id);
                        const grantable = rankData.grantable === '*' || (rankData.grantable || []).includes(p.id);
                        const blocked = r.isTop || !canEdit || !grantable;
                        return `<label class="perm ${on ? 'is-on' : ''} ${blocked ? 'is-blocked' : ''}">
                            <input type="checkbox" data-perm="${escapeHtml(p.id)}" data-grade="${r.grade}"
                                ${on ? 'checked' : ''} ${blocked ? 'disabled' : ''} />
                            <span class="perm-text">
                                <span class="perm-label">${escapeHtml(p.label)}</span>
                                <span class="perm-desc">${escapeHtml(p.description)}</span>
                            </span>
                        </label>`;
                    }).join('')}
                </div>
            </div>`).join('');

        return `<div class="rank-row ${r.isTop ? 'is-top' : ''}" data-rank="${r.grade}">
            <div class="rank-head">
                <span class="rank-grade">G${r.grade}</span>
                <input class="rank-name-input" type="text" value="${escapeHtml(r.name)}"
                    data-name="${r.grade}" ${canEdit ? '' : 'disabled'} maxlength="48" />
                <div class="rank-meta">
                    <span class="muted">${r.memberCount} member${r.memberCount === 1 ? '' : 's'}</span>
                    <span class="rank-perm-count">${escapeHtml(permCount)}</span>
                    <i class="fas fa-chevron-down muted"></i>
                </div>
            </div>
            <div class="rank-body">
                ${r.isTop ? '<p class="hint"><i class="fas fa-crown"></i> The boss rank always keeps every permission — that\'s what stops a crew locking itself out.</p>' : groups}
                ${canEdit && !r.isTop && r.grade !== 0 ? `
                    <div class="rank-foot">
                        <button class="btn btn-danger btn-sm" data-delrank="${r.grade}"><i class="fas fa-trash"></i> Delete rank</button>
                    </div>` : ''}
            </div>
        </div>`;
    }).join('');

    list.querySelectorAll('.rank-head').forEach((head) => {
        head.onclick = (e) => {
            if (e.target.closest('input')) return;
            head.parentElement.classList.toggle('is-open');
        };
    });

    list.querySelectorAll('[data-perm]').forEach((cb) => {
        cb.onchange = () => saveRankPermissions(Number(cb.dataset.grade));
    });
    list.querySelectorAll('[data-name]').forEach((inp) => {
        inp.onchange = async () => {
            const res = await call('XS-CriminalTablet:ranks:update', Number(inp.dataset.name), { name: inp.value });
            report(res, 'Rank renamed.');
            if (res && res.ok) refreshAll();
        };
    });
    list.querySelectorAll('[data-delrank]').forEach((b) => {
        b.onclick = async () => {
            const res = await call('XS-CriminalTablet:ranks:delete', Number(b.dataset.delrank));
            if (report(res, 'Rank removed.')) { renderRanks(); refreshAll(); }
        };
    });
}

async function saveRankPermissions(grade) {
    const row = $(`.rank-row[data-rank="${grade}"]`);
    if (!row) return;
    const perms = Array.from(row.querySelectorAll('[data-perm]:checked')).map((cb) => cb.dataset.perm);
    const res = await call('XS-CriminalTablet:ranks:update', grade, { permissions: perms });
    if (!res || !res.ok) {
        flash((res && res.error) || 'Could not save that', 'error');
        renderRanks();
        return;
    }
    // Re-read so the header count and my own permission set stay honest.
    renderRanks();
    refreshSnapshotQuiet();
}

$('#addRankBtn').onclick = async () => {
    const name = $('#newRankName').value.trim();
    if (!name) return flash('Name the rank first.', 'error');
    const res = await call('XS-CriminalTablet:ranks:add', name);
    if (report(res, 'Rank added.')) { $('#newRankName').value = ''; renderRanks(); }
};

// ═══════════════════════════════════════════════════════════
// TURF
// ═══════════════════════════════════════════════════════════
let _turfMap = null, _turfLayer = null;

async function refreshTerritories() {
    state.territories = await call('XS-CriminalTablet:territory:getAll') || [];
    state.capture = await call('XS-CriminalTablet:capture:getState') || {};
    if (state.activeApp === 'turf') renderTurf();
}

async function renderTurf() {
    const myId = state.gang && state.gang.id;
    const all = state.territories || [];

    if (ensureMap('territoryMap', 'turf')) {
        _turfLayer.clearLayers();
        all.forEach((t) => plotZone(_turfMap, _turfLayer, t));
    }

    // Where am I standing, and can we take it?
    const here = await call('XS-CriminalTablet:capture:whereAmI');
    const hereEl = $('#turfHere');
    if (here && here.inZone) {
        hereEl.classList.remove('hidden');
        // Turf never changes hands from standing on it, so the action is
        // always "work it" — with the ceiling stated so nobody grinds
        // toward a takeover that doesn't exist.
        hereEl.innerHTML = `
            <div class="turf-here-main">
                <div class="turf-here-label">You're standing on ${escapeHtml(here.label)}</div>
                <div class="muted">${here.mine
                    ? 'Your crew\'s block. Standing on it pushes your share back up.'
                    : `${escapeHtml(here.holder || 'Another crew')}'s block — you can build share here, but it stays theirs.`}
                    ${here.blocked && !here.mine ? ` — ${escapeHtml(here.blocked)}` : ''}</div>
                ${influenceBar(here.influence, here.myInfluence)}
            </div>
            <div class="turf-actions">
                ${!here.blocked && can('capture_territory')
                    ? `<button class="btn btn-accent btn-sm" data-claim="${escapeHtml(here.zone)}">
                        <i class="fas fa-flag"></i> ${here.mine ? 'Shore it up' : `Work it (max ${here.cap}%)`}
                       </button>` : ''}
            </div>`;
        wireTurfButtons(hereEl);
    } else {
        hereEl.classList.add('hidden');
    }

    // Filtered list. Every zone a player can see belongs to some crew —
    // the server never sends unassigned ones.
    const filtered = all.filter((t) => {
        const mine = t.holderId === myId;
        if (state.turfFilter === 'mine') return mine;
        if (state.turfFilter === 'rival') return !mine;
        return true;
    });

    $('#turfCount').textContent = `${all.filter((t) => t.holderId === myId).length} held`;

    const grid = $('#turfGrid');
    if (!filtered.length) {
        grid.innerHTML = '<div class="empty"><i class="fas fa-map"></i>Nothing here.</div>';
        return;
    }

    grid.innerHTML = filtered.map((t, i) => {
        const mine = t.holderId && t.holderId === myId;
        const cls = mine ? 'mine' : (t.holderId ? 'held' : '');
        const holderCls = mine ? 'mine' : 'held';
        const shapeColor = mine ? ((state.gang && state.gang.color) || '#f5a524')
            : (t.holderColor || '#e5484d');
        return `<div class="turf ${cls} rise" style="--i:${i}">
            <div class="turf-top">
                <div class="turf-head">
                    ${turfShape(t, shapeColor)}
                    <div>
                        <div class="turf-label">${escapeHtml(t.label)}</div>
                        <div class="turf-zone">${escapeHtml(t.zone)}${t.capturable ? '' : ' · locked'}</div>
                    </div>
                </div>
                <span class="turf-holder ${holderCls}">${escapeHtml(t.holder || '—')}</span>
            </div>
            ${influenceBar(t.influence, t.myInfluence)}
            <div class="turf-actions">
                ${t.center || t.coords ? `<button class="btn btn-ghost btn-sm" data-turfwp='${escapeHtml(JSON.stringify(t.center || t.coords))}'><i class="fas fa-map-pin"></i> Waypoint</button>` : ''}
            </div>
        </div>`;
    }).join('');

    wireTurfButtons(grid);
}

// One stacked bar showing how a block is split between crews. This is the
// whole territory system in a single row: a rival at 40% of your turf is
// something you can see without any of it being a countdown to losing it.
function influenceBar(shares, mine) {
    if (!Array.isArray(shares) || !shares.length) return '';
    const total = shares.reduce((a, s) => a + s.influence, 0);
    const slack = Math.max(0, 100 - total);

    return `<div class="influence">
        <div class="influence-bar">
            ${shares.map((s) => `<span class="influence-seg"
                style="width:${s.influence}%; background:${escapeHtml(s.gangColor)}"
                title="${escapeHtml(s.gangLabel)} ${s.influence}%"></span>`).join('')}
            ${slack > 0 ? `<span class="influence-seg is-slack" style="width:${slack}%"></span>` : ''}
        </div>
        <div class="influence-keys">
            ${shares.map((s) => `<span class="influence-key">
                <i style="background:${escapeHtml(s.gangColor)}"></i>${escapeHtml(s.gangLabel)} ${s.influence}%
            </span>`).join('')}
            ${mine ? `<span class="influence-key mine">You ${mine}%</span>` : ''}
        </div>
    </div>`;
}

// A tiny plan view of the zone's own footprint, normalised into a 40x40
// box. Zones drawn by hand all look different, so this makes the list
// scannable in a way "Grove Street / Ballas" never is.
function turfShape(t, color) {
    if (t.points && t.points.length >= 3) {
        const xs = t.points.map((p) => p.x);
        const ys = t.points.map((p) => p.y);
        const minX = Math.min(...xs), maxX = Math.max(...xs);
        const minY = Math.min(...ys), maxY = Math.max(...ys);
        // Uniform scale on the larger axis keeps the real proportions —
        // stretching to fill would make every zone look like a square.
        const span = Math.max(maxX - minX, maxY - minY) || 1;
        const offX = (40 - ((maxX - minX) / span) * 34) / 2;
        const offY = (40 - ((maxY - minY) / span) * 34) / 2;
        const pts = t.points.map((p) => {
            const x = offX + ((p.x - minX) / span) * 34;
            // World Y grows north; SVG Y grows down.
            const y = offY + ((maxY - p.y) / span) * 34;
            return `${x.toFixed(1)},${y.toFixed(1)}`;
        }).join(' ');
        return `<div class="turf-shape" style="color:${escapeHtml(color)}">
            <svg viewBox="0 0 40 40"><polygon points="${pts}"></polygon></svg></div>`;
    }
    return `<div class="turf-shape" style="color:${escapeHtml(color)}">
        <svg viewBox="0 0 40 40"><circle cx="20" cy="20" r="14"></circle></svg></div>`;
}

function wireTurfButtons(scope) {
    scope.querySelectorAll('[data-claim]').forEach((b) => {
        b.onclick = async () => {
            const res = await call('XS-CriminalTablet:capture:start', b.dataset.claim);
            if (res && res.ok && res.note) flash(res.note, 'info');
            if (report(res, res && res.note ? null : 'Your crew is working it.')) refreshTerritories();
        };
    });
    scope.querySelectorAll('[data-turfwp]').forEach((b) => {
        b.onclick = () => {
            try { nui('setWaypoint', JSON.parse(b.dataset.turfwp)); } catch (e) { /* malformed, ignore */ }
        };
    });
}

$$('#turfFilters .pill').forEach((p) => {
    p.onclick = () => {
        state.turfFilter = p.dataset.turf;
        $$('#turfFilters .pill').forEach((x) => x.classList.toggle('is-active', x === p));
        renderTurf();
    };
});

// ═══════════════════════════════════════════════════════════
// WAR ROOM
// ═══════════════════════════════════════════════════════════
async function renderWar() {
    const data = await call('XS-CriminalTablet:war:getOverview');
    if (!data) return;

    state.war = data.active || null;
    state.stash = data.stash || null;
    renderWarChip();

    // Active engagement
    const activeEl = $('#warActive');
    if (data.active) {
        const w = data.active;
        const isRaid = w.kind === 'raid';
        const pct = isRaid
            ? Math.min(100, ((w.holdProgress || 0) / Math.max(1, w.holdTarget)) * 100)
            : Math.max(2, Math.min(98, 50 + (((w.scoreAttack || 0) - (w.scoreDefend || 0)) / Math.max(1, w.scoreToWin)) * 50));

        const aColor = w.attackerColor || '#f5a524';
        const dColor = w.defenderColor || '#e5484d';
        // Each side's half is washed in its own gang colour, so you can
        // tell at a glance who is who without reading the labels.
        activeEl.style.setProperty('--war-a', aColor);
        activeEl.style.setProperty('--war-d', dColor);

        activeEl.classList.remove('hidden');
        activeEl.innerHTML = `
            <div class="war-kind">${isRaid ? (w.phase === 'prep' ? 'RAID STAGING' : 'RAID IN PROGRESS') : 'WAR IN PROGRESS'}</div>
            <div class="war-sides">
                <div class="war-side">
                    <span class="war-side-tag">${isRaid ? 'Attacking' : 'Declared'}</span>
                    <div class="war-side-name" style="color:${escapeHtml(aColor)}">${escapeHtml(w.attackerLabel)}</div>
                    <div class="war-side-score">${w.scoreAttack || 0}</div>
                </div>
                <div class="war-vs">VS</div>
                <div class="war-side right">
                    <span class="war-side-tag">Defending</span>
                    <div class="war-side-name" style="color:${escapeHtml(dColor)}">${escapeHtml(w.defenderLabel)}</div>
                    <div class="war-side-score">${w.scoreDefend || 0}</div>
                </div>
            </div>
            <div class="war-bar">
                <div class="war-bar-fill" style="width:${pct}%; background:${escapeHtml(aColor)}; color:${escapeHtml(aColor)}"></div>
                ${isRaid ? '' : '<div class="war-bar-mid"></div>'}
            </div>
            <div class="war-foot">
                <span>${isRaid
                    ? (w.phase === 'prep' ? 'The defenders have been warned — they know you are coming'
                                          : `Hold ${w.holdTarget}s uncontested at their HQ`)
                    : `First to lead by ${w.scoreToWin} takes it`}</span>
                <span class="war-clock">${w.phase === 'prep'
                    ? 'Live in ' + countdown(w.startsAt)
                    : countdown(w.endsAt) + ' left'}</span>
            </div>`;
    } else {
        activeEl.classList.add('hidden');
    }

    // Stash window
    const stashEl = $('#stashBanner');
    if (data.stash) {
        stashEl.classList.remove('hidden');
        stashEl.innerHTML = `
            <i class="fas fa-sack-dollar"></i>
            <div class="stash-main">
                <div class="stash-title">${escapeHtml(data.stash.loserLabel)}'s safe is exposed</div>
                <div class="muted">Get to it before the window closes — ${countdown(data.stash.expiresAt)} left.</div>
            </div>
            <button class="btn btn-accent btn-sm" data-stashwp><i class="fas fa-map-pin"></i> Waypoint</button>`;
        stashEl.querySelector('[data-stashwp]').onclick = () => nui('setWaypoint', data.stash.coords);
    } else {
        stashEl.classList.add('hidden');
    }

    // Stats
    const fought = data.warWins + data.warLosses;
    $('#warStats').innerHTML = statGrid([
        { label: 'Record', icon: 'fa-crosshairs', value: `${data.warWins}–${data.warLosses}`,
          sub: fought ? `${fought} fought` : 'never fought' },
        { label: 'Treasury', icon: 'fa-sack-dollar', value: money(data.bank) },
        { label: 'Raid cost', icon: 'fa-fire', value: money(data.raidCost),
          sub: data.bank >= data.raidCost ? 'affordable' : 'too expensive' },
        { label: 'War cost', icon: 'fa-skull', value: money(data.warCost),
          sub: data.bank >= data.warCost ? 'affordable' : 'too expensive' },
    ]);

    // The single most useful thing to tell someone opening this tab is why
    // they can't do the thing they came here to do.
    let hint = 'Raids hit a rival HQ for cash and turf. A war is longer and opens their safe if you win.';
    if (!data.hasHq) hint = 'Place your Crew HQ first — you need one before anyone will take you seriously, and rivals need one to raid.';
    else if (!data.hasSafe) hint = 'You have no Crew Safe placed, so there is nothing for a rival to loot if you lose a war. Placing one is opting into risk.';
    else if (data.raidCooldown > Date.now()) hint = `Your crew can raid again in ${countdown(data.raidCooldown)}.`;
    $('#warHint').textContent = hint;

    // Rivals
    const list = $('#rivalList');
    const rivals = data.rivals || [];
    if (!rivals.length) {
        list.innerHTML = '<div class="empty"><i class="fas fa-user-group"></i>No other crews on the server yet.</div>';
    } else {
        list.innerHTML = rivals.map((r) => `
            <div class="tile">
                <span class="tile-avatar" style="border-color:${escapeHtml(r.color || '#333')};color:${escapeHtml(r.color || '#ccc')}">${escapeHtml(initials(r.label))}</span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(r.label)}
                        ${r.immune ? '<span class="tag-inactive">RECOVERING</span>' : ''}
                        ${!r.hasHq ? '<span class="tag-inactive">NO HQ</span>' : ''}
                    </span>
                    <span class="tile-sub">
                        ${escapeHtml(r.tier)} · ${num(r.rep)} rep · ${r.members} member${r.members === 1 ? '' : 's'}
                        · ${r.zones} zone${r.zones === 1 ? '' : 's'} · ${r.warWins}–${r.warLosses}
                    </span>
                </div>
                <div class="tile-stat">${r.online} online</div>
                <div class="tile-actions">
                    <button class="btn btn-ghost btn-sm" data-raid="${r.id}"
                        ${!data.canRaid || !r.hasHq || r.immune || data.active ? 'disabled' : ''}>
                        <i class="fas fa-fire"></i> Raid
                    </button>
                    <button class="btn btn-danger btn-sm" data-declare="${r.id}"
                        ${!data.canDeclare || data.active ? 'disabled' : ''}>
                        <i class="fas fa-skull"></i> War
                    </button>
                </div>
            </div>`).join('');

        list.querySelectorAll('[data-raid]').forEach((b) => {
            b.onclick = async () => {
                const res = await call('XS-CriminalTablet:war:startRaid', Number(b.dataset.raid));
                if (report(res, 'Raid staged — move out.')) renderWar();
            };
        });
        list.querySelectorAll('[data-declare]').forEach((b) => {
            b.onclick = async () => {
                const res = await call('XS-CriminalTablet:war:declare', Number(b.dataset.declare));
                if (report(res, 'War declared.')) renderWar();
            };
        });
    }

    // History
    const hist = data.history || [];
    const myId = state.gang && state.gang.id;
    $('#warHistory').innerHTML = hist.length ? hist.map((h) => {
        const won = h.winner_id === myId;
        const drawn = !h.winner_id;
        return `<div class="log">
            <span class="log-cat war"><i class="fas ${h.kind === 'raid' ? 'fa-fire' : 'fa-skull'}"></i></span>
            <span class="log-msg">${escapeHtml(h.attacker_label || '?')} vs ${escapeHtml(h.defender_label || '?')} —
                <strong style="color:${drawn ? 'var(--muted)' : (won ? 'var(--good)' : 'var(--danger)')}">
                    ${drawn ? 'stalemate' : (won ? 'won' : 'lost')}
                </strong></span>
            <span class="log-time">${escapeHtml(formatTime(h.finished_at))}</span>
        </div>`;
    }).join('') : '<div class="log-empty">No engagements yet.</div>';
}

// ═══════════════════════════════════════════════════════════
// CONTRACTS
// ═══════════════════════════════════════════════════════════
let contractCategories = [];

async function renderContracts() {
    const [status, board, boardStatus] = await Promise.all([
        call('XS-CriminalTablet:tasks:getStatus'),
        call('XS-CriminalTablet:tasks:getAvailable'),
        call('XS-CriminalTablet:contracts:getStatus'),
    ]);

    if (status) {
        $('#taskRankNum').textContent = status.level;
        $('#taskRankTitle').textContent = status.title;
        $('#taskTotalCompleted').textContent = `${status.totalCompleted} job${status.totalCompleted === 1 ? '' : 's'} completed`;
        const pct = status.xpNeeded ? Math.min(100, (status.xp / status.xpNeeded) * 100) : 100;
        $('#taskXpFill').style.width = pct + '%';
        $('#taskXpLabel').textContent = status.xpNeeded ? `${num(status.xp)} / ${num(status.xpNeeded)} XP` : `${num(status.xp)} XP — maxed`;
        $('#cancelTaskBtn').classList.toggle('hidden', !status.active);
    }

    if (boardStatus) {
        contractCategories = boardStatus.categories || [];
        $('#boardRotation').textContent = boardStatus.enabled && boardStatus.nextRotationAt
            ? `Rerolls in ${countdown(boardStatus.nextRotationAt)}`
            : '';
        renderContractFilters();
    }

    renderContractList((board && board.tasks) || []);
    renderDealer();
}

function renderContractFilters() {
    const cats = [{ id: 'all', label: 'All', icon: 'fa-border-all' }, ...contractCategories];
    $('#contractFilters').innerHTML = cats.map((c) =>
        `<button class="pill ${state.contractFilter === c.id ? 'is-active' : ''}" data-cat="${escapeHtml(c.id)}">
            <i class="fas ${escapeHtml(c.icon || 'fa-circle')}"></i> ${escapeHtml(c.label)}
        </button>`).join('');
    $$('#contractFilters .pill').forEach((p) => {
        p.onclick = () => { state.contractFilter = p.dataset.cat; renderContracts(); };
    });
}

function catOf(id) {
    return contractCategories.find((c) => c.id === id) || { label: id, icon: 'fa-circle' };
}

function renderContractList(list) {
    const el = $('#taskList');
    const shown = (list || []).filter((t) => state.contractFilter === 'all' || t.category === state.contractFilter);

    if (!shown.length) {
        el.innerHTML = '<div class="empty"><i class="fas fa-file-circle-xmark"></i>Nothing on the board right now.</div>';
        return;
    }

    el.innerHTML = shown.map((t, i) => {
        const cat = catOf(t.category);
        const onCooldown = t.cooldownMs > 0;
        const mins = Math.ceil(t.cooldownMs / 60000);
        // A stable job code off the contract id — dossier flavour, and it
        // gives support something to quote when a job misbehaves.
        const code = String(t.id).toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6).padEnd(6, 'X');
        return `<div class="contract ${t.locked ? 'is-locked' : ''} rise" style="--i:${i}">
            <div class="contract-top">
                <span class="contract-cat"><i class="fas ${escapeHtml(cat.icon)}"></i>${escapeHtml(cat.label)}</span>
                <span class="difficulty">${[1, 2, 3, 4, 5].map((n) => `<i class="${n <= (t.difficulty || 1) ? 'on' : ''}"></i>`).join('')}</span>
            </div>
            <div>
                <div class="contract-name">${escapeHtml(t.label)}</div>
                <div class="contract-code">JOB-${escapeHtml(code)} · ${escapeHtml(t.type)}</div>
            </div>
            <div class="contract-rewards">
                <div class="reward"><span class="reward-value">+${num(t.reward)}</span><span class="reward-label">Rep</span></div>
                ${t.cash ? `<div class="reward"><span class="reward-value">${money(t.cash)}</span><span class="reward-label">Cash</span></div>` : ''}
                <div class="reward"><span class="reward-value">+${num(t.xp)}</span><span class="reward-label">XP</span></div>
            </div>
            <button class="btn ${t.locked || onCooldown ? 'btn-ghost' : 'btn-accent'} btn-sm" data-task="${escapeHtml(t.id)}"
                ${t.locked || onCooldown || !can('accept_contracts') ? 'disabled' : ''}>
                ${t.locked ? `Needs rank ${t.minLevel}` : (onCooldown ? `Cooldown ${mins}m` : 'Take the job')}
            </button>
        </div>`;
    }).join('');

    el.querySelectorAll('[data-task]').forEach((b) => {
        b.onclick = async () => {
            const res = await call('XS-CriminalTablet:tasks:accept', b.dataset.task);
            if (report(res, 'Job accepted — check your map.')) nui('close');
        };
    });
}

$('#cancelTaskBtn').onclick = async () => {
    const res = await call('XS-CriminalTablet:tasks:cancel');
    if (report(res, 'Job cancelled.')) renderContracts();
};

async function renderTaskBadges() {
    const list = await call('XS-CriminalTablet:tasks:getAchievements');
    const el = $('#taskBadgeList');
    if (!Array.isArray(list) || !list.length) {
        el.innerHTML = '<div class="empty"><i class="fas fa-medal"></i>No badges configured.</div>';
        return;
    }
    el.innerHTML = list.map((b) => `
        <div class="badge ${b.earned ? 'earned' : ''}">
            <span class="badge-icon"><i class="fas ${b.earned ? 'fa-medal' : 'fa-lock'}"></i></span>
            <div class="badge-text">
                <div class="badge-name">${escapeHtml(b.label)}</div>
                <div class="badge-desc">${escapeHtml(b.description)}</div>
            </div>
        </div>`).join('');
}

async function renderTaskLeaderboard() {
    const rows = await call('XS-CriminalTablet:tasks:getLeaderboard');
    const el = $('#taskLeaderboard');
    if (!Array.isArray(rows) || !rows.length) {
        el.innerHTML = '<div class="empty"><i class="fas fa-ranking-star"></i>Nobody has finished a contract yet.</div>';
        return;
    }
    el.innerHTML = rows.map((r, i) => `
        <div class="tile">
            <span class="tile-avatar">${i + 1}</span>
            <div class="tile-main">
                <span class="tile-name">${escapeHtml(r.name)}</span>
                <span class="tile-sub">Rank ${r.level} · ${r.badges} badge${r.badges === 1 ? '' : 's'}</span>
            </div>
            <div class="tile-stat">${num(r.total_completed)} jobs</div>
        </div>`).join('');
}

const taskInvitePS = attachPlayerSearch($('#taskInviteId'));

async function renderTaskCrew() {
    const status = await call('XS-CriminalTablet:tasks:getCrewStatus');
    const list = $('#taskCrewList');
    const members = (status && status.members) || [];

    $('#taskCancelCrewBtn').classList.toggle('hidden', !(status && status.isLeader));

    if (!members.length) {
        list.innerHTML = '<div class="empty"><i class="fas fa-user-group"></i>No crew yet — invite someone to run a harder job together.</div>';
        $('#taskCoopPicker').classList.add('hidden');
        return;
    }

    list.innerHTML = members.map((m) => `
        <div class="tile">
            <span class="tile-avatar">${escapeHtml(initials(m.name))}</span>
            <div class="tile-main">
                <span class="tile-name">${escapeHtml(m.name)}${m.isLeader ? ' <span class="tag-owner">LEAD</span>' : ''}</span>
            </div>
        </div>`).join('');

    if (status.isLeader) {
        const tasks = await call('XS-CriminalTablet:tasks:getCoopTasks');
        const picker = $('#taskCoopPicker');
        picker.classList.remove('hidden');
        picker.innerHTML = (tasks || []).map((t) => {
            const cat = catOf(t.category);
            return `<div class="contract">
                <div class="contract-top">
                    <span class="contract-cat"><i class="fas ${escapeHtml(cat.icon)}"></i>${escapeHtml(cat.label)}</span>
                    ${t.coopOnly ? '<span class="flag">CO-OP</span>' : ''}
                </div>
                <div class="contract-name">${escapeHtml(t.label)}</div>
                <div class="contract-rewards">
                    <div class="reward"><span class="reward-value">+${num(t.reward)}</span><span class="reward-label">Rep</span></div>
                    ${t.cash ? `<div class="reward"><span class="reward-value">${money(t.cash)}</span><span class="reward-label">Cash</span></div>` : ''}
                </div>
                <button class="btn btn-accent btn-sm" data-coop="${escapeHtml(t.id)}">Start together</button>
            </div>`;
        }).join('');

        picker.querySelectorAll('[data-coop]').forEach((b) => {
            b.onclick = async () => {
                const res = await call('XS-CriminalTablet:tasks:acceptCoop', b.dataset.coop);
                if (report(res, 'Crew job started.')) nui('close');
            };
        });
    }
}

$('#taskInviteBtn').onclick = async () => {
    const id = taskInvitePS.selected();
    if (!id) return flash('Pick someone from the list first.', 'error');
    const res = await call('XS-CriminalTablet:tasks:inviteCoop', id);
    if (report(res, 'Invite sent.')) { taskInvitePS.clear(); renderTaskCrew(); }
};

$('#taskCancelCrewBtn').onclick = async () => {
    const res = await call('XS-CriminalTablet:tasks:cancelCrew');
    if (report(res, 'Crew disbanded.')) renderTaskCrew();
};

async function renderDealer() {
    const status = await call('XS-CriminalTablet:dealer:getStatus');
    const el = $('#dealerStatus');
    if (!status) { el.textContent = 'unavailable'; return; }
    if (status.active) el.textContent = 'A dealer is out right now';
    else if (status.cooldownMs > 0) el.textContent = `Back in ${Math.ceil(status.cooldownMs / 3600000)}h`;
    else el.textContent = 'Available';
    $('#callDealerBtn').disabled = !!(status.active || status.cooldownMs > 0);
}

$('#callDealerBtn').onclick = async () => {
    const res = await call('XS-CriminalTablet:dealer:contact');
    if (report(res, 'Dealer is on the way — check your map.')) { renderDealer(); nui('close'); }
};

// ═══════════════════════════════════════════════════════════
// GARAGE
// ═══════════════════════════════════════════════════════════
async function renderGarage() {
    const data = await call('XS-CriminalTablet:garage:list');
    const list = $('#garageList');
    if (!data) return;

    $('#garageSlots').textContent = `${data.used} / ${data.slots}`;
    $('#garageStoreBtn').disabled = !data.canStore || !data.point;
    $('#garageHint').textContent = data.point
        ? `Vehicles come out at your placed garage point — you have to be within ${Math.round(data.spawnRadius)}m of it.`
        : 'Your crew has not placed a Garage Point yet. Place one from Hub > Property first.';

    const vehicles = data.vehicles || [];
    if (!vehicles.length) {
        list.innerHTML = '<div class="empty"><i class="fas fa-car-side"></i>No vehicles in the crew garage.</div>';
        return;
    }

    list.innerHTML = vehicles.map((v) => `
        <div class="tile ${v.stored ? '' : 'is-danger'}">
            <span class="tile-avatar"><i class="fas fa-car-side"></i></span>
            <div class="tile-main">
                <span class="tile-name">${escapeHtml(v.label || v.model)}</span>
                <span class="tile-sub">
                    <span style="font-family:var(--mono)">${escapeHtml(v.plate)}</span>
                    · ${v.stored ? 'in the garage' : '<span style="color:var(--danger)">out right now</span>'}
                </span>
            </div>
            <div class="tile-actions">
                <button class="btn btn-accent btn-sm" data-take="${v.id}" ${!v.stored || !data.canTake || !data.point ? 'disabled' : ''}>
                    <i class="fas fa-key"></i> Take out
                </button>
                <button class="btn btn-danger btn-sm" data-delveh="${v.id}" ${!data.canDelete ? 'disabled' : ''} title="Scrap">
                    <i class="fas fa-trash"></i>
                </button>
            </div>
        </div>`).join('');

    list.querySelectorAll('[data-take]').forEach((b) => {
        b.onclick = () => nui('garageTake', { id: Number(b.dataset.take) });
    });
    list.querySelectorAll('[data-delveh]').forEach((b) => {
        b.onclick = async () => {
            const res = await call('XS-CriminalTablet:garage:delete', Number(b.dataset.delveh));
            if (report(res, 'Scrapped.')) renderGarage();
        };
    });
}

$('#garageStoreBtn').onclick = () => nui('garageStore');

// ═══════════════════════════════════════════════════════════
// TREASURY
// ═══════════════════════════════════════════════════════════
function renderTreasury() {
    const g = state.gang;
    if (!g) return;

    countUp($('#bankBalance'), g.bank, money);
    $('#treasuryTier').textContent = g.tier;
    $('#treasuryRep').textContent = `${num(g.rep)} rep`;
    $('#withdrawBtn').disabled = !can('bank_withdraw');

    renderLedger();
}

async function renderLedger() {
    const rows = await call('XS-CriminalTablet:bankGetLedger');
    const el = $('#bankLedger');
    if (!Array.isArray(rows) || !rows.length) {
        el.innerHTML = can('bank_ledger')
            ? '<div class="log-empty">No transactions yet.</div>'
            : '<div class="log-empty">Your rank cannot read the ledger.</div>';
        return;
    }
    el.innerHTML = rows.map((r) => {
        const negative = ['withdraw', 'upgrade', 'unlock'].includes(r.kind) || r.amount < 0;
        const amount = Math.abs(r.amount);
        return `<div class="ledger">
            <span class="ledger-kind ${escapeHtml(r.kind)}">${escapeHtml(r.kind)}</span>
            <span class="ledger-name">${escapeHtml(r.name)}</span>
            <span class="ledger-amount ${negative ? 'minus' : 'plus'}">${negative ? '−' : '+'}${money(amount)}</span>
            <span class="ledger-time">${escapeHtml(formatTime(r.created_at))}</span>
        </div>`;
    }).join('');
}

async function bankAction(name) {
    const amount = Number($('#bankAmount').value);
    if (!amount || amount <= 0) return flash('Enter an amount first.', 'error');
    const res = await call(name, amount);
    if (res && res.ok) {
        $('#bankAmount').value = '';
        state.gang.bank = res.balance;
        flash(name.includes('Deposit') ? `Deposited ${money(amount)}.` : `Withdrew ${money(amount)}.`, 'success');
        renderTreasury();
        refreshSnapshotQuiet();
    } else {
        flash((res && res.error) || 'That did not work', 'error');
    }
}
$('#depositBtn').onclick = () => bankAction('XS-CriminalTablet:bankDeposit');
$('#withdrawBtn').onclick = () => bankAction('XS-CriminalTablet:bankWithdraw');

const EFFECT_LABELS = {
    maxMembersBonus: (v) => `+${v} members`,
    vaultSlotsBonus: (v) => `+${v} vault slots`,
    vaultWeightBonusPct: (v) => `+${v}% vault weight`,
    garageSlotsBonus: (v) => `+${v} garage bays`,
    raidRewardPct: (v) => `+${v}% raid cut`,
    captureSpeedPct: (v) => `+${v}% capture speed`,
};

async function renderUpgrades() {
    const data = await call('XS-CriminalTablet:upgrades:getTracks');
    const grid = $('#upgradeGrid');
    if (!data) return;

    $('#upgradeBank').textContent = money(data.bank);
    const tracks = data.tracks || [];

    if (!tracks.length) {
        grid.innerHTML = '<div class="empty"><i class="fas fa-arrow-up-right-dots"></i>No upgrades configured.</div>';
        return;
    }

    grid.innerHTML = tracks.map((t, i) => {
        const maxed = t.level >= t.maxLevel;
        const nextStep = t.steps[t.level];
        const effects = nextStep ? nextStep.effects.map((e) =>
            `<span class="effect">${escapeHtml((EFFECT_LABELS[e.key] || ((v) => `${e.key} ${v}`))(e.value))}</span>`).join('') : '';

        return `<div class="upgrade ${maxed ? 'is-max' : ''} rise" style="--i:${i}">
            <div class="upgrade-top">
                <span class="upgrade-icon"><i class="fas ${escapeHtml(t.icon)}"></i></span>
                <div>
                    <div class="upgrade-name">${escapeHtml(t.label)}</div>
                    <div class="muted">Level ${t.level} / ${t.maxLevel}</div>
                </div>
            </div>
            <div class="upgrade-desc">${escapeHtml(t.description)}</div>
            <div class="pips">${t.steps.map((s) => `<span class="pip ${s.owned ? 'on' : ''}"></span>`).join('')}</div>
            ${effects ? `<div class="upgrade-effects">${effects}</div>` : ''}
            <div class="upgrade-foot">
                <span class="muted">${maxed ? 'Fully upgraded' : `Next: ${money(t.nextCost)}`}</span>
                <button class="btn btn-accent btn-sm" data-upgrade="${escapeHtml(t.id)}"
                    ${maxed || !t.affordable || !data.canBuy ? 'disabled' : ''}>Buy</button>
            </div>
        </div>`;
    }).join('');

    grid.querySelectorAll('[data-upgrade]').forEach((b) => {
        b.onclick = async () => {
            const res = await call('XS-CriminalTablet:upgrades:buy', b.dataset.upgrade);
            if (report(res, 'Upgraded.')) { renderUpgrades(); refreshSnapshotQuiet(); }
        };
    });
}

async function renderPerks() {
    const data = await call('XS-CriminalTablet:gangperks:getTree');
    const tree = $('#perkTree');
    if (!data) return;

    $('#gangPerkPoints').textContent = data.perkPoints || 0;
    const branches = data.branches || [];

    if (!branches.length) {
        tree.innerHTML = '<div class="empty"><i class="fas fa-diagram-project"></i>No perks configured.</div>';
        return;
    }

    tree.innerHTML = branches.map((b) => `
        <div class="perk-branch">
            <div class="perk-branch-head"><i class="fas ${escapeHtml(b.icon)}"></i>${escapeHtml(b.label)}</div>
            ${b.tiers.map((t) => `
                <div class="perk-node ${t.owned ? 'owned' : ''} ${t.locked ? 'locked' : ''}">
                    <div class="perk-node-top">
                        <span class="perk-name">${escapeHtml(t.label)}</span>
                        <span class="perk-cost">${t.owned ? '<i class="fas fa-check"></i>' : `${t.cost} pt${t.cost === 1 ? '' : 's'}`}</span>
                    </div>
                    <div class="perk-desc">${escapeHtml(t.description)}</div>
                    ${t.owned ? '' : `<button class="btn btn-accent btn-sm" data-perk="${escapeHtml(t.id)}"
                        ${t.locked || !t.affordable || !can('manage_perks') ? 'disabled' : ''}>
                        ${t.locked ? 'Buy the tier below first' : 'Buy'}</button>`}
                </div>`).join('')}
        </div>`).join('');

    tree.querySelectorAll('[data-perk]').forEach((b) => {
        b.onclick = async () => {
            const res = await call('XS-CriminalTablet:gangperks:buyPerk', b.dataset.perk);
            if (report(res, 'Perk bought.')) { renderPerks(); refreshSnapshotQuiet(); }
        };
    });
}

// ═══════════════════════════════════════════════════════════
// STANDING
// ═══════════════════════════════════════════════════════════
async function renderStanding() {
    const data = await call('XS-CriminalTablet:analytics:getStandings');
    const table = $('#standingTable');
    if (!data) return;

    if (data.error) {
        $('#standingBreakdown').innerHTML = '';
        table.innerHTML = `<div class="empty"><i class="fas fa-lock"></i>${escapeHtml(data.error)}</div>`;
        return;
    }

    const b = data.breakdown;
    // A rank is only meaningful against the field size, so every tile
    // carries "of N" rather than a bare position.
    $('#standingBreakdown').innerHTML = b ? statGrid([
        { label: 'Overall', icon: 'fa-ranking-star', value: `#${b.overall}`, sub: `of ${b.total} crews` },
        { label: 'Rep', icon: 'fa-fire', value: `#${b.rep}`, sub: `of ${b.total}` },
        { label: 'Territory', icon: 'fa-map-location-dot', value: `#${b.territory}`, sub: `of ${b.total}` },
        { label: 'Members', icon: 'fa-users', value: `#${b.members}`, sub: `of ${b.total}` },
        { label: 'Wars won', icon: 'fa-crosshairs', value: `#${b.wars}`, sub: `of ${b.total}` },
    ]) : '';

    const gangs = data.gangs || [];
    if (!gangs.length) {
        table.innerHTML = '<div class="empty"><i class="fas fa-ranking-star"></i>No crews ranked yet.</div>';
        return;
    }

    const topScore = Math.max(1, ...gangs.map((g) => g.score || 0));

    table.innerHTML = gangs.map((g) => `
        <div class="standing ${g.mine ? 'is-mine' : ''}"
             style="--score:${((g.score || 0) / topScore) * 100}%; --row:${escapeHtml(g.color || '#666')}">
            <span class="standing-rank ${g.rank === 1 ? 'top' : ''}">${g.rank}</span>
            <span class="standing-swatch" style="background:${escapeHtml(g.color || '#666')}"></span>
            <div class="standing-main">
                <div class="standing-name">${escapeHtml(g.label)}</div>
                <div class="standing-sub">${escapeHtml(g.tier)} · ${escapeHtml(g.levelTitle)} · ${g.online} online</div>
            </div>
            <div class="standing-metrics">
                <div class="metric"><div class="metric-value">${num(g.rep)}</div><div class="metric-label">Rep</div></div>
                <div class="metric"><div class="metric-value">${g.zones}</div><div class="metric-label">Turf</div></div>
                <div class="metric"><div class="metric-value">${g.members}</div><div class="metric-label">Crew</div></div>
                <div class="metric"><div class="metric-value">${g.warWins}</div><div class="metric-label">Wars</div></div>
                ${g.treasury !== null && g.treasury !== undefined
                    ? `<div class="metric"><div class="metric-value">${money(g.treasury)}</div><div class="metric-label">Bank</div></div>` : ''}
            </div>
            <span class="standing-score">${num(g.score)}</span>
        </div>`).join('');
}

// ═══════════════════════════════════════════════════════════
// BLACKMARKET
// ═══════════════════════════════════════════════════════════
let blackmarketLoaded = false;
let dmActiveHandle = null;
let myHandle = null;

async function renderBlackmarket() {
    if (!blackmarketLoaded) {
        myHandle = await call('XS-CriminalTablet:chat:getMyHandle');
        $('#myHandle').textContent = myHandle || '—';
        blackmarketLoaded = true;
    }
    renderWorldFeed();
    renderDMThreads();
}

function appendChatBubble(container, handle, message, mine) {
    const el = document.createElement('div');
    el.className = 'bubble' + (mine ? ' mine' : '');
    el.innerHTML = `<span class="bubble-handle">${escapeHtml(handle)}</span>
                    <span class="bubble-text">${escapeHtml(message)}</span>`;
    container.appendChild(el);
    container.scrollTop = container.scrollHeight;
}

async function renderWorldFeed() {
    const feed = $('#worldFeed');
    const rows = await call('XS-CriminalTablet:chat:getWorldHistory');
    feed.innerHTML = '';
    if (!Array.isArray(rows) || !rows.length) {
        feed.innerHTML = '<div class="log-empty">Feed is quiet.</div>';
        return;
    }
    rows.forEach((m) => appendChatBubble(feed, m.handle, m.message, m.handle === myHandle));
}

function onWorldMessage(m) {
    const feed = $('#worldFeed');
    if (!feed) return;
    const empty = feed.querySelector('.log-empty');
    if (empty) empty.remove();
    appendChatBubble(feed, m.handle, m.message, m.handle === myHandle);
}

$('#worldSendBtn').onclick = async () => {
    const input = $('#worldInput');
    const text = input.value.trim();
    if (!text) return;
    input.value = '';
    const res = await call('XS-CriminalTablet:chat:postWorld', text);
    if (res && !res.ok) flash(res.error || 'Could not post that', 'error');
};
$('#worldInput').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('#worldSendBtn').click(); });

async function renderDMThreads() {
    const threads = await call('XS-CriminalTablet:chat:getThreads');
    const list = $('#dmThreadList');
    $('#dmConversation').classList.add('hidden');
    list.classList.remove('hidden');

    if (!Array.isArray(threads) || !threads.length) {
        list.innerHTML = '<div class="empty"><i class="fas fa-comment-slash"></i>No conversations yet.</div>';
        return;
    }
    list.innerHTML = threads.map((t) => `
        <div class="tile" data-thread="${escapeHtml(t.handle)}" style="cursor:pointer">
            <span class="tile-avatar"><i class="fas fa-user-secret"></i></span>
            <div class="tile-main">
                <span class="tile-name">${escapeHtml(t.handle)}</span>
                <span class="tile-sub">${escapeHtml(t.lastMessage || '')}</span>
            </div>
            ${t.unread ? `<span class="count">${t.unread}</span>` : ''}
        </div>`).join('');

    list.querySelectorAll('[data-thread]').forEach((row) => {
        row.onclick = () => openDMThread(row.dataset.thread);
    });
}

async function openDMThread(handle) {
    dmActiveHandle = handle;
    $('#dmThreadList').classList.add('hidden');
    $('#dmConversation').classList.remove('hidden');

    const feed = $('#dmFeed');
    feed.innerHTML = '';
    const rows = await call('XS-CriminalTablet:chat:getThread', handle);
    if (!Array.isArray(rows) || !rows.length) {
        feed.innerHTML = '<div class="log-empty">Nothing here yet.</div>';
        return;
    }
    rows.forEach((m) => appendChatBubble(feed, m.from_handle, m.message, m.from_handle === myHandle));
}

function onDMReceived(m) {
    if (dmActiveHandle && m.from_handle === dmActiveHandle) {
        const feed = $('#dmFeed');
        const empty = feed.querySelector('.log-empty');
        if (empty) empty.remove();
        appendChatBubble(feed, m.from_handle, m.message, false);
    } else {
        flash(`New message from ${m.from_handle}`, 'info');
    }
}

$('#dmBackBtn').onclick = () => { dmActiveHandle = null; renderDMThreads(); };
$('#dmSendBtn').onclick = async () => {
    const input = $('#dmInput');
    const text = input.value.trim();
    if (!text || !dmActiveHandle) return;
    input.value = '';
    const res = await call('XS-CriminalTablet:chat:sendDM', dmActiveHandle, text);
    if (res && res.ok) appendChatBubble($('#dmFeed'), myHandle, text, true);
    else flash((res && res.error) || 'Could not send that', 'error');
};
$('#dmInput').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('#dmSendBtn').click(); });

$('#dmNewBtn').onclick = () => {
    const handle = $('#dmNewHandle').value.trim();
    if (!handle) return flash('Enter a handle first.', 'error');
    $('#dmNewHandle').value = '';
    openDMThread(handle);
};

$('#editHandleBtn').onclick = () => {
    $('#handleEditRow').classList.remove('hidden');
    $('#handleInput').value = myHandle || '';
    $('#handleInput').focus();
};
$('#cancelHandleBtn').onclick = () => $('#handleEditRow').classList.add('hidden');
$('#saveHandleBtn').onclick = async () => {
    const res = await call('XS-CriminalTablet:chat:setHandle', $('#handleInput').value.trim());
    if (res && res.ok) {
        myHandle = res.handle;
        $('#myHandle').textContent = myHandle;
        $('#handleEditRow').classList.add('hidden');
        flash('Handle updated.', 'success');
    } else {
        flash((res && res.error) || 'Could not change that', 'error');
    }
};

// ═══════════════════════════════════════════════════════════
// INVITES
// ═══════════════════════════════════════════════════════════
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

// ═══════════════════════════════════════════════════════════
// FIELD RADIAL
// A real wheel rather than a list — the slices are generated from
// whatever actions actually make sense where the player is standing.
// ═══════════════════════════════════════════════════════════
const RADIAL_GLYPHS = {
    'fa-spray-can': '', 'fa-warehouse': '', 'fa-kit-medical': '',
    'fa-heart-pulse': '', 'fa-flag': '', 'fa-handcuffs': '',
    'fa-mask': '', 'fa-car-rear': '', 'fa-people-carry-box': '',
    'fa-person-walking': '', 'fa-user-lock': '', 'fa-hand': '',
    'fa-screwdriver': '', 'fa-tablet-screen-button': '',
};

function openRadial(data) {
    const root = $('#radialRoot');
    const svg = $('#radialSvg');
    const items = (data && data.items) || [];

    applyTheme(data && data.color);
    $('#radialHubLabel').textContent = 'FIELD';
    $('#radialHubSub').textContent = (data && data.gang) || '';

    if (!items.length) {
        svg.innerHTML = '';
        root.classList.remove('hidden');
        return;
    }

    const cx = 200, cy = 200, rInner = 72, rOuter = 190;
    const step = (Math.PI * 2) / items.length;
    // Start at the top rather than at 3 o'clock — a wheel reads better
    // when the first slice is where the eye lands.
    const offset = -Math.PI / 2 - step / 2;

    svg.innerHTML = items.map((item, i) => {
        const a0 = offset + step * i;
        const a1 = a0 + step;
        const mid = a0 + step / 2;
        const large = step > Math.PI ? 1 : 0;

        const p = (r, a) => `${cx + r * Math.cos(a)} ${cy + r * Math.sin(a)}`;
        const gap = 0.012; // hairline between slices
        const path = [
            `M ${p(rInner, a0 + gap)}`,
            `L ${p(rOuter, a0 + gap)}`,
            `A ${rOuter} ${rOuter} 0 ${large} 1 ${p(rOuter, a1 - gap)}`,
            `L ${p(rInner, a1 - gap)}`,
            `A ${rInner} ${rInner} 0 ${large} 0 ${p(rInner, a0 + gap)}`,
            'Z',
        ].join(' ');

        const ir = rInner + (rOuter - rInner) * 0.38;
        const tr = rInner + (rOuter - rInner) * 0.68;
        const ix = cx + ir * Math.cos(mid), iy = cy + ir * Math.sin(mid);
        const tx = cx + tr * Math.cos(mid), ty = cy + tr * Math.sin(mid);
        const glyph = RADIAL_GLYPHS[item.icon] || '';

        // Long labels get split rather than clipped.
        const words = String(item.label).split(' ');
        const lines = words.length > 1 && item.label.length > 10
            ? [words.slice(0, Math.ceil(words.length / 2)).join(' '), words.slice(Math.ceil(words.length / 2)).join(' ')]
            : [item.label];

        return `<g class="radial-slice ${item.disabled ? 'disabled' : ''}" data-radial="${escapeHtml(item.id)}">
            <path class="radial-slice-bg" d="${path}"></path>
            <text class="radial-icon" x="${ix}" y="${iy}" style="font-family:'Font Awesome 6 Free';font-weight:900">${glyph}</text>
            ${lines.map((ln, li) => `<text class="radial-text" x="${tx}" y="${ty + (li - (lines.length - 1) / 2) * 11}">${escapeHtml(ln)}</text>`).join('')}
        </g>`;
    }).join('');

    svg.querySelectorAll('[data-radial]').forEach((g) => {
        const item = items.find((x) => x.id === g.dataset.radial);
        g.addEventListener('mouseenter', () => {
            $('#radialHubLabel').textContent = item.label.toUpperCase();
            $('#radialHubSub').textContent = item.note || '';
        });
        g.addEventListener('mouseleave', () => {
            $('#radialHubLabel').textContent = 'FIELD';
            $('#radialHubSub').textContent = (data && data.gang) || '';
        });
        if (item.disabled) return;
        g.addEventListener('click', () => nui('radial:select', { id: item.id }));
    });

    root.classList.remove('hidden');
}

function closeRadial() {
    $('#radialRoot').classList.add('hidden');
}

$('#radialRoot').addEventListener('click', (e) => {
    if (e.target.classList.contains('radial-scrim')) nui('radial:close');
});

// Expose the few things graffiti.js and admin.js need.
window.XS = {
    call, nui, flash, report, escapeHtml, money, num, initials, formatTime,
    applyTheme, state, can, $, $$, statCard, statGrid,
    ensureMap, mapLatLng, mapWorld, plotZone, mapOf: (key) => _maps[key] || null,
};
