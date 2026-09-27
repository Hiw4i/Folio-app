from __future__ import annotations
import io
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright
from browser import render
from fixtures import generate


class OfficeRendererTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory=tempfile.TemporaryDirectory(prefix='folio-office-')
        cls.fixtures=Path(cls.directory.name);generate(cls.fixtures)
        cls.playwright=sync_playwright().start()
        executable=os.environ.get('CHROMIUM_PATH') or shutil.which('chromium') or shutil.which('google-chrome')
        options={'headless':True}
        if executable: options['executable_path']=executable
        cls.browser=cls.playwright.chromium.launch(**options)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close();cls.playwright.stop();cls.directory.cleanup()

    def load(self, name, **kwargs):
        page=render(self.browser,self.fixtures/name,**kwargs);self.addCleanup(page.close)
        events=page.evaluate('events')
        self.assertFalse(page.errors,page.errors)
        self.assertTrue(any(e['type']=='ready' for e in events),events)
        return page

    def pixel(self, page, x, y):
        return Image.open(io.BytesIO(page.screenshot())).convert('RGB').getpixel((int(x),int(y)))

    def test_pptx_ready_is_complete_and_has_text(self):
        page=self.load('basic.pptx')
        ready=page.evaluate('events.filter(e=>e.type==="ready")')
        self.assertEqual(ready,[{'type':'ready','count':2,'hasText':True}])

    def test_pptx_paragraph_defaults_size_and_colour(self):
        page=self.load('basic.pptx')
        style=page.locator('.text-block').first.evaluate('(e)=>({size:getComputedStyle(e).fontSize,color:getComputedStyle(e).color})')
        self.assertEqual(style,{'size':'40px','color':'rgb(255, 255, 255)'})

    def test_pptx_crop_uses_remaining_source(self):
        page=self.load('basic.pptx');box=page.locator('.folio-picture').first.bounding_box()
        for fraction in [.05,.5,.95]:
            self.assertEqual(self.pixel(page,box['x']+box['width']*fraction,box['y']+box['height']/2),(0,0,255))

    def test_pptx_group_scale_and_offset(self):
        page=self.load('basic.pptx');rect=page.locator('.folio-group').first.bounding_box();slide=page.locator('.slide').first.bounding_box()
        self.assertAlmostEqual(rect['x'],206,delta=.05);self.assertAlmostEqual(rect['y']-slide['y'],61.8,delta=.05)
        self.assertAlmostEqual(rect['width'],164.8,delta=.05);self.assertAlmostEqual(rect['height'],82.4,delta=.05)
        self.assertEqual(self.pixel(page,rect['x']+rect['width']*.25,rect['y']+rect['height']*.5),(0,255,0))
        self.assertEqual(self.pixel(page,rect['x']+rect['width']*.75,rect['y']+rect['height']*.5),(255,255,0))
        self.assertEqual(page.locator('.folio-group').evaluate('(e)=>getComputedStyle(e).borderTopWidth'),'0px')

    def test_pptx_uses_presentation_order(self):
        page=self.load('reordered.pptx')
        self.assertIn('Second slide',page.locator('.slide').first.text_content())

    def test_pptx_arbitrary_slide_part_name(self):
        page=self.load('renamed.pptx')
        self.assertIn('First slide',page.locator('.slide').first.text_content())

    def test_pptx_optional_app_properties(self):
        self.load('no_app.pptx')

    def test_pptx_broken_relationship_reports_error_not_partial_ready(self):
        page=render(self.browser,self.fixtures/'broken.pptx');self.addCleanup(page.close)
        self.assertEqual(page.evaluate('events.filter(e=>e.type==="ready").length'),0)
        self.assertIn('relationship',page.evaluate('events.find(e=>e.type==="error").message'))

    def test_pptx_default_background_is_white(self):
        page=self.load('basic.pptx');page.evaluate('FolioOffice.goToPosition(1,false)');page.wait_for_timeout(200)
        bg=page.locator('.folio-background-paint').nth(1)
        self.assertEqual(bg.evaluate('(e)=>getComputedStyle(e).backgroundColor'),'rgb(255, 255, 255)')

    def test_pptx_background_theme_reference_placeholder(self):
        page=self.load('bgref.pptx')
        self.assertEqual(page.locator('.folio-background-paint').first.evaluate('(e)=>getComputedStyle(e).backgroundColor'),'rgb(220, 122, 33)')

    def test_pptx_gradient_background(self):
        page=self.load('gradient.pptx')
        bg=page.locator('.folio-background-paint').first.evaluate('(e)=>getComputedStyle(e).backgroundImage')
        self.assertIn('linear-gradient(90deg',bg);self.assertIn('rgb(255, 0, 0)',bg);self.assertIn('rgb(0, 0, 255)',bg)

    def test_pptx_image_background_does_not_fade_text(self):
        page=self.load('background_image.pptx')
        self.assertEqual(page.locator('.folio-background-paint').first.evaluate('(e)=>getComputedStyle(e).opacity'),'0.5')
        self.assertEqual(page.locator('.folio-slide-background').first.evaluate('(e)=>getComputedStyle(e).opacity'),'1')
        self.assertIn('blob:',page.locator('.folio-background-paint').first.evaluate('(e)=>getComputedStyle(e).backgroundImage'))
        self.assertFalse(page.evaluate('Object.prototype.hasOwnProperty("set")'))

    def test_pptx_font_theme_autofit_and_explicit_bold_reset(self):
        page=self.load('text_properties.pptx')
        style=page.locator('.text-block').first.evaluate('(e)=>{const s=getComputedStyle(e);return [s.fontSize,s.fontWeight,s.fontStyle,s.fontFamily]}')
        self.assertEqual(style[:3],['32px','400','italic']);self.assertNotIn('+mn',style[3]);self.assertIn('Calibri',style[3])

    def test_pptx_shared_media_uses_one_blob(self):
        page=self.load('basic.pptx')
        urls=page.locator('.folio-picture img').evaluate_all('(els)=>els.map(e=>e.src)')
        self.assertEqual(len(set(urls)),1);self.assertEqual(page.evaluate('resourceCounts.created'),1)

    def test_pptx_svg_ids_unique(self):
        page=self.load('basic.pptx')
        ids=page.locator('svg [id]').evaluate_all('(els)=>els.map(e=>e.id)')
        self.assertEqual(len(ids),len(set(ids)))

    def test_pptx_portrait_center_respects_reserved_chrome(self):
        page=self.load('basic.pptx');box=page.locator('.slide').first.bounding_box()
        self.assertAlmostEqual(box['y']+box['height']/2,74+(915-74-108)/2,delta=.1)

    def test_pptx_landscape_resize_fits_viewport(self):
        page=self.load('basic.pptx');page.set_viewport_size({'width':915,'height':412});page.wait_for_timeout(120)
        box=page.locator('.slide').first.bounding_box()
        self.assertGreaterEqual(box['x'],0);self.assertGreaterEqual(box['y'],0)
        self.assertLessEqual(box['x']+box['width'],915.1);self.assertLessEqual(box['y']+box['height'],412.1)

    def test_docx_fits_mobile_without_side_clipping(self):
        page=self.load('basic.docx')
        for box in page.locator('section.docx').evaluate_all('(els)=>els.map(e=>e.getBoundingClientRect().toJSON())'):
            self.assertAlmostEqual(box['left'],0,delta=.1);self.assertAlmostEqual(box['right'],412,delta=.1)

    def test_docx_pages_preserve_text_background_and_headers(self):
        page=self.load('basic.docx');count=page.locator('section.docx').count()
        self.assertGreater(count,1)
        self.assertEqual(page.locator('header').count(),count);self.assertEqual(page.locator('footer').count(),count)
        text=''.join(page.locator('article').all_text_contents())
        for index in range(1,46):self.assertEqual(text.count(f'Paragraph-{index:02d}:'),2)
        self.assertEqual(page.locator('section.docx').first.evaluate('(e)=>getComputedStyle(e).backgroundColor'),'rgb(255, 244, 204)')

    def test_docx_asymmetric_crop_is_not_shifted(self):
        page=self.load('crop.docx');box=page.locator('.folio-docx-picture').bounding_box()
        for fraction in [.05,.5,.95]:self.assertEqual(self.pixel(page,box['x']+box['width']*fraction,box['y']+box['height']*.5),(0,0,255))

    def test_docx_horizontal_flip(self):
        page=self.load('flip.docx');box=page.locator('.folio-docx-picture').bounding_box()
        self.assertEqual(self.pixel(page,box['x']+box['width']*.2,box['y']+box['height']*.5),(0,0,255))
        self.assertEqual(self.pixel(page,box['x']+box['width']*.8,box['y']+box['height']*.5),(255,0,0))

    def test_docx_absolute_anchor_uses_page_coordinates(self):
        page=self.load('anchor.docx')
        box=page.locator('section.docx > div').first.bounding_box();sheet=page.locator('section.docx').first.bounding_box();scale=sheet['width']/816
        self.assertAlmostEqual(box['x']-sheet['x'],96*scale,delta=.1);self.assertAlmostEqual(box['y']-sheet['y'],192*scale,delta=.1)
        self.assertEqual(page.locator('section.docx > div').first.evaluate('(e)=>e.style.zIndex'),'0')

    def test_docx_long_table_is_split_without_losing_rows(self):
        page=self.load('table.docx');self.assertGreater(page.locator('table').count(),1)
        text=''.join(page.locator('article').all_text_contents())
        for index in range(70):self.assertEqual(text.count(f'Row-{index:02d}'),1)
        self.assertTrue(page.locator('td[rowspan="4"]').count())

    def test_docx_columns_are_not_flattened(self):
        page=self.load('columns.docx')
        self.assertEqual(page.locator('article').first.evaluate('(e)=>getComputedStyle(e).columnCount'),'2')
        self.assertEqual(page.locator('section.docx').count(),1)

    def test_docx_continuous_sections_remain_separate_articles(self):
        page=self.load('continuous.docx')
        self.assertGreaterEqual(page.locator('article').count(),2)
        self.assertIn('Continuous section preserved',''.join(page.locator('article').all_text_contents()))

    def test_docx_cached_page_break_is_respected(self):
        page=self.load('break.docx')
        self.assertEqual(page.locator('section.docx').count(),2)
        self.assertIn('After cached break',page.locator('section.docx').nth(1).text_content())

    def test_docx_base_styles_can_follow_derived_styles(self):
        page=self.load('styles.docx')
        style=page.locator('article span').first.evaluate('(e)=>[getComputedStyle(e).fontSize,getComputedStyle(e).color]')
        self.assertEqual(style,['29.3333px','rgb(36, 104, 172)'])

    def test_docx_resize_keeps_page_fit(self):
        page=self.load('basic.docx');page.set_viewport_size({'width':700,'height':915});page.wait_for_timeout(120)
        box=page.locator('section.docx').first.bounding_box()
        self.assertAlmostEqual(box['width'],700,delta=.1);self.assertAlmostEqual(box['x'],0,delta=.1)

    def test_scroll_does_not_measure_all_pages(self):
        page=self.load('basic.docx')
        page.evaluate('''() => { window.measurements=0; const original=Element.prototype.getBoundingClientRect;
          Element.prototype.getBoundingClientRect=function(){measurements++;return original.call(this)};
          document.getElementById('viewport').scrollTop=600;
        }''');page.wait_for_timeout(120)
        self.assertEqual(page.evaluate('measurements'),0)
        self.assertGreater(page.evaluate('events.filter(e=>e.type==="position").at(-1).current'),1)

    def test_unicode_search_uses_original_offsets(self):
        page=self.load('basic.docx')
        page.evaluate('''() => {const el=document.querySelector('article p');el.textContent='İ🦊 i 🦊';FolioOffice.search('🦊')}''')
        page.wait_for_function('events.some(e=>e.type==="search"&&!e.searching&&e.count===2)',timeout=5000)
        self.assertEqual(page.locator('mark').all_text_contents(),['🦊','🦊'])

    def test_docx_blob_resources_released_at_pagehide(self):
        page=self.load('basic.docx');self.assertGreater(page.evaluate('resourceCounts.created'),0)
        page.evaluate('window.dispatchEvent(new Event("pagehide"))')
        counts=page.evaluate('resourceCounts');self.assertEqual(counts['created'],counts['revoked'])

    def test_pptx_metadata_cache_is_bounded_and_copy_isolated(self):
        page=self.load('basic.pptx')
        result=page.evaluate('''() => {
          let reads=0;const zip={file:path=>({asText:()=>{reads++;return '{}'}})},parse=()=>({attrs:{name:'clean'}});
          const first=FolioPptx.readPart(zip,'ppt/slideMasters/master.xml',parse);first.attrs.name='mutated';
          const second=FolioPptx.readPart(zip,'ppt/slideMasters/master.xml',parse);const cached=reads;
          for(let i=0;i<20;i++)FolioPptx.readPart(zip,'ppt/slideMasters/part'+i,parse);
          FolioPptx.readPart(zip,'ppt/slideMasters/master.xml',parse);
          return {name:second.attrs.name,cached,reads};
        }''')
        self.assertEqual(result,{'name':'clean','cached':1,'reads':22})

    def test_pptx_svg_gradient_references_are_local_to_each_svg(self):
        page=self.load('gradient_shapes.pptx')
        gradients=page.locator('svg linearGradient')
        self.assertGreaterEqual(gradients.count(),4)
        ids=gradients.evaluate_all('(els)=>els.map(e=>e.id)')
        self.assertEqual(len(ids),len(set(ids)))
        self.assertTrue(page.evaluate("Array.from(document.querySelectorAll('svg [fill^=\"url(#\"]')).every(el=>el.closest('svg').querySelector('[id=\"'+el.getAttribute('fill').slice(5,-1)+'\"]'))"))

    def test_pptx_group_rotation_and_flips(self):
        page=self.load('rotated.pptx')
        group=page.locator('.folio-group').first
        self.assertIn('rotate(90deg)',group.get_attribute('style'))
        self.assertIn('scale(-1,1)',group.get_attribute('style'))
        self.assertIn('scale(1,-1)',page.locator('.folio-picture').first.get_attribute('style'))
        size=group.bounding_box();self.assertAlmostEqual(size['width'],82.4,delta=.1);self.assertAlmostEqual(size['height'],164.8,delta=.1)

    def test_pptx_text_insets_and_normal_word_wrapping(self):
        page=self.load('wrapped.pptx')
        box=page.locator('.block.content').first
        self.assertAlmostEqual(float(box.evaluate('(e)=>getComputedStyle(e).paddingLeft').removesuffix('px')),19.2,delta=.01)
        text=box.locator('.text-block').first
        self.assertEqual(text.text_content(),'One two three four five six seven eight nine ten')
        lines=text.evaluate('(e)=>{const r=document.createRange();r.selectNodeContents(e);return Array.from(r.getClientRects()).map(r=>r.width)}')
        self.assertGreater(len(lines),1)
        for width in lines:self.assertLessEqual(width,192*412/960)

    def test_pptx_table_cells_and_backgrounds(self):
        page=self.load('table.pptx')
        self.assertEqual(page.locator('td').count(),6)
        for row in range(3):
            for column in range(2):self.assertIn(f'Cell {row},{column}',page.locator('td').nth(row*2+column).text_content())
        self.assertTrue(any('221, 221, 136' in colour for colour in page.locator('td').evaluate_all('(els)=>els.map(e=>getComputedStyle(e).backgroundColor)')))

    def test_pptx_color_map_overrides_and_master_reset(self):
        page=self.load('basic.pptx')
        result=page.evaluate("""() => {
          const context={slideMasterContent:{'p:sldMaster':{'p:clrMap':{attrs:{accent1:'accent1'}}}},
            slideLayoutContent:{'p:sldLayout':{'p:clrMapOvr':{'a:overrideClrMapping':{attrs:{accent1:'accent2'}}}}},
            themeContent:{'a:theme':{'a:themeElements':{'a:clrScheme':{'a:accent1':{'a:srgbClr':{attrs:{val:'FF0000'}}},'a:accent2':{'a:srgbClr':{attrs:{val:'0000FF'}}}}}}}};
          const layout=FolioPptx.schemeColor('a:accent1',undefined,undefined,context);
          context.slideContent={'p:sld':{'p:clrMapOvr':{'a:masterClrMapping':{}}}};
          return [layout,FolioPptx.schemeColor('a:accent1',undefined,undefined,context)];
        }""")
        self.assertEqual(result,['0000FF','FF0000'])

    def test_pptx_package_paths_cannot_escape_root(self):
        page=self.load('basic.pptx')
        results=page.evaluate("""()=>['../../../../escape','https://example.invalid/a','/ppt/media/a.png','../media/a.png'].map(p=>FolioPptx.resolvePart('ppt/slides/intro.xml',p))""")
        self.assertEqual(results,['','','ppt/media/a.png','ppt/media/a.png'])

    def test_docx_merged_rows_remain_on_one_page(self):
        page=self.load('table.docx');cell=page.locator('td[rowspan="4"]')
        text=cell.text_content()
        for index in range(8,12):self.assertIn(f'Row-{index:02d}',text)
        self.assertTrue(cell.evaluate('(e)=>e.getBoundingClientRect().bottom <= e.closest("section.docx").getBoundingClientRect().bottom'))

    def test_pptx_cleanup_releases_shared_blobs(self):
        page=self.load('basic.pptx');page.evaluate('window.dispatchEvent(new Event("pagehide"))')
        counts=page.evaluate('resourceCounts');self.assertEqual(counts['created'],counts['revoked'])


    def test_pptx_svg_gradient_keeps_intermediate_stop_position(self):
        page=self.load('gradient_shapes.pptx')
        stops=page.locator('svg linearGradient').first.locator('stop').evaluate_all('(els)=>els.map(e=>e.getAttribute("offset"))')
        self.assertEqual(stops,['0','0.2','1'])

    def test_pptx_svg_gradient_flows_in_authored_direction(self):
        page=self.load('gradient_shapes.pptx')
        box=page.locator('svg').filter(has=page.locator('linearGradient')).first.bounding_box()
        left=self.pixel(page,box['x']+box['width']*.05,box['y']+box['height']*.5)
        right=self.pixel(page,box['x']+box['width']*.95,box['y']+box['height']*.5)
        self.assertGreater(left[0],240);self.assertLess(left[1],100)
        self.assertGreater(right[1],240);self.assertLess(right[0],100)


    def test_unicode_search_query_preserves_combining_character_semantics(self):
        page=self.load('basic.docx')
        page.evaluate("() => {document.querySelector('article p').textContent='İx İ';FolioOffice.search('İ')}")
        page.wait_for_function('events.some(e=>e.type==="search"&&!e.searching&&e.count===2)',timeout=5000)
        self.assertEqual(page.locator('mark').all_text_contents(),['İ','İ'])



    def assert_no_chrome_events(self, page):
        self.assertEqual(page.evaluate("events.filter(e => e.type === 'tap' || e.type === 'scroll')"), [])

    def clear_events(self, page):
        page.evaluate('events.length = 0')

    def pointer_sequence(self, page, sequence):
        """Dispatch edge-case sequences without relying on OS touch synthesis."""
        page.evaluate("""sequence => {
          const target = document.getElementById('viewport');
          for (const [type, values] of sequence) {
            target.dispatchEvent(new PointerEvent(type, {
              bubbles: true, pointerId: 1, pointerType: 'touch',
              isPrimary: true, clientX: 206, clientY: 450, button: 0,
              ...values,
            }));
          }
        }""", sequence)

    def test_docx_edge_to_edge_in_both_orientations(self):
        page = self.load('basic.docx')
        for width, height in [(360, 800), (915, 412), (1200, 800), (412, 915)]:
            with self.subTest(width=width, height=height):
                page.set_viewport_size({'width': width, 'height': height})
                page.wait_for_timeout(100)
                boxes = page.locator('section.docx').evaluate_all(
                    '(els) => els.map(e => e.getBoundingClientRect().toJSON())')
                for box in boxes:
                    self.assertAlmostEqual(box['left'], 0, delta=.1)
                    self.assertAlmostEqual(box['right'], width, delta=.1)
                self.assertEqual(page.evaluate('document.getElementById("viewport").scrollWidth'), width)

    def test_docx_opens_landscape_wider_than_authored_page(self):
        page = self.load('basic.docx', size=(915, 412))
        box = page.locator('section.docx').first.bounding_box()
        self.assertAlmostEqual(box['x'], 0, delta=.1)
        self.assertAlmostEqual(box['width'], 915, delta=.1)
        self.assertGreater(float(page.locator('section.docx').first.evaluate('(e) => e.style.zoom')), 1)

    def test_docx_fractional_and_mixed_page_widths_fit_without_drift(self):
        page = self.load('basic.docx')
        boxes = page.evaluate("""() => {
          const pages = [...document.querySelectorAll('section.docx')];
          pages.forEach((page, index) => { page.style.width = index % 2 ? '841.9pt' : '595.3pt'; });
          // Repeated fit must read authored widths, never the previous zoom.
          for (let i = 0; i < 6; i++) FolioDocx.fit(document.getElementById('document'), document.getElementById("viewport"));
          return pages.map(page => page.getBoundingClientRect().toJSON());
        }""")
        for box in boxes:
            self.assertAlmostEqual(box['left'], 0, delta=.1)
            self.assertAlmostEqual(box['right'], 412, delta=.1)

    def test_docx_resize_preserves_reading_offset_without_chrome_scroll(self):
        page = self.load('basic.docx')
        page.evaluate('FolioOffice.goToPosition(1, false)')
        page.wait_for_timeout(100)
        before = page.locator('section.docx').nth(1).bounding_box()
        before_fraction = -before['y'] / before['height']
        self.clear_events(page)
        page.set_viewport_size({'width': 915, 'height': 412})
        page.wait_for_timeout(150)
        after = page.locator('section.docx').nth(1).bounding_box()
        self.assertAlmostEqual(-after['y'] / after['height'], before_fraction, delta=.01)
        self.assert_no_chrome_events(page)

    def test_pptx_centre_tap_is_single_event_without_navigation(self):
        page = self.load('basic.pptx')
        self.clear_events(page)
        page.mouse.click(206, 450)
        self.assertEqual(page.evaluate('events'), [{'type': 'tap'}])
        self.assertEqual(page.evaluate('document.getElementById("viewport").scrollLeft'), 0)

    def test_pptx_edge_taps_navigate_without_chrome_events(self):
        page = self.load('basic.pptx')
        self.clear_events(page)
        page.mouse.click(390, 450)
        page.wait_for_function('Math.abs(document.getElementById("viewport").scrollLeft - 412) < 1')
        page.wait_for_timeout(60)
        self.assertTrue(page.evaluate('events.some(e => e.type === "position" && e.current === 2)'))
        self.assert_no_chrome_events(page)
        page.mouse.click(20, 450)
        page.wait_for_function('document.getElementById("viewport").scrollLeft < 1')
        page.wait_for_timeout(60)
        self.assertTrue(page.evaluate('events.some(e => e.type === "position" && e.current === 1)'))
        self.assert_no_chrome_events(page)

    def test_pptx_first_and_last_edge_do_not_toggle_chrome(self):
        page = self.load('basic.pptx')
        self.clear_events(page)
        page.mouse.click(20, 450)
        page.wait_for_timeout(80)
        self.assert_no_chrome_events(page)
        page.evaluate('FolioOffice.goToPosition(1, false)')
        page.wait_for_timeout(80)
        self.clear_events(page)
        page.mouse.click(390, 450)
        page.wait_for_timeout(80)
        self.assert_no_chrome_events(page)
        self.assertAlmostEqual(page.evaluate('document.getElementById("viewport").scrollLeft'), 412, delta=1)

    def test_pptx_programmatic_navigation_does_not_emit_chrome_scroll(self):
        page = self.load('basic.pptx')
        self.clear_events(page)
        page.evaluate('FolioOffice.goToPosition(1, false)')
        # Explicit instant must override the viewport's CSS smooth behavior.
        self.assertAlmostEqual(page.evaluate('document.getElementById("viewport").scrollLeft'), 412, delta=1)
        page.wait_for_timeout(80)
        self.assert_no_chrome_events(page)

    def test_pptx_real_touch_swipe_only_changes_slide(self):
        page = self.load('basic.pptx')
        self.clear_events(page)
        session = page.context.new_cdp_session(page)
        session.send('Emulation.setTouchEmulationEnabled', {'enabled': True})
        session.send('Input.dispatchTouchEvent', {
            'type': 'touchStart', 'touchPoints': [{'x': 350, 'y': 450}],
        })
        for x in range(320, 19, -30):
            session.send('Input.dispatchTouchEvent', {
                'type': 'touchMove', 'touchPoints': [{'x': x, 'y': 450}],
            })
            page.wait_for_timeout(20)
        session.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
        page.wait_for_function('Math.abs(document.getElementById("viewport").scrollLeft - 412) < 1')
        page.wait_for_timeout(80)
        self.assertTrue(page.evaluate('events.some(e => e.type === "position" && e.current === 2)'))
        self.assert_no_chrome_events(page)
        session.detach()

    def test_pptx_two_finger_drag_never_navigates_or_toggles_chrome(self):
        page = self.load('basic.pptx')
        self.clear_events(page)
        session = page.context.new_cdp_session(page)
        session.send('Emulation.setTouchEmulationEnabled', {'enabled': True})
        session.send('Input.dispatchTouchEvent', {
            'type': 'touchStart', 'touchPoints': [{'x': 350, 'y': 450}, {'x': 250, 'y': 450}],
        })
        for x in (320, 290, 260, 230, 200):
            session.send('Input.dispatchTouchEvent', {
                'type': 'touchMove',
                'touchPoints': [{'x': x, 'y': 450}, {'x': x - 100, 'y': 450}],
            })
            page.wait_for_timeout(20)
        session.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
        page.wait_for_timeout(120)
        self.assertEqual(page.evaluate('document.getElementById("viewport").scrollLeft'), 0)
        self.assertEqual(page.evaluate('events'), [])
        session.detach()

    def test_pptx_drag_returning_to_origin_is_not_a_tap(self):
        page = self.load('basic.pptx')
        self.clear_events(page)
        self.pointer_sequence(page, [
            ['pointerdown', {}], ['pointermove', {'clientX': 100}],
            ['pointermove', {}], ['pointerup', {}],
        ])
        self.assert_no_chrome_events(page)

    def test_pptx_pointercancel_clears_tap_and_next_tap_still_works(self):
        page = self.load('basic.pptx')
        self.clear_events(page)
        self.pointer_sequence(page, [
            ['pointerdown', {}], ['pointercancel', {}], ['pointerup', {}],
        ])
        self.assert_no_chrome_events(page)
        page.mouse.click(206, 450)
        self.assertEqual(page.evaluate('events'), [{'type': 'tap'}])

    def test_pptx_multitouch_never_leaves_a_tap_candidate(self):
        page = self.load('basic.pptx')
        second = {'pointerId': 2, 'isPrimary': False, 'clientX': 300}
        for releases in [[second, {}], [{}, second]]:
            with self.subTest(releases=releases):
                self.clear_events(page)
                self.pointer_sequence(page, [
                    ['pointerdown', {}], ['pointerdown', second],
                    ['pointerup', releases[0]], ['pointerup', releases[1]],
                ])
                self.assert_no_chrome_events(page)
        page.mouse.click(206, 450)
        self.assertEqual(page.evaluate('events'), [{'type': 'tap'}])

    def test_pptx_long_press_does_not_toggle_chrome(self):
        page = self.load('basic.pptx')
        self.clear_events(page)
        page.mouse.move(206, 200)
        page.mouse.down()
        page.wait_for_timeout(550)
        page.mouse.up()
        self.assert_no_chrome_events(page)

    def test_pptx_secondary_click_does_not_toggle_chrome(self):
        page = self.load('basic.pptx')
        self.clear_events(page)
        page.mouse.click(206, 450, button='right')
        self.assert_no_chrome_events(page)

    def test_pptx_link_does_not_toggle_chrome(self):
        page = self.load('basic.pptx')
        page.evaluate("""() => {
          const link = document.createElement('a'); link.href = 'https://example.invalid';
          link.style.cssText = 'position:fixed;left:180px;top:435px;width:50px;height:30px';
          link.textContent = 'Link'; document.getElementById("viewport").appendChild(link);
        }""")
        self.clear_events(page)
        page.mouse.click(206, 450)
        self.assert_no_chrome_events(page)

    def test_pptx_selected_text_is_not_a_chrome_tap(self):
        page = self.load('basic.pptx')
        page.evaluate("""() => {
          const range = document.createRange();
          range.selectNodeContents(document.querySelector('.text-block'));
          getSelection().removeAllRanges(); getSelection().addRange(range);
        }""")
        self.clear_events(page)
        self.pointer_sequence(page, [['pointerdown', {}], ['pointerup', {}]])
        self.assert_no_chrome_events(page)

    def test_pptx_rotation_keeps_current_slide_without_chrome_events(self):
        page = self.load('basic.pptx')
        page.evaluate('FolioOffice.goToPosition(1, false)')
        page.wait_for_timeout(80)
        for width, height in [(915, 412), (360, 800), (412, 915)]:
            with self.subTest(width=width):
                self.clear_events(page)
                page.set_viewport_size({'width': width, 'height': height})
                page.wait_for_timeout(150)
                self.assertAlmostEqual(page.evaluate('document.getElementById("viewport").scrollLeft'), width, delta=1)
                self.assertTrue(page.evaluate('events.some(e => e.type === "position" && e.current === 2)'))
                self.assert_no_chrome_events(page)

    def test_pptx_disposed_document_ignores_pointer_events(self):
        page = self.load('basic.pptx')
        self.clear_events(page)
        page.evaluate('window.dispatchEvent(new Event("pagehide"))')
        self.pointer_sequence(page, [['pointerdown', {}], ['pointerup', {}]])
        self.assert_no_chrome_events(page)


if __name__ == '__main__':
    unittest.main(verbosity=2)

