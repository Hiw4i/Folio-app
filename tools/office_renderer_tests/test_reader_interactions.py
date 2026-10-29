"""Selection/physics regression tests against the real bundled Office assets.

CDP dispatches genuine Chromium touch gestures (not just PointerEvent objects).
Android ActionMode/Flutter composition still require device integration tests.
"""
from __future__ import annotations
import io
import re
import unittest
from PIL import Image, ImageChops
import test_renderers


class ReaderInteractionTests(unittest.TestCase):
    setUpClass = classmethod(test_renderers.OfficeRendererTests.setUpClass.__func__)
    tearDownClass = classmethod(test_renderers.OfficeRendererTests.tearDownClass.__func__)
    load = test_renderers.OfficeRendererTests.load
    clear_events = test_renderers.OfficeRendererTests.clear_events
    assert_no_chrome_events = test_renderers.OfficeRendererTests.assert_no_chrome_events
    assert_slide_frame = test_renderers.OfficeRendererTests.assert_slide_frame

    def touch_session(self, page):
        session = page.context.new_cdp_session(page)
        session.send('Emulation.setTouchEmulationEnabled', {'enabled': True})
        self.addCleanup(session.detach)
        return session

    def touch(self, page, session, kind, *points):
        session.send('Input.dispatchTouchEvent', {'type': kind,
            'touchPoints': [{'x': x, 'y': y, 'id': i} for i, (x, y) in enumerate(points)]})
        page.wait_for_timeout(25)

    def transform(self, page, axis='y'):
        return page.evaluate("axis => {const s=getComputedStyle(document.getElementById('document'));"
            "const m=new DOMMatrixReadOnly(s.transform==='none'?undefined:s.transform);"
            "return axis==='x'?m.m41:m.m42}", axis)

    def select(self, page, fmt):
        page.evaluate("""fmt => {
          const root=document.querySelector(fmt==='docx'?'article p':'.slide .text-block');
          const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
          const node=walker.nextNode(),range=document.createRange();
          range.setStart(node,0);range.setEnd(node,Math.min(8,node.length));
          const selected=getSelection();selected.removeAllRanges();selected.addRange(range);
        }""",fmt)
        page.wait_for_timeout(140)

    def test_rubber_resists_monotonically_without_exceeding_viewport(self):
        page=self.load('basic.docx')
        values=page.evaluate('[1,100,200,500,10000].map(n=>FolioReaderMotion.rubber(n,915))')
        self.assertTrue(all(0 < value < 915 for value in values))
        self.assertEqual(values,sorted(values))
        self.assertLess(values[1],100)
        self.assertLess(values[3]-values[2],300*.26)
        self.assertAlmostEqual(page.evaluate('FolioReaderMotion.rubber(-100,915)'),-values[1])

    def test_analytic_spring_is_frame_rate_independent_and_settles(self):
        page=self.load('basic.docx')
        values=page.evaluate('[0,.25,.5,1,2].map(t=>FolioReaderMotion.spring(200,0,t))')
        self.assertAlmostEqual(values[0]['position'],200)
        self.assertAlmostEqual(values[0]['velocity'],0)
        self.assertTrue(all(0 <= v['position'] <= 200 for v in values))
        self.assertLess(abs(values[-1]['position']),.001)

    def test_pptx_navigation_clamps_and_displays_one_frame_without_scrolling(self):
        page=self.load('basic.pptx')
        for requested,expected in [(-5,0),(1,1),(99,1),(0,0)]:
            page.evaluate('index=>FolioOffice.goToPosition(index,false)',requested)
            self.assert_slide_frame(page,expected)

    def test_docx_top_real_touch_bounces_and_returns(self):
        page=self.load('basic.docx');session=self.touch_session(page)
        self.clear_events(page)
        self.touch(page,session,'touchStart',(206,270))
        for y in range(310,591,40): self.touch(page,session,'touchMove',(206,y))
        self.assertGreater(self.transform(page),15)
        self.assertLess(self.transform(page),320)
        self.assertEqual(page.evaluate('document.getElementById("viewport").scrollTop'),0)
        self.touch(page,session,'touchEnd')
        page.wait_for_timeout(1550)
        self.assertAlmostEqual(self.transform(page),0,delta=.1)
        self.assert_no_chrome_events(page)
        self.assertFalse(page.errors,page.errors)

    def test_docx_bottom_real_touch_bounces_and_returns(self):
        page=self.load('basic.docx');session=self.touch_session(page)
        page.evaluate('document.getElementById("viewport").scrollTop=1e7')
        page.wait_for_timeout(80);self.clear_events(page)
        end=page.evaluate('document.getElementById("viewport").scrollTop')
        self.touch(page,session,'touchStart',(206,720))
        for y in range(680,279,-40): self.touch(page,session,'touchMove',(206,y))
        self.assertLess(self.transform(page),-15)
        self.touch(page,session,'touchEnd');page.wait_for_timeout(1550)
        self.assertAlmostEqual(self.transform(page),0,delta=.1)
        self.assertAlmostEqual(page.evaluate('document.getElementById("viewport").scrollTop'),end,delta=1)
        self.assert_no_chrome_events(page)

    def test_pptx_first_edge_swipe_stays_without_chrome_or_slide_change(self):
        page=self.load('basic.pptx');session=self.touch_session(page);self.clear_events(page)
        self.touch(page,session,'touchStart',(80,450))
        for x in range(120,361,40): self.touch(page,session,'touchMove',(x,450))
        # No free swipe panning: the finger never drags the slide.
        self.assertEqual(self.transform(page,'x'),0)
        self.assertEqual(page.evaluate('document.getElementById("viewport").scrollLeft'),0)
        # Release is a rightward swipe: the same discrete prev command as an
        # edge tap, clamped on the first slide.
        self.touch(page,session,'touchEnd');page.wait_for_timeout(200)
        self.assertAlmostEqual(self.transform(page,'x'),0,delta=.1)
        self.assertEqual(page.evaluate('document.getElementById("viewport").scrollLeft'),0)
        self.assert_no_chrome_events(page)

    def test_pptx_last_edge_swipe_stays_without_chrome_or_slide_change(self):
        page=self.load('basic.pptx');session=self.touch_session(page)
        page.evaluate('FolioOffice.goToPosition(1,false)');page.wait_for_timeout(100);self.clear_events(page)
        self.touch(page,session,'touchStart',(350,450))
        for x in range(310,29,-40): self.touch(page,session,'touchMove',(x,450))
        # No free swipe panning: the finger never drags the slide.
        self.assertEqual(self.transform(page,'x'),0)
        # Release is a leftward swipe: the same discrete next command as an
        # edge tap, clamped on the last slide.
        self.touch(page,session,'touchEnd');page.wait_for_timeout(200)
        self.assertAlmostEqual(self.transform(page,'x'),0,delta=.1)
        self.assert_slide_frame(page,1)
        self.assert_no_chrome_events(page)

    def test_catching_spring_preserves_stretched_position(self):
        page=self.load('basic.docx');session=self.touch_session(page)
        self.touch(page,session,'touchStart',(206,270))
        for y in range(330,651,40): self.touch(page,session,'touchMove',(206,y))
        self.touch(page,session,'touchEnd')
        before=self.transform(page)
        self.assertGreater(before,10)
        self.touch(page,session,'touchStart',(206,650))
        self.assertGreater(self.transform(page),before*.5)
        self.touch(page,session,'touchEnd');page.wait_for_timeout(1550)
        self.assertAlmostEqual(self.transform(page),0,delta=.1)

    def test_reduced_motion_disables_edge_stretch(self):
        page=self.load('basic.docx');page.emulate_media(reduced_motion='reduce')
        session=self.touch_session(page)
        self.touch(page,session,'touchStart',(206,270))
        for y in range(320,621,50): self.touch(page,session,'touchMove',(206,y))
        self.assertEqual(self.transform(page),0)
        self.touch(page,session,'touchEnd');page.wait_for_timeout(100)
        self.assertEqual(self.transform(page),0)

    def test_touchcancel_resets_transform_and_restores_next_tap(self):
        page=self.load('basic.pptx');session=self.touch_session(page)
        self.touch(page,session,'touchStart',(90,450))
        self.touch(page,session,'touchMove',(230,450))
        # No free swipe panning in PPTX: the finger never drags the slide.
        self.assertEqual(self.transform(page,'x'),0)
        self.touch(page,session,'touchCancel');self.clear_events(page)
        self.assertEqual(self.transform(page,'x'),0)
        page.mouse.click(206,450)
        self.assertEqual(page.evaluate('events.filter(e=>e.type==="tap")'),[{'type':'tap'}])

    def test_rotation_during_spring_clears_transform_and_refits_docx(self):
        page=self.load('basic.docx');session=self.touch_session(page)
        self.touch(page,session,'touchStart',(206,270))
        self.touch(page,session,'touchMove',(206,570));self.touch(page,session,'touchEnd')
        page.set_viewport_size({'width':915,'height':412});page.wait_for_timeout(160)
        self.assertEqual(self.transform(page),0)
        box=page.locator('section.docx').first.bounding_box()
        self.assertAlmostEqual(box['width'],915,delta=.1)
        self.assertAlmostEqual(box['x'],0,delta=.1)

    def test_selection_stops_motion_and_restores_native_gestures(self):
        page=self.load('basic.docx');session=self.touch_session(page)
        self.touch(page,session,'touchStart',(206,270))
        self.touch(page,session,'touchMove',(206,570));self.touch(page,session,'touchEnd')
        self.select(page,'docx')
        self.assertEqual(self.transform(page),0)
        self.assertEqual(page.evaluate('document.getElementById("viewport").style.touchAction'),'auto')
        self.assertTrue(page.evaluate('FolioSelection.isActive()'))
        page.evaluate('FolioSelection.clear()');page.wait_for_timeout(80)
        self.assertEqual(page.evaluate('document.getElementById("viewport").style.touchAction'),'pinch-zoom')

    def test_office_selection_has_normalized_geometry_and_no_text_in_bridge(self):
        for fmt in ['docx','pptx']:
            with self.subTest(format=fmt):
                page=self.load('basic.'+fmt);self.clear_events(page);self.select(page,fmt)
                message=page.evaluate('events.filter(e=>e.type==="selection").at(-1)')
                self.assertTrue(message['active']);self.assertTrue(message['showMenu'])
                self.assertEqual(set(message),{'type','active','showMenu','x','top','bottom'})
                for key in ['x','top','bottom']: self.assertTrue(0<=message[key]<=1)
                self.assertTrue(page.evaluate('FolioSelection.copyText().length>0'))
                self.assertFalse(page.errors,page.errors)

    def test_docx_heading_and_body_paint_one_silhouette(self):
        # The heading's glyph box is 22 px tall and the body line 9 px, with an
        # 8.6 px paragraph gap between them. Judging that gap by the shorter row
        # allowed only 5.9 px, so the heading was painted as a separate bar.
        page=self.load('basic.docx')
        page.evaluate("""() => {
          const walker=document.createTreeWalker(document.querySelector('article'),NodeFilter.SHOW_TEXT);
          const nodes=[];
          for(let n=walker.nextNode();n;n=walker.nextNode()) if(n.data.trim()) nodes.push(n);
          const range=document.createRange();
          range.setStart(nodes[0],0);range.setEnd(nodes[1],nodes[1].data.length);
          const selected=getSelection();selected.removeAllRanges();selected.addRange(range);
        }""")
        page.wait_for_timeout(160)
        path=page.evaluate("document.querySelector('#folio-selection-highlight path')?.getAttribute('d')||''")
        self.assertTrue(path.startswith('M'),path)
        self.assertEqual(path.count('M'),1,path)
        self.assertFalse(page.errors,page.errors)

    def test_same_line_fragments_join_across_the_list_indent(self):
        # A list marker hangs a word-space away from its text. Fragments within
        # half a line height now paint one silhouette; wider gaps (columns,
        # table cells) still split. The probe pins both sides of that boundary.
        page=self.load('basic.docx')
        page.evaluate("""() => {
          const host=document.querySelector('article');
          const wrap=document.createElement('div');
          wrap.style.cssText='position:relative;display:inline-block;font-size:14px;line-height:24px;white-space:pre';
          wrap.innerHTML='<span id="probe-a">AA</span>'
            +'<span id="probe-b" style="margin-left:8px">BBBB</span>'
            +'<span id="probe-c" style="margin-left:40px">CCCC</span>';
          host.insertBefore(wrap,host.firstChild);
          const range=document.createRange();
          range.setStart(document.getElementById('probe-a').firstChild,0);
          range.setEnd(document.getElementById('probe-c').firstChild,4);
          const selected=getSelection();selected.removeAllRanges();selected.addRange(range);
        }""")
        page.wait_for_timeout(160)
        path=page.evaluate("document.querySelector('#folio-selection-highlight path')?.getAttribute('d')||''")
        self.assertTrue(path.startswith('M'),path)
        # The 8 px neighbours share one bar; the 40 px gap stays a second bar.
        self.assertEqual(path.count('M'),2,path)
        self.assertFalse(page.errors,page.errors)

    def test_selection_publish_never_serializes_text_or_entire_range_rects(self):
        page=self.load('basic.docx')
        page.evaluate("""() => {
          Selection.prototype.toString=()=>{throw Error('selection text serialized while dragging')};
          Range.prototype.getClientRects=()=>{throw Error('whole selection geometry measured')};
        }""")
        self.select(page,'docx')
        self.assertFalse(page.errors,page.errors)
        self.assertTrue(page.evaluate('events.some(e=>e.type==="selection"&&e.active)'))

    def test_repeated_unchanged_selection_events_keep_toolbar_visible_without_bridge_traffic(self):
        page=self.load('basic.docx');self.select(page,'docx');self.clear_events(page)
        page.evaluate('for(let i=0;i<1000;i++)document.dispatchEvent(new Event("selectionchange"))')
        page.wait_for_timeout(180)
        events=page.evaluate('events.filter(e=>e.type==="selection")')
        self.assertEqual(events,[])
        self.assertFalse(page.errors,page.errors)

    def test_select_all_copies_multiple_pages_and_has_no_markup(self):
        for fmt in ['docx','pptx']:
            with self.subTest(format=fmt):
                page=self.load('basic.'+fmt)
                self.select(page,fmt)
                before=page.evaluate('FolioSelection.copyText()')
                page.evaluate('FolioSelection.selectAll()');page.wait_for_timeout(100)
                text=page.evaluate('FolioSelection.copyText()')
                self.assertGreater(len(text),len(before))
                self.assertNotIn('<style',text);self.assertNotIn('{font',text)
                if fmt=='pptx':
                    self.assertIn('First slide',text);self.assertIn('Second slide',text)
                self.assertTrue(page.evaluate('FolioSelection.isActive()'))

    def test_select_all_keeps_visible_highlight_and_menu_after_scrolling(self):
        page=self.load('basic.docx')
        self.select(page,'docx')
        page.evaluate('FolioSelection.selectAll()')
        page.evaluate('document.getElementById("viewport").scrollTop+=500')
        page.wait_for_timeout(260)
        self.assertTrue(page.evaluate('FolioSelection.isActive()'))
        self.assertTrue(page.evaluate('events.filter(e=>e.type==="selection").at(-1).showMenu'))
        self.assertTrue(page.evaluate('''() => {
          const shape=document.querySelector('#folio-selection-highlight path');
          return !!shape?.getAttribute('d') && shape.getBBox().width > 0;
        }'''))
        painted = Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        page.locator('#folio-selection-highlight path').evaluate(
            "e => e.style.visibility = 'hidden'")
        hidden = Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        self.assertIsNotNone(ImageChops.difference(painted, hidden).getbbox())

    def test_search_clears_dom_ranges_before_replacing_text_nodes(self):
        page=self.load('basic.pptx');self.select(page,'pptx')
        page.evaluate("FolioOffice.search('slide')");page.wait_for_timeout(150)
        self.assertFalse(page.evaluate('FolioSelection.isActive()'))
        self.assertFalse(page.errors,page.errors)
        self.assertGreater(page.locator('mark').count(),0)

    def test_selection_toolbar_stays_during_scroll_and_follows_selection(self):
        page=self.load('basic.docx');self.select(page,'docx')
        before=page.evaluate('events.filter(e=>e.type==="selection").at(-1)')
        self.assertTrue(before['active'] and before['showMenu'],before)
        self.clear_events(page)
        page.evaluate('document.getElementById("viewport").scrollTop+=80')
        page.wait_for_timeout(45)
        messages=page.evaluate('events.filter(e=>e.type==="selection")')
        self.assertTrue(messages and all(e['showMenu'] for e in messages),messages)
        last=messages[-1]
        self.assertLess(last['top'],before['top']-0.04,last)
        page.wait_for_timeout(160)
        self.assertTrue(page.evaluate('events.filter(e=>e.type==="selection").at(-1).showMenu'))
        self.assert_no_chrome_events(page)

    def test_selection_colors_match_folio_not_android_blue_or_yellow(self):
        page=self.load('basic.pptx')
        value=page.locator('.text-block').first.evaluate('e=>getComputedStyle(e,"::selection").backgroundColor')
        self.assertIn(value,('rgba(0, 0, 0, 0)','transparent'))
        page.evaluate("FolioOffice.search('slide')");page.wait_for_timeout(100)
        colors=page.locator('mark').first.evaluate('e=>({bg:getComputedStyle(e).backgroundColor,fg:getComputedStyle(e).color})')
        self.assertEqual(colors,{'bg':'rgb(215, 222, 232)','fg':'rgb(22, 26, 32)'})

    def test_pptx_selection_edge_taps_do_not_navigate_or_toggle_chrome(self):
        page=self.load('basic.pptx');self.select(page,'pptx');self.clear_events(page)
        page.mouse.click(390,450);page.wait_for_timeout(120)
        self.assertEqual(page.evaluate('document.getElementById("viewport").scrollLeft'),0)
        self.assert_no_chrome_events(page)

    def test_no_selection_means_no_bridge_traffic_on_ordinary_taps(self):
        page=self.load('basic.pptx');self.clear_events(page)
        for _ in range(5): page.mouse.click(206,450);page.wait_for_timeout(30)
        self.assertEqual(page.evaluate('events.filter(e=>e.type==="selection")'),[])

    def test_clear_is_idempotent_and_copy_after_clear_is_empty(self):
        page=self.load('basic.docx');self.select(page,'docx')
        page.evaluate('FolioSelection.clear();FolioSelection.clear()');page.wait_for_timeout(80)
        self.assertEqual(page.evaluate('FolioSelection.copyText()'),'')
        self.assertFalse(page.evaluate('FolioSelection.isActive()'))
        self.assertFalse(page.errors,page.errors)

    def test_selection_ignores_content_outside_document(self):
        page=self.load('basic.docx');self.clear_events(page)
        page.evaluate('getSelection().selectAllChildren(document.getElementById("status"))')
        page.wait_for_timeout(140)
        self.assertFalse(page.evaluate('FolioSelection.isActive()'))
        self.assertEqual(page.evaluate('FolioSelection.copyText()'),'')
        self.assertEqual(page.evaluate('events.filter(e=>e.type==="selection")'),[])

    def test_pptx_images_cannot_start_selection_or_enter_select_all(self):
        page=self.load('basic.pptx')
        image=page.locator('.folio-picture img').first
        self.assertEqual(image.evaluate('e=>getComputedStyle(e).userSelect'),'none')
        self.assertFalse(image.evaluate('e=>e.draggable'))
        image.evaluate('''image=>{
          image.alt='IMAGE MUST NOT BE COPIED';
          const range=document.createRange();range.selectNode(image);
          const value=getSelection();value.removeAllRanges();value.addRange(range);
        }''')
        page.wait_for_timeout(160)
        self.assertFalse(page.evaluate('FolioSelection.isActive()'))
        self.assertEqual(page.evaluate('FolioSelection.copyText()'),'')
        page.evaluate('FolioSelection.selectAll()');page.wait_for_timeout(160)
        text=page.evaluate('FolioSelection.copyText()')
        self.assertIn('First slide',text);self.assertIn('Second slide',text)
        self.assertNotIn('IMAGE MUST NOT BE COPIED',text)
        self.assertFalse(page.errors,page.errors)

    def test_office_highlight_uses_format_specific_corner_radius(self):
        for fmt,radius in [('docx',2),('pptx',4)]:
            with self.subTest(format=fmt):
                page=self.load('basic.'+fmt);self.select(page,fmt)
                path=page.locator('#folio-selection-highlight path').get_attribute('d')
                coordinates=[float(n) for n in re.findall(r'-?\d+(?:\.\d+)?',path)]
                self.assertAlmostEqual(abs(coordinates[1]-coordinates[3]),radius,delta=.03)

    def drag_docx_handle_to_edge(self,page):
        self.select(page,'docx')
        handle=page.locator('[data-folio-selection-handle="end"]')
        self.assertTrue(handle.is_visible())
        box=handle.bounding_box()
        page.mouse.move(box['x']+box['width']/2,box['y']+box['height']/2)
        page.mouse.down();page.mouse.move(206,903,steps=4)

    def test_docx_stationary_handle_scrolls_and_extends_selection(self):
        page=self.load('basic.docx')
        self.drag_docx_handle_to_edge(page)
        before=page.evaluate('document.getElementById("viewport").scrollTop')
        text_before=page.evaluate('FolioSelection.copyText()')
        page.wait_for_timeout(450)
        after=page.evaluate('document.getElementById("viewport").scrollTop')
        self.assertGreater(after-before,100)
        self.assertGreater(len(page.evaluate('FolioSelection.copyText()')),len(text_before))
        self.assertFalse(page.evaluate('events.filter(e=>e.type==="selection").at(-1).showMenu'))
        page.mouse.up();page.wait_for_timeout(170)
        self.assertTrue(page.evaluate('events.filter(e=>e.type==="selection").at(-1).showMenu'))
        self.assert_no_chrome_events(page);self.assertFalse(page.errors,page.errors)

    def test_docx_handle_edge_scroll_stops_on_release_cancel_blur_and_dispose(self):
        for ending in ['release','cancel','blur','dispose']:
            with self.subTest(ending=ending):
                page=self.load('basic.docx');self.drag_docx_handle_to_edge(page)
                page.wait_for_timeout(100)
                if ending=='release': page.mouse.up()
                elif ending=='cancel': page.evaluate('window.dispatchEvent(new PointerEvent("pointercancel",{pointerId:1}))')
                elif ending=='blur': page.evaluate('window.dispatchEvent(new Event("blur"))')
                else: page.evaluate('FolioSelection.dispose()')
                page.wait_for_timeout(60)
                stopped=page.evaluate('document.getElementById("viewport").scrollTop')
                page.wait_for_timeout(180)
                self.assertEqual(page.evaluate('document.getElementById("viewport").scrollTop'),stopped)
                self.assertFalse(page.errors,page.errors)

    def test_docx_edge_hold_keeps_newly_visible_selected_text_highlighted(self):
        page=self.load('basic.docx');self.drag_docx_handle_to_edge(page)
        page.wait_for_timeout(850)
        self.assertGreater(page.evaluate('document.getElementById("viewport").scrollTop'),450)
        bounds=page.locator('#folio-selection-highlight path').bounding_box()
        self.assertGreater(bounds['y']+bounds['height'],795)
        self.assertLess(bounds['y'],200)
        self.assertFalse(page.evaluate('events.filter(e=>e.type==="selection").at(-1).showMenu'))
        page.mouse.up();self.assertFalse(page.errors,page.errors)

    def test_docx_edge_speed_is_independent_of_display_cadence_and_caps_late_frames(self):
        for hz in [60,120]:
            with self.subTest(hz=hz):
                page=self.load('basic.docx');self.select(page,'docx')
                page.evaluate('''()=>{
                  const spacer=document.createElement('div');spacer.style.height='20000px';
                  document.getElementById('viewport').appendChild(spacer);
                }''')
                handle=page.locator('[data-folio-selection-handle="end"]')
                box=handle.bounding_box()
                page.mouse.move(box['x']+22,box['y']+22);page.mouse.down()
                page.evaluate('''()=>{
                  window.testFrames=new Map();window.testFrameId=0;window.testTime=0;
                  window.requestAnimationFrame=callback=>{testFrames.set(++testFrameId,callback);return testFrameId};
                  window.cancelAnimationFrame=id=>testFrames.delete(id);
                  window.stepEdge=time=>{testTime=time;const callbacks=[...testFrames.values()];
                    testFrames.clear();for(const callback of callbacks)callback(time)};
                }''')
                page.mouse.move(206,950)
                page.evaluate('''hz=>{stepEdge(0);for(let i=1;i<=hz*3;i++)stepEdge(i*1000/hz)}''',hz)
                # 1000 px/s; after .9 s, smoothstep ramps to +60% by2.4 s.
                # Its integrated distance at3 s is 3810 px.
                offset=page.evaluate('document.getElementById("viewport").scrollTop')
                self.assertAlmostEqual(offset,3810,delta=2)
                page.evaluate('stepEdge(13000)')
                after_pause=page.evaluate('document.getElementById("viewport").scrollTop')
                self.assertAlmostEqual(after_pause-offset,80,delta=1)
                page.mouse.up();self.assertFalse(page.errors,page.errors)

    def test_docx_active_handle_follows_focus_when_crossing_the_anchor(self):
        page=self.load('basic.docx');self.select(page,'docx')
        handle=page.locator('[data-folio-selection-handle="start"]')
        handle.evaluate('e=>window.crossingHandle=e')
        target=page.evaluate('''()=>{
          const node=getSelection().anchorNode,r=document.createRange();
          r.setStart(node,12);r.collapse(true);const box=r.getBoundingClientRect();
          return {x:box.left,y:box.bottom};
        }''')
        box=handle.bounding_box();page.mouse.move(box['x']+22,box['y']+22)
        page.mouse.down();page.mouse.move(target['x'],target['y']+12)
        page.wait_for_timeout(50)
        geometry=page.evaluate('''()=>{
          const value=getSelection(),r=document.createRange();
          r.setStart(value.focusNode,value.focusOffset);r.collapse(true);
          const focus=r.getBoundingClientRect(),handle=crossingHandle.getBoundingClientRect();
          return {anchor:value.anchorOffset,focus:value.focusOffset,side:crossingHandle.dataset.folioSelectionHandle,
            x:handle.left+22,focusX:focus.left};
        }''')
        self.assertEqual(geometry['anchor'],8);self.assertEqual(geometry['focus'],12)
        self.assertEqual(geometry['side'],'end')
        self.assertAlmostEqual(geometry['x'],geometry['focusX'],delta=1)
        page.mouse.up();self.assertFalse(page.errors,page.errors)

    def test_docx_second_touch_cancels_handle_drag_and_edge_scrolling(self):
        page=self.load('basic.docx');self.select(page,'docx');session=self.touch_session(page)
        start=page.locator('[data-folio-selection-handle="start"]').bounding_box()
        end=page.locator('[data-folio-selection-handle="end"]').bounding_box()
        first=(start['x']+22,start['y']+22);second=(end['x']+22,end['y']+22)
        self.touch(page,session,'touchStart',first)
        self.touch(page,session,'touchStart',first,second)
        self.touch(page,session,'touchMove',first,(206,903))
        page.wait_for_timeout(350)
        self.assertEqual(page.evaluate('document.getElementById("viewport").scrollTop'),0)
        self.assertFalse(page.evaluate('events.filter(e=>e.type==="selectionHandle").at(-1).active'))
        self.touch(page,session,'touchEnd');self.assertFalse(page.errors,page.errors)

    def test_docx_real_touch_handle_hold_scrolls_without_releasing_selection(self):
        page=self.load('basic.docx');self.select(page,'docx');session=self.touch_session(page)
        box=page.locator('[data-folio-selection-handle="end"]').bounding_box()
        self.touch(page,session,'touchStart',(box['x']+22,box['y']+22))
        self.touch(page,session,'touchMove',(206,903))
        page.wait_for_timeout(350)
        self.assertGreater(page.evaluate('document.getElementById("viewport").scrollTop'),100)
        self.assertTrue(page.evaluate('FolioSelection.isActive()'))
        self.touch(page,session,'touchEnd');self.assertFalse(page.errors,page.errors)

    def test_docx_select_all_exposes_a_handle_at_its_visible_text_endpoint(self):
        page=self.load('basic.docx');page.evaluate('FolioSelection.selectAll()')
        page.wait_for_timeout(160)
        self.assertTrue(page.locator('[data-folio-selection-handle="start"]').is_visible())
        self.assertEqual(page.evaluate('getSelection().getRangeAt(0).startContainer.nodeType'),3)
        self.assertTrue(page.evaluate('FolioSelection.copyText().includes("Paragraph-45")'))

    def test_pptx_empty_tap_clears_selection_without_navigation_or_chrome_toggle(self):
        for x,y in [(206,30),(390,450)]:
            with self.subTest(point=(x,y)):
                page=self.load('basic.pptx');self.select(page,'pptx');self.clear_events(page)
                page.mouse.click(x,y);page.wait_for_timeout(160)
                self.assertFalse(page.evaluate('FolioSelection.isActive()'))
                self.assert_no_chrome_events(page)
                self.assertEqual(page.evaluate('events.filter(e=>e.type==="position")'),[])
                self.assertEqual(page.locator('.folio-slide-frame.is-active').count(),1)

    def test_touch_down_without_drag_keeps_office_selection_pill_stable(self):
        for fmt in ['docx','pptx']:
            with self.subTest(format=fmt):
                page=self.load('basic.'+fmt);self.select(page,fmt);self.clear_events(page)
                page.evaluate('''()=>document.getElementById('viewport').dispatchEvent(new PointerEvent('pointerdown',
                  {bubbles:true,pointerId:7,isPrimary:true,pointerType:'touch',button:0,clientX:206,clientY:450}))''')
                page.wait_for_timeout(50)
                self.assertFalse(page.evaluate('events.some(e=>e.type==="selection"&&!e.showMenu)'))
                page.evaluate('window.dispatchEvent(new PointerEvent("pointercancel",{pointerId:7}))')

    def test_whitespace_only_office_selection_has_no_highlight_or_pill(self):
        for fmt in ['docx','pptx']:
            for text,start in [(' \u00a0\u200b\u2060\ufeff\n',0),('Actual text   ',11)]:
                with self.subTest(format=fmt,text=text):
                    page=self.load('basic.'+fmt)
                    page.evaluate('''({fmt,text,start})=>{
                      const host=document.querySelector(fmt==='pptx'?'.slide':'article');
                      const shape=document.createElement('div');shape.id='empty-selection-probe';
                      shape.className='text-block';shape.style.cssText='position:relative;white-space:pre;font-size:30px';
                      shape.textContent=text;host.prepend(shape);
                      const range=document.createRange();range.setStart(shape.firstChild,start);
                      range.setEnd(shape.firstChild,text.length);getSelection().removeAllRanges();getSelection().addRange(range);
                    }''',{'fmt':fmt,'text':text,'start':start})
                    page.wait_for_timeout(180)
                    self.assertFalse(page.evaluate('FolioSelection.isActive()'))
                    self.assertEqual(page.evaluate('FolioSelection.copyText()'),'')
                    self.assertEqual(page.locator('#folio-selection-highlight path').get_attribute('d'),'')
                    self.assertFalse(page.evaluate('events.some(e=>e.type==="selection"&&e.active)'))
                    if fmt=='pptx' and start==0:
                        self.assertEqual(page.locator('#empty-selection-probe').evaluate('e=>getComputedStyle(e).userSelect'),'none')

    def test_owned_office_handles_emit_haptics_only_for_changed_endpoints(self):
        for fmt in ['docx','pptx']:
            with self.subTest(format=fmt):
                page=self.load('basic.'+fmt);self.select(page,fmt);self.clear_events(page)
                targets=page.evaluate('''()=>{
                  window.hapticNow=0;performance.now=()=>hapticNow;
                  const node=getSelection().focusNode;
                  return [9,10,11,12].map(offset=>{const r=document.createRange();r.setStart(node,offset);r.collapse(true);
                    const rect=r.getBoundingClientRect();return {x:rect.left,y:rect.bottom+12}});
                }''')
                box=page.locator('[data-folio-selection-handle="end"]').bounding_box()
                self.assertIsNotNone(box)
                page.mouse.move(box['x']+22,box['y']+22);page.mouse.down()
                self.assertEqual(page.evaluate('events.filter(e=>e.type==="selectionHaptic")'),[])
                for target in targets:
                    page.mouse.move(target['x'],target['y'])
                self.assertEqual(len(page.evaluate('events.filter(e=>e.type==="selectionHaptic")')),1)
                page.evaluate('hapticNow=50')
                page.mouse.move(targets[-1]['x'],targets[-1]['y'])
                self.assertEqual(len(page.evaluate('events.filter(e=>e.type==="selectionHaptic")')),1)
                page.mouse.move(targets[1]['x'],targets[1]['y'])
                self.assertEqual(page.evaluate('events.filter(e=>e.type==="selectionHaptic")'),
                    [{'type':'selectionHaptic'},{'type':'selectionHaptic'}])
                page.mouse.up();self.assertFalse(page.errors,page.errors)

    def test_selection_does_not_paint_blank_fragment_between_real_text(self):
        for fmt in ['docx','pptx']:
            with self.subTest(format=fmt):
                page=self.load('basic.'+fmt)
                point=page.evaluate('''fmt=>{
                  const host=document.querySelector(fmt==='pptx'?'.slide':'article');
                  const probe=document.createElement('div');probe.style.cssText='position:relative;height:250px';
                  for(const [index,text] of ['First text',' \u00a0\u200b\u2060\ufeff '.repeat(30),'Last text'].entries()) {
                    const block=document.createElement('div');block.className='text-block';
                    block.style.cssText=`position:absolute;left:20px;top:${index*80}px;width:300px;height:40px;white-space:pre;font-size:24px;line-height:36px`;
                    block.textContent=text;probe.appendChild(block);
                  }
                  host.prepend(probe);const range=document.createRange();
                  range.setStart(probe.firstChild.firstChild,0);range.setEnd(probe.lastChild.firstChild,9);
                  getSelection().removeAllRanges();getSelection().addRange(range);
                  const blank=document.createRange();blank.selectNodeContents(probe.children[1].firstChild);
                  const rect=blank.getClientRects()[0],root=document.getElementById('document').getBoundingClientRect();
                  return {x:rect.left+10-root.left,y:(rect.top+rect.bottom)/2-root.top};
                }''',fmt)
                page.wait_for_timeout(180)
                self.assertTrue(page.evaluate('FolioSelection.isActive()'))
                self.assertFalse(page.evaluate('''point=>document.querySelector('#folio-selection-highlight path')
                  .isPointInFill(new DOMPoint(point.x,point.y))''',point))

    def test_office_highlight_does_not_bridge_multicolumn_gutters(self):
        page=self.load('basic.docx')
        point=page.evaluate('''() => {
          const host=document.querySelector('article');
          const probe=document.createElement('div');probe.style.cssText='position:relative;height:220px';
          const columns=document.createElement('div');
          columns.style.cssText='position:absolute;left:20px;top:0;width:360px;height:200px;'
            +'column-count:2;column-gap:60px;font-size:20px;line-height:40px';
          // docx-preview keeps column sections as a CSS-columns article with
          // one p per paragraph, fragmented across the columns.
          const line=document.createElement('p');
          line.style.cssText='margin:0';
          line.textContent='word '.repeat(240);
          columns.appendChild(line);
          probe.appendChild(columns);host.prepend(probe);
          // One paragraph fragmented across two CSS columns: the same block
          // paints on both sides of the gutter on one baseline.
          const range=document.createRange();
          range.setStart(line.firstChild,0);
          range.setEnd(line.firstChild,line.firstChild.length);
          getSelection().removeAllRanges();getSelection().addRange(range);
          const columns_=columns.getBoundingClientRect();
          const root=document.getElementById('document').getBoundingClientRect();
          return {x:columns_.left+200-root.left,y:columns_.top+20-root.top};
        }''')
        page.wait_for_timeout(180)
        self.assertTrue(page.evaluate('FolioSelection.isActive()'))
        self.assertFalse(page.evaluate('''point=>document.querySelector('#folio-selection-highlight path')
          .isPointInFill(new DOMPoint(point.x,point.y))''',point))

    def test_office_highlight_bridges_justified_gaps_inside_one_block(self):
        for fmt in ['docx','pptx']:
            with self.subTest(format=fmt):
                page=self.load('basic.'+fmt)
                point=page.evaluate('''fmt=>{
                  const host=document.querySelector(fmt==='pptx'?'.slide':'article');
                  const probe=document.createElement('div');probe.style.cssText='position:relative;height:60px';
                  const line=document.createElement(fmt==='pptx'?'div':'p');
                  if(fmt==='pptx')line.className='text-block';
                  line.style.cssText='position:absolute;left:20px;top:0;width:360px;height:40px;margin:0;white-space:pre;font-size:24px;line-height:40px';
                  // Justified Word lines stretch word spacing far past half a
                  // line height, and runs arrive as separate spans.
                  for(const [index,word] of ['Left','Right'].entries()){
                    const span=document.createElement('span');
                    span.style.cssText=`position:absolute;left:${index*220}px;top:0`;
                    span.textContent=word;line.appendChild(span);
                  }
                  host.prepend(probe);probe.appendChild(line);
                  const range=document.createRange();
                  range.setStart(line.children[0].firstChild,0);
                  range.setEnd(line.children[1].firstChild,4);
                  getSelection().removeAllRanges();getSelection().addRange(range);
                  const first=line.children[0].firstChild.parentElement.getBoundingClientRect();
                  const root=document.getElementById('document').getBoundingClientRect();
                  return {x:(first.right+line.children[1].getBoundingClientRect().left)/2-root.left,
                    y:(first.top+first.bottom)/2-root.top};
                }''',fmt)
                page.wait_for_timeout(180)
                self.assertTrue(page.evaluate('FolioSelection.isActive()'))
                self.assertTrue(page.evaluate('''point=>document.querySelector('#folio-selection-highlight path')
                  .isPointInFill(new DOMPoint(point.x,point.y))''',point))

    def test_office_highlight_keeps_separate_blocks_across_wide_gaps(self):
        for fmt in ['docx','pptx']:
            with self.subTest(format=fmt):
                page=self.load('basic.'+fmt)
                point=page.evaluate('''fmt=>{
                  const host=document.querySelector(fmt==='pptx'?'.slide':'article');
                  const probe=document.createElement('div');probe.style.cssText='position:relative;height:60px';
                  for(const [index,word] of ['Left','Right'].entries()){
                    const block=document.createElement(fmt==='pptx'?'div':'p');
                    if(fmt==='pptx')block.className='text-block';
                    block.style.cssText=`position:absolute;left:${index*220}px;top:0;width:80px;height:40px;margin:0;white-space:pre;font-size:24px;line-height:40px`;
                    block.textContent=word;probe.appendChild(block);
                  }
                  host.prepend(probe);
                  const range=document.createRange();
                  range.setStart(probe.children[0].firstChild,0);
                  range.setEnd(probe.children[1].firstChild,5);
                  getSelection().removeAllRanges();getSelection().addRange(range);
                  const first=probe.children[0].getBoundingClientRect();
                  const root=document.getElementById('document').getBoundingClientRect();
                  return {x:(first.right+probe.children[1].getBoundingClientRect().left)/2-root.left,
                    y:(first.top+first.bottom)/2-root.top};
                }''',fmt)
                page.wait_for_timeout(180)
                self.assertTrue(page.evaluate('FolioSelection.isActive()'))
                self.assertFalse(page.evaluate('''point=>document.querySelector('#folio-selection-highlight path')
                  .isPointInFill(new DOMPoint(point.x,point.y))''',point))

    def test_scrolling_selected_docx_repaints_highlight_in_real_time(self):
        page=self.load('basic.docx');page.evaluate('FolioSelection.selectAll()')
        page.wait_for_timeout(180)
        page.evaluate('''()=>{
          window.paintTimes=[];
          window.firstScrollAt=Infinity;window.lastScrollAt=-Infinity;
          document.getElementById('viewport').addEventListener('scroll',()=>{
            const now=performance.now();
            window.firstScrollAt=Math.min(window.firstScrollAt,now);
            window.lastScrollAt=now;
          },{passive:true});
          new MutationObserver(()=>window.paintTimes.push(performance.now()))
            .observe(document.querySelector('#folio-selection-highlight path'),
              {attributes:true,attributeFilter:['d']});
          window.probeStart=performance.now();
        }''')
        for _ in range(5):
            page.evaluate('document.getElementById("viewport").scrollTop+=100')
            page.wait_for_timeout(25)
        page.wait_for_timeout(45)
        result=page.evaluate('''() => {
          const viewport=document.getElementById('viewport');
          const doc=document.getElementById('document').getBoundingClientRect();
          const walker=document.createTreeWalker(document.getElementById('document'),
            NodeFilter.SHOW_TEXT,
            {acceptNode:n=>n.nodeValue.trim()?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT});
          let probe=null;
          outer: for(let node=walker.nextNode();node;node=walker.nextNode()){
            const range=document.createRange();range.selectNodeContents(node);
            for(const rect of range.getClientRects()){
              const top=rect.top-doc.top;
              // Below the initially painted slice, inside the final viewport.
              if(rect.width>4 && top>viewport.clientHeight+8){
                probe={x:rect.left+rect.width/2-doc.left,y:(rect.top+rect.bottom)/2-doc.top};
                break outer;
              }
            }
          }
          const shape=document.querySelector('#folio-selection-highlight path');
          return {probe,paints:window.paintTimes,paintCount:window.paintTimes.length,
            elapsed:performance.now()-window.probeStart,
            paintedDuringScroll:window.paintTimes.some(time=>
              time>=window.firstScrollAt && time<window.lastScrollAt+100),
            highlighted:!!probe && !!shape?.getAttribute('d')
              && shape.isPointInFill(new DOMPoint(probe.x,probe.y))};
        }''')
        self.assertIsNotNone(result['probe'])
        self.assertGreaterEqual(result['paintCount'],2,result)
        self.assertLessEqual(result['paintCount'],result['elapsed']/64+2,result)
        self.assertTrue(result['paintedDuringScroll'],result)
        self.assertTrue(result['highlighted'],result)
        page.wait_for_timeout(160)
        self.assertTrue(page.evaluate('events.filter(e=>e.type==="selection").at(-1).showMenu'))


if __name__ == '__main__': unittest.main()
