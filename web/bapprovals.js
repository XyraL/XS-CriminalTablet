// Builder Approvals page: crew logos and tag photos waiting on staff.
(function () {
    const esc = (v) => window.XS.escapeHtml(v);
    const acall = (name, ...args) => window.XS.nui('admin:call', { name, args });
    const toast = (m, k) => window.XSAdmin.toast(m, k);
    let el = null;
    let data = null;
    const KIND = { logo: ['Crew logo', 'fa-shield-halved'], tag: ['Tag photo', 'fa-spray-can'] };
    const ago = (ms) => {
        if (!ms) return '';
        const m = Math.floor((Date.now() - ms) / 60000);
        if (m < 60) return m < 1 ? 'just now' : `${m}m ago`;
        const h = Math.floor(m / 60);
        return h < 24 ? `${h}h ago` : `${Math.floor(h / 24)}d ago`;
    };

    function setCount() {
        const c = document.getElementById('bxCountApprovals');
        const n = data ? data.pending.length : 0;
        if (c) { c.textContent = n; c.classList.toggle('hidden', !n); }
    }

    async function load() {
        const res = await acall('XS-CriminalTablet:admin:approvals');
        if (!res || !res.ok) return;
        data = { pending: Array.isArray(res.data.pending) ? res.data.pending : [], recent: Array.isArray(res.data.recent) ? res.data.recent : [] };
        setCount();
        render();
    }

    function render() {
        if (!el) return;
        if (!data) { el.innerHTML = '<div class="bx-empty"><i class="fas fa-image"></i><b>Loading</b></div>'; return; }
        const card = (s) => `<div class="ba-card" data-id="${s.id}">
            <div class="ba-img"><img src="${esc(s.url)}" alt="" onerror="this.parentNode.innerHTML='<span>This link does not load an image</span>'"></div>
            <div class="ba-body">
                <div class="ba-head"><span class="ba-dot" style="background:${esc(s.color || '#666')}"></span><b>${esc(s.crew)}</b><span class="bx-chip blue"><i class="fas ${KIND[s.kind][1]}"></i>${KIND[s.kind][0]}</span></div>
                ${s.kind === 'tag' ? `<div class="ba-label">“${esc(s.label)}”</div>` : ''}
                <small>Sent by ${esc(s.by)} · ${esc(ago(s.at))}</small>
                <a class="ba-url mono">${esc(s.url)}</a>
                <input class="bx-input sm" data-note="${s.id}" maxlength="120" placeholder="Note for the crew (optional)">
                <div class="ba-acts"><button class="bx-btn sm danger" data-review="${s.id}" data-ok="0"><i class="fas fa-xmark"></i>Turn down</button><button class="bx-btn sm primary" data-review="${s.id}" data-ok="1"><i class="fas fa-check"></i>Approve</button></div>
            </div></div>`;
        el.innerHTML = `${data.pending.length ? `<div class="ba-grid">${data.pending.map(card).join('')}</div>`
                : '<div class="bx-empty"><i class="fas fa-circle-check"></i><b>Nothing waiting</b><p>When a crew sends a logo or a photo to spray, it shows here first.</p></div>'}
            <div class="bx-sec"><div class="bx-sectitle"><h2>Decided lately</h2><span>${data.recent.length}</span></div>
                ${data.recent.length ? `<div class="bx-card"><table class="bx-table"><thead><tr><th></th><th>Crew</th><th>What</th><th>Decision</th><th>By</th><th class="r">When</th></tr></thead><tbody>${data.recent.map((s) => `<tr>
                    <td><span class="ba-mini"><img src="${esc(s.url)}" alt="" onerror="this.style.display='none'"></span></td>
                    <td><b>${esc(s.crew)}</b></td><td>${esc(KIND[s.kind][0])}${s.kind === 'tag' ? ` · ${esc(s.label)}` : ''}</td>
                    <td><span class="bx-chip ${s.status === 'approved' ? 'ok' : 'bad'}">${s.status === 'approved' ? 'Approved' : 'Turned down'}</span>${s.note ? ` <small class="bx-hint">${esc(s.note)}</small>` : ''}</td>
                    <td>${esc(s.reviewer || '')}</td><td class="r">${esc(ago(s.decidedAt))}</td></tr>`).join('')}</tbody></table></div>` : '<p class="bx-hint">Nothing decided yet.</p>'}
            </div>`;
        el.querySelectorAll('[data-review]').forEach((b) => b.addEventListener('click', async () => {
            const id = Number(b.dataset.review);
            const note = (el.querySelector(`[data-note="${id}"]`) || {}).value || '';
            b.disabled = true;
            const res = await acall('XS-CriminalTablet:admin:review', id, b.dataset.ok === '1', note);
            if (!res || !res.ok) { b.disabled = false; return toast((res && res.error) || 'That did not work', 'error'); }
            toast(b.dataset.ok === '1' ? 'Approved. The crew has it now.' : 'Turned down. The crew has been told.', 'success');
            data = { pending: res.data.pending || [], recent: res.data.recent || [] };
            setCount();
            render();
        }));
    }

    window.XS.BuilderApprovals = {
        mount(target) { el = target; render(); load(); },
        count: load,
    };
})();
