(() => {
  'use strict';

  // Safety net: if the boot sequence dies synchronously (e.g. a helper
  // script failed to parse, so motion/selection factories are undefined),
  // neither ready nor error is ever posted and the reader spins on
  // "Opening document..." forever. Report once via the native bridge.
  // Resource load failures (fonts, images) target their element, not the
  // window, so they never trip this — only uncaught script errors do.
  // Ignored after ready: a working document must not be torn down by a
  // later unrelated exception.
  window.FolioOfficeReady = false;
  window.addEventListener('error', (event) => {
    try {
      if (window.FolioOfficeReady) return;
      if (event && event.target !== window) return;
      if (window.FolioBridge && typeof window.FolioBridge.postMessage === 'function') {
        window.FolioBridge.postMessage(JSON.stringify({
          type: 'error',
          message: 'The document could not be rendered.',
          recoverable: true,
        }));
        window.FolioOfficeReady = true;
      }
    } catch (_) {}
  });

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
    pageBounds: [],
    disposed: false,
    resizeFrame: 0,
  };

  const motion = window.FolioReaderMotion.create({
    viewport, content: documentRoot, horizontal: format === 'pptx',
    canStart: () => state.ready && !state.disposed,
    cancelTap: () => { if (state.pointer) state.pointer.moved = true; },
  });
  const selection = window.FolioReaderSelection.create({
    viewport, content: documentRoot, post, format, cancelMotion: () => motion.reset(),
    visiblePages: visiblePageElements,
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

  function visiblePageElements() {
    if (format === 'pptx') return state.pages[state.position] ? [state.pages[state.position]] : [];
    const top = viewport.scrollTop, bottom = top + viewport.clientHeight;
    let lo = 0, hi = state.pageBounds.length;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (state.pageBounds[mid].bottom < top) lo = mid + 1;
      else hi = mid;
    }
    const first = lo;
    while (lo < state.pageBounds.length && state.pageBounds[lo].top <= bottom) lo++;
    return state.pages.slice(first, lo);
  }

  function refreshGeometry() {
    state.pages = Array.from(documentRoot.querySelectorAll(format === 'docx'
      ? '.docx-wrapper > section.docx' : '.folio-slide-frame'));
    if (format !== 'docx') return;
    const rect = viewport.getBoundingClientRect();
    // One read batch after layout. The scroll path never measures every page.
    state.pageBounds = state.pages.map((page) => {
      const r = page.getBoundingClientRect();
      const top = r.top - rect.top + viewport.scrollTop;
      return { top, bottom: top + r.height };
    });
    state.centers = state.pageBounds.map((bounds) => (bounds.top + bounds.bottom) / 2);
  }

  // Word derives its position from the scroll offset. PowerPoint never
  // scrolls: exactly one slide frame is displayed and the position is
  // explicit state, swapped by showSlide().
  function publishPosition(force = false) {
    if (format !== 'docx' || !state.pages.length || state.disposed) return;
    const center = viewport.scrollTop + viewport.clientHeight / 2;
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

  // PowerPoint navigation without any scrolling: the target slide frame is
  // displayed, the previous one is hidden. The swap is instant by nature —
  // no scroll offset, no animation, nothing to snap, fling or clamp.
  function showSlide(index) {
    const pages = state.pages;
    if (!pages.length || state.disposed) return;
    const next = Math.max(0, Math.min(Math.trunc(Number(index) || 0), pages.length - 1));
    const target = pages[next];
    const previous = pages[state.position];
    if (previous && previous !== target) previous.classList.remove('is-active');
    target.classList.add('is-active');
    state.position = next;
    state.count = pages.length;
    if (overview.built) syncOverviewActive();
    post('position', { current: next + 1, count: pages.length });
  }

  // Обзор слайдов (свайп вверх): лента миниатюр у нижнего края, прокручивается
  // по горизонтали и живёт внутри WebView, чтобы карточки были точными клонами
  // настоящих слайдов. Раскрытие следует за пальцем, у краёв скролла —
  // резиновый отскок.
  const overview = {
    root: null, grid: null, track: null, cards: [],
    built: false, open: false, closeTimer: 0,
    observer: null, drag: null, motion: null,
  };
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const overviewDragSlop = 12;
  const overviewOpenVelocity = 600;
  // Зазор за нижним краем в закрытом состоянии ленты. Должен совпадать с
  // translateY(calc(100% + 28px)) в office.css — иначе первые кадры drag'а
  // дёрнутся. 12px нижнего отступа + запас на тень ленты.
  const overviewTravelGap = 28;

  function ensureOverview() {
    if (overview.built || format !== 'pptx' || state.disposed) return;
    const layer = document.createElement('div');
    layer.id = 'folio-overview';
    layer.hidden = true;
    const grid = document.createElement('div');
    grid.className = 'folio-overview-grid';
    const track = document.createElement('div');
    track.className = 'folio-overview-track';
    overview.cards = state.pages.map((page, index) => {
      const slide = page.querySelector(':scope > .slide');
      // Авторский размер кадра до вписывания: карточки масштабируются от него.
      const width = slide ? numericStyle(slide, 'width', 960) : 960;
      const height = slide ? numericStyle(slide, 'height', 540) : 540;
      const card = document.createElement('button');
      card.type = 'button';
      card.className = 'folio-overview-card';
      card.setAttribute('aria-label', `Slide ${index + 1}`);
      const sheet = document.createElement('div');
      sheet.className = 'folio-overview-sheet';
      sheet.style.aspectRatio = `${width} / ${height}`;
      if (slide) {
        const clone = slide.cloneNode(true);
        // Клон — навигационная миниатюра: ссылки убираются, чтобы тап по ним
        // доходил до карточки (общий обработчик гасит клики по <a>), а пометки
        // поиска не замирали в карточках навсегда.
        clone.querySelectorAll('a').forEach((anchor) => {
          anchor.replaceWith(...anchor.childNodes);
        });
        clone.querySelectorAll('mark[data-folio-search]').forEach((mark) => {
          mark.replaceWith(...mark.childNodes);
        });
        clone.style.left = '0px';
        clone.style.top = '0px';
        clone.style.boxShadow = 'none';
        sheet.appendChild(clone);
      }
      const label = document.createElement('span');
      label.className = 'folio-overview-index';
      label.textContent = String(index + 1);
      sheet.appendChild(label);
      card.append(sheet);
      card.addEventListener('click', () => {
        if (!overview.open || state.disposed) return;
        // Лента остаётся открытой: по ней можно щёлкать слайд за слайдом.
        showSlide(index);
      });
      track.appendChild(card);
      return { card, sheet, clone: sheet.firstElementChild, height };
    });
    grid.appendChild(track);
    layer.append(grid);
    document.body.appendChild(layer);
    overview.root = layer;
    overview.grid = grid;
    overview.track = track;
    overview.built = true;
    // Скролл, резинка и флинт ленты — общий модуль физики читалки: нативный
    // скроллер выключен (touch-action: none), инерция непрерывно переходит
    // в резинку у краёв без детекции прибытия.
    overview.motion = window.FolioReaderMotion.create({
      viewport: grid,
      content: track,
      horizontal: true,
      ownsScroll: true,
      maxOverscroll: 72,
      canStart: () => overview.open && state.ready && !state.disposed,
      cancelTap: () => {},
    });
    bindOverviewDismissal();
    // Реагируем на смену размеров вьюпорта. Измерение переносится на следующий
    // кадр: первое уведомление наблюдателя может прийти раньше, чем раскладка
    // ленты устоится.
    overview.observer = new ResizeObserver(() => requestAnimationFrame(layoutOverview));
    overview.observer.observe(grid);
  }

  function layoutOverview() {
    if (!overview.built || !overview.cards.length) return;
    const boxHeight = overview.cards[0].sheet.clientHeight;
    if (boxHeight <= 0) return;
    for (const item of overview.cards) {
      if (item.clone) item.clone.style.transform = `scale(${boxHeight / item.height})`;
    }
  }

  function syncOverviewActive() {
    overview.cards.forEach((item, index) => {
      item.card.classList.toggle('is-active', index === state.position);
    });
    if (!overview.open) return;
    // Лента следует за позицией: активная карточка держится по центру.
    overview.cards[state.position]?.card.scrollIntoView({
      inline: 'center',
      block: 'nearest',
      behavior: reducedMotion.matches ? 'instant' : 'smooth',
    });
  }

  function openOverview() {
    if (overview.open || overview.drag || !state.ready || state.disposed) return;
    selection.clear(); // Поиск/выделение не должны жить под лентой обзора.
    ensureOverview();
    syncOverviewActive();
    const layer = overview.root;
    clearTimeout(overview.closeTimer);
    overview.closeTimer = 0;
    layer.hidden = false;
    // Инлайновые transform/opacity могли остаться от незавершённого закрытия
    // (settle-close держит их до таймера) — они перебили бы .is-open.
    layer.style.transform = '';
    layer.style.opacity = '';
    layer.style.pointerEvents = '';
    // Прыжок к текущему слайду до появления ленты, чтобы не было видно скролла.
    const active = overview.cards[state.position]?.card;
    if (active) {
      active.scrollIntoView({ inline: 'center', block: 'nearest', behavior: 'instant' });
    }
    requestAnimationFrame(() => {
      if (overview.open) layer.classList.add('is-open');
      layoutOverview();
    });
    overview.open = true;
    post('overview', { open: true });
  }

  function closeOverview() {
    if (!overview.open || state.disposed) return;
    const layer = overview.root;
    overview.open = false;
    layer.style.pointerEvents = 'none';
    layer.classList.remove('is-open');
    post('overview', { open: false });
    clearTimeout(overview.closeTimer);
    if (reducedMotion.matches) {
      overview.closeTimer = 0;
      layer.hidden = true;
      return;
    }
    overview.closeTimer = setTimeout(() => {
      overview.closeTimer = 0;
      if (overview.open || overview.drag || state.disposed) return;
      layer.hidden = true;
    }, 320);
  }

  // Живое раскрытие: лента следует за пальцем вверх один к одному (после
  // небольшого slop), решение открыть/закрыть принимается на подъёме по
  // прогрессу и скорости жеста.
  function startOverviewDrag(pointer, event) {
    if (overview.drag || overview.open || state.disposed || !state.ready) return;
    selection.clear(); // Выделение не должно жить под лентой.
    ensureOverview();
    syncOverviewActive();
    const layer = overview.root;
    clearTimeout(overview.closeTimer);
    overview.closeTimer = 0;
    layer.hidden = false;
    layer.style.pointerEvents = 'none';
    layer.style.transition = 'none';
    // Центрируем активную карточку, пока лента ещё за краем экрана.
    const active = overview.cards[state.position]?.card;
    if (active) {
      active.scrollIntoView({ inline: 'center', block: 'nearest', behavior: 'instant' });
    }
    layoutOverview();
    pointer.overviewDragged = true;
    pointer.moved = true;
    overview.drag = {
      startY: event.clientY,
      lastY: event.clientY,
      lastT: event.timeStamp,
      velocity: 0,
      progress: 0,
      travel: layer.offsetHeight + overviewTravelGap,
    };
    paintOverviewDrag(0);
    post('overview', { open: true });
  }

  function paintOverviewDrag(progress) {
    const drag = overview.drag;
    drag.progress = progress;
    overview.root.style.transform = `translateY(${(1 - progress) * drag.travel}px)`;
    overview.root.style.opacity = String(progress);
  }

  function updateOverviewDrag(clientY, timeStamp) {
    const drag = overview.drag;
    if (!drag) return;
    const dt = Math.min(80, Math.max(1, timeStamp - drag.lastT));
    drag.velocity = drag.velocity * 0.35 + (((drag.lastY - clientY) / dt) * 1000) * 0.65;
    drag.lastY = clientY;
    drag.lastT = timeStamp;
    paintOverviewDrag(Math.max(0, Math.min(1, (drag.startY - clientY) / drag.travel)));
  }

  function settleOverviewDrag(canceled) {
    const drag = overview.drag;
    if (!drag) return;
    overview.drag = null;
    const layer = overview.root;
    layer.style.transition = '';
    const open = !canceled
      && (drag.progress > 0.45 || drag.velocity > overviewOpenVelocity);
    if (open) {
      layer.style.pointerEvents = '';
      layer.style.transform = '';
      layer.style.opacity = '';
      layer.classList.add('is-open');
      overview.open = true;
      syncOverviewActive();
    } else {
      layer.style.pointerEvents = 'none';
      layer.style.transform = `translateY(${drag.travel}px)`;
      layer.style.opacity = '0';
      overview.closeTimer = setTimeout(() => {
        overview.closeTimer = 0;
        if (overview.open || overview.drag || state.disposed) return;
        layer.hidden = true;
        layer.style.transform = '';
        layer.style.opacity = '';
      }, 320);
    }
    // Открытие уже опубликовано на старте drag'а — наверх уходит только
    // фактическая смена состояния.
    if (!open) post('overview', { open: false });
  }

  // Свайп вниз по ленте закрывает выбор. Горизонтальный скролл, резинка у
  // краёв и флинт целиком живут в reader-motion (touch-action: none), поэтому
  // из собственных жестов ленты остался только dismissal.
  function bindOverviewDismissal() {
    let startX = 0, startY = 0, tracking = false;
    overview.grid.addEventListener('touchstart', (event) => {
      tracking = event.touches.length === 1;
      if (!tracking) return;
      startX = event.touches[0].clientX;
      startY = event.touches[0].clientY;
    }, { passive: true });
    overview.grid.addEventListener('touchmove', (event) => {
      if (!tracking || event.touches.length !== 1) return;
      const dy = event.touches[0].clientY - startY;
      const dx = event.touches[0].clientX - startX;
      if (dy > 36 && Math.abs(dy) > Math.abs(dx)) {
        tracking = false;
        closeOverview();
      }
    }, { passive: true });
    overview.grid.addEventListener('touchcancel', () => { tracking = false; }, { passive: true });
  }

  function zoomed() {
    return (window.visualViewport?.scale || 1) > 1.01;
  }

  function onScroll() {
    // PowerPoint has no scrollable viewport at all; this is Word's pager.
    if (format !== 'docx' || state.scrollFrame || state.disposed) return;
    state.scrollFrame = requestAnimationFrame(() => {
      state.scrollFrame = 0;
      const current = viewport.scrollTop;
      const delta = current - state.lastScroll;
      state.lastScroll = current;
      if (state.pointer && Math.abs(current - state.pointer.scroll) > 1) {
        state.pointer.moved = true;
      }
      if (!selection.isActive() && !motion.isAnimating
          && Math.abs(delta) > 0.5) post('scroll', { delta });
      publishPosition(false);
    });
  }

  function wrapSlides() {
    documentRoot.querySelectorAll('img').forEach((image) => { image.draggable = false; });
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
    // per-frame: hidden frames have no layout, so their slides are scaled
    // from inline sizes only (numericStyle reads element.style first).
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
    window.FolioOfficeReady = true;
    status.hidden = true;
    if (format === 'pptx') showSlide(0);
    else publishPosition(true);
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
    if (format === 'pptx') {
      // Показать слайд с попаданием — мгновенный обмен кадров, без прокрутки.
      const index = state.pages.indexOf(hit.closest('.folio-slide-frame'));
      if (index >= 0) showSlide(index);
      return;
    }
    hit.scrollIntoView({ behavior: smooth ? 'smooth' : 'instant', block: 'center' });
    window.setTimeout(() => publishPosition(true), smooth ? 260 : 0);
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
    // PowerPoint: смена слайда — мгновенная замена кадра, без прокрутки.
    if (format === 'pptx') {
      showSlide(index);
      return;
    }
    const pages = pageElements();
    const target = pages[Math.max(0, Math.min(Math.trunc(Number(index) || 0), pages.length - 1))];
    if (!target) return;
    target.scrollIntoView({
      behavior: smooth ? 'smooth' : 'instant',
      block: 'start',
      inline: 'nearest',
    });
  }

  window.FolioOffice = {
    search,
    nextHit: () => stepHit(1),
    previousHit: () => stepHit(-1),
    goToPosition,
    closeOverview,
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
    // Пока открыта лента обзора, навигация читалки не вооружается: касание
    // документа закрывает ленту (см. pointerup), сама лента живёт своими
    // жестами.
    if (overview.open) return;
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
      selectionActive: selection.isActive(),
      scroll: viewport.scrollTop,
    };
  }, { passive: true });
  // Listen on window so a release/cancellation outside the viewport also
  // clears the sequence. Never let a drag that returns to its origin be a tap.
  window.addEventListener('pointermove', (event) => {
    const pointer = state.pointer;
    if (!pointer || pointer.id !== event.pointerId) return;
    const dx = event.clientX - pointer.x;
    const dy = event.clientY - pointer.y;
    if (Math.hypot(dx, dy) > tapSlop) pointer.moved = true;
    if (pointer.overviewDragged) {
      updateOverviewDrag(event.clientY, event.timeStamp);
      return;
    }
    // Живое раскрытие ленты: строго вертикальный жест вверх одним пальцем,
    // на незумированном слайде без выделения и интерактивных целей.
    if (format === 'pptx' && !overview.open && !pointer.multitouch
        && !pointer.interactive && !pointer.selectionActive && !zoomed()
        && dy < -overviewDragSlop && -dy > Math.abs(dx)) {
      startOverviewDrag(pointer, event);
    }
  }, { passive: true });
  window.addEventListener('pointercancel', (event) => {
    activePointers.delete(event.pointerId);
    if (state.pointer?.id === event.pointerId) {
      if (overview.drag) settleOverviewDrag(true);
      state.pointer = null;
    }
  }, { passive: true });
  window.addEventListener('pointerup', (event) => {
    activePointers.delete(event.pointerId);
    if (overview.drag) {
      // Второй палец (щипок) отменяет раскрытие, если pointercancel не пришёл.
      settleOverviewDrag(state.pointer?.multitouch === true);
      state.pointer = null;
      return;
    }
    if (overview.open) {
      // Касание документа при открытой ленте закрывает выбор; касания самой
      // ленты обслуживают её карточки и свайп-дисмисс. У тач-указателей цель
      // событий остаётся элементом нажатия, поэтому лента различима по target.
      if (event.target instanceof Element
          && !event.target.closest('#folio-overview')) {
        closeOverview();
      }
      return;
    }
    const pointer = state.pointer;
    if (!pointer || pointer.id !== event.pointerId) return;
    state.pointer = null;
    // Мультитач-жест или щипок (изменение масштаба за время касания)
    // навигацию не вызывает: ни тап, ни свайп. Одиночный палец после
    // чужого мультитача тоже молчит — кандидат создаётся только одним.
    const scale = window.visualViewport?.scale || 1;
    if (state.disposed || !state.ready || activePointers.size
        || pointer.interactive || isInteractive(event.target)
        || pointer.multitouch || Math.abs(scale - (pointer.scale || 1)) > 0.001
        ) return;
    const bounds = viewport.getBoundingClientRect();
    const x = event.clientX - bounds.left, y = event.clientY - bounds.top;
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return;
    const dx = event.clientX - pointer.x, dy = event.clientY - pointer.y;
    if (pointer.selectionActive) {
      if (!pointer.moved && event.timeStamp - pointer.startedAt <= tapTimeout
          && Math.hypot(dx, dy) <= tapSlop && !selection.hitText(event.clientX, event.clientY)) selection.clear();
      return; // The touch that dismisses selection never also navigates the reader.
    }
    if (selection.isActive()) return;
    if (format === 'pptx') {
      // На увеличенном слайде навигация полностью заблокирована: палец
      // панорамирует содержимое нативно, и ни свайп, ни тап по краю не
      // меняют слайд. Доступен только неподвижный тап (хром читалки).
      if (!zoomed()) {
        // Вертикальный свайп — отдельный жест: вверх открывает обзор слайдов,
        // вниз ничего не делает. Он всегда съедается, чтобы диагональ не
        // листала слайды.
        if (Math.abs(dy) > swipeSlop && Math.abs(dy) > Math.abs(dx)) {
          if (dy < 0) openOverview();
          return;
        }
        // Свайп делает то же самое, что тап по краю, и тем же способом:
        // влево — вперёд, вправо — назад; слайд просто заменяется другим.
        if (Math.abs(dx) > swipeSlop && Math.abs(dx) >= Math.abs(dy)) {
          goToPosition(state.position + (dx < 0 ? 1 : -1));
          return;
        }
        if (pointer.moved
            || event.timeStamp - pointer.startedAt > tapTimeout
            || Math.hypot(dx, dy) > tapSlop) return;
        if (x < viewport.clientWidth * 0.24) {
          goToPosition(state.position - 1);
        } else if (x > viewport.clientWidth * 0.76) {
          goToPosition(state.position + 1);
        } else post('tap');
      } else {
        if (pointer.moved
            || event.timeStamp - pointer.startedAt > tapTimeout
            || Math.hypot(dx, dy) > tapSlop) return;
        post('tap');
      }
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
      if (format === 'pptx') {
        // Slide resize preserves the slide index, not stale pixels: re-fit
        // the visible slide and re-assert the same position.
        layoutSlides();
        showSlide(position);
        return;
      }
      // Preserve the page-relative reading offset while Word's fit scale
      // changes.
      const page = state.pages[position];
      const before = page?.getBoundingClientRect();
      const viewportTop = viewport.getBoundingClientRect().top;
      const fraction = before?.height > 0 ? (viewportTop - before.top) / before.height : 0;
      window.FolioDocx.fit(documentRoot, viewport);
      if (page && before?.height > 0) {
        const after = page.getBoundingClientRect();
        viewport.scrollTo({ top: viewport.scrollTop + after.top - viewportTop
          + fraction * after.height, behavior: 'instant' });
      }
      // A layout correction is not a user's reading gesture.
      state.lastScroll = viewport.scrollTop;
      refreshGeometry(); publishPosition(true);
    });
  });
  window.addEventListener('pagehide', () => {
    state.disposed = true;
    motion.dispose(); selection.dispose();
    overview.open = false;
    overview.drag = null;
    overview.observer?.disconnect();
    clearTimeout(overview.closeTimer);
    overview.motion?.dispose();
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
