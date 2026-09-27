/* Native browser selection, Flutter-owned toolbar. Only normalized endpoint
   geometry crosses the bridge during a drag; selected text is read on Copy. */
(() => {
  'use strict';
  function create({ viewport, content, post, cancelMotion, visiblePages }) {
    let disposed = false, frame = 0, settleTimer = 0, lastMessage = JSON.stringify({ active: false });
    let pointerDown = false, scrolling = false, changing = false, selectionTimer = 0;
    let geometry = { x: 0.5, top: 0.2, bottom: 0.25 };
    let visibleSelectionRects = [];
    const highlight = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    const highlightPath = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    const nativeRangeRects = Range.prototype.getClientRects;
    highlight.id = 'folio-selection-highlight';
    highlight.setAttribute('aria-hidden', 'true');
    highlight.appendChild(highlightPath);
    content.appendChild(highlight);
    const pointers = new Set();
    const selection = () => window.getSelection();
    function isActive() {
      const value = selection();
      return !!value && !value.isCollapsed && value.rangeCount > 0
        && content.contains(value.anchorNode) && content.contains(value.focusNode);
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
          if (Math.abs((row.top + row.bottom) / 2 - center)
              <= Math.min(row.bottom - row.top, height) * .35
              && box.left <= row.right + 2 && box.right >= row.left - 2) {
            found = row; break;
          }
        }
        if (found) {
          found.left = Math.min(found.left, box.left);
          found.top = Math.min(found.top, box.top);
          found.right = Math.max(found.right, box.right);
          found.bottom = Math.max(found.bottom, box.bottom);
        } else rows.push({ ...box });
      }
      rows.sort((a, b) => (a.top + a.bottom - b.top - b.bottom) || a.left - b.left);
      const groups = [];
      for (const row of rows) {
        let owner = null;
        for (let i = groups.length - 1; i >= 0; i--) {
          const previous = groups[i].at(-1);
          const height = Math.min(previous.bottom - previous.top, row.bottom - row.top);
          const gap = row.top - previous.bottom;
          if (gap >= -height * .35 && gap <= Math.min(12, Math.max(2, height * .65))
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
          const radius = Math.min(6, a / 2, b / 2);
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
      const selected = selection().getRangeAt(0);
      const pages = visiblePages?.() || [content];
      for (const page of pages) {
        const bounds = page.getBoundingClientRect();
        if (bounds.bottom < top || bounds.top > top + height
            || bounds.right < left || bounds.left > left + width
            || !selected.intersectsNode(page)) continue;
        const walker = document.createTreeWalker(page, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.length || !selected.intersectsNode(node)) continue;
          const start = node === selected.startContainer ? selected.startOffset : 0;
          const end = node === selected.endContainer ? selected.endOffset : node.length;
          if (end <= start) continue;
          const fragment = document.createRange();
          fragment.setStart(node, start); fragment.setEnd(node, end);
          for (const rect of nativeRangeRects.call(fragment)) {
            if (rect.right <= left || rect.left >= left + width
                || rect.bottom <= top || rect.top >= top + height) continue;
            visibleSelectionRects.push({ left: rect.left - left, top: rect.top - top,
              right: rect.right - left, bottom: rect.bottom - top });
            documentRects.push({ left: rect.left - root.left, top: rect.top - root.top,
              right: rect.right - root.left, bottom: rect.bottom - root.top });
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
      paintHighlight();
      let payload = { active: false };
      if (isActive()) {
        const showMenu = !pointerDown && !scrolling && !changing;
        // Native Android handles do not reliably emit DOM pointer events.
        // A short quiet-period keeps the pill hidden during their drag and
        // avoids measuring/rebuilding glass on every selected-character change.
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
          geometry = { x: Math.max(0, Math.min(1, x)),
            top: Math.max(0, Math.min(1, above)),
            bottom: Math.max(0, Math.min(1, below)) };
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
      clearTimeout(selectionTimer);
      changing = isActive();
      if (changing) {
        cancelMotion();
        selectionTimer = setTimeout(() => { changing = false; schedule(); }, 120);
      }
      schedule();
    }
    function down(event) {
      pointers.add(event.pointerId); pointerDown = true; schedule();
    }
    function up(event) {
      pointers.delete(event.pointerId); pointerDown = pointers.size > 0; schedule();
    }
    function onScroll() {
      if (!isActive()) return;
      scrolling = true; schedule(); clearTimeout(settleTimer);
      settleTimer = setTimeout(() => { scrolling = false; schedule(); }, 100);
    }
    function clear() {
      if (isActive()) selection().removeAllRanges();
      schedule();
    }
    function selectAll() {
      if (disposed) return;
      cancelMotion();
      const value = selection();
      if (!value) return;
      value.selectAllChildren(content); schedule();
    }
    function copyText() {
      return !disposed && isActive() ? selection().toString() : '';
    }
    function resume() {
      // Native selection handles are not DOM pointer targets on every WebView.
      // A selectionchange still updates the anchor; resuming after focus/resize
      // makes the menu recover from an interrupted native gesture.
      pointers.clear(); pointerDown = false; scrolling = false; schedule();
    }
    function dispose() {
      disposed = true; cancelAnimationFrame(frame); clearTimeout(settleTimer);
      clearTimeout(selectionTimer);
      highlight.remove();
      pointers.clear();
      document.removeEventListener('selectionchange', changed);
      viewport.removeEventListener('pointerdown', down);
      window.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', up);
      viewport.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', resume);
      window.removeEventListener('focus', resume);
      window.visualViewport?.removeEventListener('resize', schedule);
      window.visualViewport?.removeEventListener('scroll', schedule);
    }
    document.addEventListener('selectionchange', changed);
    viewport.addEventListener('pointerdown', down, { passive: true });
    window.addEventListener('pointerup', up, { passive: true });
    window.addEventListener('pointercancel', up, { passive: true });
    viewport.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', resume);
    window.addEventListener('focus', resume);
    window.visualViewport?.addEventListener('resize', schedule);
    window.visualViewport?.addEventListener('scroll', schedule);
    return { isActive, selectAll, clear, copyText, refresh: schedule, dispose };
  }
  window.FolioReaderSelection = { create };
})();
