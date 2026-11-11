(function () {
    const SOUNDS = {
        shake: [
            { file: 'sounds/shake1.ogg', from: 0.85, to: 3.35 },
            { file: 'sounds/shake2.ogg', from: 0.05, to: 1.23 },
        ],
    };
    const TARGET_DB = -31;

    let ctx = null;
    const buffers = new Map();
    const voices = new Map();

    function audio() {
        try {
            if (!ctx) {
                const AC = window.AudioContext || window.webkitAudioContext;
                if (!AC) return null;
                ctx = new AC();
            }
            if (ctx.state === 'suspended') ctx.resume();
            return ctx;
        } catch (e) {
            return null;
        }
    }

    function load(file) {
        if (!buffers.has(file)) {
            const c = audio();
            buffers.set(file, !c ? Promise.resolve(null) : fetch(file)
                .then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(new Error(String(r.status)))))
                .then((data) => c.decodeAudioData(data))
                .catch(() => null));
        }
        return buffers.get(file);
    }

    function warm() {
        SOUNDS.shake.forEach((clip) => { ready(clip); });
    }

    async function ready(clip) {
        const buf = await load(clip.file);
        if (!buf) return null;
        if (clip.gain === undefined) {
            const a = clip.from;
            const b = clip.to;
            const d = buf.getChannelData(0);
            const s = Math.floor(a * buf.sampleRate);
            const e = Math.min(d.length, Math.floor(b * buf.sampleRate));
            let sum = 0;
            for (let i = s; i < e; i++) sum += d[i] * d[i];
            const db = 10 * Math.log10(sum / Math.max(1, e - s) + 1e-12);
            clip.gain = Math.min(8, Math.pow(10, (TARGET_DB - db) / 20));
        }
        return buf;
    }

    const pick = (list) => list[Math.floor(Math.random() * list.length)];

    function voice(id) {
        const c = audio();
        if (!c) return null;
        let v = voices.get(id);
        if (v) return v;
        const out = c.createGain();
        out.gain.value = 0;
        out.connect(c.destination);
        v = { out, shakeToken: 0, shakes: new Set(), started: false };
        voices.set(id, v);
        return v;
    }

    function setVolume(v, vol) {
        const c = audio();
        if (!c || !v) return;
        const target = Math.max(0, Math.min(1, Number(vol ?? 1)));
        v.out.gain.setTargetAtTime(target, c.currentTime, 0.05);
    }

    async function shake(v, ms) {
        const c = audio();
        if (!c || !v) return;
        const token = ++v.shakeToken;
        let left = Math.max(0.2, ms / 1000);
        let t = 0;
        while (left > 0.15) {
            const clip = pick(SOUNDS.shake);
            const buf = await ready(clip);
            if (!buf || v.shakeToken !== token) return;
            const len = Math.min(left, clip.to - clip.from);
            t = Math.max(t, c.currentTime + 0.01);
            const src = c.createBufferSource();
            src.buffer = buf;
            const g = c.createGain();
            g.gain.setValueAtTime(0, t);
            g.gain.linearRampToValueAtTime(clip.gain, t + 0.015);
            g.gain.setValueAtTime(clip.gain, Math.max(t + 0.02, t + len - 0.08));
            g.gain.linearRampToValueAtTime(0, t + len);
            src.connect(g).connect(v.out);
            src.start(t, clip.from, len + 0.01);
            v.shakes.add(src);
            src.onended = () => v.shakes.delete(src);
            t += len;
            left -= len;
        }
    }

    function stop(id) {
        const v = voices.get(id);
        if (!v) return;
        voices.delete(id);
        v.shakeToken++;
        const c = audio();
        const t = c ? c.currentTime : 0;
        v.shakes.forEach((src) => { try { src.stop(t + 0.05); } catch (e) { /* already stopped */ } });
        if (c) v.out.gain.setTargetAtTime(0, t, 0.02);
        setTimeout(() => { try { v.out.disconnect(); } catch (e) { /* already gone */ } }, 600);
    }

    window.addEventListener('message', (ev) => {
        const { action, data } = ev.data || {};
        if (action !== 'spraySound' || !data) return;
        const id = String(data.id || 'self');
        if (data.kind === 'stop') { stop(id); return; }
        const v = voice(id);
        if (!v) return;
        warm();
        if (data.vol !== undefined || !v.started) { setVolume(v, data.vol); v.started = true; }
        if (data.kind === 'shake') shake(v, Number(data.ms) || 1500);
    });
})();
