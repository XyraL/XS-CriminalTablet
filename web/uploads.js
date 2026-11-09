// Crew uploads on the tablet: the Logo tab in Roster and Own Photos in
// the Studio. Everything goes to staff before anyone else sees it.
(function () {
    const { escapeHtml: esc, call, flash, initials } = window.XS;
    const $ = (s) => document.querySelector(s);
    let data = null;
    const STATUS = { pending: ['Waiting on staff', 'warn'], approved: ['Approved', 'good'], rejected: ['Turned down', 'bad'] };
    const ago = (ms) => {
        if (!ms) return '';
        const m = Math.floor((Date.now() - ms) / 60000);
        if (m < 60) return m < 1 ? 'just now' : `${m}m ago`;
        const h = Math.floor(m / 60);
        return h < 24 ? `${h}h ago` : `${Math.floor(h / 24)}d ago`;
    };

    function rows(kind) {
        const list = (data && data.submissions || []).filter((s) => s.kind === kind);
        if (!list.length) return '';
        return `<h2 class="section-head"><span>Sent to staff</span><span class="count">${list.length}</span></h2>
            <div class="tile-list">${list.map((s) => {
                const [label, tone] = STATUS[s.status] || [s.status, ''];
                return `<div class="tile compact up-row"><span class="up-thumb"><img src="${esc(s.url)}" alt="" onerror="this.style.display='none'"></span>
                    <div class="tile-main"><span class="tile-name">${esc(kind === 'logo' ? 'Crew logo' : s.label)} <span class="up-status ${tone}">${esc(label)}</span></span>
                        <span class="tile-sub">Sent by ${esc(s.by)} · ${esc(ago(s.at))}${s.note ? ` · “${esc(s.note)}”` : ''}</span></div></div>`;
            }).join('')}</div>`;
    }

    function form(kind) {
        return `<div class="up-form">
            ${kind === 'tag' ? '<label class="field"><span>Name</span><input type="text" id="up-name-tag" maxlength="40" placeholder="What the crew calls it"></label>' : ''}
            <label class="field"><span>Image link</span><input type="text" id="up-url-${kind}" maxlength="500" placeholder="https://… ending in .png, .jpg, .webp or .gif"></label>
            <div class="up-preview" id="up-prev-${kind}"><span>The image shows here</span></div>
            <button class="btn btn-accent" id="up-send-${kind}"><i class="fas fa-paper-plane"></i> Send to staff</button>
            <p class="hint"><i class="fas fa-circle-info"></i><span>Paste a direct link to the image. Staff check it first. Nobody outside the crew sees it until it is approved.</span></p>
        </div>`;
    }

    function paintLogo() {
        const root = $('#crewLogoRoot');
        if (!root) return;
        const g = window.XS.state.gang;
        if (!data || !g) { root.innerHTML = '<div class="empty"><i class="fas fa-image"></i>Crew logos are not available right now.</div>'; return; }
        if (!data.enabled.logo) { root.innerHTML = '<div class="empty"><i class="fas fa-image"></i>Staff have switched crew logos off.</div>'; return; }
        root.innerHTML = `<div class="up-logo">
                <span class="up-big" style="background:${esc(g.color || '#4d8bff')}">${data.logo ? `<img src="${esc(data.logo)}" alt="">` : esc(initials(g.label))}</span>
                <div><h2>${esc(g.label)}</h2><p class="muted">${data.logo ? 'Your crew logo shows on the tablet, the war scoreboard and to rival crews.' : 'No logo yet. Your initials show until staff approve one.'}</p>
                    ${data.logo && data.can.logo ? '<button class="btn btn-ghost btn-sm" id="up-remove"><i class="fas fa-trash"></i> Remove the logo</button>' : ''}</div>
            </div>
            ${data.can.logo ? form('logo') : '<p class="hint"><i class="fas fa-lock"></i><span>Only the boss, or a rank that can set the crew notice, can send a logo.</span></p>'}
            ${rows('logo')}`;
        bind('logo');
        const rm = root.querySelector('#up-remove');
        if (rm) rm.addEventListener('click', async () => {
            const res = await call('XS-CriminalTablet:approvals:removeLogo');
            if (res && res.ok) { flash('Logo removed.', 'success'); render(); } else flash((res && res.error) || 'That did not work', 'error');
        });
    }

    function paintPhotos() {
        const root = $('#tagPhotosRoot');
        if (!root) return;
        if (!data) { root.innerHTML = '<div class="empty"><i class="fas fa-image"></i>Own photos are not available right now.</div>'; return; }
        if (!data.enabled.tag) { root.innerHTML = '<div class="empty"><i class="fas fa-image"></i>Staff have switched custom tag photos off.</div>'; return; }
        root.innerHTML = `${data.can.tag ? form('tag') : '<p class="hint"><i class="fas fa-lock"></i><span>Only a rank that can manage graffiti can send photos.</span></p>'}
            ${rows('tag') || '<div class="empty"><i class="fas fa-spray-can"></i>Send your crew\'s own photo and once staff approve it, it is in the Library to spray.</div>'}`;
        bind('tag');
    }

    function bind(kind) {
        const url = $(`#up-url-${kind}`);
        const prev = $(`#up-prev-${kind}`);
        if (url && prev) url.addEventListener('input', () => {
            const v = url.value.trim();
            prev.innerHTML = /^https:\/\//.test(v) ? `<img src="${esc(v)}" alt="" onerror="this.parentNode.innerHTML='<span>That link does not load an image</span>'">` : '<span>The image shows here</span>';
        });
        const send = $(`#up-send-${kind}`);
        if (send) send.addEventListener('click', async () => {
            const name = kind === 'tag' ? ($('#up-name-tag').value || '').trim() : '';
            send.disabled = true;
            const res = await call('XS-CriminalTablet:approvals:submit', kind, url.value.trim(), name);
            send.disabled = false;
            if (res && res.ok) { flash('Sent. Staff will check it.', 'success'); render(); }
            else flash((res && res.error) || 'That did not work', 'error');
        });
    }

    async function render() {
        const res = await call('XS-CriminalTablet:approvals:mine');
        data = res && res.enabled && res.can ? res : null;
        paintLogo();
        paintPhotos();
    }

    // Both tabs live inside existing apps, so they refresh whenever those do.
    ['renderRoster', 'renderGraffiti'].forEach((fn) => {
        const orig = window[fn];
        if (typeof orig !== 'function') return;
        window[fn] = function () {
            const out = orig.apply(this, arguments);
            render();
            return out;
        };
    });

    window.XS.Uploads = { render };
})();
