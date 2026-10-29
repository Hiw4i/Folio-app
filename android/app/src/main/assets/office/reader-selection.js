/* Browser ranges, owned Office handles and a Flutter-owned toolbar. Only
   normalized geometry crosses the bridge; selected text is read on Copy. */
(() => {
  'use strict';
  const EDGE_SCROLL_POLICY = Object.freeze({
    zone: 72, minimumSpeed: 280, maximumSpeed: 1000,
    dwellSeconds: .9, rampSeconds: 1.5, maximumExtraSpeed: .6, maximumFrameSeconds: .05,
  });
  const SELECTION_VISUALS = Object.freeze({ docxCornerRadius: 2, pptxCornerRadius: 4, highlightRefreshMs: 64 });
  const SELECTION_GESTURES = Object.freeze({ hapticIntervalMs: 40 });
  const meaningfulText = (text) => /[^\s\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/u.test(text);
  function create({ viewport, content, post, cancelMotion, visiblePages, format }) {
    let disposed = false, frame = 0, settleTimer = 0, lastMessage = JSON.stringify({ active: false });
    let scrolling = false, changing = false, selectionTimer = 0;
    let geometry = { x: 0.5, top: 0.2, bottom: 0.25 };
    let visibleSelectionRects = [];
    const highlight = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    const highlightPath = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    const nativeRangeRects = Range.prototype.getClientRects;
    highlight.id = 'folio-selection-highlight';
    highlight.setAttribute('aria-hidden', 'true');
    highlight.appendChild(highlightPath);
    content.appendChild(highlight);
    const ownedHandles = format === 'docx' || format === 'pptx';
    const textOnly = format === 'pptx';
    const handles = [];
    let drag = null, edgeFrame = 0, edgeLast = null, edgeHeld = 0, edgeDirection = 0, edgePosition = 0;
    let textNodes = new WeakMap(), cachedRange = null, observedRange = null, cachedHasText = false, highlightTime = 0;
    let blockColumns = new WeakMap();
    let lastHapticTime = -Infinity;
    const selection = () => window.getSelection();
    const selectable = (node) => node?.nodeType === Node.TEXT_NODE && node.length > 0
      && !node.parentElement?.closest('style,script,svg')
      && (!textOnly || meaningfulText(node.parentElement?.closest('.text-block')?.textContent || ''));
    function markEmptyTextShapes() {
      if (!textOnly) return;
      for (const block of content.querySelectorAll('.text-block')) {
        block.toggleAttribute('data-folio-empty-text', !meaningfulText(block.textContent));
      }
    }
    function nodesFor(page) {
      let nodes = textNodes.get(page);
      if (!nodes) {
        nodes = [];
        const walker = document.createTreeWalker(page, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (selectable(node)) nodes.push(node);
        }
        textNodes.set(page, nodes);
      }
      return nodes;
    }
    const observer = new MutationObserver((records) => {
      if (!records.some((record) => record.target !== highlight
          && record.target !== highlightPath)) return;
      textNodes = new WeakMap(); cachedRange = null;
      blockColumns = new WeakMap();
      markEmptyTextShapes();
    });
    observer.observe(content, { childList: true, characterData: true, subtree: true });
    function isActive() {
      const value = selection();
      if (!value || value.isCollapsed || !value.rangeCount
          || !content.contains(value.anchorNode) || !content.contains(value.focusNode)) return false;
      const range = value.getRangeAt(0);
      if (cachedRange?.startContainer === range.startContainer
          && cachedRange.startOffset === range.startOffset
          && cachedRange.endContainer === range.endContainer
          && cachedRange.endOffset === range.endOffset) return cachedHasText;
      cachedRange = range.cloneRange();
      cachedHasText = false;
      // Handle drags normally end within a text node. Inspect its selected
      // slice before consulting the document index on multi-node boundaries.
      for (const node of [range.startContainer, range.endContainer]) {
        if (!selectable(node)) continue;
        const start = node === range.startContainer ? range.startOffset : 0;
        const end = node === range.endContainer ? range.endOffset : node.length;
        if (meaningfulText(node.data.slice(start, end))) { cachedHasText = true; return true; }
      }
      for (const node of nodesFor(content)) {
        const start = node === range.startContainer ? range.startOffset : 0;
        const end = node === range.endContainer ? range.endOffset : node.length;
        if (range.intersectsNode(node) && meaningfulText(node.data.slice(start, end))) {
          cachedHasText = true; break;
        }
      }
      return cachedHasText;
    }
    function endpoint(node, offset, end) {
      const range = document.createRange();
      range.setStart(node, offset); range.collapse(true);
      let rect = range.getBoundingClientRect();
      // Some WebViews return an empty rectangle for a collapsed range. Measure
      // one adjacent character, never all glyphs in a multi-page selection.
      if (!rect.height && node.nodeType === Node.TEXT_NODE && node.length) {
        const index = Math.min(Math.max(0, offset - (end ? 1 : 0)), node.length - 1);
        range.setStart(node, index); range.setEnd(node, index + 1);
        rect = range.getBoundingClientRect();
      }
      return rect;
    }
    function outline(rects) {
      const rows = [];
      for (const box of rects.sort((a, b) => (a.top + a.bottom - b.top - b.bottom) || a.left - b.left)) {
        const center = (box.top + box.bottom) / 2, height = box.bottom - box.top;
        let found = null;
        for (let i = rows.length - 1; i >= 0; i--) {
          const row = rows[i];
          // A list marker hangs a word-space into the indent (an 8 px gap at a
          // 26.9 px line in the markdown reader), so same-line fragments are
          // joined across half their height. Fragments of one block — or of
          // one column inside a multi-column block — join across any gap:
          // justified Word lines stretch word spacing far past that allowance.
          // Other blocks (table cells, columns) stay on this geometric rule.
          const allowance = Math.max(2, Math.min(row.bottom - row.top, height) * .5);
          if (Math.abs((row.top + row.bottom) / 2 - center)
              <= Math.min(row.bottom - row.top, height) * .35
              && (box.block && row.blocks.includes(box.block)
                  || box.left <= row.right + allowance
                  && box.right >= row.left - allowance)) {
            found = row; break;
          }
        }
        if (found) {
          found.left = Math.min(found.left, box.left);
          found.top = Math.min(found.top, box.top);
          found.right = Math.max(found.right, box.right);
          found.bottom = Math.max(found.bottom, box.bottom);
          if (box.block && !found.blocks.includes(box.block)) found.blocks.push(box.block);
        } else rows.push({ ...box, blocks: box.block ? [box.block] : [] });
      }
      rows.sort((a, b) => (a.top + a.bottom - b.top - b.bottom) || a.left - b.left);
      const groups = [];
      for (const row of rows) {
        let owner = null;
        for (let i = groups.length - 1; i >= 0; i--) {
          const previous = groups[i].at(-1);
          const previousHeight = previous.bottom - previous.top;
          const rowHeight = row.bottom - row.top;
          const gap = row.top - previous.bottom;
          // Compare the gap with the mean row height, not the shorter row: a
          // heading is several times taller than a body line, and measuring by
          // the body alone orphaned every heading from the paragraph below it.
          if (gap >= -Math.min(previousHeight, rowHeight) * .35
              && gap <= (previousHeight + rowHeight) / 2 * .65
              && row.left < previous.right && row.right > previous.left) {
            owner = groups[i]; break;
          }
        }
        if (owner) owner.push(row); else groups.push([row]);
      }
      const fmt = (value) => Number(value.toFixed(2));
      let result = '';
      for (const group of groups) {
        const first = group[0], last = group.at(-1);
        const points = [[first.left, first.top], [first.right, first.top]];
        for (let i = 1; i < group.length; i++) {
          const upper = group[i - 1], lower = group[i];
          const seam = (upper.bottom + lower.top) / 2;
          points.push([upper.right, seam], [lower.right, seam]);
        }
        points.push([last.right, last.bottom], [last.left, last.bottom]);
        for (let i = group.length - 1; i > 0; i--) {
          const lower = group[i], upper = group[i - 1];
          const seam = (upper.bottom + lower.top) / 2;
          points.push([lower.left, seam], [upper.left, seam]);
        }
        const corners = [];
        for (let i = 0; i < points.length; i++) {
          const before = points[(i - 1 + points.length) % points.length];
          const p = points[i], after = points[(i + 1) % points.length];
          const dx1 = p[0] - before[0], dy1 = p[1] - before[1];
          const dx2 = after[0] - p[0], dy2 = after[1] - p[1];
          const a = Math.hypot(dx1, dy1), b = Math.hypot(dx2, dy2);
          if (!a || !b) continue;
          const radius = Math.min(format === 'docx' ? SELECTION_VISUALS.docxCornerRadius
            : SELECTION_VISUALS.pptxCornerRadius, a / 2, b / 2);
          corners.push({ before: [p[0] - dx1 / a * radius, p[1] - dy1 / a * radius],
            vertex: p, after: [p[0] + dx2 / b * radius, p[1] + dy2 / b * radius] });
        }
        if (!corners.length) continue;
        result += `M${fmt(corners[0].before[0])},${fmt(corners[0].before[1])}`;
        corners.forEach((corner, i) => {
          result += `Q${fmt(corner.vertex[0])},${fmt(corner.vertex[1])} `
            + `${fmt(corner.after[0])},${fmt(corner.after[1])}`;
          const next = corners[(i + 1) % corners.length];
          result += `L${fmt(next.before[0])},${fmt(next.before[1])}`;
        });
        result += 'Z';
      }
      return result;
    }
    // Nearest block-level container: same-line fragments of one paragraph merge
    // across any justified gap. Inside a CSS multi-column section (Word column
    // layouts stay as emitted columns) each column is its own merge group, or
    // the block rule would fill the gutter between columns.
    function blockOf(node) {
      return node.parentElement?.closest('p,.text-block,li,td,th') || null;
    }
    function columnsOf(block) {
      let columns = blockColumns.get(block);
      if (columns === undefined) {
        columns = null;
        for (let el = block.parentElement; el && el !== content; el = el.parentElement) {
          const count = parseInt(getComputedStyle(el).columnCount);
          if (count > 1) { columns = { element: el, count }; break; }
        }
        blockColumns.set(block, columns);
      }
      return columns;
    }
    function paintHighlight() {
      // The vector overlay belongs to the scrolling document. Existing glyphs
      // and highlight are composited together, without a one-frame scroll lag.
      if (highlight.parentNode !== content) content.appendChild(highlight);
      const visual = window.visualViewport;
      const width = Math.max(1, visual?.width || viewport.clientWidth);
      const height = Math.max(1, visual?.height || viewport.clientHeight);
      const left = visual?.offsetLeft || 0, top = visual?.offsetTop || 0;
      visibleSelectionRects = [];
      if (!isActive()) { highlightPath.setAttribute('d', ''); return; }
      const root = content.getBoundingClientRect();
      const documentRects = [];
      const columnBoxes = new Map(), mergeKeys = new Map();
      const selected = selection().getRangeAt(0);
      const pages = visiblePages?.() || [content];
      for (const page of pages) {
        const bounds = page.getBoundingClientRect();
        // Hidden pptx slide frames (display:none) measure 0x0: no visible
        // selection can live there, so skip the text walk entirely.
        if (bounds.width <= 0 || bounds.height <= 0
            || bounds.bottom < top || bounds.top > top + height
            || bounds.right < left || bounds.left > left + width
            || !selected.intersectsNode(page)) continue;
        for (const node of nodesFor(page)) {
          if (!node.length || !selected.intersectsNode(node)) continue;
          const start = node === selected.startContainer ? selected.startOffset : 0;
          const end = node === selected.endContainer ? selected.endOffset : node.length;
          if (end <= start || !meaningfulText(node.data.slice(start, end))) continue;
          const block = blockOf(node), columns = block ? columnsOf(block) : null;
          const fragment = document.createRange();
          fragment.setStart(node, start); fragment.setEnd(node, end);
          for (const rect of nativeRangeRects.call(fragment)) {
            if (rect.right <= left || rect.left >= left + width
                || rect.bottom <= top || rect.top >= top + height) continue;
            let key = block;
            if (block && columns) {
              let box = columnBoxes.get(columns.element);
              if (!box) {
                const bounds = columns.element.getBoundingClientRect();
                const style = getComputedStyle(columns.element);
                box = { left: bounds.left + (parseFloat(style.borderLeftWidth) || 0)
                  + (parseFloat(style.paddingLeft) || 0),
                  band: Math.max(1, (columns.element.clientWidth
                    - (parseFloat(style.paddingLeft) || 0)
                    - (parseFloat(style.paddingRight) || 0)) / columns.count) };
                columnBoxes.set(columns.element, box);
              }
              // Rect centers never sit in a gutter, so equal bands separate
              // the columns without parsing column-gap.
              const index = Math.min(columns.count - 1, Math.max(0,
                Math.floor((rect.left + rect.width / 2 - box.left) / box.band)));
              let keys = mergeKeys.get(block);
              if (!keys) { keys = new Map(); mergeKeys.set(block, keys); }
              key = keys.get(index);
              if (!key) { key = { block, column: index }; keys.set(index, key); }
            }
            visibleSelectionRects.push({ left: rect.left - left, top: rect.top - top,
              right: rect.right - left, bottom: rect.bottom - top });
            documentRects.push({ left: rect.left - root.left, top: rect.top - root.top,
              right: rect.right - root.left, bottom: rect.bottom - root.top, block: key });
          }
        }
      }
      highlightPath.setAttribute('d', outline(documentRects));
      highlightPath.setAttribute('fill', getComputedStyle(document.documentElement)
        .getPropertyValue('--folio-selection').trim() || 'rgba(95, 107, 124, 0.4)');
    }
    function publish() {
      frame = 0;
      if (disposed) return;
      // The vector moves with the document at compositor cadence, so a repaint
      // only matters for selection parts that scrolled into view. Scrolling —
      // with or without an owned drag — refreshes the visible slice at most
      // once per 64 ms; quiet frames and plain drags repaint immediately.
      const now = performance.now();
      if (!isActive() || (!scrolling && !edgeFrame)
          || ((drag || scrolling) && now - highlightTime >= SELECTION_VISUALS.highlightRefreshMs)) {
        paintHighlight(); highlightTime = now;
      }
      paintHandles();
      if (drag) {
        const visual = window.visualViewport;
        post('selectionHandle', { active: true,
          x: (drag.x - (visual?.offsetLeft || 0)) / Math.max(1, visual?.width || viewport.clientWidth),
          y: (drag.y - (visual?.offsetTop || 0)) / Math.max(1, visual?.height || viewport.clientHeight) });
      }
      let payload = { active: false };
      if (isActive()) {
        // The pill follows the selection like the PDF and text readers: it
        // stays shown while scrolling and its anchor refreshes each frame.
        // Only an owned drag or a changing range hides it.
        const showMenu = !drag && !changing;
        if (showMenu) {
          const value = selection(), range = value.getRangeAt(0);
          const first = endpoint(range.startContainer, range.startOffset, false);
          const last = endpoint(range.endContainer, range.endOffset, true);
          const visual = window.visualViewport;
          const width = Math.max(1, visual?.width || viewport.clientWidth);
          const height = Math.max(1, visual?.height || viewport.clientHeight);
          const left = visual?.offsetLeft || 0, top = visual?.offsetTop || 0;
          const visible = (r) => r.height > 0 && r.bottom > top && r.top < top + height
            && r.right >= left && r.left <= left + width;
          // Do not walk the document to find a visible character when both ends
          // are off-screen (Select all). A stable viewport anchor is sufficient.
          const anchor = visible(first) ? first : visible(last) ? last : null;
          const line = visibleSelectionRects[0];
          const x = anchor ? (anchor.left - left) / width
            : line ? (line.left + line.right) / (2 * width) : 0.5;
          const above = anchor ? (anchor.top - top) / height
            : line ? line.top / height : 0.2;
          const below = visible(last) ? (last.bottom - top) / height
            : anchor ? (anchor.bottom - top) / height
            : line ? line.bottom / height : 0.25;
          // Sub-pixel anchor churn posts a bridge message per frame; rounding
          // collapses idle jitter without a visible step.
          const snap = (value) => Number(value.toFixed(3));
          geometry = { x: snap(Math.max(0, Math.min(1, x))),
            top: snap(Math.max(0, Math.min(1, above))),
            bottom: snap(Math.max(0, Math.min(1, below))) };
        }
        payload = { active: true, showMenu, ...geometry };
      }
      const encoded = JSON.stringify(payload);
      if (encoded === lastMessage) return;
      lastMessage = encoded; post('selection', payload);
    }
    function schedule() {
      if (!disposed && !frame) frame = requestAnimationFrame(publish);
    }
    function changed() {
      const active = isActive(), range = active ? selection().getRangeAt(0) : null;
      const same = range && observedRange
        && range.startContainer === observedRange.startContainer && range.startOffset === observedRange.startOffset
        && range.endContainer === observedRange.endContainer && range.endOffset === observedRange.endOffset;
      if (!active) endDrag();
      if (same || (!range && !observedRange)) { schedule(); return; }
      observedRange = range?.cloneRange() || null;
      clearTimeout(selectionTimer);
      changing = active;
      if (changing) {
        cancelMotion();
        selectionTimer = setTimeout(() => { changing = false; schedule(); }, 120);
      }
      schedule();
    }
    function onScroll() {
      if (!isActive()) return;
      scrolling = true; schedule(); clearTimeout(settleTimer);
      settleTimer = setTimeout(() => { scrolling = false; schedule(); }, 100);
    }
    function paintHandles() {
      if (!ownedHandles) return;
      const active = isActive();
      const value = active ? selection() : null;
      const range = active ? value.getRangeAt(0) : null;
      if (drag && range) {
        const focusAtStart = value.focusNode === range.startContainer && value.focusOffset === range.startOffset;
        for (const handle of handles) {
          const start = handle === drag.handle ? focusAtStart : !focusAtStart;
          handle.dataset.folioSelectionHandle = start ? 'start' : 'end';
        }
      }
      if (scrolling || edgeFrame) {
        for (const handle of handles) {
          handle.hidden = handle !== drag?.handle;
          if (handle === drag?.handle) {
            handle.style.left = `${drag.x - 22}px`; handle.style.top = `${drag.y - 10}px`;
          }
        }
        return;
      }
      for (const handle of handles) {
        const start = handle.dataset.folioSelectionHandle === 'start';
        const rect = range ? endpoint(start ? range.startContainer : range.endContainer,
          start ? range.startOffset : range.endOffset, !start) : null;
        const visual = window.visualViewport;
        const top = visual?.offsetTop || 0, bottom = top + (visual?.height || viewport.clientHeight);
        handle.hidden = !active || !rect?.height || rect.bottom < top || rect.top > bottom;
        if (handle.hidden) continue;
        handle.style.left = `${(start ? rect.left : rect.right) - 22}px`;
        handle.style.top = `${rect.bottom - 10}px`;
      }
    }
    function holdIntegral(seconds) {
      const policy = EDGE_SCROLL_POLICY;
      const progress = Math.max(0, Math.min(1, (seconds - policy.dwellSeconds) / policy.rampSeconds));
      return seconds + policy.maximumExtraSpeed * (policy.rampSeconds * (progress ** 3 - progress ** 4 / 2)
        + Math.max(0, seconds - policy.dwellSeconds - policy.rampSeconds));
    }
    function edgeTarget() {
      if (format !== 'docx' || !drag || disposed || !isActive()) return null;
      const visual = window.visualViewport, scale = visual?.scale || 1;
      const bounds = viewport.getBoundingClientRect();
      const top = Math.max(bounds.top, visual?.offsetTop || 0);
      const bottom = Math.min(bounds.bottom, (visual?.offsetTop || 0)
        + (visual?.height || viewport.clientHeight));
      const zone = Math.min(EDGE_SCROLL_POLICY.zone / scale, (bottom - top) / 2);
      const leading = drag.y - top, trailing = bottom - drag.y;
      let direction = 0, proximity = 0;
      if (leading < zone && leading <= trailing) { direction = -1; proximity = 1 - leading / zone; }
      else if (trailing < zone) { direction = 1; proximity = 1 - trailing / zone; }
      const maximum = viewport.scrollHeight - viewport.clientHeight;
      if (!direction || maximum <= 0 || (direction < 0 && viewport.scrollTop <= 0)
          || (direction > 0 && viewport.scrollTop >= maximum)) return null;
      return { direction, proximity: Math.max(0, Math.min(1, proximity)), maximum, scale };
    }
    function stopEdge() {
      cancelAnimationFrame(edgeFrame); edgeFrame = 0;
      edgeLast = null; edgeHeld = 0; edgeDirection = 0;
    }
    function extendDrag() {
      if (!drag || !drag.anchor.isConnected) return;
      const visual = window.visualViewport;
      const left = visual?.offsetLeft || 0, top = visual?.offsetTop || 0;
      const x = Math.max(left + 1, Math.min(left + (visual?.width || viewport.clientWidth) - 1, drag.x));
      const y = Math.max(top + 1, Math.min(top + (visual?.height || viewport.clientHeight) - 1, drag.y));
      const hit = document.caretRangeFromPoint(x, y);
      if (!hit || !selectable(hit.startContainer) || !content.contains(hit.startContainer)) return;
      if (hit.startContainer === drag.anchor && hit.startOffset === drag.offset) return;
      const value = selection();
      if (value.focusNode !== hit.startContainer || value.focusOffset !== hit.startOffset) {
        value.setBaseAndExtent(drag.anchor, drag.offset, hit.startContainer, hit.startOffset);
        const now = performance.now();
        if (now - lastHapticTime >= SELECTION_GESTURES.hapticIntervalMs) {
          lastHapticTime = now; post('selectionHaptic');
        }
      }
    }
    function edgeTick(now) {
      edgeFrame = 0;
      const target = edgeTarget();
      if (!target) { stopEdge(); schedule(); return; }
      if (edgeLast === null || edgeDirection !== target.direction) {
        edgeHeld = 0; edgeDirection = target.direction; edgePosition = viewport.scrollTop;
      } else {
        const dt = Math.max(0, (now - edgeLast) / 1000);
        edgeHeld += dt;
        const policy = EDGE_SCROLL_POLICY;
        const speed = (policy.minimumSpeed + (policy.maximumSpeed - policy.minimumSpeed) * target.proximity) / target.scale;
        const distance = speed * (holdIntegral(edgeHeld)
          - holdIntegral(edgeHeld - Math.min(dt, policy.maximumFrameSeconds)));
        // Chromium rounds scrollTop to device pixels. Keep the fractional
        // remainder so a 120 Hz display does not lose distance each frame.
        if (Math.abs(viewport.scrollTop - edgePosition) > 1) edgePosition = viewport.scrollTop;
        edgePosition = Math.max(0, Math.min(target.maximum, edgePosition + target.direction * distance));
        viewport.scrollTop = edgePosition;
        extendDrag();
      }
      edgeLast = now;
      edgeFrame = requestAnimationFrame(edgeTick);
    }
    function updateEdge() {
      const target = edgeTarget();
      if (!target) { stopEdge(); return; }
      if (edgeDirection && edgeDirection !== target.direction) stopEdge();
      if (!edgeFrame) edgeFrame = requestAnimationFrame(edgeTick);
    }
    function handleDown(event) {
      if (!isActive() || event.button > 0) return;
      if (!event.isPrimary || (drag && drag.id !== event.pointerId)) {
        event.preventDefault(); event.stopPropagation(); endDrag(); return;
      }
      event.preventDefault(); event.stopPropagation(); cancelMotion(); endDrag();
      const range = selection().getRangeAt(0), handle = event.currentTarget;
      const start = handle.dataset.folioSelectionHandle === 'start';
      const rect = endpoint(start ? range.startContainer : range.endContainer,
        start ? range.startOffset : range.endOffset, !start);
      drag = { id: event.pointerId, handle,
        anchor: start ? range.endContainer : range.startContainer,
        offset: start ? range.endOffset : range.startOffset,
        dx: event.clientX - (start ? rect.left : rect.right), dy: event.clientY - rect.bottom,
        initialX: event.clientX, initialY: event.clientY,
        x: start ? rect.left : rect.right, y: rect.bottom };
      // Make the held endpoint the Selection focus immediately. The active
      // knob can then cross the fixed anchor without swapping pointer owners.
      selection().setBaseAndExtent(drag.anchor, drag.offset,
        start ? range.startContainer : range.endContainer,
        start ? range.startOffset : range.endOffset);
      handle.setPointerCapture(event.pointerId);
      // Capture keeps delivering this drag while caret hit-testing reaches the
      // glyph underneath the handle's transparent 44 px touch target.
      handle.style.pointerEvents = 'none';
      lastHapticTime = -Infinity; schedule();
    }
    function handleMove(event) {
      if (!drag || event.pointerId !== drag.id) return;
      event.preventDefault();
      drag.x = event.clientX - drag.dx; drag.y = event.clientY - drag.dy;
      extendDrag(); updateEdge(); schedule();
    }
    function endDrag() {
      stopEdge();
      if (!drag) return;
      const previous = drag; drag = null;
      previous.handle.style.pointerEvents = '';
      if (previous.handle.hasPointerCapture(previous.id)) previous.handle.releasePointerCapture(previous.id);
      post('selectionHandle', { active: false }); schedule();
    }
    function handleUp(event) { if (drag && event.pointerId === drag.id) endDrag(); }
    function visibilityChanged() { if (document.hidden) endDrag(); }
    function clear() {
      endDrag();
      const value = selection();
      if (value && content.contains(value.anchorNode) && content.contains(value.focusNode)) value.removeAllRanges();
      schedule();
    }
    function selectAll() {
      if (disposed) return;
      cancelMotion();
      const value = selection();
      if (!value) return;
      endDrag();
      if (textOnly || ownedHandles) {
        const nodes = nodesFor(content).filter((node) => meaningfulText(node.data));
        if (!nodes.length) { clear(); return; }
        const range = document.createRange();
        range.setStart(nodes[0], 0); range.setEnd(nodes.at(-1), nodes.at(-1).length);
        value.removeAllRanges(); value.addRange(range);
      } else value.selectAllChildren(content);
      schedule();
    }
    function copyText() {
      if (disposed || !isActive()) return '';
      if (!textOnly) return selection().toString();
      const selected = selection().getRangeAt(0), fragments = [];
      let previous = null;
      for (const node of nodesFor(content)) {
        if (!selected.intersectsNode(node)) continue;
        const start = node === selected.startContainer ? selected.startOffset : 0;
        const end = node === selected.endContainer ? selected.endOffset : node.length;
        const block = node.parentElement.closest('p,.text-block');
        if (fragments.length && previous !== block) fragments.push('\n');
        fragments.push(node.data.slice(start, end)); previous = block;
      }
      return fragments.join('');
    }
    function hitText(x, y) {
      const hit = document.caretRangeFromPoint(x, y), node = hit?.startContainer;
      if (!selectable(node) || !content.contains(node)) return false;
      for (const index of [hit.startOffset - 1, hit.startOffset]) {
        if (index < 0 || index >= node.length || !meaningfulText(node.data[index])) continue;
        const glyph = document.createRange(); glyph.setStart(node, index); glyph.setEnd(node, index + 1);
        for (const rect of nativeRangeRects.call(glyph)) {
          if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) return true;
        }
      }
      return false;
    }
    function resume() {
      endDrag(); scrolling = false; schedule();
    }
    function dispose() {
      if (disposed) return;
      endDrag(); observer.disconnect();
      disposed = true; cancelAnimationFrame(frame); clearTimeout(settleTimer);
      clearTimeout(selectionTimer);
      highlight.remove();
      handles.forEach((handle) => handle.remove());
      document.removeEventListener('selectionchange', changed);
      viewport.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', resume);
      window.removeEventListener('focus', resume);
      window.removeEventListener('blur', endDrag);
      window.removeEventListener('pointermove', handleMove);
      window.removeEventListener('pointerup', handleUp);
      window.removeEventListener('pointercancel', handleUp);
      document.removeEventListener('visibilitychange', visibilityChanged);
      window.visualViewport?.removeEventListener('resize', schedule);
      window.visualViewport?.removeEventListener('scroll', schedule);
    }
    document.addEventListener('selectionchange', changed);
    if (ownedHandles) {
      for (const side of ['start', 'end']) {
        const handle = document.createElement('div');
        handle.dataset.folioSelectionHandle = side; handle.hidden = true;
        handle.setAttribute('aria-hidden', 'true');
        handle.addEventListener('pointerdown', handleDown);
        handle.addEventListener('lostpointercapture', endDrag);
        document.body.appendChild(handle); handles.push(handle);
      }
      window.addEventListener('pointermove', handleMove, { passive: false });
      window.addEventListener('pointerup', handleUp);
      window.addEventListener('pointercancel', handleUp);
      window.addEventListener('blur', endDrag);
      document.addEventListener('visibilitychange', visibilityChanged);
    }
    viewport.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', resume);
    window.addEventListener('focus', resume);
    window.visualViewport?.addEventListener('resize', schedule);
    window.visualViewport?.addEventListener('scroll', schedule);
    return { isActive, selectAll, clear, copyText, hitText, cancelDrag: endDrag, refresh: schedule, dispose };
  }
  window.FolioReaderSelection = { create };
})();
