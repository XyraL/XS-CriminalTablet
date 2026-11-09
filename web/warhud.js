// Raid and war scoreboard, kill feed and lead banner. Never takes focus;
// the client pushes state on every change and the clock runs here.
(function () {
    const root = document.getElementById('warHud');
    const esc = (v) => window.XS.escapeHtml(v);
    const safe = (hex) => (/^#[0-9a-f]{6}$/i.test(hex || '') ? hex : '#f5a524');
    let hud = null;
    let skew = 0;
    let timer = null;
    let lastKey = '';

    const clock = (ms) => {
        const s = Math.max(0, Math.floor(ms / 1000));
        return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
    };
    const nowServer = () => Date.now() + skew;

    function side(label, color, score, mine, sub, right, logo) {
        const mark = logo ? `<img src="${esc(logo)}" alt="">` : esc((label || '?').split(/\s+/).slice(0, 2).map((w) => w[0]).join('').toUpperCase());
        return `<div class="wh2-side ${right ? 'right' : ''}">
            <span class="wh2-crest" style="background:${safe(color)}">${mark}</span>
            <div class="wh2-who"><b>${esc(label)}</b><small>${mine ? '<em>You</em>' : ''}${esc(sub)}</small></div>
            <span class="wh2-score">${esc(score)}</span>
        </div>`;
    }

    function render() {
        if (!hud) return;
        const s = hud.state;
        const mine = hud.mine;
        const a = safe(s.attackerColor);
        const d = safe(s.defenderColor);
        let head;
        let bar;
        let extra = '';
        if (s.kind === 'raid') {
            const prep = s.phase === 'prep';
            head = prep ? `<span class="wh2-kind hot">Raid incoming</span><span class="wh2-clock" data-until="${s.startsAt}">${clock(s.startsAt - nowServer())}</span>`
                : `<span class="wh2-kind hot">Raid</span><span class="wh2-clock" data-until="${s.endsAt}">${clock(s.endsAt - nowServer())}</span>`;
            const pct = Math.max(0, Math.min(100, (s.holdProgress / Math.max(1, s.holdTarget)) * 100));
            bar = prep ? '<div class="wh2-note">The attackers get the HQ ready to hit. Get there first.</div>'
                : `<div class="wh2-bar"><i style="width:${pct}%;background:${a}"></i></div><div class="wh2-note">Holding the HQ <b>${Math.floor(s.holdProgress)}/${s.holdTarget}s</b> · it only counts with no defenders on it</div>`;
            head = `<div class="wh2-head">${head}</div>`;
            return paint(head + `<div class="wh2-sides">${side(s.attackerLabel, a, prep ? '' : s.scoreAttack, mine === 'attack', prep ? 'Attacking' : 'on the HQ', false, s.attackerLogo)}<span class="wh2-vs">vs</span>${side(s.defenderLabel, d, prep ? '' : s.scoreDefend, mine === 'defend', prep ? 'Defending' : 'on the HQ', true, s.defenderLogo)}</div>` + bar);
        }
        const lead = (s.scoreAttack || 0) - (s.scoreDefend || 0);
        const frac = Math.max(2, Math.min(98, 50 + (lead / Math.max(1, s.scoreToWin)) * 50));
        head = `<div class="wh2-head"><span class="wh2-kind">War</span><span class="wh2-clock" data-until="${s.endsAt}">${clock(s.endsAt - nowServer())}</span></div>`;
        bar = `<div class="wh2-bar split"><i style="width:${frac}%;background:${a}"></i><u style="background:${d}"></u><span class="wh2-mid"></span></div>
            <div class="wh2-note">First to <b>${s.scoreToWin}</b> ahead wins · kills ${s.killsAttack || 0}–${s.killsDefend || 0}</div>`;
        if ((s.objectives || []).length) {
            extra = `<div class="wh2-objs">${s.objectives.map((o) => {
                const owner = o.owner === 'attack' ? a : (o.owner === 'defend' ? d : null);
                const taking = o.taking === 'attack' ? a : (o.taking === 'defend' ? d : null);
                return `<div class="wh2-obj ${o.contested ? 'contested' : ''} ${o.owner && o.owner === mine ? 'ours' : ''}" title="${esc(o.label)}">
                    <span class="wh2-ring" style="--p:${o.progress};${taking ? `--t:${taking};` : ''}${owner ? `background:${owner}` : ''}"><b>${esc(o.id)}</b></span>
                    <small>${esc(o.label)}</small></div>`;
            }).join('')}</div>`;
        }
        paint(head + `<div class="wh2-sides">${side(s.attackerLabel, a, s.scoreAttack, mine === 'attack', 'Attacking', false, s.attackerLogo)}<span class="wh2-vs">vs</span>${side(s.defenderLabel, d, s.scoreDefend, mine === 'defend', 'Defending', true, s.defenderLogo)}</div>` + bar + extra);
    }

    function paint(html) {
        const card = root.querySelector('.wh2-card');
        if (card) card.innerHTML = html;
    }

    function tick() {
        root.querySelectorAll('[data-until]').forEach((el) => { el.textContent = clock(Number(el.dataset.until) - nowServer()); });
    }

    function show(data) {
        if (!data || !data.state) {
            hud = null;
            root.classList.add('hidden');
            root.innerHTML = '';
            lastKey = '';
            clearInterval(timer);
            timer = null;
            return;
        }
        hud = data;
        if (data.state.serverNow) skew = data.state.serverNow - Date.now();
        const key = `${data.state.id}:${data.state.kind}`;
        if (key !== lastKey) {
            lastKey = key;
            root.innerHTML = '<div class="wh2-card"></div><div class="wh2-banner"></div><div class="wh2-feed"></div>';
        }
        root.classList.remove('hidden');
        render();
        if (!timer) timer = setInterval(tick, 250);
    }

    function feed(e) {
        if (!hud || !e) return;
        const box = root.querySelector('.wh2-feed');
        if (!box) return;
        const row = document.createElement('div');
        row.className = `wh2-line ${e.side && e.side === hud.mine ? 'good' : 'bad'}`;
        if (e.kind === 'kill') {
            row.innerHTML = `<b style="color:${safe(e.killerColor)}">${esc(e.killer)}</b><i class="fas fa-crosshairs"></i><b style="color:${safe(e.victimColor)}">${esc(e.victim)}</b>`;
        } else {
            row.innerHTML = `<b style="color:${safe(e.color)}">${esc(e.crew)}</b><span>took</span><em>${esc(e.letter)}</em><span>${esc(e.label)}</span>`;
        }
        box.prepend(row);
        while (box.children.length > 5) box.lastChild.remove();
        setTimeout(() => row.classList.add('out'), 6500);
        setTimeout(() => row.remove(), 7000);
    }

    function lead(e) {
        if (!hud || !e) return;
        const s = hud.state;
        const banner = root.querySelector('.wh2-banner');
        if (!banner) return;
        const label = e.side === 'attack' ? s.attackerLabel : s.defenderLabel;
        const color = safe(e.side === 'attack' ? s.attackerColor : s.defenderColor);
        banner.innerHTML = `<b style="color:${color}">${esc(label)}</b> take the lead`;
        banner.classList.remove('on');
        void banner.offsetWidth;
        banner.classList.add('on');
    }

    window.addEventListener('message', (ev) => {
        const { action, data } = ev.data || {};
        if (action === 'warHud') show(data);
        else if (action === 'warFeed') feed(data);
        else if (action === 'warLead') lead(data);
    });
})();
