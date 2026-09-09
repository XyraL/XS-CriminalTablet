// ─────────────────────────────────────────────────────────────
// Admin tablet controller. Separate root from the player device, but
// reuses the same NUI fetch helper. All real validation happens
// server-side (ACE check) — this is just the panel.
// ─────────────────────────────────────────────────────────────
(() => {
    const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'XS-CriminalTablet';
    const $ = (s) => document.querySelector(s);

    async function nui(cb, body = {}) {
        try {
            const r = await fetch(`https://${RES}/${cb}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json; charset=UTF-8' },
                body: JSON.stringify(body),
            });
            return await r.json().catch(() => ({}));
        } catch (e) { return {}; }
    }
    const call = (name, ...args) => nui('admin:call', { name, args });

    function flash(msg, type = 'info') {
        const stack = $('#adminToastStack');
        if (!stack) return;
        const toast = document.createElement('div');
        toast.className = `toast toast-${type}`;
        toast.textContent = msg;
        stack.appendChild(toast);
        setTimeout(() => toast.classList.add('toast-out'), 2600);
        setTimeout(() => toast.remove(), 3000);
    }

    // Wraps a callback result: toasts on failure, returns the result either way.
    async function callChecked(label, name, ...args) {
        const res = await call(name, ...args);
        if (res && res.ok === false) flash(res.error || `${label} failed`, 'error');
        else if (res && res.ok) flash(`${label} done`, 'success');
        return res;
    }

    let overview = { gangs: [], territories: [] };

    const ADMIN_BOOT_LINES = [
        'VERIFYING ACE PERMISSION...',
        'STAFF CREDENTIALS <span class="ok">[OK]</span>',
        'LOADING ADMIN MODULES...',
        'LOCKDOWN OVERRIDE — ACCESS GRANTED',
    ];

    function playAdminBoot(onDone) {
        const screen = $('#adminBootScreen');
        const linesEl = $('#adminBootLines');
        if (!screen || !linesEl) { onDone && onDone(); return; }
        linesEl.innerHTML = '';
        screen.classList.remove('is-hidden');
        let i = 0;
        function next() {
            if (i >= ADMIN_BOOT_LINES.length) {
                setTimeout(() => { screen.classList.add('is-hidden'); onDone && onDone(); }, 280);
                return;
            }
            const div = document.createElement('div');
            div.className = 'boot-line';
            div.innerHTML = ADMIN_BOOT_LINES[i] + (i === ADMIN_BOOT_LINES.length - 1 ? '<span class="boot-cursor"></span>' : '');
            linesEl.appendChild(div);
            requestAnimationFrame(() => div.classList.add('is-shown'));
            i++;
            setTimeout(next, 200);
        }
        next();
    }

    window.openAdminUI = async () => {
        $('#root').classList.add('hidden');
        $('#adminRoot').classList.remove('hidden');
        playAdminBoot();
        await refresh();
    };

    $('#adminCloseBtn').onclick = () => nui('admin:close');

    async function refresh() {
        overview = await call('XS-CriminalTablet:admin:getOverview');
        if (!overview || !overview.gangs) overview = { gangs: [], territories: [] };
        renderGangs();
        renderTerritories();
        renderDashboard();
        renderBoostSearch();
        renderChatMod();
        renderDealerStock();
    }

    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    }

    function renderGangs() {
        const list = $('#adminGangList');
        list.innerHTML = '';
        if (!overview.gangs.length) { list.innerHTML = '<div class="log-empty">No gangs yet.</div>'; return; }

        overview.gangs.forEach((g) => {
            const card = document.createElement('div');
            card.className = 'admin-gang-card';
            card.innerHTML = `
                <div class="row-between">
                    <div>
                        <div class="member-name">${escapeHtml(g.label)} <span class="muted">(#${g.id})</span></div>
                        <div class="muted">Boss: ${escapeHtml(g.owner || '—')} · ${g.memberCount} members · ${escapeHtml(g.tier)}</div>
                    </div>
                    <button class="icon-btn danger" data-act="disband" data-id="${g.id}" title="Disband">✕</button>
                </div>
                <div class="admin-form">
                    <input class="a-label" placeholder="rename label" value="${escapeHtml(g.label)}" />
                    <input class="a-boss" placeholder="new boss citizenid" />
                    <button data-act="updateLabel" data-id="${g.id}">Rename</button>
                    <button data-act="updateBoss" data-id="${g.id}">Set boss</button>
                </div>
                <div class="admin-form">
                    <input class="a-notoriety" type="number" placeholder="+/- notoriety" />
                    <button data-act="notoriety" data-id="${g.id}">Apply</button>
                    <input class="a-bank" type="number" placeholder="set bank $" value="${g.bank}" />
                    <button data-act="bank" data-id="${g.id}">Set</button>
                </div>
                <div class="admin-members" data-members="${g.id}"></div>
                <button class="btn btn-ghost" data-act="toggleMembers" data-id="${g.id}">Members / rep</button>`;
            list.appendChild(card);
        });

        list.querySelectorAll('[data-act]').forEach((btn) => {
            btn.onclick = async () => {
                const { act, id } = btn.dataset;
                const card = btn.closest('.admin-gang-card');
                if (act === 'disband') {
                    if (btn.dataset.confirm !== '1') {
                        btn.dataset.confirm = '1';
                        btn.textContent = '✔';
                        btn.title = 'Click again to confirm disband';
                        setTimeout(() => { btn.dataset.confirm = '0'; btn.textContent = '✕'; }, 3000);
                        return;
                    }
                    await callChecked('Disband', 'XS-CriminalTablet:admin:disbandGang', id);
                } else if (act === 'updateLabel') {
                    await callChecked('Rename', 'XS-CriminalTablet:admin:updateGang', id, { label: card.querySelector('.a-label').value });
                } else if (act === 'updateBoss') {
                    const boss = card.querySelector('.a-boss').value.trim();
                    if (!boss) return;
                    await callChecked('Set boss', 'XS-CriminalTablet:admin:updateGang', id, { boss });
                } else if (act === 'notoriety') {
                    const amt = Number(card.querySelector('.a-notoriety').value) || 0;
                    await callChecked('Notoriety adjust', 'XS-CriminalTablet:admin:adjustNotoriety', id, amt);
                } else if (act === 'bank') {
                    await callChecked('Bank set', 'XS-CriminalTablet:admin:setBank', id, Number(card.querySelector('.a-bank').value) || 0);
                } else if (act === 'toggleMembers') {
                    await renderMembers(id, card.querySelector(`[data-members="${id}"]`));
                    return;
                }
                await refresh();
            };
        });
    }

    async function renderMembers(gangId, container, force = false) {
        if (!force && container.dataset.loaded === '1') { container.innerHTML = ''; container.dataset.loaded = '0'; return; }
        const members = await call('XS-CriminalTablet:admin:getMembers', gangId);
        container.innerHTML = '';
        container.dataset.loaded = '1';
        (members || []).forEach((m) => {
            const row = document.createElement('div');
            row.className = 'member';
            row.innerHTML = `
                <span class="member-name">${escapeHtml(m.name)}</span>
                <span class="member-rep">${m.rep} rep</span>
                <div class="member-actions">
                    <input class="rep-delta" type="number" placeholder="+/-" style="width:70px" />
                    <button data-rep-cid="${m.citizenid}">Apply</button>
                    <button data-promote-cid="${m.citizenid}" data-grade="${m.grade + 1}" title="Promote">▲</button>
                    <button data-promote-cid="${m.citizenid}" data-grade="${m.grade - 1}" title="Demote">▼</button>
                    <button class="icon-btn danger" data-kick-cid="${m.citizenid}" title="Kick">✕</button>
                </div>`;
            container.appendChild(row);
        });
        container.querySelectorAll('[data-rep-cid]').forEach((btn) => {
            btn.onclick = async () => {
                const amt = Number(btn.parentElement.querySelector('.rep-delta').value) || 0;
                await callChecked('Rep adjust', 'XS-CriminalTablet:admin:adjustRep', btn.dataset.repCid, amt);
                await renderMembers(gangId, container, true);
            };
        });
        container.querySelectorAll('[data-promote-cid]').forEach((btn) => {
            btn.onclick = async () => {
                await callChecked('Grade set', 'XS-CriminalTablet:admin:setMemberGrade', gangId, btn.dataset.promoteCid, btn.dataset.grade);
                await renderMembers(gangId, container, true);
            };
        });
        container.querySelectorAll('[data-kick-cid]').forEach((btn) => {
            btn.onclick = async () => {
                if (btn.dataset.confirm !== '1') {
                    btn.dataset.confirm = '1';
                    btn.textContent = '✔';
                    setTimeout(() => { btn.dataset.confirm = '0'; btn.textContent = '✕'; }, 3000);
                    return;
                }
                await callChecked('Kick', 'XS-CriminalTablet:admin:kickMember', gangId, btn.dataset.kickCid);
                await renderMembers(gangId, container, true);
            };
        });
    }

    function renderTerritories() {
        const list = $('#adminTerritoryList');
        list.innerHTML = '';
        if (!(overview.territories || []).length) { list.innerHTML = '<div class="log-empty">No zones with coords set yet.</div>'; }

        (overview.territories || []).forEach((t) => {
            const row = document.createElement('div');
            row.className = 'admin-gang-card';
            const options = ['<option value="">Unassigned</option>']
                .concat(overview.gangs.map((g) => `<option value="${g.id}" ${t.holderId === g.id ? 'selected' : ''}>${escapeHtml(g.label)}</option>`));
            row.innerHTML = `
                <div class="row-between">
                    <span class="member-name">${escapeHtml(t.label)} <span class="muted">(${escapeHtml(t.zone)})</span></span>
                    <button class="icon-btn danger" data-del-zone="${t.zone}" title="Delete">✕</button>
                </div>
                <div class="admin-form">
                    <select class="terr-holder">${options.join('')}</select>
                    <button data-set-zone="${t.zone}">Set holder</button>
                    <button data-move-zone="${t.zone}">Move to my position</button>
                </div>
                <div class="admin-form">
                    <input class="terr-label" placeholder="rename label" value="${escapeHtml(t.label)}" />
                    <button data-label-zone="${t.zone}">Rename</button>
                </div>`;
            list.appendChild(row);
        });

        list.querySelectorAll('[data-set-zone]').forEach((btn) => {
            btn.onclick = async () => {
                const sel = btn.parentElement.querySelector('.terr-holder');
                await callChecked('Territory set', 'XS-CriminalTablet:admin:setTerritory', btn.dataset.setZone, sel.value || null);
                await refresh();
            };
        });
        list.querySelectorAll('[data-move-zone]').forEach((btn) => {
            btn.onclick = async () => {
                await callChecked('Zone moved', 'XS-CriminalTablet:admin:setZoneCoords', btn.dataset.moveZone);
                await refresh();
            };
        });
        list.querySelectorAll('[data-label-zone]').forEach((btn) => {
            btn.onclick = async () => {
                const card = btn.closest('.admin-gang-card');
                await callChecked('Zone renamed', 'XS-CriminalTablet:admin:updateZone', btn.dataset.labelZone, { label: card.querySelector('.terr-label').value });
                await refresh();
            };
        });
        list.querySelectorAll('[data-del-zone]').forEach((btn) => {
            btn.onclick = async () => {
                if (btn.dataset.confirm !== '1') {
                    btn.dataset.confirm = '1';
                    btn.textContent = '✔';
                    setTimeout(() => { btn.dataset.confirm = '0'; btn.textContent = '✕'; }, 3000);
                    return;
                }
                await callChecked('Zone deleted', 'XS-CriminalTablet:admin:deleteZone', btn.dataset.delZone);
                await refresh();
            };
        });
    }

    $('#adminCreateZoneBtn').onclick = async () => {
        const key = $('#newZoneKey').value.trim();
        const label = $('#newZoneLabel').value.trim();
        if (!key) return;
        const res = await call('XS-CriminalTablet:admin:createZone', key, label || key, 0);
        if (!res.ok) { flash(res.error || 'Failed to create zone', 'error'); return; }
        await callChecked('Zone placed', 'XS-CriminalTablet:admin:setZoneCoords', res.zone);
        $('#newZoneKey').value = '';
        $('#newZoneLabel').value = '';
        await refresh();
    };

    $('#adminCreateBtn').onclick = async () => {
        const name = $('#newGangName').value.trim();
        const label = $('#newGangLabelAdmin').value.trim();
        const boss = $('#newGangBoss').value.trim();
        const res = await call('XS-CriminalTablet:admin:createGang', name, label, boss);
        $('#adminCreateError').textContent = '';
        if (res.ok) {
            $('#newGangName').value = '';
            $('#newGangLabelAdmin').value = '';
            $('#newGangBoss').value = '';
            flash('Gang created', 'success');
            await refresh();
        } else {
            $('#adminCreateError').textContent = res.error || 'Failed to create gang';
        }
    };

    // ── Dashboard ──
    async function renderDashboard() {
        const d = await call('XS-CriminalTablet:admin:getDashboard');
        if (!d) return;
        $('#statGangCount').textContent = d.gangCount;
        $('#statZoneCount').textContent = d.zoneCount;
        $('#statGangBank').textContent = '$' + Number(d.totalGangBank).toLocaleString();
        $('#statBoostPlayers').textContent = d.boosting.players;
        $('#statBoostTotal').textContent = d.boosting.totalBoosted;
        $('#statBoostActive').textContent = d.boosting.activeJobs;
        $('#statChatMsgs').textContent = d.worldMsgCount;
        $('#statHandles').textContent = d.handleCount;
        const cd = $('#statDealerCooldown');
        if (d.dealer && d.dealer.cooldownMs > 0) {
            cd.textContent = `${(d.dealer.cooldownMs / 3600000).toFixed(1)}h remaining`;
        } else {
            cd.textContent = 'Ready';
        }
    }

    // ── Boosting oversight ──
    async function renderBoostSearch() {
        const query = $('#boostSearchInput') ? $('#boostSearchInput').value.trim() : '';
        const rows = await call('XS-CriminalTablet:admin:boostSearch', query);
        const list = $('#boostSearchResults');
        list.innerHTML = '';
        if (!rows || !rows.length) { list.innerHTML = '<div class="log-empty">No matches.</div>'; return; }

        rows.forEach((r) => {
            const row = document.createElement('div');
            row.className = 'admin-gang-card';
            row.innerHTML = `
                <div class="row-between">
                    <div>
                        <div class="member-name">${escapeHtml(r.name)} <span class="muted">(${escapeHtml(r.citizenid)})</span></div>
                        <div class="muted">${r.total_boosted} boosted · $${Number(r.total_cash).toLocaleString()} earned</div>
                    </div>
                    <button class="icon-btn danger" data-reset-cid="${r.citizenid}" title="Reset">✕</button>
                </div>
                <div class="admin-form">
                    <input class="b-level" type="number" placeholder="level" value="${r.level}" style="max-width:90px;" />
                    <input class="b-xp" type="number" placeholder="xp" value="${r.xp}" style="max-width:110px;" />
                    <input class="b-boosted" type="number" placeholder="total boosted" value="${r.total_boosted}" style="max-width:130px;" />
                    <input class="b-cash" type="number" placeholder="total cash" value="${r.total_cash}" style="max-width:130px;" />
                    <input class="b-perks" type="number" placeholder="perk pts" value="${r.perk_points}" style="max-width:100px;" />
                    <button data-save-cid="${r.citizenid}">Save</button>
                </div>`;
            list.appendChild(row);
        });

        list.querySelectorAll('[data-save-cid]').forEach((btn) => {
            btn.onclick = async () => {
                const card = btn.closest('.admin-gang-card');
                const fields = {
                    level: Number(card.querySelector('.b-level').value),
                    xp: Number(card.querySelector('.b-xp').value),
                    total_boosted: Number(card.querySelector('.b-boosted').value),
                    total_cash: Number(card.querySelector('.b-cash').value),
                    perk_points: Number(card.querySelector('.b-perks').value),
                };
                await callChecked('Stats saved', 'XS-CriminalTablet:admin:boostSetStats', btn.dataset.saveCid, fields);
                await renderBoostSearch();
            };
        });
        list.querySelectorAll('[data-reset-cid]').forEach((btn) => {
            btn.onclick = async () => {
                if (btn.dataset.confirm !== '1') {
                    btn.dataset.confirm = '1'; btn.textContent = '✔';
                    setTimeout(() => { btn.dataset.confirm = '0'; btn.textContent = '✕'; }, 3000);
                    return;
                }
                await callChecked('Stats reset', 'XS-CriminalTablet:admin:boostResetStats', btn.dataset.resetCid);
                await renderBoostSearch();
            };
        });
    }
    if ($('#boostSearchBtn')) $('#boostSearchBtn').onclick = renderBoostSearch;

    // ── Blackmarket moderation ──
    async function renderChatMod() {
        const rows = await call('XS-CriminalTablet:admin:chatGetWorld');
        const list = $('#chatModList');
        list.innerHTML = '';
        if (!rows || !rows.length) { list.innerHTML = '<div class="log-empty">No messages yet.</div>'; return; }

        [...rows].reverse().forEach((m) => {
            const row = document.createElement('div');
            row.className = 'member';
            row.innerHTML = `
                <span class="member-name">${escapeHtml(m.handle)}</span>
                <span class="member-rank">${escapeHtml(m.message)}</span>
                <div class="member-actions">
                    <button class="icon-btn danger" data-del-msg="${m.id}" title="Delete">✕</button>
                </div>`;
            list.appendChild(row);
        });

        list.querySelectorAll('[data-del-msg]').forEach((btn) => {
            btn.onclick = async () => {
                await callChecked('Message deleted', 'XS-CriminalTablet:admin:chatDeleteWorld', btn.dataset.delMsg);
                await renderChatMod();
            };
        });
    }
    if ($('#resolveHandleBtn')) {
        $('#resolveHandleBtn').onclick = async () => {
            const handle = $('#resolveHandleInput').value.trim();
            if (!handle) return;
            const res = await call('XS-CriminalTablet:admin:chatResolveHandle', handle);
            $('#resolveHandleResult').textContent = res.ok ? `→ ${res.citizenid}` : (res.error || 'not found');
        };
    }

    // ── Dealer control ──
    async function renderDealerStock() {
        const stock = await call('XS-CriminalTablet:admin:dealerGetStock');
        const list = $('#dealerStockList');
        list.innerHTML = '';
        if (!stock || !stock.length) { list.innerHTML = '<div class="log-empty">No stock rolled yet.</div>'; return; }
        stock.forEach((s) => {
            const row = document.createElement('div');
            row.className = 'member';
            row.innerHTML = `<span class="member-name">${escapeHtml(s.label)}</span><span class="member-rank">$${Number(s.price).toLocaleString()}</span>`;
            list.appendChild(row);
        });
    }
    if ($('#dealerRerollBtn')) {
        $('#dealerRerollBtn').onclick = async () => {
            await callChecked('Stock rerolled', 'XS-CriminalTablet:admin:dealerReroll');
            await renderDealerStock();
        };
    }
    if ($('#dealerClearCooldownBtn')) {
        $('#dealerClearCooldownBtn').onclick = async () => {
            await callChecked('Cooldown cleared', 'XS-CriminalTablet:admin:dealerClearCooldown');
            await renderDashboard();
        };
    }
})();
