// Builder "Crafting and perks": bench recipes, the perk tree and treasury
// upgrades. Each tab saves on its own and can go back to config.lua.
(function () {
    const esc = (v) => window.XS.escapeHtml(v);
    const acall = (name, ...args) => window.XS.nui('admin:call', { name, args });
    const toast = (m, k) => window.XSAdmin.toast(m, k);

    const FX = {
        slotsBonus: 'Vault slots', weightBonusPct: 'Vault weight %', maxMembersBonus: 'Members', craftTimePct: 'Crafting time % (minus is faster)',
        bonusOutputChance: 'Double output chance %', tierBoost: 'Recipes unlock tiers early', captureSpeedPct: 'Capture speed %',
        defenceWeightPct: 'Defence on own turf %', raidCutPct: 'Raid cut %', vaultSlotsBonus: 'Vault slots', vaultWeightBonusPct: 'Vault weight %',
        garageSlotsBonus: 'Garage bays', raidRewardPct: 'Raid reward %',
    };
    const ICONS = ['fa-vault', 'fa-users', 'fa-user-plus', 'fa-screwdriver-wrench', 'fa-crosshairs', 'fa-shield-halved', 'fa-bolt', 'fa-sack-dollar', 'fa-warehouse', 'fa-boxes-stacked', 'fa-person-running', 'fa-flag', 'fa-star', 'fa-fire'];
    const TABS = [['recipes', 'Bench recipes'], ['perks', 'Perk tree'], ['upgrades', 'Upgrades']];

    let el = null;
    let data = null;
    let tab = 'recipes';
    let draft = {};
    let base = {};

    const copy = (v) => JSON.parse(JSON.stringify(v));
    const dirty = (k) => draft[k] && JSON.stringify(draft[k]) !== JSON.stringify(base[k]);

    // Effects live as plain keys on a perk tier or upgrade level; the editor
    // works on a small list of { k, v } rows instead.
    const toRows = (obj, keys) => keys.filter((k) => obj[k] !== undefined && obj[k] !== 0).map((k) => ({ k, v: obj[k] }));
    function fromRows(target, rows, keys) {
        keys.forEach((k) => { delete target[k]; });
        (rows || []).forEach((r) => { if (keys.includes(r.k) && Number(r.v)) target[r.k] = Number(r.v); });
        return target;
    }

    // Rebuilds what is saved. With `only`, just that tab's draft is reset,
    // so unsaved edits on the other tabs survive a save here.
    function prime(only) {
        base = {
            recipes: copy(data.recipes || []).map((r) => Object.assign(r, { time: Math.round((r.time || 5000) / 100) / 10 })),
            perks: copy(data.perks || []).map((b) => Object.assign(b, { tiers: (b.tiers || []).map((t) => Object.assign(t, { fx: toRows(t, data.perkEffects) })) })),
            upgrades: copy(data.upgrades || []).map((u) => Object.assign(u, { levels: (u.levels || []).map((l) => Object.assign(l, { fx: toRows(l, data.upgradeEffects) })) })),
        };
        if (only) draft[only] = copy(base[only]); else draft = copy(base);
    }

    async function load() {
        const res = await acall('XS-CriminalTablet:admin:content');
        if (!res || !res.ok) return;
        data = res.data;
        ['recipes', 'perks', 'upgrades', 'tiers', 'perkEffects', 'upgradeEffects', 'items'].forEach((k) => { if (!Array.isArray(data[k])) data[k] = Object.values(data[k] || {}); });
        prime();
        render();
    }

    const num = (path, value, min, max, step, unit) => `<div class="bx-unit"><input type="number" data-path="${path}" value="${esc(value)}" min="${min}" max="${max}" step="${step || 1}">${unit ? `<em>${esc(unit)}</em>` : ''}</div>`;
    const txt = (path, value, max, ph, mono) => `<input class="bx-input ${mono ? 'mono' : ''}" data-path="${path}" value="${esc(value || '')}" maxlength="${max}" placeholder="${esc(ph || '')}" ${mono ? 'list="bc-items"' : ''}>`;

    function fxRows(path, rows, keys) {
        return `<div class="bc-fx">${(rows || []).map((r, i) => `<div class="bc-fxrow">
                <select class="bx-input sm" data-path="${path}.${i}.k">${keys.map((k) => `<option value="${k}" ${k === r.k ? 'selected' : ''}>${esc(FX[k] || k)}</option>`).join('')}</select>
                <input class="bx-input sm mono" type="number" data-path="${path}.${i}.v" value="${esc(r.v)}" style="width:80px">
                <button class="bx-tool danger" data-del="${path}.${i}" title="Remove"><i class="fas fa-xmark"></i></button></div>`).join('')}
            ${(rows || []).length < 3 ? `<button class="bx-btn xs ghost" data-addfx="${path}" data-key="${keys[0]}"><i class="fas fa-plus"></i>Effect</button>` : ''}</div>`;
    }

    function recipesView() {
        return draft.recipes.map((r, i) => `<div class="bx-card bc-item">
            <div class="bc-head"><span class="bx-kindico"><i class="fas fa-screwdriver-wrench"></i></span>${txt(`recipes.${i}.label`, r.label, 48, 'Recipe name')}
                <select class="bx-input" data-path="recipes.${i}.tier" style="width:150px">${data.tiers.map((t) => `<option ${t === r.tier ? 'selected' : ''}>${esc(t)}</option>`).join('')}</select>
                ${num(`recipes.${i}.time`, r.time, 0.5, 120, 0.5, 's')}
                <button class="bx-tool danger" data-del="recipes.${i}" title="Remove recipe"><i class="fas fa-trash"></i></button></div>
            <div class="bc-body"><div class="bx-mini"><span>Makes</span><div class="bc-line">${txt(`recipes.${i}.output.item`, r.output && r.output.item, 64, 'item name', true)}${num(`recipes.${i}.output.count`, r.output && r.output.count, 1, 1000, 1, 'x')}</div></div>
                <div class="bx-mini"><span>Needs</span>${(r.inputs || []).map((inp, j) => `<div class="bc-line">${txt(`recipes.${i}.inputs.${j}.item`, inp.item, 64, 'item name', true)}${num(`recipes.${i}.inputs.${j}.count`, inp.count, 1, 1000, 1, 'x')}<button class="bx-tool danger" data-del="recipes.${i}.inputs.${j}"><i class="fas fa-xmark"></i></button></div>`).join('')}
                    <button class="bx-btn xs ghost" data-add="recipes.${i}.inputs"><i class="fas fa-plus"></i>Ingredient</button></div></div>
        </div>`).join('') + '<button class="bx-newcard bc-new" data-add="recipes"><i class="fas fa-plus"></i>New recipe</button>';
    }

    function perksView() {
        return draft.perks.map((b, i) => `<div class="bx-card bc-item">
            <div class="bc-head"><span class="bx-kindico"><i class="fas ${esc(b.icon)}"></i></span>${txt(`perks.${i}.label`, b.label, 32, 'Branch name')}
                <select class="bx-input" data-path="perks.${i}.icon" style="width:190px">${ICONS.map((ic) => `<option value="${ic}" ${ic === b.icon ? 'selected' : ''}>${ic.replace('fa-', '')}</option>`).join('')}</select>
                <button class="bx-tool danger" data-del="perks.${i}" title="Remove branch"><i class="fas fa-trash"></i></button></div>
            <div class="bc-tiers">${(b.tiers || []).map((t, j) => `<div class="bc-tier"><span class="bc-step">${j + 1}</span>
                <div class="bc-tiermain">${txt(`perks.${i}.tiers.${j}.label`, t.label, 40, 'Perk name')}${txt(`perks.${i}.tiers.${j}.description`, t.description, 120, 'What it does, in a few words')}</div>
                ${num(`perks.${i}.tiers.${j}.cost`, t.cost, 1, 20, 1, 'pts')}
                ${fxRows(`perks.${i}.tiers.${j}.fx`, t.fx, data.perkEffects)}
                <button class="bx-tool danger" data-del="perks.${i}.tiers.${j}" title="Remove perk"><i class="fas fa-xmark"></i></button></div>`).join('')}
                ${(b.tiers || []).length < 6 ? `<button class="bx-btn xs ghost" data-add="perks.${i}.tiers"><i class="fas fa-plus"></i>Perk</button>` : ''}</div>
        </div>`).join('') + (draft.perks.length < 8 ? '<button class="bx-newcard bc-new" data-add="perks"><i class="fas fa-plus"></i>New branch</button>' : '');
    }

    function upgradesView() {
        return draft.upgrades.map((u, i) => `<div class="bx-card bc-item">
            <div class="bc-head"><span class="bx-kindico"><i class="fas ${esc(u.icon)}"></i></span>${txt(`upgrades.${i}.label`, u.label, 40, 'Upgrade name')}
                <select class="bx-input" data-path="upgrades.${i}.icon" style="width:190px">${ICONS.map((ic) => `<option value="${ic}" ${ic === u.icon ? 'selected' : ''}>${ic.replace('fa-', '')}</option>`).join('')}</select>
                <button class="bx-tool danger" data-del="upgrades.${i}" title="Remove upgrade"><i class="fas fa-trash"></i></button></div>
            <div class="bc-body1">${txt(`upgrades.${i}.description`, u.description, 120, 'One line on what it is for')}</div>
            <div class="bc-tiers">${(u.levels || []).map((l, j) => `<div class="bc-tier"><span class="bc-step">L${j + 1}</span>
                ${num(`upgrades.${i}.levels.${j}.cost`, l.cost, 0, 100000000, 1000, '$')}
                ${fxRows(`upgrades.${i}.levels.${j}.fx`, l.fx, data.upgradeEffects)}
                <button class="bx-tool danger" data-del="upgrades.${i}.levels.${j}" title="Remove level"><i class="fas fa-xmark"></i></button></div>`).join('')}
                ${(u.levels || []).length < 8 ? `<button class="bx-btn xs ghost" data-add="upgrades.${i}.levels"><i class="fas fa-plus"></i>Level</button>` : ''}</div>
        </div>`).join('') + (draft.upgrades.length < 12 ? '<button class="bx-newcard bc-new" data-add="upgrades"><i class="fas fa-plus"></i>New upgrade</button>' : '');
    }

    function render() {
        if (!el) return;
        if (!data) { el.innerHTML = '<div class="bx-empty"><i class="fas fa-screwdriver-wrench"></i><b>Loading</b></div>'; return; }
        const body = tab === 'perks' ? perksView() : (tab === 'upgrades' ? upgradesView() : recipesView());
        const hint = {
            recipes: 'Crews use these at any crafting bench they have placed. A recipe only shows once the crew reaches its tier.',
            perks: 'Crews spend perk points down each branch in order. Effects add up across everything they own.',
            upgrades: 'Bought with the treasury, one level at a time. The Prices page can still change any cost.',
        }[tab];
        el.innerHTML = `<datalist id="bc-items">${data.items.map((i) => `<option value="${esc(i.name)}" data-image="${esc(i.image || '')}">${esc(i.label)}</option>`).join('')}</datalist>
            <div class="bx-tabs">${TABS.map(([id, label]) => `<button class="bx-tab ${id === tab ? 'on' : ''}" data-tab-go="${id}">${esc(label)}<em>${(draft[id] || []).length}</em></button>`).join('')}</div>
            <p class="bx-hint" style="margin:-6px 0 14px">${esc(hint)} ${data.edited[tab] ? '<span class="bx-chip warn">Changed from config.lua</span>' : '<span class="bx-chip off">As config.lua</span>'}</p>
            <div class="bc-list">${body}</div>
            <div class="bx-savebar ${dirty(tab) ? '' : 'quiet'}">
                ${dirty(tab) ? '<span><b>Unsaved</b> changes</span><button class="bx-btn sm ghost" id="bc-discard">Discard</button>' : ''}
                ${data.edited[tab] ? '<button class="bx-btn sm ghost" id="bc-reset"><i class="fas fa-rotate-left"></i>Back to config.lua</button>' : ''}
                <button class="bx-btn sm primary" id="bc-save" ${dirty(tab) ? '' : 'disabled'}><i class="fas fa-check"></i>Save ${esc(TABS.find((t) => t[0] === tab)[1].toLowerCase())}</button>
            </div>`;
        bind();
    }

    function walk(path) {
        const parts = path.split('.');
        let node = draft;
        for (let i = 0; i < parts.length - 1; i++) node = node[/^\d+$/.test(parts[i]) ? Number(parts[i]) : parts[i]];
        return [node, /^\d+$/.test(parts[parts.length - 1]) ? Number(parts[parts.length - 1]) : parts[parts.length - 1]];
    }

    function bind() {
        el.querySelectorAll('[data-tab-go]').forEach((b) => b.addEventListener('click', () => { tab = b.dataset.tabGo; render(); }));
        el.querySelectorAll('[data-path]').forEach((i) => i.addEventListener('change', () => {
            const [node, key] = walk(i.dataset.path);
            node[key] = i.type === 'number' ? Number(i.value) : i.value.trim();
            render();
        }));
        el.querySelectorAll('[data-del]').forEach((b) => b.addEventListener('click', () => {
            const [node, key] = walk(b.dataset.del);
            if (Array.isArray(node)) node.splice(key, 1);
            render();
        }));
        el.querySelectorAll('[data-addfx]').forEach((b) => b.addEventListener('click', () => {
            const [node, key] = walk(`${b.dataset.addfx}.x`);
            node.push({ k: b.dataset.key, v: 1 });
            render();
        }));
        el.querySelectorAll('[data-add]').forEach((b) => b.addEventListener('click', () => {
            const path = b.dataset.add;
            const list = path.split('.').length === 1 ? draft[path] : walk(`${path}.x`)[0];
            if (path === 'recipes') list.push({ id: '', label: 'New recipe', tier: data.tiers[0], time: 5, output: { item: '', count: 1 }, inputs: [{ item: '', count: 1 }] });
            else if (path === 'perks') list.push({ id: '', label: 'New branch', icon: 'fa-star', tiers: [{ id: '', label: 'First perk', description: '', cost: 1, fx: [] }] });
            else if (path === 'upgrades') list.push({ id: '', label: 'New upgrade', icon: 'fa-star', description: '', levels: [{ cost: 25000, fx: [] }] });
            else if (path.endsWith('.inputs')) list.push({ item: '', count: 1 });
            else if (path.endsWith('.tiers')) list.push({ id: '', label: 'New perk', description: '', cost: list.length + 1, fx: [] });
            else if (path.endsWith('.levels')) list.push({ cost: ((list[list.length - 1] || {}).cost || 25000) * 2, fx: [] });
            render();
        }));
        const discard = el.querySelector('#bc-discard');
        if (discard) discard.addEventListener('click', () => { draft[tab] = copy(base[tab]); render(); });
        const reset = el.querySelector('#bc-reset');
        if (reset) reset.addEventListener('click', async () => {
            const res = await acall('XS-CriminalTablet:admin:resetContent', tab);
            if (!res || !res.ok) return toast((res && res.error) || 'Could not reset', 'error');
            data = res.data; prime(tab); render();
            toast('Back to what config.lua says.', 'success');
        });
        const save = el.querySelector('#bc-save');
        if (save) save.addEventListener('click', async () => {
            let payload = copy(draft[tab]);
            if (tab === 'recipes') payload = payload.map((r) => Object.assign(r, { time: Math.round(Number(r.time) * 1000) }));
            if (tab === 'perks') payload = payload.map((b) => Object.assign(b, { tiers: b.tiers.map((t) => { const out = fromRows(Object.assign({}, t), t.fx, data.perkEffects); delete out.fx; return out; }) }));
            if (tab === 'upgrades') payload = payload.map((u) => Object.assign(u, { levels: u.levels.map((l) => { const out = fromRows(Object.assign({}, l), l.fx, data.upgradeEffects); delete out.fx; return out; }) }));
            const res = await acall('XS-CriminalTablet:admin:saveContent', tab, payload);
            if (!res || !res.ok) return toast((res && res.error) || 'Could not save', 'error');
            data = res.data;
            prime(tab);
            render();
            toast('Saved. Crews have it now.', 'success');
        });
    }

    window.XS.BuilderContent = {
        mount(target) { el = target; if (!data) { render(); load(); } else render(); },
    };
})();
