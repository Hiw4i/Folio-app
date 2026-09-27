(() => {
  'use strict';

  const params = new URLSearchParams(window.location.search);
  const format = params.get('format') || document.body.dataset.format;
  const viewport = document.getElementById('viewport');
  const documentRoot = document.getElementById('document');
  const status = document.getElementById('status');
  const documentUrl = '/document/active';
  const state = {
    format,
    ready: false,
    position: 0,
    count: 0,
    hits: [],
    activeHit: -1,
    searchRevision: 0,
    lastScroll: 0,
    scrollFrame: 0,
    pointer: null,
    pages: [],
    centers: [],
    disposed: false,
    resizeFrame: 0,
  };

  const motion = window.FolioReaderMotion.create({
    viewport, content: documentRoot, horizontal: format === 'pptx',
    canStart: () => state.ready && !state.disposed,
    cancelTap: () => { if (state.pointer) state.pointer.moved = true; },
  });
  const selection = window.FolioReaderSelection.create({
    viewport, content: documentRoot, post, cancelMotion: () => motion.reset(),
    visiblePages: () => state.pages,
  });
  window.FolioSelection = selection;

  const ownedUrls = new Set();
  const createObjectURL = URL.createObjectURL.bind(URL);
  const revokeObjectURL = URL.revokeObjectURL.bind(URL);
  URL.createObjectURL = (blob) => {
    const url = createObjectURL(blob); ownedUrls.add(url); return url;
  };
  URL.revokeObjectURL = (url) => { ownedUrls.delete(url); revokeObjectURL(url); };

  document.body.dataset.format = format || 'unknown';

  function post(type, payload = {}) {
    const message = JSON.stringify({ type, ...payload });
    if (window.FolioBridge && typeof window.FolioBridge.postMessage === 'function') {
      window.FolioBridge.postMessage(message);
    }
  }

  function fail(message, recoverable = true) {
    status.hidden = false;
    status.textContent = message;
    post('error', { message, recoverable });
  }

  function pageElements() { return state.pages; }

  function refreshGeometry() {
    state.pages = Array.from(documentRoot.querySelectorAll(format === 'docx'
      ? '.docx-wrapper > section.docx' : '.folio-slide-frame'));
    const rect = viewport.getBoundingClientRect();
    // One read batch after layout. The scroll path never measures every page.
    state.centers = state.pages.map((page) => {
      const r = page.getBoundingClientRect();
      return format === 'pptx' ? r.left - rect.left + viewport.scrollLeft + r.width / 2
        : r.top - rect.top + viewport.scrollTop + r.height / 2;
    });
  }

  function publishPosition(force = false) {
    if (!state.pages.length || state.disposed) return;
    const center = format === 'pptx' ? viewport.scrollLeft + viewport.clientWidth / 2
      : viewport.scrollTop + viewport.clientHeight / 2;
    let lo = 0, hi = state.centers.length;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (state.centers[mid] < center) lo = mid + 1;
      else hi = mid;
    }
    let closest = Math.min(lo, state.centers.length - 1);
    if (closest > 0 && Math.abs(state.centers[closest - 1] - center) < Math.abs(state.centers[closest] - center)) closest--;
    if (force || closest !== state.position || state.pages.length !== state.count) {
      state.position = closest; state.count = state.pages.length;
      post('position', { current: closest + 1, count: state.count });
    }
  }

  function zoomed() {
    return (window.visualViewport?.scale || 1) > 1.01;
  }

  // Pure range math for the zoomed-slide clamp below; covered by browser tests.
  function zoomedSlideRange(position, clientWidth, scale) {
    const lo = position * clientWidth;
    return { lo, hi: lo + clientWidth * (1 - 1 / scale) };
  }

  // Zoomed PPTX never leaves the current slide: no finger flips and no
  // snap/fling animations to neighbours. Pinch-zoom itself is native and
  // untouched; while the scale is changing (active pinch) scroll is left
  // alone so the clamp never fights the browser's pinch anchor.
  function clampZoomedSlide() {
    if (format !== 'pptx' || state.disposed || !zoomed()) {
      clampZoomedSlide.lastScale = window.visualViewport?.scale || 1;
      return;
    }
    const scale = window.visualViewport.scale || 1;
    if (Math.abs(scale - clampZoomedSlide.lastScale) > 0.001) {
      clampZoomedSlide.lastScale = scale;
      return;
    }
    const w = viewport.clientWidth;
    if (!(w > 0)) return;
    const { lo, hi } = zoomedSlideRange(state.position, w, scale);
    const bounded = Math.min(hi, Math.max(lo, viewport.scrollLeft));
    if (Math.abs(bounded - viewport.scrollLeft) > 0.5) {
      viewport.scrollTo({ left: bounded, behavior: 'instant' });
    }
  }
  clampZoomedSlide.lastScale = 1;

  function onScroll() {
    if (state.scrollFrame || state.disposed) return;
    state.scrollFrame = requestAnimationFrame(() => {
      state.scrollFrame = 0;
      const current = format === 'pptx' ? viewport.scrollLeft : viewport.scrollTop;
      const delta = current - state.lastScroll;
      state.lastScroll = current;
      if (state.pointer && Math.abs(current - state.pointer.scroll) > 1) {
        state.pointer.moved = true;
      }
      // Horizontal slide navigation never expresses intent to hide chrome.
      // Keep position updates, but avoid a bridge message on every swipe frame.
      if (format === 'docx' && !selection.isActive() && !motion.isAnimating
          && Math.abs(delta) > 0.5) post('scroll', { delta });
      // Clamp before publishing so a zoomed pan can never report a neighbour.
      clampZoomedSlide();
      publishPosition(false);
    });
  }

  function wrapSlides() {
    const slides = Array.from(documentRoot.querySelectorAll('.slide'));
    slides.forEach((slide) => {
      if (slide.parentElement?.classList.contains('folio-slide-frame')) return;
      const frame = document.createElement('section');
      frame.className = 'folio-slide-frame';
      slide.parentNode.insertBefore(frame, slide);
      frame.appendChild(slide);
    });
    layoutSlides();
  }

  function numericStyle(element, name, fallback) {
    const value = Number.parseFloat(element.style[name] || getComputedStyle(element)[name]);
    return Number.isFinite(value) && value > 0 ? value : fallback;
  }

  function layoutSlides() {
    if (format !== 'pptx') return;
    // Landscape is immersive: the viewport keeps no chrome padding (see the
    // orientation query in office.css), so slides fit the full viewport edge
    // to edge. Portrait keeps the top/bottom chrome reservation but also
    // goes edge to edge horizontally. All math is viewport-based, never
    // per-frame: off-screen frames skipped by `content-visibility: auto`
    // would otherwise report estimated sizes and mis-scale their slides.
    const landscape = viewport.clientWidth > viewport.clientHeight;
    const padTop = landscape ? 0 : 74;
    const padBottom = landscape ? 0 : 108;
    const availableWidth = Math.max(1, viewport.clientWidth);
    const availableHeight = Math.max(
      1,
      viewport.clientHeight - padTop - padBottom,
    );
    documentRoot.querySelectorAll('.folio-slide-frame > .slide').forEach((slide) => {
      const width = numericStyle(slide, 'width', 960);
      const height = numericStyle(slide, 'height', 540);
      const scale = Math.min(availableWidth / width, availableHeight / height);
      slide.style.transform = `scale(${scale})`;
      slide.style.left = `${(availableWidth - width * scale) / 2}px`;
      slide.style.top = `${(availableHeight - height * scale) / 2}px`;
    });
  }

  async function waitForAssets() {
    // Wait for intrinsic image metrics and embedded fonts before paginating.
    // Broken optional resources must not leave the reader stuck in Loading.
    const tasks = Array.from(documentRoot.querySelectorAll('img[src]')).map((img) =>
      typeof img.decode === 'function' ? img.decode().catch(() => {}) : Promise.resolve());
    if (document.fonts) tasks.push(document.fonts.ready);
    let timer;
    try {
      await Promise.race([Promise.allSettled(tasks), new Promise((resolve) => {
        timer = setTimeout(resolve, 8000);
      })]);
    } finally { clearTimeout(timer); }
    await new Promise((resolve) => requestAnimationFrame(resolve));
  }

  function finishReady() {
    refreshGeometry();
    const count = pageElements().length;
    if (!count) {
      fail('The document contains no displayable pages.', false);
      return;
    }
    state.ready = true;
    state.count = count;
    status.hidden = true;
    publishPosition(true);
    post('ready', {
      count,
      hasText: searchableTextNodes().length > 0,
    });
  }

  async function renderDocx() {
    const response = await fetch(documentUrl, { cache: 'no-store', credentials: 'omit' });
    if (!response.ok) throw new Error('The Word source is unavailable.');
    const buffer = await response.arrayBuffer();
    await window.docx.renderAsync(buffer, documentRoot, documentRoot, {
      className: 'docx',
      inWrapper: true,
      ignoreWidth: false,
      ignoreHeight: false,
      ignoreFonts: false,
      breakPages: true,
      renderHeaders: true,
      renderFooters: true,
      renderFootnotes: true,
      renderEndnotes: true,
      useBase64URL: false,
      ignoreLastRenderedPageBreak: false,
      renderAltChunks: false,
    });
    await waitForAssets();
    await window.FolioDocx.paginate(documentRoot);
    window.FolioDocx.fit(documentRoot, viewport);
    finishReady();
  }

  async function renderPptx() {
    if (!window.jQuery?.fn?.pptxToHtml || !window.FolioPptx) {
      throw new Error('The PowerPoint renderer is unavailable.');
    }
    const response = await fetch(documentUrl, { cache: 'no-store', credentials: 'omit' });
    if (!response.ok) throw new Error('The PowerPoint source is unavailable.');
    window.JSZip = window.folioPptxJsZip || window.JSZip;
    // Await actual conversion, including all slides/styles/charts. Counting
    // stable DOM nodes can incorrectly report a partly-rendered deck as ready.
    await window.jQuery(documentRoot).pptxToHtml({
      folioBuffer: await response.arrayBuffer(),
      pptxFileUrl: '',
      slideMode: false,
      keyBoardShortCut: false,
      mediaProcess: false,
      themeProcess: true,
      incSlide: { height: 0, width: 0 },
    });
    await waitForAssets();
    wrapSlides();
    finishReady();
  }

  function clearSearch() {
    documentRoot.querySelectorAll('mark[data-folio-search]').forEach((mark) => {
      mark.replaceWith(document.createTextNode(mark.textContent || ''));
    });
    documentRoot.normalize();
    state.hits = [];
    state.activeHit = -1;
  }

  function searchableTextNodes() {
    const walker = document.createTreeWalker(documentRoot, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const parent = node.parentElement;
        if (!parent || !node.nodeValue?.trim()) return NodeFilter.FILTER_REJECT;
        if (parent.closest('script, style, mark[data-folio-search], [aria-hidden="true"]')) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    return nodes;
  }

  function search(query) {
    motion.reset();
    selection.clear(); // Search replaces text nodes; old DOM ranges would be stale.
    const revision = ++state.searchRevision;
    clearSearch();
    const normalized = String(query || '').trim();
    if (!normalized) {
      post('search', { count: 0, active: -1, searching: false });
      return;
    }
    post('search', { count: 0, active: -1, searching: true });
    requestAnimationFrame(() => {
      if (revision !== state.searchRevision) return;
      searchableTextNodes().forEach((node) => {
        const text = node.nodeValue || '';
        const expression = new RegExp(normalized.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu');
        const indexes = [];
        let match;
        while ((match = expression.exec(text))) indexes.push({ index: match.index, length: match[0].length });
        for (let i = indexes.length - 1; i >= 0; i -= 1) {
          const { index, length } = indexes[i];
          const range = document.createRange();
          range.setStart(node, index);
          range.setEnd(node, index + length);
          const mark = document.createElement('mark');
          mark.dataset.folioSearch = 'match';
          range.surroundContents(mark);
        }
      });
      state.hits = Array.from(documentRoot.querySelectorAll('mark[data-folio-search]'));
      state.activeHit = state.hits.length ? 0 : -1;
      revealActiveHit(false);
      post('search', {
        count: state.hits.length,
        active: state.activeHit,
        searching: false,
      });
    });
  }

  function revealActiveHit(smooth = true) {
    motion.reset();
    state.hits.forEach((hit, index) => {
      hit.dataset.folioSearch = index === state.activeHit ? 'active' : 'match';
    });
    const hit = state.hits[state.activeHit];
    if (!hit) return;
    // PowerPoint: переход между слайдами всегда мгновенный, без анимации.
    const instant = format === 'pptx' || !smooth;
    if (format === 'pptx') {
      const frame = hit.closest('.folio-slide-frame');
      frame?.scrollIntoView({ behavior: 'instant', inline: 'center' });
    } else {
      hit.scrollIntoView({ behavior: instant ? 'instant' : 'smooth', block: 'center' });
    }
    window.setTimeout(() => publishPosition(true), instant ? 0 : 260);
  }

  function stepHit(delta) {
    if (!state.hits.length) return;
    state.activeHit = (state.activeHit + delta + state.hits.length) % state.hits.length;
    revealActiveHit(true);
    post('search', {
      count: state.hits.length,
      active: state.activeHit,
      searching: false,
    });
  }

  function goToPosition(index, smooth = true) {
    motion.reset();
    const pages = pageElements();
    const target = pages[Math.max(0, Math.min(Math.trunc(Number(index) || 0), pages.length - 1))];
    if (!target) return;
    // PowerPoint: смена слайдов всегда мгновенная, без анимации перелистывания.
    const instant = format === 'pptx' || !smooth;
    target.scrollIntoView({
      behavior: instant ? 'instant' : 'smooth',
      block: format === 'docx' ? 'start' : 'nearest',
      inline: format === 'pptx' ? 'center' : 'nearest',
    });
  }

  window.FolioOffice = {
    search,
    nextHit: () => stepHit(1),
    previousHit: () => stepHit(-1),
    goToPosition,
    // Чистая математика клампа увеличенного слайда (покрыта брауз. тестами).
    zoomedSlideRange,
  };

  document.addEventListener('click', (event) => {
    const link = event.target.closest?.('a');
    if (link) {
      event.preventDefault();
      event.stopPropagation();
    }
  }, true);
  document.addEventListener('dragstart', (event) => event.preventDefault(), true);
  viewport.addEventListener('scroll', onScroll, { passive: true });
  const activePointers = new Set();
  const tapSlop = 10;
  // Свайп в PPTX — та же дискретная команда, что и тап: порог выше tapSlop,
  // чтобы обычное дрожание пальца при тапе не листало слайды.
  const swipeSlop = 24;
  const tapTimeout = 500;
  const isInteractive = (target) => target instanceof Element
    && !!target.closest('a, button, input, textarea, select, [contenteditable="true"]');

  viewport.addEventListener('pointerdown', (event) => {
    if (!state.ready || state.disposed) return;
    activePointers.add(event.pointerId);
    // Проверка кнопки — только для мыши: тач/перо в касании сообщают
    // button 0 и всегда должны вооружать кандидата на тап/свайп.
    if (activePointers.size !== 1 || !event.isPrimary
        || (event.pointerType === 'mouse' && event.button !== 0)) {
      // Второй палец отменяет кандидата на тап/свайп: навигация жестами
      // работает только строго одним пальцем. Щипок (zoom) при этом живёт
      // своей жизнью на нативном WebView-зуме и навигацию не вызывает.
      if (state.pointer) {
        state.pointer.moved = true;
        state.pointer.multitouch = true;
      }
      return;
    }
    state.pointer = {
      id: event.pointerId, x: event.clientX, y: event.clientY,
      startedAt: event.timeStamp, moved: false,
      multitouch: false,
      scale: window.visualViewport?.scale || 1,
      interactive: isInteractive(event.target),
      selectionActive: window.getSelection()?.isCollapsed === false,
      scroll: format === 'pptx' ? viewport.scrollLeft : viewport.scrollTop,
    };
  }, { passive: true });
  // Listen on window so a release/cancellation outside the viewport also
  // clears the sequence. Never let a drag that returns to its origin be a tap.
  window.addEventListener('pointermove', (event) => {
    const pointer = state.pointer;
    if (pointer?.id === event.pointerId
        && Math.hypot(event.clientX - pointer.x, event.clientY - pointer.y) > tapSlop) {
      pointer.moved = true;
    }
  }, { passive: true });
  window.addEventListener('pointercancel', (event) => {
    activePointers.delete(event.pointerId);
    if (state.pointer?.id === event.pointerId) state.pointer = null;
  }, { passive: true });
  window.addEventListener('pointerup', (event) => {
    activePointers.delete(event.pointerId);
    const pointer = state.pointer;
    if (!pointer || pointer.id !== event.pointerId) return;
    state.pointer = null;
    // Мультитач-жест или щипок (изменение масштаба за время касания)
    // навигацию не вызывает: ни тап, ни свайп. Одиночный палец после
    // чужого мультитача тоже молчит — кандидат создаётся только одним.
    const scale = window.visualViewport?.scale || 1;
    if (state.disposed || !state.ready || activePointers.size
        || pointer.interactive || pointer.selectionActive || isInteractive(event.target)
        || pointer.multitouch || Math.abs(scale - (pointer.scale || 1)) > 0.001
        || window.getSelection()?.isCollapsed === false) return;
    const bounds = viewport.getBoundingClientRect();
    const x = event.clientX - bounds.left, y = event.clientY - bounds.top;
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return;
    const dx = event.clientX - pointer.x, dy = event.clientY - pointer.y;
    if (format === 'pptx') {
      // Свайп делает то же самое, что тап по краю, и тем же способом:
      // никакой свободной прокрутки, влево — вперёд, вправо — назад.
      // На увеличенном слайде палец панорамирует содержимое нативно,
      // поэтому жесты навигации там не срабатывают.
      if (!zoomed() && Math.abs(dx) > swipeSlop && Math.abs(dx) >= Math.abs(dy)) {
        if (dx < 0) goToPosition(state.position + 1);
        else goToPosition(state.position - 1);
        return;
      }
      if (pointer.moved
          || event.timeStamp - pointer.startedAt > tapTimeout
          || Math.hypot(dx, dy) > tapSlop) return;
      if (x < viewport.clientWidth * 0.24) goToPosition(state.position - 1);
      else if (x > viewport.clientWidth * 0.76) goToPosition(state.position + 1);
      else post('tap');
    } else {
      if (pointer.moved
          || event.timeStamp - pointer.startedAt > tapTimeout
          || Math.hypot(dx, dy) > tapSlop) return;
      post('tap');
    }
  }, { passive: true });
  window.addEventListener('resize', () => {
    if (state.resizeFrame || !state.ready || state.disposed) return;
    motion.reset();
    const position = state.position;
    if (state.pointer) state.pointer.moved = true;
    state.resizeFrame = requestAnimationFrame(() => {
      state.resizeFrame = 0;
      // Preserve the page-relative reading offset while Word's fit scale
      // changes. Slide resize preserves the slide index, not stale pixels.
      const page = format === 'docx' ? state.pages[position] : null;
      const before = page?.getBoundingClientRect();
      const viewportTop = viewport.getBoundingClientRect().top;
      const fraction = before?.height > 0 ? (viewportTop - before.top) / before.height : 0;
      layoutSlides();
      if (format === 'docx') {
        window.FolioDocx.fit(documentRoot, viewport);
        if (page && before?.height > 0) {
          const after = page.getBoundingClientRect();
          viewport.scrollTo({ top: viewport.scrollTop + after.top - viewportTop
            + fraction * after.height, behavior: 'instant' });
        }
      } else {
        goToPosition(position, false);
      }
      // A layout correction is not a user's reading gesture.
      state.lastScroll = format === 'pptx' ? viewport.scrollLeft : viewport.scrollTop;
      refreshGeometry(); publishPosition(true);
    });
  });
  window.addEventListener('pagehide', () => {
    state.disposed = true;
    motion.dispose(); selection.dispose();
    state.pointer = null; activePointers.clear();
    cancelAnimationFrame(state.scrollFrame); cancelAnimationFrame(state.resizeFrame);
    state.searchRevision++;
    for (const url of ownedUrls) revokeObjectURL(url);
    ownedUrls.clear();
    URL.createObjectURL = createObjectURL; URL.revokeObjectURL = revokeObjectURL;
  }, { once: true });

  Promise.resolve()
    .then(() => {
      if (format === 'docx') return renderDocx();
      if (format === 'pptx') return renderPptx();
      throw new Error('Unsupported Office document format.');
    })
    .catch((error) => fail(error?.message || 'The document could not be rendered.', true));
})();
