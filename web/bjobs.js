// Builder Jobs page: the contracts board's jobs, editable, plus new ones
// staff make themselves. Places are walked out in the world.
(function () {
    const esc = (v) => window.XS.escapeHtml(v);
    const money = (v) => window.XS.money(v);
    const acall = (name, ...args) => window.XS.nui('admin:call', { name, args });
    const toast = (m, k) => window.XSAdmin.toast(m, k);

    const TYPES = {
        courier: { label: 'Courier run', icon: 'fa-truck', blurb: 'Collect the van, drive it to a drop-off, hand the goods over and bring the van back. Can be ambushed.',
            places: [['vanSpawns', 'Van pick-up spots', true, 'Where the van waits. One is picked at random each run.'], ['dropoffs', 'Drop-offs', true, 'Where the goods are handed over. One is picked at random.']],
            defaults: { category: 'transport', vanModel: 'speedo', carryProp: 'prop_box_ammo04a', dropoffPedModel: 'g_m_y_lost_01', quartermasterModel: 'g_m_y_lost_01', ambushChance: 20, radius: 6 } },
        kill: { label: 'Hit', icon: 'fa-crosshairs', blurb: 'An armed target waits at one of the spots. Take them out.',
            places: [['spawnPoints', 'Target spots', true, 'Where the target stands. One is picked at random.']],
            defaults: { category: 'hit', pedModel: 'g_m_y_lost_01', weapon: 'WEAPON_PISTOL', minKillSeconds: 5 } },
        escort: { label: 'Escort', icon: 'fa-person-walking', blurb: 'Pick someone up and get them to the destination alive.',
            places: [['spawn', 'Pick-up', false, 'Where they are waiting.'], ['destination', 'Destination', false, 'Where they need to go.']],
            defaults: { category: 'transport', pedModel: 'a_m_m_soucent_01', radius: 5 } },
        heist: { label: 'Heist', icon: 'fa-sack-dollar', blurb: 'Get in and hold the spot, grab the goods, then make the getaway before time runs out.',
            places: [['infiltrate', 'Way in', false, 'Hold here to get inside.'], ['grab', 'The goods', false, 'What they take.'], ['escape', 'Getaway', false, 'Reach this to finish.']],
            defaults: { category: 'narcotic', holdSeconds: 6, radius: 2.5 } },
    };
    const DETAILS = {
        courier: [['vanModel', 'Van model', 'text'], ['carryProp', 'What they carry', 'text'], ['dropoffPedModel', 'Who takes the drop', 'text'], ['quartermasterModel', 'Who hands over the van', 'text'], ['ambushChance', 'Ambush chance', 'int', 0, 100, '%'], ['radius', 'How close counts', 'num', 1, 50, 'm']],
        kill: [['pedModel', 'Target model', 'text'], ['weapon', 'Target weapon', 'text'], ['minKillSeconds', 'Earliest a kill counts', 'int', 0, 120, 's']],
        escort: [['pedModel', 'Who they escort', 'text'], ['radius', 'How close counts', 'num', 1, 50, 'm']],
        heist: [['holdSeconds', 'Time to hold the way in', 'int', 1, 120, 's'], ['radius', 'How close counts', 'num', 1, 50, 'm']],
    };
    const PAY = [['reward', 'Crew rep', 'int', 0, 100000, 'rep'], ['cash', 'Cash', 'int', 0, 10000000, '$'], ['xp', 'Personal XP', 'int', 0, 100000, 'xp'],
        ['cooldownMinutes', 'Cooldown', 'int', 0, 1440, 'min'], ['timeLimitSeconds', 'Time limit', 'int', 60, 7200, 's']];

    let el = null;
    let data = null;
    let view = 'list';
    let draft = null;
    let original = null;
    let filter = '';

    const copy = (v) => JSON.parse(JSON.stringify(v));
    const dirty = () => draft && JSON.stringify(draft) !== JSON.stringify(original);
    const placesFor = (type) => (TYPES[type] || { places: [] }).places;
    const missing = (job) => placesFor(job.type).filter(([field, , many]) => (many ? !(job[field] || []).length : !job[field])).map(([, label]) => label);

    async function load() {
        const res = await acall('XS-CriminalTablet:admin:jobs');
        if (!res || !res.ok) return;
        data = res.data;
        data.jobs = Array.isArray(data.jobs) ? data.jobs : [];
        data.categories = Array.isArray(data.categories) ? data.categories : [];
        data.levels = Array.isArray(data.levels) ? data.levels : [];
        const live = data.jobs.filter((j) => !j.deleted && !j.disabled && !missing(j).length).length;
        const count = document.getElementById('bxCountJobs');
        if (count) count.textContent = live;
        render();
    }

    function status(job) {
        if (job.deleted) return '<span class="bx-chip off">Hidden</span>';
        if (job.disabled) return '<span class="bx-chip off">Off</span>';
        if (missing(job).length) return '<span class="bx-chip warn">Needs places</span>';
        return '<span class="bx-chip ok">On the board</span>';
    }

    function catLabel(id) {
        const c = data.categories.find((x) => x.id === id);
        return c ? c.label : id;
    }

    function listView() {
        const q = filter.toLowerCase();
        const jobs = data.jobs.filter((j) => !q || [j.label, j.type, catLabel(j.category)].join(' ').toLowerCase().includes(q));
        return `<div class="bx-listbar">
                <div class="bx-filter"><i class="fas fa-magnifying-glass"></i><input class="bx-input" id="bj-q" value="${esc(filter)}" placeholder="Search ${data.jobs.length} jobs"></div>
                <span class="bx-sp"></span>
                <button class="bx-btn primary" id="bj-new"><i class="fas fa-plus"></i>New job</button>
            </div>
            <div class="bj-grid">${jobs.map((j) => `<button class="bj-card ${j.deleted || j.disabled ? 'off' : ''}" data-edit="${esc(j.id)}">
                <div class="bj-head"><span class="bx-kindico"><i class="fas ${esc((TYPES[j.type] || {}).icon || 'fa-briefcase')}"></i></span>
                    <div><b>${esc(j.label)}</b><small>${esc((TYPES[j.type] || {}).label || j.type)} · ${esc(catLabel(j.category))}</small></div>
                    <span class="bj-dots">${[1, 2, 3, 4, 5].map((n) => `<i class="${n <= j.difficulty ? 'on' : ''}"></i>`).join('')}</span></div>
                <div class="bj-pay"><span><b>+${esc(j.reward)}</b> rep</span><span><b>${money(j.cash)}</b></span><span><b>${esc(j.xp)}</b> xp</span><span><b>${esc(j.cooldownMinutes)}</b> min</span></div>
                <div class="bj-foot">${status(j)}<span class="bx-tag">${j.source === 'builder' ? 'Made here' : (j.edited ? 'Edited' : 'config.lua')}</span>${j.coopOnly ? '<span class="bx-tag">Crew only</span>' : ''}</div>
            </button>`).join('') || '<div class="bx-empty"><i class="fas fa-briefcase"></i><b>No jobs match</b></div>'}</div>`;
    }

    function pickView() {
        return `<div class="bx-crumb"><button data-back>Jobs</button><i class="fas fa-chevron-right"></i><span>New job</span></div>
            <h2 class="bj-title">What kind of job?</h2>
            <div class="bj-types">${Object.entries(TYPES).map(([id, t]) => `<button class="bj-type" data-type="${id}">
                <span class="bx-kindico"><i class="fas ${t.icon}"></i></span><div><b>${esc(t.label)}</b><span>${esc(t.blurb)}</span></div></button>`).join('')}</div>`;
    }

    function unit(key, value, min, max, step, u) {
        return `<div class="bx-unit"><input type="number" data-num="${key}" value="${esc(value)}" min="${min}" max="${max}" step="${step || 1}">${u ? `<em>${esc(u)}</em>` : ''}</div>`;
    }

    function field([key, label, kind, min, max, u]) {
        const v = draft[key];
        const ctl = kind === 'text'
            ? `<input class="bx-input mono" data-text="${key}" value="${esc(v || '')}" maxlength="64">`
            : unit(key, v, min, max, kind === 'num' ? 0.5 : 1, u);
        return `<div class="bx-mini"><span>${esc(label)}</span>${ctl}</div>`;
    }

    function placeGroup([fieldKey, label, many, hint]) {
        const pts = many ? (draft[fieldKey] || []) : (draft[fieldKey] ? [draft[fieldKey]] : []);
        return `<div class="bx-group ${pts.length ? '' : 'need'}">
            <div class="bx-grouph"><span class="bx-gico" style="background:${pts.length ? 'var(--b-green)' : 'var(--b-amber)'}"><i class="fas fa-location-dot"></i></span>
                <div class="bx-gtext"><b>${esc(label)} <span class="bx-tag ${pts.length ? 'ok' : 'req'}">${pts.length ? (many ? `${pts.length} placed` : 'Placed') : 'Needed'}</span></b><span>${esc(hint)}</span></div></div>
            <div class="bx-points">${pts.map((p, i) => `<div class="bx-pt"><span class="bx-ptn">${i + 1}</span>
                <div class="bx-ptmain"><b>${Math.round(p.x)}, ${Math.round(p.y)}, ${Math.round(p.z)}</b><small>${many || p.w !== undefined ? `facing ${Math.round(p.w || 0)}°` : 'position'}</small></div>
                <div class="bx-ptacts"><button class="bx-tool danger" data-unplace="${fieldKey}" data-i="${i}" title="Remove"><i class="fas fa-trash"></i></button></div></div>`).join('')}</div>
            <div class="bx-addrow"><button class="bx-btn sm" data-walk="${fieldKey}" data-many="${many ? 1 : 0}" data-label="${esc(label)}"><i class="fas fa-person-walking"></i>${pts.length && !many ? 'Walk and move it' : 'Walk and place'}</button>
                <button class="bx-btn sm ghost" data-here="${fieldKey}" data-many="${many ? 1 : 0}"><i class="fas fa-location-crosshairs"></i>Where I'm stood</button></div>
        </div>`;
    }

    function editView() {
        const t = TYPES[draft.type];
        const isConfig = draft.source === 'config';
        const need = missing(draft);
        return `<div class="bx-crumb"><button data-back>Jobs</button><i class="fas fa-chevron-right"></i><span>${esc(draft.label || 'New job')}</span></div>
            <div class="bx-edhead"><input class="bx-edname" id="bj-name" value="${esc(draft.label || '')}" placeholder="Name the job" maxlength="48">
                <span class="bx-chip blue"><i class="fas ${t.icon}"></i>${esc(t.label)}</span></div>
            <div class="bx-edmeta"><span class="bx-hint">${isConfig ? 'From config.lua. Saving here keeps your version; Back to config.lua undoes it.' : 'Made in the builder.'}</span>
                ${need.length ? `<span class="bx-chip warn">Needs: ${esc(need.join(', '))}</span>` : '<span class="bx-chip ok">Ready for the board</span>'}</div>
            <div class="bx-cols2" style="margin-top:16px;align-items:start">
                <div>
                    <div class="bx-card"><div class="bx-cardhead"><h3>Basics</h3></div><div class="bx-cardbody bj-form">
                        <div class="bx-mini"><span>Category</span><select class="bx-input" data-select="category">${data.categories.map((c) => `<option value="${esc(c.id)}" ${c.id === draft.category ? 'selected' : ''}>${esc(c.label)}</option>`).join('')}</select></div>
                        <div class="bx-mini"><span>Personal rank needed</span><select class="bx-input" data-select="minLevel">${data.levels.map((l) => `<option value="${l.level}" ${Number(draft.minLevel) === l.level ? 'selected' : ''}>${l.level} · ${esc(l.title)}</option>`).join('')}</select></div>
                        <div class="bx-mini"><span>Difficulty</span><div class="bj-seg">${[1, 2, 3, 4, 5].map((n) => `<button data-diff="${n}" class="${Number(draft.difficulty) === n ? 'on' : ''}">${n}</button>`).join('')}</div></div>
                        <label class="bx-toggle"><span class="bx-switch ${draft.coopOnly ? 'on' : ''}" data-bool="coopOnly"></span>Crew only (never solo)</label>
                        <label class="bx-toggle"><span class="bx-switch ${draft.disabled ? '' : 'on'}" data-bool="enabled"></span>On the board</label>
                    </div></div>
                    <div class="bx-card" style="margin-top:14px"><div class="bx-cardhead"><h3>Pay and timing</h3></div><div class="bx-cardbody bj-form">${PAY.map(field).join('')}</div></div>
                    <div class="bx-card" style="margin-top:14px"><div class="bx-cardhead"><h3>${esc(t.label)} details</h3></div><div class="bx-cardbody bj-form">${DETAILS[draft.type].map(field).join('')}</div></div>
                </div>
                <div><div class="bx-groups">${t.places.map(placeGroup).join('')}</div>
                    <p class="bx-hint" style="margin-top:10px">Walk and place closes the builder. Stand on the spot, face the way it should face and press E. Enter brings you back here.</p></div>
            </div>
            <div class="bx-savebar ${dirty() ? '' : 'quiet'}">
                ${dirty() ? '<span><b>Unsaved</b> changes</span><button class="bx-btn sm ghost" id="bj-discard">Discard</button>' : ''}
                ${isConfig && draft.edited ? '<button class="bx-btn sm ghost" id="bj-restore"><i class="fas fa-rotate-left"></i>Back to config.lua</button>' : ''}
                ${draft.id ? `<button class="bx-btn sm danger" id="bj-delete"><i class="fas fa-trash"></i>${isConfig ? 'Hide' : 'Delete'}</button>` : ''}
                <button class="bx-btn sm primary" id="bj-save" ${dirty() ? '' : 'disabled'}><i class="fas fa-check"></i>Save job</button>
            </div>`;
    }

    function render() {
        if (!el) return;
        if (!data) { el.innerHTML = '<div class="bx-empty"><i class="fas fa-briefcase"></i><b>Loading jobs</b></div>'; return; }
        el.innerHTML = view === 'pick' ? pickView() : (view === 'edit' && draft ? editView() : listView());
        bind();
    }

    function open(job) {
        draft = copy(job);
        original = copy(job);
        view = 'edit';
        render();
        document.getElementById('adminPage').scrollTop = 0;
    }

    function setVal(key, value) { draft[key] = value; render(); }

    function bind() {
        const q = el.querySelector('#bj-q');
        if (q) q.addEventListener('input', () => { filter = q.value; const pos = q.selectionStart; render(); const a = el.querySelector('#bj-q'); a.focus(); a.setSelectionRange(pos, pos); });
        const nw = el.querySelector('#bj-new');
        if (nw) nw.addEventListener('click', () => { view = 'pick'; render(); });
        el.querySelectorAll('[data-edit]').forEach((b) => b.addEventListener('click', () => open(data.jobs.find((j) => j.id === b.dataset.edit))));
        el.querySelectorAll('[data-back]').forEach((b) => b.addEventListener('click', () => { view = 'list'; draft = null; render(); }));
        el.querySelectorAll('[data-type]').forEach((b) => b.addEventListener('click', () => {
            const t = TYPES[b.dataset.type];
            const job = Object.assign({ type: b.dataset.type, label: '', difficulty: 2, minLevel: 1, reward: 40, cash: 2000, xp: 30, cooldownMinutes: 30, timeLimitSeconds: 600, coopOnly: false, disabled: false, source: 'builder' }, t.defaults);
            draft = job;
            original = {};
            view = 'edit';
            render();
            const n = el.querySelector('#bj-name');
            if (n) n.focus();
        }));
        const name = el.querySelector('#bj-name');
        if (name) name.addEventListener('change', () => setVal('label', name.value.trim()));
        el.querySelectorAll('[data-select]').forEach((s) => s.addEventListener('change', () => setVal(s.dataset.select, s.dataset.select === 'minLevel' ? Number(s.value) : s.value)));
        el.querySelectorAll('[data-diff]').forEach((b) => b.addEventListener('click', () => setVal('difficulty', Number(b.dataset.diff))));
        el.querySelectorAll('[data-bool]').forEach((s) => s.addEventListener('click', () => {
            if (s.dataset.bool === 'enabled') setVal('disabled', !draft.disabled);
            else setVal(s.dataset.bool, !draft[s.dataset.bool]);
        }));
        el.querySelectorAll('[data-num]').forEach((i) => i.addEventListener('change', () => {
            const n = Number(i.value);
            setVal(i.dataset.num, Number.isFinite(n) ? Math.min(Number(i.max), Math.max(Number(i.min), n)) : draft[i.dataset.num]);
        }));
        el.querySelectorAll('[data-text]').forEach((i) => i.addEventListener('change', () => setVal(i.dataset.text, i.value.trim().replace(/[^A-Za-z0-9_]/g, ''))));
        el.querySelectorAll('[data-unplace]').forEach((b) => b.addEventListener('click', () => {
            const f = b.dataset.unplace;
            if (Array.isArray(draft[f])) draft[f].splice(Number(b.dataset.i), 1); else draft[f] = null;
            render();
        }));
        el.querySelectorAll('[data-walk]').forEach((b) => b.addEventListener('click', () => {
            window.XS.nui('admin:jobWalk', { job: draft.label || 'New job', field: b.dataset.walk, label: b.dataset.label, many: b.dataset.many === '1' });
        }));
        el.querySelectorAll('[data-here]').forEach((b) => b.addEventListener('click', async () => {
            const here = await acall('XS-CriminalTablet:admin:whereAmI');
            if (!here || here.x === undefined) return toast('Could not read where you are', 'error');
            api.onPoints({ field: b.dataset.here, points: [{ x: here.x, y: here.y, z: here.z, w: here.heading || 0 }] });
        }));
        const discard = el.querySelector('#bj-discard');
        if (discard) discard.addEventListener('click', () => { draft = copy(original); if (!draft.type) { view = 'list'; draft = null; } render(); });
        const save = el.querySelector('#bj-save');
        if (save) save.addEventListener('click', async () => {
            if (!draft.label) return toast('Give the job a name first.', 'error');
            const res = await acall('XS-CriminalTablet:admin:saveJob', draft);
            if (!res || !res.ok) return toast((res && res.error) || 'Could not save', 'error');
            toast(missing(draft).length ? 'Saved. It goes on the board once its places are set.' : 'Saved. It is on the board now.', 'success');
            const id = res.id;
            await load();
            const fresh = data.jobs.find((j) => j.id === id);
            if (fresh) open(fresh);
        });
        const del = el.querySelector('#bj-delete');
        if (del) del.addEventListener('click', async () => {
            if (del.dataset.armed !== '1') { del.dataset.armed = '1'; del.innerHTML = '<i class="fas fa-triangle-exclamation"></i>Click again'; return; }
            const res = await acall('XS-CriminalTablet:admin:deleteJob', draft.id);
            if (!res || !res.ok) return toast((res && res.error) || 'Could not remove it', 'error');
            toast(draft.source === 'config' ? 'Hidden from the board.' : 'Deleted.', 'success');
            view = 'list'; draft = null;
            await load();
        });
        const restore = el.querySelector('#bj-restore');
        if (restore) restore.addEventListener('click', async () => {
            const res = await acall('XS-CriminalTablet:admin:restoreJob', draft.id);
            if (!res || !res.ok) return toast((res && res.error) || 'Could not put it back', 'error');
            toast('Back to what config.lua says.', 'success');
            const id = draft.id;
            await load();
            const fresh = data.jobs.find((j) => j.id === id);
            if (fresh) open(fresh);
        });
    }

    const api = {
        mount(target) { el = target; if (!data) { render(); load(); } else render(); },
        home() { view = 'list'; draft = null; render(); },
        // Points come back here from walk-and-place, or from Where I'm stood.
        onPoints({ field, points }) {
            if (!draft || !Array.isArray(points) || !points.length) return;
            const def = placesFor(draft.type).find(([f]) => f === field);
            if (!def) return;
            if (def[2]) draft[field] = (draft[field] || []).concat(points).slice(0, 20);
            else { const p = points[points.length - 1]; draft[field] = { x: p.x, y: p.y, z: p.z }; }
            if (window.XSAdmin.page() !== 'admin-jobs') window.XSAdmin.go('admin-jobs');
            render();
        },
        isDirty: () => !!dirty(),
    };
    window.XS.BuilderJobs = api;
})();
