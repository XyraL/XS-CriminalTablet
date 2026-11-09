// Rivals app: every other crew, what they have done to you, and a full
// dossier per crew. Everything here is read from the server's own record.
(function () {
    const { escapeHtml: esc, money, num, initials, call, nui } = window.XS;
    let view = 'list';
    let rivalId = null;
    let data = null;
    let dossier = null;

    const ICON = { kill: 'fa-skull', tag: 'fa-spray-can', cover: 'fa-spray-can', work: 'fa-flag', hq: 'fa-eye', raid: 'fa-house-fire', war: 'fa-crosshairs', warreq: 'fa-ban' };
    const ASKED = {
        declined: ['They turned down your war', 'You turned down their war'],
        expired: ['They never answered your war request', 'You let their war request run out'],
        cancelled: ['You took back a war request', 'They took back a war request'],
    };
    const safe = (hex) => (/^#[0-9a-f]{6}$/i.test(hex || '') ? hex : '#94a3b8');
    const ago = (ms) => {
        if (!ms) return '';
        const m = Math.floor((Date.now() - ms) / 60000);
        if (m < 1) return 'just now';
        if (m < 60) return `${m}m ago`;
        const h = Math.floor(m / 60);
        if (h < 24) return `${h}h ago`;
        return `${Math.floor(h / 24)}d ago`;
    };
    const crest = (c, size) => (c.logo
        ? `<span class="rv-crest${size ? ` ${size}` : ''}" style="background:${safe(c.color)}"><img src="${esc(c.logo)}" alt=""></span>`
        : `<span class="rv-crest${size ? ` ${size}` : ''}" style="background:${safe(c.color)}">${esc(initials(c.label))}</span>`);

    // One plain sentence per event, told from your crew's side.
    function line(e, crew) {
        const who = e.name || (e.ours ? 'One of ours' : `Someone from ${crew}`);
        const won = e.detail === 'won';
        switch (e.kind) {
        case 'kill': return e.ours ? `${who} took out ${e.detail}` : `${who} took out ${e.detail}`;
        case 'tag': return e.ours ? `${who} tagged a wall on ${e.detail}` : `${who} tagged a wall on ${e.detail}`;
        case 'cover': return e.ours ? `${who} covered one of their tags` : `${who} covered one of your tags`;
        case 'work': return e.ours ? `You worked their block ${e.detail}` : `They worked your block ${e.detail}`;
        case 'hq': return e.ours ? 'You were seen round their HQ' : `${e.detail} round your HQ`;
        case 'raid': return e.ours ? `You raided them and ${won ? 'won' : 'lost'}` : `They raided you and ${won ? 'won' : 'lost'}`;
        case 'warreq': return (ASKED[e.detail] || ['A war request ended', 'A war request ended'])[e.ours ? 0 : 1];
        case 'war': return e.detail === 'draw' ? 'War ended in a draw' : (e.ours ? `You declared war and ${won ? 'won' : 'lost'}` : `They declared war and ${won ? 'won' : 'lost'}`);
        default: return e.detail || e.kind;
        }
    }

    function waypointBtn(x, y) {
        return x || y ? `<button class="icon-btn" data-wp="${x},${y}" title="Set a waypoint"><i class="fas fa-location-arrow"></i></button>` : '';
    }

    function listView() {
        const feed = (data.feed || []).map((e) => `<div class="tile compact rv-feed">
                <span class="tile-avatar"><i class="fas ${ICON[e.kind] || 'fa-circle-info'}"></i></span>
                <div class="tile-main"><span class="tile-name"><b style="color:${safe(e.color)}">${esc(e.crew)}</b></span>
                    <span class="tile-sub">${esc(line(Object.assign({ ours: false }, e), e.crew))} · ${esc(ago(e.at))}</span></div>
                ${waypointBtn(e.x, e.y)}</div>`).join('');
        const cards = (data.rivals || []).map((r) => `<button class="rv-card" data-rival="${r.id}">
                <div class="rv-cardhead">${crest(r)}<div><b>${esc(r.label)}</b><small>${esc(r.tier)} · LV ${r.level} · ${num(r.members)} members · ${num(r.blocks)} blocks</small></div>
                    ${r.record.week ? `<span class="rv-heat">${r.record.week} this week</span>` : ''}</div>
                <div class="rv-rec">
                    <span><em>Wars</em><b>${r.record.warsWon}–${r.record.warsLost}</b></span>
                    <span><em>Raids</em><b>${r.record.raidsWon}–${r.record.raidsLost}</b></span>
                    <span><em>Kills</em><b>${r.record.killsOurs}–${r.record.killsTheirs}</b></span>
                    <span><em>On your turf</em><b>${r.record.tagsOnUs + r.record.workOnUs}</b></span>
                </div>
                <div class="rv-last">${r.record.last ? `Last run-in ${esc(ago(r.record.last))}` : 'No run-ins yet'}<i class="fas fa-arrow-right"></i></div>
            </button>`).join('');
        return `<h2 class="section-head"><span>Latest moves on you</span></h2>
            <div class="tile-list">${feed || '<div class="empty"><i class="fas fa-shield-halved"></i>Nobody has moved on your crew lately.</div>'}</div>
            <h2 class="section-head"><span>Rival crews</span><span class="count">${(data.rivals || []).length}</span></h2>
            <div class="rv-grid">${cards || '<div class="empty"><i class="fas fa-users-slash"></i>No other crews yet.</div>'}</div>`;
    }

    function dossierView() {
        const d = dossier;
        const c = d.crew;
        const r = d.record;
        const stat = (label, value, sub, icon) => `<div class="stat"><div class="stat-head"><span class="stat-icon"><i class="fas ${icon}"></i></span><span class="stat-label">${esc(label)}</span></div><span class="stat-value">${esc(value)}</span>${sub ? `<span class="stat-sub">${esc(sub)}</span>` : ''}</div>`;
        return `<button class="btn btn-ghost btn-sm rv-back" data-back><i class="fas fa-chevron-left"></i> All rivals</button>
            <div class="rv-hero" style="--rv:${safe(c.color)}">${crest(c, 'big')}
                <div class="rv-heromain"><h1>${esc(c.label)}</h1>
                    <div class="rv-chips"><span class="chip chip-tier">${esc(c.tier)}</span><span class="chip">LV ${c.level} · ${esc(c.levelTitle)}</span>
                        <span class="chip">${num(c.members)} members · ${num(c.online)} online</span><span class="chip">Wars ${c.warWins}–${c.warLosses} overall</span>
                        ${c.treasury !== undefined && c.treasury !== null ? `<span class="chip">${esc(money(c.treasury))} banked</span>` : ''}</div></div></div>
            <div class="stat-grid">
                ${stat('Wars with you', `${r.warsWon}–${r.warsLost}`, r.warsDrawn ? `${r.warsDrawn} drawn` : 'won–lost', 'fa-crosshairs')}
                ${stat('Raids', `${r.raidsWon}–${r.raidsLost}`, 'won–lost', 'fa-house-fire')}
                ${stat('Kills', `${r.killsOurs}–${r.killsTheirs}`, 'yours–theirs', 'fa-skull')}
                ${stat('On your turf', num(r.tagsOnUs + r.workOnUs), `${r.tagsOnUs} tags · ${r.workOnUs} times worked`, 'fa-flag')}
                ${stat('At your HQ', num(r.hqVisits), 'times seen', 'fa-eye')}
            </div>
            <div class="hub-split">
                <div><h2 class="section-head"><span>Known faces</span><span class="count">${d.faces.length}</span></h2>
                    <div class="tile-list">${d.faces.map((f) => `<div class="tile compact"><span class="tile-avatar">${esc(initials(f.name))}</span><div class="tile-main"><span class="tile-name">${esc(f.name)}</span><span class="tile-sub">${f.count} run-in${f.count === 1 ? '' : 's'} · last ${esc(ago(f.last))}</span></div></div>`).join('')
                        || '<div class="empty"><i class="fas fa-user-secret"></i>Nobody from their side has shown their face to you yet.</div>'}</div></div>
                <div><h2 class="section-head"><span>Their blocks</span><span class="count">${d.blocks.length}</span></h2>
                    <div class="tile-list">${d.blocks.map((b) => `<div class="tile compact"><span class="tile-avatar"><i class="fas fa-map-location-dot"></i></span><div class="tile-main"><span class="tile-name">${esc(b.label)}</span><span class="tile-sub">${esc(b.zone)}</span></div>${waypointBtn(b.x, b.y)}</div>`).join('')
                        || '<div class="empty"><i class="fas fa-map"></i>They hold no blocks.</div>'}</div></div>
            </div>
            <h2 class="section-head"><span>Between you</span></h2>
            <div class="log-list">${d.timeline.map((e) => `<div class="log"><span class="log-cat ${e.ours ? 'economy' : 'war'}"><i class="fas ${ICON[e.kind] || 'fa-circle-info'}"></i></span><span class="log-msg">${esc(line(e, c.label))}</span>${waypointBtn(e.x, e.y)}<span class="log-time">${esc(ago(e.at))}</span></div>`).join('')
                || '<div class="log-empty">Nothing between your crews yet.</div>'}</div>`;
    }

    function paint() {
        const root = document.getElementById('rivalsRoot');
        if (!root) return;
        if (view === 'dossier' && dossier) root.innerHTML = dossierView();
        else if (data) root.innerHTML = listView();
        else root.innerHTML = '<div class="empty"><i class="fas fa-user-secret"></i>Loading what we know…</div>';
        root.querySelectorAll('[data-rival]').forEach((b) => b.addEventListener('click', () => openDossier(Number(b.dataset.rival))));
        root.querySelectorAll('[data-back]').forEach((b) => b.addEventListener('click', () => { view = 'list'; dossier = null; render(); }));
        root.querySelectorAll('[data-wp]').forEach((b) => b.addEventListener('click', (e) => {
            e.stopPropagation();
            const [x, y] = b.dataset.wp.split(',').map(Number);
            nui('setWaypoint', { x, y });
        }));
    }

    async function openDossier(id) {
        rivalId = id;
        view = 'dossier';
        dossier = null;
        paint();
        dossier = await call('XS-CriminalTablet:intel:dossier', id);
        if (!dossier || !dossier.crew) { view = 'list'; dossier = null; }
        paint();
    }

    async function render() {
        if (view === 'dossier' && rivalId) return openDossier(rivalId);
        paint();
        data = await call('XS-CriminalTablet:intel:rivals');
        paint();
    }

    window.XS.Rivals = { render, onIntel() { if (view === 'list') render(); } };
})();
