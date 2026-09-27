"""Selection/physics regression tests against the real bundled Office assets.

CDP dispatches genuine Chromium touch gestures (not just PointerEvent objects).
Android ActionMode/Flutter composition still require device integration tests.
"""
from __future__ import annotations
import io
import unittest
from PIL import Image, ImageChops
import test_renderers


class ReaderInteractionTests(unittest.TestCase):
    setUpClass = classmethod(test_renderers.OfficeRendererTests.setUpClass.__func__)
    tearDownClass = classmethod(test_renderers.OfficeRendererTests.tearDownClass.__func__)
    load = test_renderers.OfficeRendererTests.load
    clear_events = test_renderers.OfficeRendererTests.clear_events
    assert_no_chrome_events = test_renderers.OfficeRendererTests.assert_no_chrome_events

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

    def test_pptx_zoomed_slide_range_math(self):
        page=self.load('basic.pptx')
        self.assertEqual(page.evaluate('FolioOffice.zoomedSlideRange(2,412,2)'),{'lo':824,'hi':1030})
        self.assertEqual(page.evaluate('FolioOffice.zoomedSlideRange(0,412,1)'),{'lo':0,'hi':0})
        self.assertEqual(page.evaluate('FolioOffice.zoomedSlideRange(1,400,4)'),{'lo':400,'hi':700})

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
        self.assertAlmostEqual(page.evaluate('document.getElementById("viewport").scrollLeft'),412,delta=1)
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

    def test_selection_publish_never_serializes_text_or_entire_range_rects(self):
        page=self.load('basic.docx')
        page.evaluate("""() => {
          Selection.prototype.toString=()=>{throw Error('selection text serialized while dragging')};
          Range.prototype.getClientRects=()=>{throw Error('whole selection geometry measured')};
        }""")
        self.select(page,'docx')
        self.assertFalse(page.errors,page.errors)
        self.assertTrue(page.evaluate('events.some(e=>e.type==="selection"&&e.active)'))

    def test_repeated_selection_events_are_coalesced_and_deduplicated(self):
        page=self.load('basic.docx');self.select(page,'docx');self.clear_events(page)
        page.evaluate('for(let i=0;i<1000;i++)document.dispatchEvent(new Event("selectionchange"))')
        page.wait_for_timeout(180)
        events=page.evaluate('events.filter(e=>e.type==="selection")')
        self.assertLessEqual(len(events),2,events)  # hide once, show once after quiet
        self.assertTrue(events[-1]['showMenu'])
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

    def test_selection_toolbar_hides_during_scroll_and_recovers(self):
        page=self.load('basic.docx');self.select(page,'docx');self.clear_events(page)
        page.evaluate('document.getElementById("viewport").scrollTop+=80')
        page.wait_for_timeout(45)
        messages=page.evaluate('events.filter(e=>e.type==="selection")')
        self.assertTrue(any(e['active'] and not e.get('showMenu') for e in messages),messages)
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


if __name__ == '__main__': unittest.main()
