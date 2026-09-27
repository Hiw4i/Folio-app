/* Shared touch physics for the Office readers. Wheel/keyboard scrolling,
   browser text selection and zoomed panning remain native. */
(() => {
  'use strict';

  const clamp = (value, min, max) => Math.max(min, Math.min(value, max));
  // The fast Flutter BouncingScrollPhysics friction factor is 0.26.
  function rubber(distance, dimension) {
    const extent = Math.max(1, dimension);
    return Math.sign(distance) * extent * (1 - 1 / (1 + Math.abs(distance) * 0.26 / extent));
  }
  // Over-damped spring: mass .3, stiffness 75, damping ratio 1.3.
  // An analytic solution is stable even when a frame is late or skipped.
  function spring(displacement, velocity, seconds) {
    const omega = Math.sqrt(75 / 0.3), ratio = 1.3;
    const root = Math.sqrt(ratio * ratio - 1);
    const r1 = -omega * (ratio - root), r2 = -omega * (ratio + root);
    const a = (velocity - r2 * displacement) / (r1 - r2);
    const b = displacement - a;
    const e1 = Math.exp(r1 * seconds), e2 = Math.exp(r2 * seconds);
    return { position: a * e1 + b * e2, velocity: a * r1 * e1 + b * r2 * e2 };
  }

  function create({ viewport, content, horizontal, canStart, cancelTap }) {
    const media = window.matchMedia('(prefers-reduced-motion: reduce)');
    let reduced = media.matches, disposed = false, gesture = null;
    let frame = 0, animation = null, position = 0, maximum = 0, dimension = 1;
    let previousBehavior = '', previousSnap = '', ownsStyles = false;
    const current = () => horizontal ? viewport.scrollLeft : viewport.scrollTop;
    const selected = () => window.getSelection()?.isCollapsed === false;
    const zoomed = () => (window.visualViewport?.scale || 1) > 1.01;
    const canDrive = () => !disposed && canStart() && !selected() && !zoomed();
    const axis = (touch) => horizontal ? touch.clientX : touch.clientY;
    const cross = (touch) => horizontal ? touch.clientY : touch.clientX;

    function measure() {
      dimension = Math.max(1, horizontal ? viewport.clientWidth : viewport.clientHeight);
      maximum = Math.max(0, horizontal ? viewport.scrollWidth - viewport.clientWidth
        : viewport.scrollHeight - viewport.clientHeight);
    }
    function acquire() {
      if (ownsStyles) return;
      previousBehavior = viewport.style.scrollBehavior;
      previousSnap = viewport.style.scrollSnapType;
      viewport.style.scrollBehavior = 'auto';
      viewport.style.scrollSnapType = 'none';
      ownsStyles = true;
    }
    function restore() {
      if (!ownsStyles) return;
      viewport.style.scrollBehavior = previousBehavior;
      viewport.style.scrollSnapType = previousSnap;
      ownsStyles = false;
    }
    function paint() {
      const bounded = clamp(position, 0, maximum);
      viewport.scrollTo(horizontal ? { left: bounded, behavior: 'instant' }
        : { top: bounded, behavior: 'instant' });
      const offset = reduced ? 0 : -rubber(position - bounded, dimension);
      content.style.transform = Math.abs(offset) < 0.01 ? ''
        : horizontal ? `translate3d(${offset}px,0,0)` : `translate3d(0,${offset}px,0)`;
      content.style.willChange = offset ? 'transform' : '';
    }
    function stopFrame() {
      cancelAnimationFrame(frame); frame = 0; animation = null;
    }
    function reset() {
      stopFrame(); gesture = null;
      content.style.transform = ''; content.style.willChange = '';
      restore(); position = current();
    }
    function finish(target) {
      position = clamp(target, 0, maximum); paint();
      animation = null; frame = 0; restore();
    }
    function springTo(target, velocity) {
      acquire();
      animation = { kind: 'spring', target, origin: position, velocity, start: performance.now() };
      frame = requestAnimationFrame(tick);
    }
    function tick(now) {
      frame = 0;
      if (disposed || !animation) return;
      if (!canDrive()) { reset(); return; }
      const a = animation;
      if (a.kind === 'spring') {
        const seconds = Math.max(0, (now - a.start) / 1000);
        const value = spring(a.origin - a.target, a.velocity, seconds);
        position = a.target + value.position;
        if ((Math.abs(value.position) < 0.25 && Math.abs(value.velocity) < 4) || seconds > 1.4) {
          finish(a.target); return;
        }
      } else {
        const dt = clamp((now - a.last) / 1000, 0, 0.05); a.last = now;
        const speed = Math.max(0, Math.abs(a.velocity) - (1400 + Math.abs(a.velocity) * 2) * dt);
        const velocity = Math.sign(a.velocity) * speed;
        position += (a.velocity + velocity) * 0.5 * dt; a.velocity = velocity;
        if (position < 0 || position > maximum) {
          if (reduced) { finish(clamp(position, 0, maximum)); return; }
          springTo(clamp(position, 0, maximum), velocity); paint(); return;
        }
        if (speed < 10) { finish(position); return; }
      }
      paint(); frame = requestAnimationFrame(tick);
    }
    function refreshTouchAction() {
      // After a pinch, native WebView panning must regain both axes. Likewise,
      // never intercept the browser's selection-handle auto-scroll.
      viewport.style.touchAction = selected() || zoomed() ? 'auto' : 'pinch-zoom';
      // Увеличенный слайд не должен снапаться и перелистываться на соседей:
      // свободный пан внутри текущего слайда, снап-точки выкл. На зуме-аут
      // инлайн сбрасывается и возвращается CSS scroll-snap-type: mandatory.
      if (horizontal) viewport.style.scrollSnapType = zoomed() ? 'none' : '';
      if (selected() || zoomed()) reset();
    }
    function start(event) {
      // PowerPoint (horizontal): свободная свайп-прокрутка отключена.
      // Листание только дискретное — тап или направленный свайп как
      // команда prev/next обрабатывается в office.js (pointerup).
      if (horizontal) { reset(); return; }
      if (event.touches.length !== 1 || !canDrive()
          || event.target.closest?.('a,button,input,textarea,select,[contenteditable="true"]')) {
        if (gesture || animation) cancelTap();
        reset(); return;
      }
      if (animation) cancelTap();
      const interrupted = !!animation;
      stopFrame();
      if (!interrupted) {
        // A transformed document changes scrollWidth/scrollHeight. Measure only
        // at rest; an interrupted spring keeps its untransformed geometry and
        // logical offset so catching it with a finger does not visibly jump.
        content.style.transform = ''; content.style.willChange = '';
        measure(); position = current();
      }
      const touch = event.touches[0];
      gesture = { id: touch.identifier, start: axis(touch), cross: cross(touch), last: axis(touch),
        time: event.timeStamp, velocity: 0, dragging: false, interrupted,
        startPage: Math.round(position / dimension) };
    }
    function move(event) {
      const g = gesture;
      if (!g) return;
      if (event.touches.length !== 1 || !canDrive()) { cancelTap(); reset(); return; }
      const touch = Array.from(event.touches).find((t) => t.identifier === g.id);
      if (!touch) { reset(); return; }
      const coordinate = axis(touch), travel = coordinate - g.start;
      if (!g.dragging) {
        if (Math.hypot(travel, cross(touch) - g.cross) <= 8) return;
        if (Math.abs(travel) < Math.abs(cross(touch) - g.cross)) { cancelTap(); reset(); return; }
        if (!event.cancelable) { reset(); return; }
        g.dragging = true; acquire(); cancelTap();
      }
      if (event.cancelable) event.preventDefault();
      const delta = g.last - coordinate;
      const dt = clamp(event.timeStamp - g.time, 1, 80);
      const sample = clamp(delta / dt * 1000, -8000, 8000);
      g.velocity = g.velocity * 0.35 + sample * 0.65;
      g.last = coordinate; g.time = event.timeStamp;
      position += delta;
      if (reduced) position = clamp(position, 0, maximum);
      // At most one scroll write per display frame, no per-page layout reads.
      if (!frame) frame = requestAnimationFrame(() => { frame = 0; if (!disposed && gesture) paint(); });
    }
    function end(event) {
      const g = gesture;
      if (!g) return;
      if (event.touches.length) { cancelTap(); reset(); return; }
      gesture = null; cancelAnimationFrame(frame); frame = 0;
      if (!g.dragging && !g.interrupted) { restore(); return; }
      paint();
      const velocity = event.timeStamp - g.time > 100 ? 0 : g.velocity;
      if (horizontal) {
        // PowerPoint: без анимации перелистывания — мгновенный переход
        // на целевой слайд вместо пружинной анимации.
        const projected = position + velocity * 0.12;
        const page = clamp(Math.round(projected / dimension), g.startPage - 1, g.startPage + 1);
        const target = clamp(page * dimension, 0, maximum);
        finish(target);
      } else if (position < 0 || position > maximum) {
        if (reduced) finish(clamp(position, 0, maximum));
        else springTo(clamp(position, 0, maximum), velocity);
      } else if (Math.abs(velocity) >= 50) {
        acquire(); animation = { kind: 'fling', velocity, last: performance.now() };
        frame = requestAnimationFrame(tick);
      } else finish(position);
    }
    function cancel() { if (gesture) cancelTap(); reset(); }
    function motionChanged(event) { reduced = event.matches; reset(); }
    function visibilityChanged() { if (document.hidden) reset(); }
    function dispose() {
      if (disposed) return;
      reset(); disposed = true; viewport.style.touchAction = '';
      viewport.removeEventListener('touchstart', start);
      viewport.removeEventListener('touchmove', move);
      viewport.removeEventListener('touchend', end);
      viewport.removeEventListener('touchcancel', cancel);
      viewport.removeEventListener('wheel', reset);
      document.removeEventListener('selectionchange', refreshTouchAction);
      document.removeEventListener('visibilitychange', visibilityChanged);
      window.visualViewport?.removeEventListener('resize', refreshTouchAction);
      media.removeEventListener('change', motionChanged);
    }
    viewport.addEventListener('touchstart', start, { passive: true });
    viewport.addEventListener('touchmove', move, { passive: false });
    viewport.addEventListener('touchend', end, { passive: true });
    viewport.addEventListener('touchcancel', cancel, { passive: true });
    viewport.addEventListener('wheel', reset, { passive: true });
    document.addEventListener('selectionchange', refreshTouchAction);
    document.addEventListener('visibilitychange', visibilityChanged);
    window.visualViewport?.addEventListener('resize', refreshTouchAction);
    media.addEventListener('change', motionChanged);
    refreshTouchAction();
    return { reset, dispose, get isDragging() { return gesture?.dragging === true; },
      get isAnimating() { return animation !== null; } };
  }
  window.FolioReaderMotion = { create, rubber, spring };
})();
