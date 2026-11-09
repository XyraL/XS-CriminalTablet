// Builder settings page. Edits a draft; Save sends only what changed, and
// the server stores it as an override on top of config.lua.
(function () {
    const esc = (v) => window.XS.escapeHtml(v);
    const acall = (name, ...args) => window.XS.nui('admin:call', { name, args });
    const toast = (msg, kind) => window.XSAdmin && window.XSAdmin.toast(msg, kind);

    let ctx = null;
    let el = null;
    let draft = {};
    let section = 'all';
    let query = '';
    let onlyChanged = false;
    let busy = false;
    let flash = null;
    let leaveTo = null;

    const list = (v) => (Array.isArray(v) ? v : (v && typeof v === 'object' ? Object.values(v) : []));
    const copy = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
    const icon = (name) => `<i class="fas ${esc(name)}"></i>`;

    function same(a, b) {
        if (Array.isArray(a) || Array.isArray(b) || (a && typeof a === 'object') || (b && typeof b === 'object')) {
            const x = list(a);
            const y = list(b);
            return x.length === y.length && x.every((v, i) => same(v, y[i]));
        }
        if (typeof a === 'number' && typeof b === 'number') return Math.abs(a - b) < 1e-9;
        return a === b;
    }

    const fields = () => ctx.sections.reduce((all, s) => all.concat(s.fields), []);
    const defOf = (key) => fields().find((f) => f.key === key);
    const current = (key) => (Object.prototype.hasOwnProperty.call(draft, key) ? draft[key] : ctx.values[key]);
    const changed = (key) => !same(current(key), ctx.defaults[key]);
    const pending = () => Object.keys(draft).filter((k) => !same(draft[k], ctx.values[k]));
    const permLabel = (id) => {
        for (const g of ctx.perms) for (const p of list(g.permissions)) if (p.id === id) return p.label;
        return id;
    };

    function truthy(v) {
        if (Array.isArray(v)) return v.length > 0;
        return v !== false && v !== undefined && v !== null && v !== '' && v !== 0;
    }

    function live(def, depth) {
        if (!def.needs || (depth || 0) > 6) return true;
        const parent = defOf(def.needs);
        return truthy(current(def.needs)) && (!parent || live(parent, (depth || 0) + 1));
    }

    function fmt(def, v) {
        if (v === undefined || v === null) return '—';
        if (def.type === 'bool') return v ? 'On' : 'Off';
        if (def.type === 'item') return v ? String(v) : 'No item';
        if (def.type === 'perms') return list(v).length ? `${list(v).length} picked` : 'Nothing';
        if (def.unit === '$') return window.XS.money(v);
        return `${v}${def.unit ? ` ${def.unit}` : ''}`;
    }

    function control(def) {
        const v = current(def.key);
        const k = esc(def.key);
        const off = !live(def);
        switch (def.type) {
        case 'bool':
            return `<span class="bx-switch ${v ? 'on' : ''} ${off ? 'dis' : ''}" data-bool="${k}"></span>`;
        case 'int':
        case 'num':
            return `<div class="bx-unit"><input type="number" data-num="${k}" value="${esc(v)}" min="${def.min !== undefined ? def.min : ''}" max="${def.max !== undefined ? def.max : ''}" step="${def.step || 1}" ${off ? 'disabled' : ''}>${def.unit ? `<em>${esc(def.unit)}</em>` : ''}<button data-step="${k}" data-dir="-1" ${off ? 'disabled' : ''}>−</button><button data-step="${k}" data-dir="1" ${off ? 'disabled' : ''}>+</button></div>`;
        case 'select':
            return `<select class="bx-input" data-select="${k}" ${off ? 'disabled' : ''}>${list(def.options).map((o) => `<option value="${esc(o)}" ${o === v ? 'selected' : ''}>${esc(o)}</option>`).join('')}</select>`;
        case 'text':
            return `<input class="bx-input ${def.upper ? 'mono' : ''}" data-text="${k}" maxlength="${def.max || 64}" value="${esc(v)}" ${off ? 'disabled' : ''}>`;
        case 'item': {
            const on = !!v;
            return `${def.off ? `<span class="bx-switch ${on ? 'on' : ''} ${off ? 'dis' : ''}" data-itemon="${k}"></span>` : ''}<input class="bx-input mono" list="bs-items" data-item="${k}" value="${esc(on ? v : '')}" placeholder="No item needed" ${(!on && def.off) || off ? 'disabled' : ''} style="width:190px">`;
        }
        case 'perms': {
            const have = new Set(list(v));
            return `<div class="bs-perms">${ctx.perms.map((g) => `<div class="bs-permgroup"><span>${esc(g.label)}</span><div>${list(g.permissions).map((p) =>
                `<button class="bs-perm ${have.has(p.id) ? 'on' : ''}" data-perm="${k}" data-id="${esc(p.id)}" title="${esc(p.description || '')}" ${off ? 'disabled' : ''}><i class="fas ${have.has(p.id) ? 'fa-check' : 'fa-plus'}"></i>${esc(p.label)}</button>`).join('')}</div></div>`).join('')}</div>`;
        }
        default:
            return '';
        }
    }

    function row(def) {
        const isChanged = changed(def.key);
        const needRestart = def.restart && !same(current(def.key), (ctx.boot || {})[def.key]);
        return `<div class="bx-setrow ${def.type === 'perms' ? 'stack' : ''} ${isChanged ? 'changed' : ''} ${live(def) ? '' : 'dim'} ${flash === def.key ? 'hit' : ''}" data-row="${esc(def.key)}">
            <div class="bx-setinfo"><b>${esc(def.label)}${def.restart ? '<span class="bx-restart">Restart</span>' : ''}</b>
                ${def.hint ? `<p>${esc(def.hint)}</p>` : ''}
                ${isChanged ? `<span class="bx-default">config.lua: ${esc(fmt(def, ctx.defaults[def.key]))} · <button data-reset="${esc(def.key)}">Reset</button></span>` : ''}
                ${needRestart ? '<span class="bx-default" style="color:var(--b-amber)">Restart the script for this to take effect.</span>' : ''}
            </div>
            <div class="bx-setctl">${control(def)}</div>
        </div>`;
    }

    function matches(def, sec) {
        if (onlyChanged && !changed(def.key)) return false;
        if (!query) return true;
        const hay = [def.label, def.hint || '', def.key, sec.label].join(' ').toLowerCase();
        return query.split(/\s+/).every((w) => hay.includes(w));
    }

    function render() {
        if (!el || !ctx) return;
        const scroller = document.getElementById('adminPage');
        const top = scroller ? scroller.scrollTop : 0;
        const all = fields();
        const changedCount = all.filter((f) => changed(f.key)).length;
        const searching = query || onlyChanged;
        const shown = ctx.sections.filter((s) => searching || section === 'all' || s.id === section).map((s) => {
            const rows = s.fields.filter((f) => matches(f, s));
            if (!rows.length) return '';
            const secChanged = s.fields.filter((f) => changed(f.key)).length;
            return `<section class="bx-setsec" data-sec="${esc(s.id)}">
                <div class="bx-setsech"><span class="bx-kindico">${icon(s.icon)}</span><div style="flex:1;min-width:0"><h2>${esc(s.label)}</h2>${s.hint ? `<p>${esc(s.hint)}</p>` : ''}</div>
                ${secChanged ? `<button class="bx-btn xs ghost" data-resetsec="${esc(s.id)}"><i class="fas fa-rotate-left"></i>Reset section</button>` : ''}</div>
                ${rows.map(row).join('')}
            </section>`;
        }).join('');
        const p = pending();
        el.innerHTML = `<datalist id="bs-items">${list(ctx.items).map((i) => `<option value="${esc(i.name)}" data-image="${esc(i.image || '')}">${esc(i.label)}</option>`).join('')}</datalist>
            <div class="bx-setbar">
                <div class="bx-filter"><i class="fas fa-magnifying-glass"></i><input class="bx-input" id="bs-q" value="${esc(query)}" placeholder="Search ${all.length} settings"></div>
                <label class="bx-toggle" id="bs-only"><span class="bx-switch ${onlyChanged ? 'on' : ''}"></span>Only changed</label>
                <span class="bx-sp"></span>
                <span class="bx-chip ${changedCount ? 'warn' : ''}">${changedCount} changed from config.lua</span>
            </div>
            <div class="bx-set">
                <div class="bx-setnav">
                    <button class="${section === 'all' && !searching ? 'on' : ''}" data-sec-go="all"><i class="fas fa-sliders"></i><span>All settings</span></button>
                    ${ctx.sections.map((s) => {
                        const n = s.fields.filter((f) => changed(f.key)).length;
                        return `<button class="${section === s.id && !searching ? 'on' : ''}" data-sec-go="${esc(s.id)}">${icon(s.icon)}<span>${esc(s.label)}</span>${n ? `<em>${n}</em>` : ''}</button>`;
                    }).join('')}
                </div>
                <div>${shown || '<div class="bx-empty"><i class="fas fa-magnifying-glass"></i><b>Nothing matches</b><p>Try another word, or turn off Only changed.</p></div>'}<div style="height:70px"></div></div>
            </div>
            ${p.length ? `<div class="bx-savebar"><span><b>${p.length}</b> unsaved</span><button class="bx-btn sm ghost" id="bs-discard">Discard</button><button class="bx-btn sm primary" id="bs-save"><i class="fas fa-check"></i>Save changes<span class="bx-kbd">Ctrl S</span></button></div>` : ''}`;
        bind();
        if (scroller) scroller.scrollTop = top;
        if (flash) {
            const hit = el.querySelector(`[data-row="${CSS.escape(flash)}"]`);
            if (hit) hit.scrollIntoView({ block: 'center' });
            flash = null;
        }
        const count = document.getElementById('bxCountSettings');
        if (count) { count.textContent = changedCount; count.classList.toggle('hidden', !changedCount); }
    }

    function set(key, value) {
        draft[key] = value;
        if (same(value, ctx.values[key])) delete draft[key];
        render();
    }

    function clampNum(def, raw) {
        let n = Number(raw);
        if (!Number.isFinite(n)) n = Number(ctx.values[def.key]) || 0;
        if (def.type === 'int') n = Math.round(n);
        else n = Math.round(n / (def.step || 0.1)) * (def.step || 0.1);
        n = Math.round(n * 1000) / 1000;
        if (def.min !== undefined) n = Math.max(def.min, n);
        if (def.max !== undefined) n = Math.min(def.max, n);
        return n;
    }

    function bind() {
        const q = el.querySelector('#bs-q');
        q.addEventListener('input', () => {
            query = q.value.trim().toLowerCase();
            const pos = q.selectionStart;
            render();
            const again = el.querySelector('#bs-q');
            again.focus();
            again.setSelectionRange(pos, pos);
        });
        el.querySelector('#bs-only').addEventListener('click', () => { onlyChanged = !onlyChanged; render(); });
        el.querySelectorAll('[data-sec-go]').forEach((b) => b.addEventListener('click', () => {
            section = b.dataset.secGo;
            query = '';
            onlyChanged = false;
            render();
            const scroller = document.getElementById('adminPage');
            if (scroller) scroller.scrollTop = 0;
        }));
        el.querySelectorAll('[data-bool]').forEach((s) => s.addEventListener('click', () => {
            if (s.classList.contains('dis')) return;
            set(s.dataset.bool, !current(s.dataset.bool));
        }));
        el.querySelectorAll('[data-num]').forEach((i) => i.addEventListener('change', () => set(i.dataset.num, clampNum(defOf(i.dataset.num), i.value))));
        el.querySelectorAll('[data-step]').forEach((b) => b.addEventListener('click', () => {
            const def = defOf(b.dataset.step);
            set(def.key, clampNum(def, (Number(current(def.key)) || 0) + Number(b.dataset.dir) * (def.step || 1)));
        }));
        el.querySelectorAll('[data-select]').forEach((s) => s.addEventListener('change', () => set(s.dataset.select, s.value)));
        el.querySelectorAll('[data-text]').forEach((i) => i.addEventListener('change', () => {
            const def = defOf(i.dataset.text);
            let v = i.value.replace(/[\u0000-\u001f]/g, '').trim();
            if (def.upper) v = v.toUpperCase().replace(/[^A-Z0-9]/g, '');
            if (!v) { render(); return; }
            set(def.key, v.slice(0, def.max || 64));
        }));
        el.querySelectorAll('[data-itemon]').forEach((s) => s.addEventListener('click', () => {
            if (s.classList.contains('dis')) return;
            const key = s.dataset.itemon;
            if (current(key)) { set(key, ''); return; }
            const fallback = ctx.defaults[key] || '';
            if (fallback) { set(key, fallback); return; }
            const i = el.querySelector(`[data-item="${CSS.escape(key)}"]`);
            if (i) { i.disabled = false; i.focus(); }
        }));
        el.querySelectorAll('[data-item]').forEach((i) => i.addEventListener('change', () => {
            const def = defOf(i.dataset.item);
            const v = i.value.trim().toLowerCase().replace(/[^a-z0-9_-]/g, '');
            if (!v && !def.off) { render(); return; }
            set(def.key, v);
        }));
        el.querySelectorAll('[data-perm]').forEach((b) => b.addEventListener('click', () => {
            const key = b.dataset.perm;
            const have = list(current(key)).slice();
            const at = have.indexOf(b.dataset.id);
            if (at >= 0) have.splice(at, 1); else have.push(b.dataset.id);
            set(key, have);
        }));
        el.querySelectorAll('[data-reset]').forEach((b) => b.addEventListener('click', () => set(b.dataset.reset, copy(ctx.defaults[b.dataset.reset]))));
        el.querySelectorAll('[data-resetsec]').forEach((b) => b.addEventListener('click', () => {
            const sec = ctx.sections.find((s) => s.id === b.dataset.resetsec);
            sec.fields.forEach((f) => {
                draft[f.key] = copy(ctx.defaults[f.key]);
                if (same(draft[f.key], ctx.values[f.key])) delete draft[f.key];
            });
            render();
        }));
        const discard = el.querySelector('#bs-discard');
        if (discard) discard.addEventListener('click', () => { draft = {}; render(); });
        const save = el.querySelector('#bs-save');
        if (save) save.addEventListener('click', () => api.save());
    }

    document.addEventListener('keydown', (e) => {
        if (!el || !ctx || !(e.ctrlKey && (e.key === 's' || e.key === 'S'))) return;
        if (!window.XSAdmin || window.XSAdmin.page() !== 'admin-settings') return;
        e.preventDefault();
        api.save();
    });

    const api = {
        async load() {
            const res = await acall('XS-CriminalTablet:admin:settings');
            if (!res || !res.ok || !res.data) return;
            const s = res.data;
            // Hidden fields (the wheel's actions) keep their values here but
            // are edited on their own page, not listed with the rest.
            ctx = {
                sections: list(s.sections).map((sec) => Object.assign(sec, { fields: list(sec.fields).filter((f) => !f.hidden).map((f) => Object.assign(f, { options: list(f.options) })) })),
                values: s.values || {}, defaults: s.defaults || {}, boot: s.boot || {},
                perms: list(s.perms).map((g) => Object.assign(g, { permissions: list(g.permissions) })), items: list(s.items),
                radialIcons: s.radialIcons || {},
            };
            Object.keys(draft).forEach((k) => { if (same(draft[k], ctx.values[k])) delete draft[k]; });
            render();
            if (window.XS.BuilderRadial && !window.XS.BuilderRadial.isDirty()) window.XS.BuilderRadial.refresh();
            if (!el) {
                const count = document.getElementById('bxCountSettings');
                const n = fields().filter((f) => changed(f.key)).length;
                if (count) { count.textContent = n; count.classList.toggle('hidden', !n); }
            }
        },
        mount(target) {
            el = target;
            if (!ctx) { el.innerHTML = '<div class="bx-empty"><i class="fas fa-gear"></i><b>Loading settings</b></div>'; api.load(); return; }
            render();
        },
        fields: () => (ctx ? ctx.sections.reduce((all, s) => all.concat(s.fields.map((f) => Object.assign({ sectionLabel: s.label }, f))), []) : []),
        isDirty: () => !!ctx && pending().length > 0,
        ready: () => !!ctx,
        value: (key) => (ctx ? current(key) : undefined),
        defaultOf: (key) => (ctx ? copy(ctx.defaults[key]) : undefined),
        radialIcons: () => (ctx ? ctx.radialIcons : {}),
        // Leaving with unsaved changes asks first, the same way the police
        // builder does, so a half-done edit is never lost by a stray click.
        confirmLeave(then) {
            leaveTo = then;
            const box = document.getElementById('bxOverlay');
            box.innerHTML = `<div class="bx-overlay"><div class="bx-modal"><h3>Leave without saving?</h3>
                <p>You have ${pending().length} unsaved ${pending().length === 1 ? 'setting' : 'settings'}.</p>
                <div class="acts"><button class="bx-btn ghost" data-leave="stay">Stay</button><button class="bx-btn danger" data-leave="drop">Discard</button><button class="bx-btn primary" data-leave="save">Save and leave</button></div></div></div>`;
            box.querySelectorAll('[data-leave]').forEach((b) => b.addEventListener('click', async () => {
                const choice = b.dataset.leave;
                box.innerHTML = '';
                if (choice === 'stay') return;
                if (choice === 'save') await api.save(); else draft = {};
                const next = leaveTo;
                leaveTo = null;
                if (next) next();
            }));
            return false;
        },
        focus(key) {
            const def = defOf(key);
            if (!def) return;
            section = def.section;
            query = '';
            onlyChanged = false;
            flash = key;
            if (el) render();
        },
        async save() {
            const a = document.activeElement;
            if (a && a !== document.body && el && el.contains(a) && a.blur) a.blur();
            if (busy || !ctx) return;
            const keys = pending();
            if (!keys.length) return;
            const changes = {};
            keys.forEach((k) => { changes[k] = draft[k]; });
            busy = true;
            const res = await acall('XS-CriminalTablet:admin:saveSettings', changes, []);
            busy = false;
            if (!res || !res.ok) { toast((res && res.error) || 'Could not save', 'error'); return; }
            ctx.values = (res.data && res.data.values) || Object.assign({}, ctx.values, changes);
            ctx.boot = (res.data && res.data.boot) || ctx.boot;
            draft = {};
            toast(`Saved ${keys.length} ${keys.length === 1 ? 'setting' : 'settings'}. They are live now.`, 'success');
            render();
        },
    };
    window.XS.BuilderSettings = api;
})();
