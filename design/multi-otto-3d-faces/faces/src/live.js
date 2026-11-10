// The live renderer section: a face picker, a pose picker and drag to turn.
(() => {
  const root = document.querySelector('#live .lv');
  const canvas = root.querySelector('canvas');
  let draw;
  try { draw = faceRenderer(canvas); } catch { root.classList.add('nogl'); return; }

  const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const TWEEN = calm ? 1 : 340, BLINK = 240;
  const lerp = (a, b, k) => a.map((v, i) => v + (b[i] - v) * k);
  const ease = x => 1 - Math.pow(1 - x, 3);
  const smooth = x => x * x * (3 - 2 * x);

  let who = 'otto', state = 'rest';
  const target = () => ({ ...faceParams(who, state), close: 0, bend: 1 });
  let from = target(), to = from, t0 = -1e9, blinkAt = -1e9;
  let orbit = [0, 0], drag = null, raf = 0, seen = true, motionSamples = 2;

  // the flat line both eye types pass through, sized to match a fully closed capsule exactly
  const flatLine = i => {
    const cap = from.arc === 0 ? from : to.arc === 0 ? to : null, s = cap || from, half = s[`e${i}`][3], r = s.er[i];
    if (!cap) return { w: half, r };
    const h = (half + r) * .2;
    return { w: r * 1.25 - h, r: h };
  };

  const at = now => {
    const p = Math.min(1, (now - t0) / TWEEN), k = ease(p), blink = (now - blinkAt) / BLINK;
    const v = { albedo: lerp(from.albedo, to.albedo, k), eo: lerp(from.eo, to.eo, k), shape: from.shape, shape2: to.shape };
    const pose = lerp(from.pose, to.pose, k);
    v.pose = [pose[0] + orbit[0], pose[1] + orbit[1], pose[2]];
    v.morph = from.shape === to.shape ? 0 : k;
    if (from.arc === to.arc) {
      v.e0 = lerp(from.e0, to.e0, k); v.e1 = lerp(from.e1, to.e1, k); v.er = lerp(from.er, to.er, k); v.arc = to.arc;
      v.close = from.close * (1 - k); v.bend = from.bend + (1 - from.bend) * k;
    } else {                                  // the eye goes through a flat line: a capsule closes into it, an arc straightens into it
      const s = smooth(p), out = s < .5, q = out ? s * 2 : s * 2 - 1, side = out ? from : to, t = out ? q : 1 - q, isArc = side.arc !== 0;
      v.er = [0, 0];
      for (const i of [0, 1]) {
        const key = `e${i}`, e = side[key], line = flatLine(i), xy = lerp(from[key].slice(0, 2), to[key].slice(0, 2), s);
        v[key] = [...xy, e[2], isArc ? e[3] + (line.w - e[3]) * t : e[3]];
        v.er[i] = isArc ? side.er[i] + (line.r - side.er[i]) * t : side.er[i];
      }
      v.arc = side.arc;
      v.close = isArc ? 0 : out ? from.close + (1 - from.close) * q : 1 - q;
      v.bend = !isArc ? 1 : out ? from.bend * (1 - q) : q;
    }
    const blinking = blink >= 0 && blink < 1;
    v.B = Math.max(v.close, blinking && v.arc === 0 ? Math.sin(Math.PI * blink) : 0);
    return { v, busy: p < 1 || blinking };
  };

  const wake = () => { raf = raf || requestAnimationFrame(tick); };
  const tick = now => {
    raf = 0;
    const { v, busy } = at(now);
    const moving = busy || drag, started = performance.now();
    draw({ ...v, N: moving ? motionSamples : 4 });   // fewer samples in motion, full quality once it settles
    if (moving && performance.now() - started > 24) motionSamples = 1;   // a slower GPU trades edges for frame rate
    if (busy) wake();
  };

  const blinkBtn = root.querySelector('[data-blink]');
  const press = (attr, value) => root.querySelectorAll(`[${attr}]`).forEach(b => b.setAttribute('aria-pressed', b.getAttribute(attr) === value));
  const label = attr => root.querySelector(`[${attr}][aria-pressed="true"]`).textContent;

  const go = () => {
    const now = performance.now(), { v } = at(now);
    from = { ...v, shape: v.morph > .5 ? v.shape2 : v.shape };   // carry on from what's on screen, including any turn
    to = target(); t0 = now; orbit = [0, 0];
    press('data-face', who); press('data-pose', state);
    canvas.setAttribute('aria-label', `${label('data-face')}, ${label('data-pose')}`);
    blinkBtn.disabled = to.arc !== 0;
    wake();
  };

  root.addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b) return;
    if (b.dataset.face) { who = b.dataset.face; go(); }
    else if (b.dataset.pose) { state = b.dataset.pose; go(); }
    else { blinkAt = performance.now(); wake(); }
  });

  canvas.addEventListener('pointerdown', e => { drag = [e.clientX, e.clientY]; canvas.setPointerCapture(e.pointerId); });
  canvas.addEventListener('pointermove', e => {
    if (!drag) return;
    orbit = [Math.max(-1.1, Math.min(1.1, orbit[0] - (e.clientY - drag[1]) * .008)), Math.max(-1.1, Math.min(1.1, orbit[1] - (e.clientX - drag[0]) * .008))];
    drag = [e.clientX, e.clientY];
    wake();
  });
  const release = () => { drag = null; wake(); };
  canvas.addEventListener('pointerup', release);
  canvas.addEventListener('pointercancel', release);

  new IntersectionObserver(([e]) => { seen = e.isIntersecting; }).observe(canvas);
  const nextBlink = () => setTimeout(() => {
    if (seen && !document.hidden && to.arc === 0 && state !== 'needs') { blinkAt = performance.now(); wake(); }
    nextBlink();
  }, 2600 + Math.random() * 2800);
  if (!calm) nextBlink();
  wake();
})();
