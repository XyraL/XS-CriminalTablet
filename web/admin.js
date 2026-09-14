// ─────────────────────────────────────────────────────────────
// Admin tablet controller.
//
// Everything staff need to run gangs without touching config.lua or the
// database: full crew creation in one form, live rank editing, in-world
// turf drawing, the graffiti library, war control and test mode.
//
// Every action re-checks the ACE permission server-side, so nothing here
// is a security boundary — it's an interface.
// ─────────────────────────────────────────────────────────────
(function () {
    const { nui, escapeHtml, money, num, initials, formatTime, applyTheme, statGrid } = window.XS;
    const $ = window.XS.$;
    const $$ = window.XS.$$;

    const acall = (name, ...args) => nui('admin:call', { name, args });

    let overview = { gangs: [], territories: [] };
    let dashboard = null;
    let openGangId = null;
    let openGangTab = 'members';

    const GANG_COLORS = ['#e5484d', '#f5a524', '#ffd60a', '#30d158', '#2dd4bf',
        '#38bdf8', '#6366f1', '#8b5cf6', '#ec4899', '#f97316', '#a3e635', '#94a3b8'];

    // ── toast (admin has its own stack) ──
    function toast(msg, type = 'info') {
        const stack = $('#adminToastStack');
        if (!stack) return;
        const el = document.createElement('div');
        el.className = `toast ${type}`;
        el.textContent = msg;
        stack.appendChild(el);
        setTimeout(() => el.remove(), 4200);
    }

    function report(res, okMsg) {
        if (res && res.ok) { if (okMsg) toast(okMsg, 'success'); return true; }
        toast((res && res.error) || 'That did not work', 'error');
        return false;
    }

    // ── boot ──
    const ADMIN_BOOT = [
        'ELEVATING PRIVILEGES...',
        'VERIFYING ACE PRINCIPAL...',
        'MOUNTING CREW DATABASE <span class="ok">[OK]</span>',
        'STAFF ACCESS GRANTED',
    ];

    function playAdminBoot() {
        const screen = $('#adminBootScreen');
        const lines = $('#adminBootLines');
        if (!screen || !lines) return;
        lines.innerHTML = '';
        screen.classList.remove('is-hidden');
        let i = 0;
        (function next() {
            if (i >= ADMIN_BOOT.length) {
                setTimeout(() => screen.classList.add('is-hidden'), 260);
                return;
            }
            const div = document.createElement('div');
            div.className = 'boot-line';
            div.innerHTML = ADMIN_BOOT[i] + (i === ADMIN_BOOT.length - 1 ? '<span class="boot-cursor"></span>' : '');
            lines.appendChild(div);
            requestAnimationFrame(() => div.classList.add('is-shown'));
            i++;
            setTimeout(next, 190);
        })();
    }

    window.openAdminUI = async function openAdminUI() {
        // Staff console has its own identity — never inherit whatever
        // gang colour the last tablet set.
        applyTheme('#ff4d5a');
        // Only ever one device on screen; both share the same NUI page.
        $('#root').classList.add('hidden');
        $('#adminRoot').classList.remove('hidden');
        playAdminBoot();
        paintSwatches();
        await refresh();
        if (window.XSMapEdit) {
            window.XSMapEdit.init();
            window.XSMapEdit.refresh();
        }
    };

    // The wizard writes gangs and zones of its own, so it needs a way to
    // pull the rest of the panel back into step with the database.
    window.XSAdmin = { refresh };

    $('#adminCloseBtn').onclick = () => nui('admin:close');

    // ── rail tabs ──
    $$('#adminRail .rail-app').forEach((btn) => {
        btn.onclick = () => {
            $$('#adminRail .rail-app').forEach((b) => b.classList.toggle('is-active', b === btn));
            $$('.admin-surface > .tabview').forEach((v) =>
                v.classList.toggle('is-active', v.dataset.tabview === btn.dataset.tab));
            onAdminTab(btn.dataset.tab);
        };
    });

    function onAdminTab(tab) {
        switch (tab) {
            case 'admin-dashboard': renderDashboard(); break;
            case 'admin-gangs': renderGangs(); break;
            case 'admin-zones': renderZones(); break;
            case 'admin-pricing': renderPricing(); break;
            case 'admin-graffiti': renderGraffitiAdmin(); break;
            case 'admin-war': renderWars(); break;
            case 'admin-test': renderTestMode(); break;
            case 'admin-blackmarket': renderChatMod(); break;
            case 'admin-dealer': renderDealerStock(); break;
        }
        if (window.XSMapEdit) window.XSMapEdit.onTab(tab);
    }

    async function refresh() {
        overview = await acall('XS-CriminalTablet:admin:getOverview') || { gangs: [], territories: [] };
        dashboard = await acall('XS-CriminalTablet:admin:getDashboard');
        populateZoneSelect();
        populateGangSelect();
        renderDashboard();
        renderGangs();
        renderZones();
    }

    // ═══ DASHBOARD ═══
    function renderDashboard() {
        if (!dashboard) return;
        $('#adminStatGrid').innerHTML = statGrid([
            { label: 'Crews', icon: 'fa-users-gear', value: dashboard.gangCount },
            { label: 'Members', icon: 'fa-users', value: dashboard.memberCount,
              sub: dashboard.gangCount ? `~${Math.round(dashboard.memberCount / dashboard.gangCount)} per crew` : null },
            { label: 'Turf claimed', icon: 'fa-map-location-dot',
              value: `${dashboard.zoneCount} / ${dashboard.zoneTotal}`,
              bar: dashboard.zoneTotal ? (dashboard.zoneCount / dashboard.zoneTotal) * 100 : 0 },
            { label: 'Total banked', icon: 'fa-sack-dollar', value: money(dashboard.totalGangBank) },
            { label: 'Gang vehicles', icon: 'fa-car-side', value: dashboard.vehicleCount },
            { label: 'Tags up', icon: 'fa-spray-can', value: dashboard.graffitiCount },
            { label: 'Live engagements', icon: 'fa-crosshairs', value: dashboard.activeWars,
              sub: dashboard.activeWars ? 'running now' : 'all quiet' },
            { label: 'World messages', icon: 'fa-comments', value: dashboard.worldMsgCount },
            { label: 'Handles issued', icon: 'fa-user-secret', value: dashboard.handleCount },
        ]);

        const contests = Object.entries(dashboard.contests || {});
        $('#adminContests').innerHTML = contests.length ? contests.map(([zone, c]) => `
            <div class="tile">
                <span class="tile-avatar"><i class="fas fa-flag"></i></span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(zone)}</span>
                    <span class="tile-sub">${escapeHtml(c.gangLabel)} · ${c.attackers} attacking · ${c.defenders} defending</span>
                </div>
                <div class="tile-stat">${c.progress}%</div>
            </div>`).join('') : '<div class="empty"><i class="fas fa-flag"></i>No turf being contested right now.</div>';

        const d = dashboard.dealer || {};
        $('#adminDealerStatus').innerHTML = `
            <div class="tile">
                <span class="tile-avatar"><i class="fas fa-handshake"></i></span>
                <div class="tile-main">
                    <span class="tile-name">Dealer</span>
                    <span class="tile-sub">${d.active ? 'Out on a call' : (d.cooldownMs > 0
                        ? `On cooldown for ${Math.ceil(d.cooldownMs / 3600000)}h`
                        : 'Available')}</span>
                </div>
            </div>`;
    }

    // ═══ GANG CREATION ═══
    function paintSwatches() {
        const row = $('#newGangSwatches');
        row.innerHTML = GANG_COLORS.map((c, i) =>
            `<span class="swatch ${i === 1 ? 'is-active' : ''}" data-c="${c}" style="background:${c}"></span>`).join('');
        row.querySelectorAll('[data-c]').forEach((s) => {
            s.onclick = () => {
                $('#newGangColor').value = s.dataset.c;
                row.querySelectorAll('.swatch').forEach((x) => x.classList.toggle('is-active', x === s));
                updateCreatePreview();
            };
        });
        updateCreatePreview();
    }

    // The internal name is derived from the display name unless staff
    // deliberately type their own — one less field to think about.
    let internalTouched = false;
    $('#newGangName').addEventListener('input', () => { internalTouched = true; });
    $('#newGangLabel').addEventListener('input', () => {
        if (!internalTouched) {
            $('#newGangName').value = $('#newGangLabel').value
                .toLowerCase().replace(/\s+/g, '_').replace(/[^a-z0-9_]/g, '');
        }
        updateCreatePreview();
    });
    $('#newGangColor').addEventListener('input', updateCreatePreview);

    function updateCreatePreview() {
        const label = $('#newGangLabel').value || 'New crew';
        const color = $('#newGangColor').value;
        const crest = $('#newGangPreview');
        crest.textContent = initials(label);
        crest.style.background = `linear-gradient(145deg, ${color}, ${color}66)`;
        $('#newGangPreviewName').textContent = label;
        $('#newGangPreviewName').style.color = color;
    }

    function populateZoneSelect() {
        // Founding a crew can hand it a zone nobody owns yet.
        const sel = $('#newGangZone');
        const free = (overview.territories || []).filter((t) => !t.holderId);
        sel.innerHTML = '<option value="">— none —</option>' + free.map((t) =>
            `<option value="${escapeHtml(t.zone)}">${escapeHtml(t.label)}</option>`).join('');

        // The new-zone form needs the crew list, not the zone list — every
        // zone is created FOR someone.
        const zoneGang = $('#newZoneGang');
        if (zoneGang) {
            const prev = zoneGang.value;
            zoneGang.innerHTML = '<option value="">— pick a crew —</option>' + (overview.gangs || []).map((g) =>
                `<option value="${g.id}">${escapeHtml(g.label)}</option>`).join('');
            if (prev) zoneGang.value = prev;
        }
    }

    $('#adminCreateBtn').onclick = async () => {
        $('#adminCreateError').textContent = '';
        const opts = {
            label: $('#newGangLabel').value.trim(),
            name: $('#newGangName').value.trim(),
            boss: $('#newGangBoss').value.trim(),
            color: $('#newGangColor').value,
            maxMembers: Number($('#newGangCap').value) || 0,
            bank: Number($('#newGangBank').value) || 0,
            motd: $('#newGangMotd').value.trim(),
            territory: $('#newGangZone').value,
            seedGraffiti: $('#newGangSeedArt').checked,
        };
        if (!opts.label) { $('#adminCreateError').textContent = 'Give it a display name.'; return; }

        const res = await acall('XS-CriminalTablet:admin:createGang', opts);
        if (!res || !res.ok) {
            $('#adminCreateError').textContent = (res && res.error) || 'Could not create that crew';
            return;
        }
        // toast() sets textContent, so this never needs escaping — built
        // by concatenation to keep it obvious it isn't markup.
        toast(opts.label + ' created.', 'success');
        ['#newGangLabel', '#newGangName', '#newGangBoss', '#newGangCap', '#newGangBank', '#newGangMotd']
            .forEach((s) => { $(s).value = ''; });
        internalTouched = false;
        updateCreatePreview();
        await refresh();
    };

    // ═══ GANG LIST ═══
    $('#gangFilter').oninput = () => renderGangs();

    function renderGangs() {
        const filter = ($('#gangFilter').value || '').toLowerCase();
        const gangs = (overview.gangs || []).filter((g) =>
            !filter || g.label.toLowerCase().includes(filter) || g.name.toLowerCase().includes(filter));
        const list = $('#adminGangList');

        if (!gangs.length) {
            list.innerHTML = '<div class="empty"><i class="fas fa-users-slash"></i>No crews yet.</div>';
            return;
        }

        list.innerHTML = gangs.map((g) => `
            <div class="admin-gang ${openGangId === g.id ? 'is-open' : ''}" data-gang="${g.id}">
                <div class="admin-gang-head">
                    <span class="admin-gang-swatch" style="background:${escapeHtml(g.color || '#666')}"></span>
                    <div class="admin-gang-main">
                        <div class="admin-gang-name">${escapeHtml(g.label)}</div>
                        <div class="admin-gang-sub">
                            ${escapeHtml(g.name)} · #${g.id} · ${escapeHtml(g.tier)} LV${g.level}
                            · ${g.memberCount}/${g.effectiveMax} · ${g.zones} turf · ${money(g.bank)}
                            ${g.hasHq ? '' : ' · NO HQ'}
                        </div>
                    </div>
                    <span class="chip">${g.online} online</span>
                    <i class="fas fa-chevron-down muted"></i>
                </div>
                <div class="admin-gang-body">
                    <div class="admin-subtabs">
                        <button class="admin-subtab ${openGangTab === 'settings' ? 'is-active' : ''}" data-sub="settings">Settings</button>
                        <button class="admin-subtab ${openGangTab === 'members' ? 'is-active' : ''}" data-sub="members">Members</button>
                        <button class="admin-subtab ${openGangTab === 'ranks' ? 'is-active' : ''}" data-sub="ranks">Ranks</button>
                        <button class="admin-subtab ${openGangTab === 'garage' ? 'is-active' : ''}" data-sub="garage">Garage</button>
                        <button class="admin-subtab ${openGangTab === 'danger' ? 'is-active' : ''}" data-sub="danger">Danger</button>
                    </div>
                    <div class="admin-subview ${openGangTab === 'settings' ? 'is-active' : ''}" data-subview="settings">${settingsForm(g)}</div>
                    <div class="admin-subview ${openGangTab === 'members' ? 'is-active' : ''}" data-subview="members"><div class="tile-list" data-members></div></div>
                    <div class="admin-subview ${openGangTab === 'ranks' ? 'is-active' : ''}" data-subview="ranks"><div data-ranks></div></div>
                    <div class="admin-subview ${openGangTab === 'garage' ? 'is-active' : ''}" data-subview="garage"><div data-garage></div></div>
                    <div class="admin-subview ${openGangTab === 'danger' ? 'is-active' : ''}" data-subview="danger">${dangerForm(g)}</div>
                </div>
            </div>`).join('');

        list.querySelectorAll('.admin-gang-head').forEach((head) => {
            head.onclick = () => {
                const row = head.parentElement;
                const id = Number(row.dataset.gang);
                openGangId = openGangId === id ? null : id;
                renderGangs();
                if (openGangId) loadGangTab(openGangId, openGangTab);
            };
        });

        list.querySelectorAll('.admin-subtab').forEach((btn) => {
            btn.onclick = () => {
                const row = btn.closest('.admin-gang');
                openGangTab = btn.dataset.sub;
                row.querySelectorAll('.admin-subtab').forEach((b) => b.classList.toggle('is-active', b === btn));
                row.querySelectorAll('.admin-subview').forEach((v) =>
                    v.classList.toggle('is-active', v.dataset.subview === openGangTab));
                loadGangTab(Number(row.dataset.gang), openGangTab);
            };
        });

        wireSettingsForms();
        if (openGangId) loadGangTab(openGangId, openGangTab);
    }

    function settingsForm(g) {
        return `<div class="form-grid">
            <label class="field"><span>Display name</span>
                <input type="text" data-f="label" data-g="${g.id}" value="${escapeHtml(g.label)}" /></label>
            <label class="field"><span>Boss citizenid</span>
                <input type="text" data-f="boss" data-g="${g.id}" value="${escapeHtml(g.owner || '')}"
                    placeholder="${escapeHtml(g.ownerName || 'none')}" /></label>
            <label class="field"><span>Member cap <em>(0 = default)</em></span>
                <input type="number" min="0" data-f="maxMembers" data-g="${g.id}" value="${g.max_members || 0}" /></label>
            <label class="field"><span>Rep</span>
                <input type="number" min="0" data-f="rep" data-g="${g.id}" value="${g.notoriety}" /></label>
            <label class="field"><span>Perk points</span>
                <input type="number" min="0" data-f="perkPoints" data-g="${g.id}" value="${g.perk_points || 0}" /></label>
            <label class="field"><span>Treasury</span>
                <input type="number" min="0" data-bank="${g.id}" value="${g.bank}" /></label>
            <div class="field field-wide"><span>Colour</span>
                <div class="color-picker">
                    <input type="color" data-f="color" data-g="${g.id}" value="${escapeHtml(g.color || '#f5a524')}" />
                    <span class="muted">Drives their tablet accent, map blips and turf shading.</span>
                </div>
            </div>
            <label class="field field-wide"><span>Crew notice</span>
                <input type="text" maxlength="255" data-f="motd" data-g="${g.id}" value="${escapeHtml(g.motd || '')}" /></label>
        </div>
        <div class="inline-form">
            <button class="btn btn-accent btn-sm" data-save="${g.id}"><i class="fas fa-floppy-disk"></i> Save settings</button>
            <button class="btn btn-ghost btn-sm" data-savebank="${g.id}">Set treasury</button>
        </div>
        <h2 class="section-head"><span>Add a member</span></h2>
        <div class="inline-form">
            <input type="text" data-addcid="${g.id}" placeholder="citizenid" />
            <button class="btn btn-ghost btn-sm" data-addmember="${g.id}"><i class="fas fa-user-plus"></i> Add</button>
        </div>`;
    }

    function dangerForm(g) {
        return `<p class="hint"><i class="fas fa-triangle-exclamation"></i>
            Reset keeps the crew, its roster, name and colour, and wipes everything they built: rep, treasury,
            perks, upgrades, property, turf and tags. Disband deletes the crew outright.</p>
        <div class="inline-form">
            <button class="btn btn-ghost btn-sm" data-reset="${g.id}"><i class="fas fa-rotate-left"></i> Reset to zero</button>
            <button class="btn btn-danger btn-sm" data-disband="${g.id}"><i class="fas fa-trash"></i> Disband</button>
        </div>`;
    }

    function wireSettingsForms() {
        $$('#adminGangList [data-save]').forEach((b) => {
            b.onclick = async () => {
                const id = Number(b.dataset.save);
                const row = b.closest('.admin-gang');
                const fields = {};
                row.querySelectorAll(`[data-f][data-g="${id}"]`).forEach((inp) => {
                    const key = inp.dataset.f;
                    fields[key] = inp.type === 'number' ? Number(inp.value) : inp.value;
                });
                // An empty boss field means "leave it alone", not "clear it" —
                // clearing an owner would leave the crew headless.
                if (!fields.boss) delete fields.boss;
                const res = await acall('XS-CriminalTablet:admin:updateGang', id, fields);
                if (report(res, 'Saved.')) await refresh();
            };
        });

        $$('#adminGangList [data-savebank]').forEach((b) => {
            b.onclick = async () => {
                const id = Number(b.dataset.savebank);
                const input = b.closest('.admin-gang').querySelector(`[data-bank="${id}"]`);
                const res = await acall('XS-CriminalTablet:admin:setBank', id, Number(input.value));
                if (report(res, 'Treasury set.')) await refresh();
            };
        });

        $$('#adminGangList [data-addmember]').forEach((b) => {
            b.onclick = async () => {
                const id = Number(b.dataset.addmember);
                const input = b.closest('.admin-gang').querySelector(`[data-addcid="${id}"]`);
                const res = await acall('XS-CriminalTablet:admin:addMember', id, input.value.trim(), 0);
                if (report(res, 'Added.')) { input.value = ''; await refresh(); loadGangTab(id, 'members'); }
            };
        });

        $$('#adminGangList [data-reset]').forEach((b) => {
            b.onclick = async () => {
                const id = Number(b.dataset.reset);
                if (b.dataset.armed !== '1') {
                    b.dataset.armed = '1';
                    b.innerHTML = '<i class="fas fa-triangle-exclamation"></i> Click again to confirm';
                    setTimeout(() => {
                        b.dataset.armed = '0';
                        b.innerHTML = '<i class="fas fa-rotate-left"></i> Reset to zero';
                    }, 4000);
                    return;
                }
                const res = await acall('XS-CriminalTablet:admin:resetGang', id);
                if (report(res, 'Crew reset.')) await refresh();
            };
        });

        $$('#adminGangList [data-disband]').forEach((b) => {
            b.onclick = async () => {
                const id = Number(b.dataset.disband);
                if (b.dataset.armed !== '1') {
                    b.dataset.armed = '1';
                    b.innerHTML = '<i class="fas fa-triangle-exclamation"></i> Click again to disband';
                    setTimeout(() => {
                        b.dataset.armed = '0';
                        b.innerHTML = '<i class="fas fa-trash"></i> Disband';
                    }, 4000);
                    return;
                }
                const res = await acall('XS-CriminalTablet:admin:disbandGang', id);
                if (report(res, 'Disbanded.')) { openGangId = null; await refresh(); }
            };
        });
    }

    async function loadGangTab(gangId, tab) {
        const row = $(`.admin-gang[data-gang="${gangId}"]`);
        if (!row) return;

        if (tab === 'members') {
            const members = await acall('XS-CriminalTablet:admin:getMembers', gangId) || [];
            const ranks = await acall('XS-CriminalTablet:admin:getRanks', gangId);
            const box = row.querySelector('[data-members]');
            if (!members.length) {
                box.innerHTML = '<div class="empty"><i class="fas fa-user-slash"></i>Nobody in this crew.</div>';
                return;
            }
            const rankOpts = ((ranks && ranks.ranks) || []).map((r) =>
                ({ grade: r.grade, name: r.name }));

            box.innerHTML = members.map((m) => `
                <div class="tile">
                    <span class="tile-avatar">${escapeHtml(initials(m.name))}</span>
                    <div class="tile-main">
                        <span class="tile-name">
                            <i class="${m.online ? 'dot-online' : 'dot-offline'}"></i>
                            ${escapeHtml(m.name)}${m.isOwner ? ' <span class="tag-owner">BOSS</span>' : ''}
                        </span>
                        <span class="tile-sub"><span style="font-family:var(--mono)">${escapeHtml(m.citizenid)}</span>
                            · ${escapeHtml(m.rank)} · ${num(m.rep)} rep</span>
                    </div>
                    <div class="tile-actions">
                        <input type="number" style="width:88px" placeholder="±rep" data-repamt="${escapeHtml(m.citizenid)}" />
                        <button class="btn btn-ghost btn-sm" data-rep="${escapeHtml(m.citizenid)}">Rep</button>
                        ${m.isOwner ? '' : `
                            <select data-agrade="${escapeHtml(m.citizenid)}" data-ag="${gangId}">
                                ${rankOpts.map((r) => `<option value="${r.grade}" ${r.grade === m.grade ? 'selected' : ''}>${escapeHtml(r.name)}</option>`).join('')}
                            </select>
                            <button class="btn btn-danger btn-sm" data-akick="${escapeHtml(m.citizenid)}" data-ag="${gangId}"><i class="fas fa-user-minus"></i></button>`}
                    </div>
                </div>`).join('');

            box.querySelectorAll('[data-rep]').forEach((b) => {
                b.onclick = async () => {
                    const cid = b.dataset.rep;
                    const amt = Number(box.querySelector(`[data-repamt="${CSS.escape(cid)}"]`).value);
                    if (!amt) return toast('Enter an amount first.', 'error');
                    const res = await acall('XS-CriminalTablet:admin:adjustRep', cid, amt);
                    if (report(res, 'Rep adjusted.')) loadGangTab(gangId, 'members');
                };
            });
            box.querySelectorAll('[data-agrade]').forEach((sel) => {
                sel.onchange = async () => {
                    const res = await acall('XS-CriminalTablet:admin:setMemberGrade',
                        Number(sel.dataset.ag), sel.dataset.agrade, Number(sel.value));
                    report(res, 'Rank set.');
                };
            });
            box.querySelectorAll('[data-akick]').forEach((b) => {
                b.onclick = async () => {
                    const res = await acall('XS-CriminalTablet:admin:kickMember',
                        Number(b.dataset.ag), b.dataset.akick);
                    if (report(res, 'Removed.')) { await refresh(); loadGangTab(gangId, 'members'); }
                };
            });
            return;
        }

        if (tab === 'ranks') {
            const data = await acall('XS-CriminalTablet:admin:getRanks', gangId);
            const box = row.querySelector('[data-ranks]');
            const ranks = (data && data.ranks) || [];
            if (!ranks.length) { box.innerHTML = '<div class="empty">No ranks.</div>'; return; }

            box.innerHTML = `<div class="rank-list">` + ranks.map((r) => {
                const all = r.permissions === '*';
                const owned = all ? [] : r.permissions;
                const groups = (data.groups || []).map((grp) => `
                    <div class="perm-group">
                        <div class="perm-group-head">${escapeHtml(grp.label)}</div>
                        <div class="perm-grid">
                            ${grp.permissions.map((p) => `
                                <label class="perm ${all || owned.includes(p.id) ? 'is-on' : ''} ${r.isTop ? 'is-blocked' : ''}">
                                    <input type="checkbox" data-aperm="${escapeHtml(p.id)}" data-arank="${r.grade}"
                                        ${all || owned.includes(p.id) ? 'checked' : ''} ${r.isTop ? 'disabled' : ''} />
                                    <span class="perm-text">
                                        <span class="perm-label">${escapeHtml(p.label)}</span>
                                        <span class="perm-desc">${escapeHtml(p.description)}</span>
                                    </span>
                                </label>`).join('')}
                        </div>
                    </div>`).join('');

                return `<div class="rank-row ${r.isTop ? 'is-top' : ''}" data-arankrow="${r.grade}">
                    <div class="rank-head">
                        <span class="rank-grade">G${r.grade}</span>
                        <input class="rank-name-input" type="text" value="${escapeHtml(r.name)}" data-aname="${r.grade}" maxlength="48" />
                        <div class="rank-meta">
                            <i class="fas fa-chevron-down muted"></i>
                        </div>
                    </div>
                    <div class="rank-body">
                        ${r.isTop ? '<p class="hint"><i class="fas fa-crown"></i> The boss rank always keeps every permission.</p>' : groups}
                    </div>
                </div>`;
            }).join('') + '</div>';

            box.querySelectorAll('.rank-head').forEach((head) => {
                head.onclick = (e) => {
                    if (e.target.closest('input')) return;
                    head.parentElement.classList.toggle('is-open');
                };
            });

            const saveRank = async (grade) => {
                const rankRow = box.querySelector(`[data-arankrow="${grade}"]`);
                const perms = Array.from(rankRow.querySelectorAll('[data-aperm]:checked')).map((c) => c.dataset.aperm);
                const res = await acall('XS-CriminalTablet:admin:updateRank', gangId, grade, {
                    name: rankRow.querySelector(`[data-aname="${grade}"]`).value,
                    permissions: perms,
                });
                report(res, 'Rank saved.');
            };

            box.querySelectorAll('[data-aperm]').forEach((c) => { c.onchange = () => saveRank(Number(c.dataset.arank)); });
            box.querySelectorAll('[data-aname]').forEach((i) => { i.onchange = () => saveRank(Number(i.dataset.aname)); });
            return;
        }

        if (tab === 'garage') {
            const data = await acall('XS-CriminalTablet:admin:garageList', gangId);
            const box = row.querySelector('[data-garage]');
            const vehicles = (data && data.vehicles) || [];
            const models = (data && data.models) || [];

            box.innerHTML = `
                <div class="inline-form">
                    <select data-grantmodel="${gangId}">
                        ${models.map((m) => `<option value="${escapeHtml(m.model)}">${escapeHtml(m.label)}</option>`).join('')}
                    </select>
                    <input type="text" data-grantcustom="${gangId}" placeholder="or a model name" />
                    <button class="btn btn-accent btn-sm" data-grant="${gangId}"><i class="fas fa-plus"></i> Grant</button>
                </div>
                <div class="tile-list">
                    ${vehicles.length ? vehicles.map((v) => `
                        <div class="tile">
                            <span class="tile-avatar"><i class="fas fa-car-side"></i></span>
                            <div class="tile-main">
                                <span class="tile-name">${escapeHtml(v.label || v.model)}</span>
                                <span class="tile-sub"><span style="font-family:var(--mono)">${escapeHtml(v.plate)}</span>
                                    · ${v.stored ? 'stored' : 'out'}</span>
                            </div>
                            <div class="tile-actions">
                                <button class="btn btn-danger btn-sm" data-delveh="${v.id}"><i class="fas fa-trash"></i></button>
                            </div>
                        </div>`).join('') : '<div class="empty"><i class="fas fa-car-side"></i>No vehicles.</div>'}
                </div>`;

            box.querySelector(`[data-grant="${gangId}"]`).onclick = async () => {
                const custom = box.querySelector(`[data-grantcustom="${gangId}"]`).value.trim();
                const picked = box.querySelector(`[data-grantmodel="${gangId}"]`).value;
                const model = custom || picked;
                if (!model) return toast('Pick or type a model.', 'error');
                const res = await acall('XS-CriminalTablet:admin:garageGrant', gangId, model, custom ? custom : null);
                if (report(res, 'Vehicle granted.')) loadGangTab(gangId, 'garage');
            };
            box.querySelectorAll('[data-delveh]').forEach((b) => {
                b.onclick = async () => {
                    const res = await acall('XS-CriminalTablet:admin:garageDelete', Number(b.dataset.delveh));
                    if (report(res, 'Removed.')) loadGangTab(gangId, 'garage');
                };
            });
        }
    }

    // ═══ ZONES ═══
    $('#zoneFilter').oninput = () => renderZones();

    $('#adminCreateZoneBtn').onclick = async () => {
        const key = $('#newZoneKey').value.trim();
        const label = $('#newZoneLabel').value.trim();
        const gangId = Number($('#newZoneGang').value) || null;
        if (!key) return toast('Give the zone a key.', 'error');
        // Zones exist for a crew. Creating one without an owner just makes
        // something players can't see, so ask for it up front.
        if (!gangId) return toast('Pick the crew this block belongs to.', 'error');

        const res = await acall('XS-CriminalTablet:admin:createZone', key, label || key, 0, gangId);
        if (report(res, 'Zone created — now give it a shape.')) {
            $('#newZoneKey').value = '';
            $('#newZoneLabel').value = '';
            await refresh();
        }
    };

    function renderZones() {
        const filter = ($('#zoneFilter').value || '').toLowerCase();
        const zones = (overview.territories || []).filter((t) =>
            !filter || t.label.toLowerCase().includes(filter) || t.zone.toLowerCase().includes(filter));
        const list = $('#adminTerritoryList');

        if (!zones.length) {
            list.innerHTML = '<div class="empty"><i class="fas fa-draw-polygon"></i>No zones yet.</div>';
            return;
        }

        const gangOpts = '<option value="">— unassigned (hidden from players) —</option>' + (overview.gangs || []).map((g) =>
            `<option value="${g.id}">${escapeHtml(g.label)}</option>`).join('');

        list.innerHTML = zones.map((t) => `
            <div class="admin-gang" data-zone="${escapeHtml(t.zone)}">
                <div class="admin-gang-head">
                    <span class="admin-gang-swatch" style="background:${escapeHtml(t.holderColor || '#4b5563')}"></span>
                    <div class="admin-gang-main">
                        <div class="admin-gang-name">${escapeHtml(t.label)}</div>
                        <div class="admin-gang-sub">
                            ${escapeHtml(t.zone)}
                            · ${t.points ? `${t.points.length}-corner polygon` : (t.coords ? `${Math.round(t.radius)}m circle` : 'NO SHAPE')}
                            · ${t.holder ? escapeHtml(t.holder) : 'UNASSIGNED'}
                            ${t.capturable ? '' : ' · LOCKED'}
                        </div>
                    </div>
                    <i class="fas fa-chevron-down muted"></i>
                </div>
                <div class="admin-gang-body">
                    <div class="form-grid">
                        <label class="field"><span>Label</span>
                            <input type="text" data-zf="label" data-z="${escapeHtml(t.zone)}" value="${escapeHtml(t.label)}" /></label>
                        <label class="field"><span>Circle radius (m)</span>
                            <input type="number" min="10" max="500" data-zf="radius" data-z="${escapeHtml(t.zone)}" value="${Math.round(t.radius || 60)}" /></label>
                        <label class="field"><span>Owned by</span>
                            <select data-holder="${escapeHtml(t.zone)}">${gangOpts}</select></label>
                        <label class="field checkbox">
                            <input type="checkbox" data-zf="capturable" data-z="${escapeHtml(t.zone)}" ${t.capturable ? 'checked' : ''} />
                            <span>Rivals can build influence here</span>
                        </label>
                    </div>
                    <div class="inline-form">
                        <button class="btn btn-accent btn-sm" data-zsave="${escapeHtml(t.zone)}"><i class="fas fa-floppy-disk"></i> Save</button>
                        <button class="btn btn-ghost btn-sm" data-zdraw="${escapeHtml(t.zone)}"><i class="fas fa-draw-polygon"></i> Walk the corners</button>
                        <button class="btn btn-ghost btn-sm" data-zsquare="${escapeHtml(t.zone)}"><i class="fas fa-vector-square"></i> Square here</button>
                        <button class="btn btn-ghost btn-sm" data-zmove="${escapeHtml(t.zone)}"><i class="fas fa-location-crosshairs"></i> Centre on me</button>
                        ${t.coords ? `<button class="btn btn-ghost btn-sm" data-ztp='${escapeHtml(JSON.stringify(t.coords))}'><i class="fas fa-plane-arrival"></i> Go there</button>` : ''}
                        <button class="btn btn-danger btn-sm" data-zdel="${escapeHtml(t.zone)}"><i class="fas fa-trash"></i> Delete</button>
                    </div>
                    <p class="hint"><i class="fas fa-circle-info"></i> Walking the corners gives the zone a real footprint. "Square here" drops a quick box around you when the exact shape doesn't matter.</p>
                </div>
            </div>`).join('');

        // Pre-select the current holder — doing it after render avoids
        // building a bespoke option list per zone.
        zones.forEach((t) => {
            const sel = list.querySelector(`[data-holder="${CSS.escape(t.zone)}"]`);
            if (sel) sel.value = t.holderId ? String(t.holderId) : '';
        });

        list.querySelectorAll('.admin-gang-head').forEach((head) => {
            head.onclick = () => head.parentElement.classList.toggle('is-open');
        });

        list.querySelectorAll('[data-zsave]').forEach((b) => {
            b.onclick = async () => {
                const zone = b.dataset.zsave;
                const row = b.closest('.admin-gang');
                const fields = {};
                row.querySelectorAll(`[data-zf][data-z="${CSS.escape(zone)}"]`).forEach((inp) => {
                    if (inp.type === 'checkbox') fields[inp.dataset.zf] = inp.checked;
                    else if (inp.type === 'number') fields[inp.dataset.zf] = Number(inp.value);
                    else fields[inp.dataset.zf] = inp.value;
                });
                const res = await acall('XS-CriminalTablet:admin:updateZone', zone, fields);
                if (!report(res, 'Zone saved.')) return;

                const holder = row.querySelector(`[data-holder="${CSS.escape(zone)}"]`).value;
                await acall('XS-CriminalTablet:admin:setTerritory', zone, holder ? Number(holder) : null);
                await refresh();
            };
        });

        list.querySelectorAll('[data-zdraw]').forEach((b) => {
            b.onclick = () => nui('admin:drawZone', { zone: b.dataset.zdraw });
        });
        list.querySelectorAll('[data-zsquare]').forEach((b) => {
            b.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:squareZone', b.dataset.zsquare, null);
                if (report(res, 'Square dropped around you.')) await refresh();
            };
        });
        list.querySelectorAll('[data-zmove]').forEach((b) => {
            b.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:setZoneCoords', b.dataset.zmove);
                if (report(res, 'Centre moved.')) await refresh();
            };
        });
        list.querySelectorAll('[data-ztp]').forEach((b) => {
            b.onclick = () => {
                try { nui('admin:teleportZone', JSON.parse(b.dataset.ztp)); } catch (e) { /* malformed, ignore */ }
            };
        });
        list.querySelectorAll('[data-zdel]').forEach((b) => {
            b.onclick = async () => {
                if (b.dataset.armed !== '1') {
                    b.dataset.armed = '1';
                    b.innerHTML = '<i class="fas fa-triangle-exclamation"></i> Confirm';
                    setTimeout(() => { b.dataset.armed = '0'; b.innerHTML = '<i class="fas fa-trash"></i> Delete'; }, 4000);
                    return;
                }
                const res = await acall('XS-CriminalTablet:admin:deleteZone', b.dataset.zdel);
                if (report(res, 'Zone deleted.')) await refresh();
            };
        });
    }

    // ═══ PRICING ═══
    // Every priced thing on the server in one place. Rows that have been
    // changed from their config default are flagged and get a Reset, so
    // staff can always see what they've touched.
    function priceRow(kind, p) {
        return `<div class="price-row ${p.overridden ? 'is-custom' : ''}">
            <div class="price-main">
                <span class="price-label">${escapeHtml(p.label)}</span>
                <span class="price-meta">
                    ${p.tier ? escapeHtml(p.tier) + ' · ' : ''}${escapeHtml(p.kind || 'upgrade')}
                    ${p.overridden ? ` · default ${money(p.default)}` : ''}
                </span>
            </div>
            <div class="price-edit">
                <span class="price-prefix">$</span>
                <input type="number" min="0" value="${p.price}" data-price="${escapeHtml(p.key)}" data-kind="${escapeHtml(kind)}" />
            </div>
            <button class="btn btn-ghost btn-sm" data-resetprice="${escapeHtml(p.key)}" data-kind="${escapeHtml(kind)}"
                ${p.overridden ? '' : 'disabled'} title="Back to the config default">
                <i class="fas fa-rotate-left"></i>
            </button>
        </div>`;
    }

    async function renderPricing() {
        const data = await acall('XS-CriminalTablet:admin:getPrices');
        if (!data) return;

        $('#priceUnlockList').innerHTML = (data.unlocks || []).map((p) => priceRow('unlock', p)).join('')
            || '<div class="empty"><i class="fas fa-tags"></i>No unlocks configured.</div>';
        $('#priceUpgradeList').innerHTML = (data.upgrades || []).map((p) => priceRow('upgrade', p)).join('')
            || '<div class="empty"><i class="fas fa-tags"></i>No upgrades configured.</div>';

        $$('[data-price]').forEach((inp) => {
            inp.onchange = async () => {
                const res = await acall('XS-CriminalTablet:admin:setPrice',
                    inp.dataset.kind, inp.dataset.price, Number(inp.value));
                if (report(res, 'Price set.')) renderPricing();
            };
        });
        $$('[data-resetprice]').forEach((b) => {
            b.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:resetPrice',
                    b.dataset.kind, b.dataset.resetprice);
                if (report(res, 'Back to the config default.')) renderPricing();
            };
        });
    }

    // ═══ GRAFFITI ═══
    function populateGangSelect() {
        const sel = $('#gfGangSelect');
        if (!sel) return;
        const prev = sel.value;
        sel.innerHTML = (overview.gangs || []).map((g) =>
            `<option value="${g.id}">${escapeHtml(g.label)}</option>`).join('');
        if (prev) sel.value = prev;
        sel.onchange = () => renderGraffitiAdmin();

        const presets = $('#gfPresetSelect');
        if (presets && !presets.options.length) {
            // Mirrors Config.Graffiti.catalogue. Keeping it in sync matters
            // less than it looks — the server validates the id either way.
            ['tag_classic', 'tag_bubble', 'tag_stencil', 'tag_drip'].forEach((id) => {
                const opt = document.createElement('option');
                opt.value = id;
                opt.textContent = id.replace('tag_', '').replace(/^\w/, (c) => c.toUpperCase());
                presets.appendChild(opt);
            });
        }
    }

    async function renderGraffitiAdmin() {
        const gangId = Number($('#gfGangSelect').value);
        if (!gangId) return;

        const art = await acall('XS-CriminalTablet:admin:graffitiListArt', gangId) || [];
        const grid = $('#gfArtList');
        grid.innerHTML = art.length ? art.map((a) => `
            <div class="art-card">
                <div class="art-thumb">${window.XS.artThumb ? window.XS.artThumb(a.art) : ''}</div>
                <div class="art-meta">
                    <div class="art-name">${escapeHtml(a.label || 'Untitled')}</div>
                    <div class="art-source">${escapeHtml(a.source)}</div>
                    <div class="art-actions">
                        <button class="btn btn-danger btn-sm" data-delart="${a.id}"><i class="fas fa-trash"></i> Remove</button>
                    </div>
                </div>
            </div>`).join('') : '<div class="empty" style="grid-column:1/-1"><i class="fas fa-spray-can"></i>This crew has no art.</div>';

        grid.querySelectorAll('[data-delart]').forEach((b) => {
            b.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:graffitiDeleteArt', Number(b.dataset.delart));
                if (report(res, 'Removed.')) renderGraffitiAdmin();
            };
        });

        const tags = await acall('XS-CriminalTablet:admin:graffitiListTags', 60) || [];
        $('#gfTagList').innerHTML = tags.length ? tags.map((t) => `
            <div class="tile">
                <span class="tile-avatar"><i class="fas fa-spray-can"></i></span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(t.gang_label || 'Unknown crew')}</span>
                    <span class="tile-sub">by ${escapeHtml(t.sprayed_name || '?')} · ${escapeHtml(formatTime(t.created_at))}
                        · <span style="font-family:var(--mono)">${Math.round(t.x)}, ${Math.round(t.y)}</span></span>
                </div>
                <div class="tile-actions">
                    <button class="btn btn-danger btn-sm" data-deltag="${t.id}"><i class="fas fa-eraser"></i></button>
                </div>
            </div>`).join('') : '<div class="empty"><i class="fas fa-spray-can"></i>Nothing sprayed yet.</div>';

        $('#gfTagList').querySelectorAll('[data-deltag]').forEach((b) => {
            b.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:graffitiRemoveTag', Number(b.dataset.deltag));
                if (report(res, 'Tag scrubbed.')) renderGraffitiAdmin();
            };
        });
    }

    $('#gfAddUrlBtn').onclick = async () => {
        const gangId = Number($('#gfGangSelect').value);
        const label = $('#gfArtLabel').value.trim();
        const url = $('#gfArtUrl').value.trim();
        if (!url) return toast('Paste a direct image link first.', 'error');
        const res = await acall('XS-CriminalTablet:admin:graffitiAddArt', gangId, label || 'Custom', url, 'url');
        if (report(res, 'Added to their library.')) {
            $('#gfArtLabel').value = '';
            $('#gfArtUrl').value = '';
            renderGraffitiAdmin();
        }
    };

    $('#gfAddPresetBtn').onclick = async () => {
        const gangId = Number($('#gfGangSelect').value);
        const preset = $('#gfPresetSelect').value;
        const res = await acall('XS-CriminalTablet:admin:graffitiAddArt', gangId,
            $('#gfArtLabel').value.trim() || 'Catalogue', preset, 'preset');
        if (report(res, 'Added.')) renderGraffitiAdmin();
    };

    $('#gfWipeGangBtn').onclick = async () => {
        const gangId = Number($('#gfGangSelect').value);
        const b = $('#gfWipeGangBtn');
        if (b.dataset.armed !== '1') {
            b.dataset.armed = '1';
            b.textContent = 'Click again to wipe every tag';
            setTimeout(() => { b.dataset.armed = '0'; b.textContent = "Wipe selected crew's tags"; }, 4000);
            return;
        }
        const res = await acall('XS-CriminalTablet:admin:graffitiWipeGang', gangId);
        if (report(res, 'Tags wiped.')) renderGraffitiAdmin();
    };

    // ═══ WAR ═══
    $('#warRefreshBtn').onclick = () => renderWars();

    async function renderWars() {
        const wars = await acall('XS-CriminalTablet:admin:warList') || [];
        const list = $('#adminWarList');
        if (!wars.length) {
            list.innerHTML = '<div class="empty"><i class="fas fa-crosshairs"></i>Nothing running right now.</div>';
            return;
        }
        list.innerHTML = wars.map((w) => `
            <div class="tile">
                <span class="tile-avatar"><i class="fas ${w.kind === 'raid' ? 'fa-fire' : 'fa-skull'}"></i></span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(w.attackerLabel)} → ${escapeHtml(w.defenderLabel)}</span>
                    <span class="tile-sub">${escapeHtml(w.kind)} · ${escapeHtml(w.phase)}
                        · ${w.scoreAttack}:${w.scoreDefend}
                        ${w.kind === 'raid' ? `· hold ${w.holdProgress}/${w.holdTarget}s` : ''}</span>
                </div>
                <div class="tile-actions">
                    <button class="btn btn-danger btn-sm" data-stopwar="${w.id}">Stop</button>
                </div>
            </div>`).join('');

        list.querySelectorAll('[data-stopwar]').forEach((b) => {
            b.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:warStop', Number(b.dataset.stopwar));
                if (report(res, 'Stopped.')) renderWars();
            };
        });
    }

    // ═══ TEST MODE ═══
    async function renderTestMode() {
        const state = await acall('XS-CriminalTablet:admin:testModeState') || {};
        const running = {};
        (state.zones || []).forEach((z) => { running[z.zone] = z; });

        const zoneList = $('#testZoneList');
        const zones = (overview.territories || []).filter((t) => t.coords);
        zoneList.innerHTML = zones.length ? zones.map((t) => {
            const live = running[t.zone];
            return `<div class="tile ${live ? 'is-mine' : ''}">
                <span class="tile-avatar"><i class="fas fa-flag"></i></span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(t.label)}</span>
                    <span class="tile-sub">${live ? `${live.count} defenders up · started by ${escapeHtml(live.by)}` : 'idle'}</span>
                </div>
                <div class="tile-actions">
                    <button class="btn ${live ? 'btn-danger' : 'btn-accent'} btn-sm"
                        data-testzone="${escapeHtml(t.zone)}" data-on="${live ? '0' : '1'}">
                        ${live ? 'Stop' : 'Spawn defenders'}
                    </button>
                </div>
            </div>`;
        }).join('') : '<div class="empty"><i class="fas fa-flag"></i>No zones with a position yet.</div>';

        zoneList.querySelectorAll('[data-testzone]').forEach((b) => {
            b.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:testModeZone',
                    b.dataset.testzone, b.dataset.on === '1');
                if (report(res, b.dataset.on === '1' ? 'Defenders spawned.' : 'Stopped.')) renderTestMode();
            };
        });

        $('#testGangList').innerHTML = (overview.gangs || []).map((g) => `
            <div class="tile">
                <span class="admin-gang-swatch" style="background:${escapeHtml(g.color || '#666')}"></span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(g.label)}</span>
                    <span class="tile-sub">Arm their next incoming raid with NPC defenders</span>
                </div>
                <div class="tile-actions">
                    <button class="btn btn-accent btn-sm" data-arm="${g.id}" data-on="1">Arm</button>
                    <button class="btn btn-ghost btn-sm" data-arm="${g.id}" data-on="0">Disarm</button>
                </div>
            </div>`).join('');

        $('#testGangList').querySelectorAll('[data-arm]').forEach((b) => {
            b.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:testModeArm',
                    Number(b.dataset.arm), b.dataset.on === '1');
                report(res, b.dataset.on === '1' ? 'Armed.' : 'Disarmed.');
            };
        });
    }

    $('#testStopAllBtn').onclick = async () => {
        const res = await acall('XS-CriminalTablet:admin:testModeStopAll');
        if (report(res, 'Everything stopped.')) renderTestMode();
    };

    // ═══ BLACKMARKET ═══
    async function renderChatMod() {
        const rows = await acall('XS-CriminalTablet:admin:chatGetWorld') || [];
        const list = $('#chatModList');
        if (!rows.length) {
            list.innerHTML = '<div class="empty"><i class="fas fa-comment-slash"></i>Nothing posted yet.</div>';
            return;
        }
        list.innerHTML = rows.map((m) => `
            <div class="tile">
                <span class="tile-avatar"><i class="fas fa-user-secret"></i></span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(m.handle)}</span>
                    <span class="tile-sub">${escapeHtml(m.message)}</span>
                </div>
                <span class="log-time">${escapeHtml(formatTime(m.created_at))}</span>
                <div class="tile-actions">
                    <button class="btn btn-danger btn-sm" data-delmsg="${m.id}"><i class="fas fa-trash"></i></button>
                </div>
            </div>`).join('');

        list.querySelectorAll('[data-delmsg]').forEach((b) => {
            b.onclick = async () => {
                const res = await acall('XS-CriminalTablet:admin:chatDeleteWorld', Number(b.dataset.delmsg));
                if (report(res, 'Deleted.')) renderChatMod();
            };
        });
    }

    $('#resolveHandleBtn').onclick = async () => {
        const handle = $('#resolveHandleInput').value.trim();
        if (!handle) return;
        const res = await acall('XS-CriminalTablet:admin:chatResolveHandle', handle);
        $('#resolveHandleResult').textContent = (res && res.ok)
            ? `→ ${res.citizenid}`
            : ((res && res.error) || 'Not found');
    };

    // ═══ DEALER ═══
    async function renderDealerStock() {
        const stock = await acall('XS-CriminalTablet:admin:dealerGetStock') || [];
        const list = $('#dealerStockList');
        if (!Array.isArray(stock) || !stock.length) {
            list.innerHTML = '<div class="empty"><i class="fas fa-box-open"></i>No stock — the dealer pool in config.lua is empty.</div>';
            return;
        }
        list.innerHTML = stock.map((s) => `
            <div class="tile">
                <span class="tile-avatar"><i class="fas fa-box"></i></span>
                <div class="tile-main">
                    <span class="tile-name">${escapeHtml(s.label || s.item)}</span>
                    <span class="tile-sub" style="font-family:var(--mono)">${escapeHtml(s.item)}</span>
                </div>
                <div class="tile-stat">${money(s.price)}</div>
            </div>`).join('');
    }

    $('#dealerRerollBtn').onclick = async () => {
        const res = await acall('XS-CriminalTablet:admin:dealerReroll');
        if (report(res, 'Stock rerolled.')) renderDealerStock();
    };
    $('#dealerClearCooldownBtn').onclick = async () => {
        const res = await acall('XS-CriminalTablet:admin:dealerClearCooldown');
        report(res, 'Cooldown cleared.');
    };
})();
