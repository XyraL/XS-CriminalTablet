// ─────────────────────────────────────────────────────────────
// Crafting bench panel. Reuses the global `nui()` helper from app.js
// (same resource, same fetch target) — no need to redefine it here.
// ─────────────────────────────────────────────────────────────
(() => {
    const $ = (s) => document.querySelector(s);

    let data = { recipes: [] };
    let selected = null;
    let qty = 1;
    let working = false;
    let stamp = null;

    window.addEventListener('message', (ev) => {
        const m = ev.data || {};
        if (m.action === 'craftOpen') openCraft(m.label, m.data || {});
        else if (m.action === 'craftClose') closeCraft();
    });

    document.addEventListener('keydown', (e) => {
        if ($('#craftRoot').classList.contains('hidden')) return;
        if (e.key === 'Escape') {
            nui('craft:escape');
            closeCraft();
        } else if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && !working) {
            const list = (data.recipes || []);
            if (!list.length) return;
            const i = Math.max(0, list.findIndex((r) => selected && r.id === selected.id));
            const next = list[(i + (e.key === 'ArrowDown' ? 1 : list.length - 1)) % list.length];
            pick(next.id);
            e.preventDefault();
        } else if (e.key === 'Enter' && selected && !working) {
            build();
        }
    });

    $('#craftCloseBtn').onclick = () => {
        nui('craft:close');
        closeCraft();
    };

    const seconds = (ms) => `${(ms / 1000).toFixed(ms < 10000 ? 1 : 0)} s`;
    const pad = (n) => String(n).padStart(2, '0');
    const picture = (img, icon) => (img ? `<img src="${esc(img)}" alt="" data-fb="${icon}">` : `<i class="fas ${icon}"></i>`);
    const thumb = (img, icon) => `<span class="bp-thumb">${picture(img, icon)}</span>`;

    // An item with no picture in the inventory falls back to an icon.
    function fallbacks(root) {
        root.querySelectorAll('img[data-fb]').forEach((img) => {
            const swap = () => {
                const i = document.createElement('i');
                i.className = `fas ${img.dataset.fb}`;
                img.replaceWith(i);
            };
            if (img.complete && !img.naturalWidth && img.src) swap();
            else img.addEventListener('error', swap, { once: true });
        });
    }
    const ready = (r) => !r.locked && r.max > 0;

    function openCraft(label, d) {
        data = Array.isArray(d) ? { recipes: d } : d;
        data.recipes = data.recipes || [];
        working = false;
        stamp = null;
        const first = data.recipes.find(ready) || data.recipes.find((r) => !r.locked) || data.recipes[0];
        selected = first || null;
        qty = 1;

        $('#craftBenchLabel').textContent = label || 'Crafting Bench';
        $('#craftBenchName').textContent = label || 'Crafting Bench';
        $('#craftCrew').textContent = data.crew || '—';
        const crest = $('#craftCrest');
        crest.innerHTML = data.logo ? `<img src="${esc(data.logo)}" alt="">`
            : esc(String(data.crew || 'XS').split(/\s+/).slice(0, 2).map((w) => w[0] || '').join('').toUpperCase());
        crest.style.borderColor = data.color || '';
        renderPerks();
        $('#craftRoot').classList.remove('hidden');
        renderList();
        renderDetail();
    }

    function closeCraft() {
        $('#craftRoot').classList.add('hidden');
        working = false;
    }

    function renderPerks() {
        const p = data.perks || {};
        const chips = [];
        if (p.timePct) chips.push(`<span class="bp-perk"><i class="fas fa-stopwatch"></i>${p.timePct > 0 ? '+' : '−'}${Math.abs(p.timePct)}% build time</span>`);
        if (p.bonusChance) chips.push(`<span class="bp-perk"><i class="fas fa-clone"></i>${p.bonusChance}% chance of double</span>`);
        if (p.tierBoost) chips.push(`<span class="bp-perk"><i class="fas fa-angles-up"></i>Works ${p.tierBoost} tier${p.tierBoost === 1 ? '' : 's'} up</span>`);
        $('#craftPerks').innerHTML = chips.join('');
    }

    function renderList() {
        const list = $('#craftRecipeList');
        const recipes = data.recipes;
        $('#craftCount').textContent = recipes.length ? `${recipes.filter(ready).length}/${recipes.length} ready` : '';
        if (!recipes.length) {
            list.innerHTML = '<div class="bp-empty"><i class="fas fa-compass-drafting"></i>No recipes for this bench yet.<br>Staff add them in the builder.</div>';
            return;
        }
        list.innerHTML = recipes.map((r, i) => {
            const state = r.locked ? `<span class="bp-state lock">${esc(r.tierName)}</span>`
                : r.max > 0 ? '<span class="bp-state ok">Ready</span>' : '<span class="bp-state short">Short</span>';
            const out = r.output || {};
            return `<button class="bp-row${selected && selected.id === r.id ? ' is-active' : ''}${r.locked ? ' is-locked' : ''}" data-recipe="${esc(r.id)}">
                <span class="bp-row-no">${pad(i + 1)}</span>
                ${thumb(out.image, 'fa-cube')}
                <span class="bp-row-main"><b>${esc(r.label)}</b><small>×${out.count || 1} · ${seconds(r.time || 0)}</small></span>
                ${state}
            </button>`;
        }).join('');
        fallbacks(list);
        list.querySelectorAll('[data-recipe]').forEach((b) => {
            b.onclick = () => { if (!working) pick(b.dataset.recipe); };
        });
    }

    function pick(id) {
        selected = data.recipes.find((r) => r.id === id) || null;
        qty = 1;
        stamp = null;
        renderList();
        renderDetail();
        const row = $(`#craftRecipeList [data-recipe="${CSS.escape(id)}"]`);
        if (row) row.scrollIntoView({ block: 'nearest' });
    }

    function renderDetail() {
        const el = $('#craftDetail');
        const r = selected;
        if (!r) {
            el.innerHTML = '<div class="bp-empty"><i class="fas fa-compass-drafting"></i>Pick a part from the index.</div>';
            $('#craftSheet').textContent = '—';
            return;
        }
        const idx = data.recipes.indexOf(r);
        $('#craftSheet').textContent = `${pad(idx + 1)} of ${pad(data.recipes.length)}`;
        const out = r.output || {};
        const max = Math.max(0, Math.min(r.max || 0, data.maxBatch || 10));
        qty = Math.max(1, Math.min(qty, Math.max(1, max)));
        const canBuild = !r.locked && max > 0 && !working;
        const uses = (r.inputs || []).map((i) => `<b>${i.count * qty}×</b> ${esc(i.label || i.item)}`).join(', ');

        el.innerHTML = `
            ${r.locked ? `<div class="bp-stamp lock">Locked<small>Reach ${esc(r.tierName)}</small></div>` : ''}
            ${stamp ? `<div class="bp-stamp ${stamp.kind}">${esc(stamp.text)}${stamp.sub ? `<small>${esc(stamp.sub)}</small>` : ''}</div>` : ''}
            <div class="bp-top">
                <div class="bp-figure">
                    <span class="bp-dim bp-dim-h"><b>OUTPUT ×${out.count || 1}</b></span>
                    <span class="bp-dim bp-dim-v"><b>${seconds(r.time || 0)}</b></span>
                    ${picture(out.image, 'fa-cube')}
                    <span class="bp-fig">FIG. ${pad(idx + 1)}</span>
                </div>
                <div class="bp-spec">
                    <span class="bp-kicker">Drawing ${pad(idx + 1)} · ${esc(r.tierName)} tier</span>
                    <h2>${esc(r.label)}</h2>
                    <p class="bp-sub">Makes <b>${out.count || 1}× ${esc(out.label || out.item || '')}</b> · ${seconds(r.time || 0)} each</p>
                    <table class="bp-bom">
                        <thead><tr><th>Qty</th><th>Part</th><th>On hand</th></tr></thead>
                        <tbody>${(r.inputs || []).map((i) => {
                            const enough = i.have >= i.count * qty;
                            return `<tr class="${enough ? 'ok' : 'short'}">
                                <td class="num">${i.count}×</td>
                                <td><span class="bp-part">${thumb(i.image, 'fa-gear')}${esc(i.label || i.item)}</span></td>
                                <td class="bp-have">${i.have} ${enough ? '<i class="fas fa-check"></i>' : `<i class="fas fa-xmark"></i> need ${i.count * qty - i.have} more`}</td>
                            </tr>`;
                        }).join('')}</tbody>
                    </table>
                </div>
            </div>
            <ol class="bp-notes">
                <span class="bp-notes-head">Notes</span>
                <li>Parts come out of your pockets when the build finishes.</li>
                <li>Walking away or closing the bench stops the build; nothing is lost.</li>
                <li>Make up to ${data.maxBatch || 10} at once.${(data.perks || {}).bonusChance ? ` Each one has a ${data.perks.bonusChance}% chance to come out double.` : ''}</li>
            </ol>
            <div class="bp-run">
                <div class="bp-qty">
                    <button data-q="-1" ${!canBuild || qty <= 1 ? 'disabled' : ''}>−</button>
                    <span id="craftQty">${qty}</span>
                    <button data-q="1" ${!canBuild || qty >= max ? 'disabled' : ''}>+</button>
                    <button class="bp-max" data-q="max" ${!canBuild || qty >= max ? 'disabled' : ''}>Max</button>
                </div>
                <div class="bp-total">${r.locked ? `Your crew reaches this at <b>${esc(r.tierName)}</b>.`
                    : max > 0 ? `Uses ${uses}. Makes <b>${(out.count || 1) * qty}× ${esc(out.label || out.item || '')}</b> in <b>${seconds((r.time || 0) * qty)}</b>.`
                    : 'You are short on parts. Everything in red has to be in your pockets.'}</div>
                <button class="bp-build" id="craftMakeBtn" ${canBuild ? '' : 'disabled'}><span class="bp-build-fill" id="craftFill"></span><span id="craftMakeLabel">Build</span></button>
            </div>`;

        fallbacks(el);
        el.querySelectorAll('[data-q]').forEach((b) => {
            b.onclick = () => {
                const q = b.dataset.q;
                qty = q === 'max' ? max : Math.max(1, Math.min(max, qty + Number(q)));
                stamp = null;
                renderDetail();
            };
        });
        $('#craftMakeBtn').onclick = build;
    }

    async function build() {
        const r = selected;
        if (!r || working || r.locked || !(r.max > 0)) return;
        working = true;
        stamp = null;
        const btn = $('#craftMakeBtn');
        const begin = await nui('craft:begin', { id: r.id, qty });
        if (!begin || !begin.ok) {
            working = false;
            stamp = { kind: 'fail', text: 'Refused', sub: (begin && begin.error) || 'try again' };
            renderDetail();
            return;
        }

        const duration = Math.max(500, Number(begin.time) || (r.time || 3000) * qty);
        btn.classList.add('is-working');
        btn.disabled = true;
        $('#craftMakeLabel').textContent = 'Working';
        $$all('#craftDetail .bp-qty button').forEach((b) => { b.disabled = true; });
        const fill = $('#craftFill');
        fill.style.transition = `width ${duration}ms linear`;
        requestAnimationFrame(() => { fill.style.width = '100%'; });
        const started = Date.now();
        const tick = setInterval(() => {
            const left = Math.max(0, duration - (Date.now() - started));
            const label = $('#craftMakeLabel');
            if (!label || !working) return clearInterval(tick);
            label.textContent = seconds(left);
        }, 100);

        await new Promise((resolve) => setTimeout(resolve, duration + 120));
        clearInterval(tick);
        if (!working) return;

        const res = await nui('craft:finish');
        working = false;
        if (res && res.ok) {
            if (res.data && Array.isArray(res.data.recipes)) {
                data = Object.assign(data, res.data);
                selected = data.recipes.find((x) => x.id === r.id) || selected;
            }
            const out = (selected && selected.output) || {};
            stamp = { kind: 'done', text: `Built ×${res.made || qty}`, sub: res.doubled ? `${res.doubled} came out double` : (out.label || '') };
        } else {
            stamp = { kind: 'fail', text: 'Failed', sub: (res && res.error) || 'try again' };
        }
        qty = 1;
        renderList();
        renderDetail();
    }

    function $$all(sel) { return Array.from(document.querySelectorAll(sel)); }

    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    }
})();
