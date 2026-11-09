// ─────────────────────────────────────────────────────────────
// Searchable list under a text box: items in the builder, cars on a
// crew's garage tab. FiveM's browser does not reliably show the native
// <datalist> popup, so any box tied to one gets this list instead.
// ─────────────────────────────────────────────────────────────
(() => {
    let open = null;
    const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

    function attach(input, opts) {
        if (input._xsList) {
            input._xsList.opts = opts;
            return input._xsList;
        }
        const box = document.createElement('div');
        box.className = 'xs-list hidden';
        document.body.appendChild(box);
        const api = { opts, active: 0, shown: [], picking: false };
        input._xsList = api;
        input.setAttribute('autocomplete', 'off');

        const options = () => {
            const o = api.opts.options;
            return (typeof o === 'function' ? o() : o) || [];
        };
        const icon = () => api.opts.icon || 'fa-cube';

        function place() {
            const r = input.getBoundingClientRect();
            box.style.left = `${r.left}px`;
            box.style.width = `${Math.max(r.width, 300)}px`;
            const below = window.innerHeight - r.bottom;
            if (below < 260 && r.top > below) {
                box.style.top = '';
                box.style.bottom = `${window.innerHeight - r.top + 4}px`;
            } else {
                box.style.bottom = '';
                box.style.top = `${r.bottom + 4}px`;
            }
        }

        function matches(q) {
            const all = options();
            if (!q) return all;
            const starts = [];
            const has = [];
            all.forEach((o) => {
                const v = String(o.value).toLowerCase();
                const l = String(o.label || '').toLowerCase();
                if (v.startsWith(q) || l.startsWith(q)) starts.push(o);
                else if (v.includes(q) || l.includes(q) || String(o.sub || '').toLowerCase().includes(q)) has.push(o);
            });
            return starts.concat(has);
        }

        function render() {
            const hits = matches(input.value.trim().toLowerCase());
            api.shown = hits.slice(0, 80);
            api.active = Math.min(api.active, Math.max(0, api.shown.length - 1));
            const total = options().length;
            box.innerHTML = api.shown.length
                ? api.shown.map((o, i) => `<div class="xs-list-row${i === api.active ? ' is-active' : ''}" data-i="${i}">
                        <span class="xs-list-pic">${o.image ? `<img src="${esc(o.image)}" alt="">` : `<i class="fas ${esc(icon())}"></i>`}</span>
                        <span class="xs-list-main"><b>${esc(o.label || o.value)}</b><small>${esc(o.value)}${o.sub ? ` · ${esc(o.sub)}` : ''}</small></span>
                    </div>`).join('') + (hits.length > api.shown.length ? `<div class="xs-list-more">${hits.length - api.shown.length} more. Keep typing.</div>` : '')
                : `<div class="xs-list-more">${total ? 'Nothing matches. What you typed still works.' : 'Nothing to pick from.'}</div>`;
            box.querySelectorAll('img').forEach((img) => {
                img.addEventListener('error', () => {
                    const i = document.createElement('i');
                    i.className = `fas ${icon()}`;
                    img.replaceWith(i);
                }, { once: true });
            });
            const act = box.querySelector('.is-active');
            if (act) act.scrollIntoView({ block: 'nearest' });
        }

        function show() {
            if (open && open !== api) open.hide();
            open = api;
            place();
            render();
            box.classList.remove('hidden');
        }
        function hide() {
            box.classList.add('hidden');
            if (open === api) open = null;
        }
        function pick(o) {
            api.picking = true;
            input.value = o.value;
            hide();
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            api.picking = false;
            if (api.opts.onPick) api.opts.onPick(o);
        }
        api.show = show;
        api.hide = hide;
        api.box = box;

        input.addEventListener('focus', show);
        input.addEventListener('input', () => {
            if (api.picking) return;
            api.active = 0;
            show();
        });
        input.addEventListener('keydown', (e) => {
            if (box.classList.contains('hidden')) {
                if (e.key === 'ArrowDown') { show(); e.preventDefault(); }
                return;
            }
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
                const n = Math.max(1, api.shown.length);
                api.active = (api.active + (e.key === 'ArrowDown' ? 1 : -1) + n) % n;
                render();
                e.preventDefault();
            } else if (e.key === 'Enter' && api.shown[api.active]) {
                pick(api.shown[api.active]);
                e.preventDefault();
            } else if (e.key === 'Escape') {
                hide();
                e.stopPropagation();
            }
        });
        input.addEventListener('blur', () => setTimeout(hide, 120));
        box.addEventListener('mousedown', (e) => {
            const row = e.target.closest('[data-i]');
            e.preventDefault();
            if (row) pick(api.shown[Number(row.dataset.i)]);
        });
        return api;
    }

    // Scrolling the page would leave the list floating where the box was.
    document.addEventListener('scroll', (e) => {
        if (open && !open.box.contains(e.target)) open.hide();
    }, true);

    // Every builder box that names a <datalist> gets the list instead.
    document.addEventListener('focusin', (e) => {
        const el = e.target;
        if (!(el instanceof HTMLInputElement) || el._xsList) return;
        const id = el.getAttribute('list');
        if (!id || !document.getElementById(id)) return;
        el.removeAttribute('list');
        attach(el, {
            options: () => {
                const dl = document.getElementById(id);
                return dl ? Array.from(dl.options).map((o) => ({
                    value: o.value, label: (o.textContent || '').trim() || o.value, image: o.dataset.image || null,
                })) : [];
            },
        }).show();
    });

    window.XSList = attach;
})();
