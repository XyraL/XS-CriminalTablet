// Builder Radial page: which actions the F6 wheel shows, what they are
// called and in what order, with the wheel itself drawn live beside the list.
(function () {
    const esc = (v) => window.XS.escapeHtml(v);
    const acall = (name, ...args) => window.XS.nui('admin:call', { name, args });
    const bs = () => window.XS.BuilderSettings;
    let el = null;
    let draft = null;
    let hover = -1;
    let dragId = null;

    const keyOn = (id) => `Radial.actions.${id}.enabled`;
    const keyLabel = (id) => `Radial.actions.${id}.label`;

    function saved() {
        const icons = bs().radialIcons() || {};
        const ids = Object.keys(icons);
        const order = (bs().value('Radial.order') || []).filter((id) => icons[id]);
        ids.forEach((id) => { if (!order.includes(id)) order.push(id); });
        const out = { order, on: {}, label: {} };
        ids.forEach((id) => { out.on[id] = bs().value(keyOn(id)) !== false; out.label[id] = bs().value(keyLabel(id)) || id; });
        return out;
    }

    const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
    const dirty = () => draft && !same(draft, saved());

    function render() {
        if (!el) return;
        if (!bs() || !bs().ready()) { el.innerHTML = '<div class="bx-empty"><i class="fas fa-circle-dot"></i><b>Loading the wheel</b></div>'; return; }
        if (!draft) draft = saved();
        const icons = bs().radialIcons();
        const shown = draft.order.filter((id) => draft.on[id]);
        const preview = shown.map((id) => ({ id, icon: icons[id], label: draft.label[id] }));
        const hoverIndex = hover >= 0 ? shown.indexOf(draft.order[hover]) : -1;
        const hovered = hoverIndex >= 0 ? preview[hoverIndex] : null;
        el.innerHTML = `<div class="we-cols">
            <div>
                <div class="bx-setbar">
                    <span class="bx-chip">${shown.length} of ${draft.order.length} on the wheel</span>
                    <span class="bx-sp"></span>
                    <button class="bx-btn sm ghost" data-go-settings><i class="fas fa-sliders"></i>Wheel settings</button>
                </div>
                <div class="we-list">${draft.order.map((id, i) => `<div class="we-item ${draft.on[id] ? '' : 'off'} ${i === hover ? 'on' : ''}" draggable="true" data-row="${esc(id)}" data-i="${i}">
                    <span class="we-grip">⋮⋮</span>
                    <span class="we-thumb"><i class="fas ${esc(icons[id])}"></i></span>
                    <div class="we-main"><input class="bx-input sm" data-label="${esc(id)}" maxlength="24" value="${esc(draft.label[id])}"><span>${esc(id)}</span></div>
                    <button class="bx-tool" data-move="${i}" data-dir="-1" title="Move up" ${i === 0 ? 'disabled' : ''}><i class="fas fa-chevron-up"></i></button>
                    <button class="bx-tool" data-move="${i}" data-dir="1" title="Move down" ${i === draft.order.length - 1 ? 'disabled' : ''}><i class="fas fa-chevron-down"></i></button>
                    <span class="bx-switch ${draft.on[id] ? 'on' : ''}" data-on="${esc(id)}"></span>
                </div>`).join('')}</div>
            </div>
            <div class="we-right">
                <div class="we-wheel">${window.XS.radialRing(preview, hoverIndex)}
                    <div class="we-hub"><span class="we-crumb">Field</span><b>${esc(hovered ? hovered.label : 'Field')}</b><span>${hovered ? `Key ${hoverIndex + 1 <= 9 ? hoverIndex + 1 : '—'}` : `${shown.length} actions`}</span></div>
                </div>
                <div class="we-tip">This is the wheel crews see on ${esc(bs().value('Radial.key') || 'F6')}. Actions that make no sense where they stand still show, greyed out with the reason.</div>
            </div>
        </div>
        ${dirty() ? `<div class="bx-savebar"><span><b>Wheel</b> has unsaved changes</span><button class="bx-btn sm ghost" id="br-discard">Discard</button><button class="bx-btn sm ghost" id="br-default">Back to config.lua</button><button class="bx-btn sm primary" id="br-save"><i class="fas fa-check"></i>Save wheel</button></div>` : `<div class="bx-savebar quiet"><button class="bx-btn sm ghost" id="br-default">Back to config.lua</button></div>`}`;
        bind();
    }

    function bind() {
        el.querySelectorAll('[data-on]').forEach((s) => s.addEventListener('click', () => {
            draft.on[s.dataset.on] = !draft.on[s.dataset.on];
            render();
        }));
        el.querySelectorAll('[data-label]').forEach((i) => i.addEventListener('change', () => {
            const v = i.value.replace(/[\u0000-\u001f]/g, '').trim().slice(0, 24);
            if (v) draft.label[i.dataset.label] = v;
            render();
        }));
        el.querySelectorAll('[data-move]').forEach((b) => b.addEventListener('click', () => {
            const i = Number(b.dataset.move);
            const j = i + Number(b.dataset.dir);
            if (j < 0 || j >= draft.order.length) return;
            [draft.order[i], draft.order[j]] = [draft.order[j], draft.order[i]];
            hover = j;
            render();
        }));
        el.querySelectorAll('.we-item').forEach((row) => {
            row.addEventListener('mouseenter', () => { if (hover !== Number(row.dataset.i)) { hover = Number(row.dataset.i); paintPreview(); } });
            row.addEventListener('dragstart', (e) => { dragId = row.dataset.row; row.classList.add('drag'); e.dataTransfer.effectAllowed = 'move'; });
            row.addEventListener('dragend', () => { dragId = null; row.classList.remove('drag'); });
            row.addEventListener('dragover', (e) => { if (!dragId) return; e.preventDefault(); row.classList.add('over'); });
            row.addEventListener('dragleave', () => row.classList.remove('over'));
            row.addEventListener('drop', (e) => {
                e.preventDefault();
                if (!dragId || dragId === row.dataset.row) return;
                const from = draft.order.indexOf(dragId);
                draft.order.splice(from, 1);
                draft.order.splice(draft.order.indexOf(row.dataset.row), 0, dragId);
                hover = draft.order.indexOf(dragId);
                render();
            });
        });
        el.querySelector('[data-go-settings]').addEventListener('click', () => { window.XSAdmin.go('admin-settings'); bs().focus('Radial.enabled'); });
        const discard = el.querySelector('#br-discard');
        if (discard) discard.addEventListener('click', () => { draft = null; render(); });
        el.querySelector('#br-default').addEventListener('click', () => {
            const icons = bs().radialIcons();
            const order = (bs().defaultOf('Radial.order') || []).slice();
            Object.keys(icons).forEach((id) => { if (!order.includes(id)) order.push(id); });
            draft = { order, on: {}, label: {} };
            Object.keys(icons).forEach((id) => { draft.on[id] = bs().defaultOf(keyOn(id)) !== false; draft.label[id] = bs().defaultOf(keyLabel(id)) || id; });
            render();
        });
        const save = el.querySelector('#br-save');
        if (save) save.addEventListener('click', api.save);
    }

    // Hovering a row only re-highlights the preview, so the label being
    // typed into is never thrown away by a full repaint.
    function paintPreview() {
        el.querySelectorAll('.we-item').forEach((r) => r.classList.toggle('on', Number(r.dataset.i) === hover));
        const icons = bs().radialIcons();
        const shown = draft.order.filter((id) => draft.on[id]);
        const preview = shown.map((id) => ({ id, icon: icons[id], label: draft.label[id] }));
        const hoverIndex = hover >= 0 ? shown.indexOf(draft.order[hover]) : -1;
        const wheel = el.querySelector('.we-wheel');
        wheel.querySelector('svg').outerHTML = window.XS.radialRing(preview, hoverIndex);
        const hub = wheel.querySelector('.we-hub');
        hub.querySelector('b').textContent = hoverIndex >= 0 ? preview[hoverIndex].label : 'Field';
        hub.querySelector('span:last-child').textContent = hoverIndex >= 0 ? `Key ${hoverIndex + 1 <= 9 ? hoverIndex + 1 : '—'}` : `${shown.length} actions`;
    }

    const api = {
        mount(target) { el = target; render(); },
        refresh() { draft = null; render(); },
        isDirty: () => !!dirty(),
        async save() {
            if (!dirty()) return;
            const base = saved();
            const changes = {};
            if (!same(draft.order, base.order)) changes['Radial.order'] = draft.order;
            Object.keys(draft.on).forEach((id) => {
                if (draft.on[id] !== base.on[id]) changes[keyOn(id)] = draft.on[id];
                if (draft.label[id] !== base.label[id]) changes[keyLabel(id)] = draft.label[id];
            });
            const res = await acall('XS-CriminalTablet:admin:saveSettings', changes, []);
            if (!res || !res.ok) { window.XSAdmin.toast((res && res.error) || 'Could not save', 'error'); return; }
            await bs().load();
            draft = null;
            window.XSAdmin.toast('Wheel saved. Crews see it the next time they open it.', 'success');
            render();
        },
    };
    window.XS.BuilderRadial = api;
})();
