"""Run the real APK-bundled renderers offline in Chromium.

Assets are injected without navigation so no Android, web server or document
network access is needed. This intentionally does not validate native CSP,
WebViewAssetLoader, fonts installed on Android, or Flutter integration.
"""
from __future__ import annotations
import base64
import re
from pathlib import Path

ASSETS = Path(__file__).resolve().parents[2] / 'android/app/src/main/assets/office'


def render(browser, fixture: Path, *, size=(412, 915), initial_script='', assets=ASSETS):
    page = browser.new_page(viewport={'width':size[0],'height':size[1]},device_scale_factor=1)
    page.errors = []
    page.on('pageerror', lambda error: page.errors.append(str(error)))
    fmt=fixture.suffix.lstrip('.')
    page.set_content(f'<body data-format="{fmt}"><main id="viewport"><div id="document"></div></main><div id="status">Opening…</div></body>')
    page.evaluate('''() => {
      window.events=[];
      window.FolioBridge={postMessage:value=>events.push(JSON.parse(value))};
      window.resourceCounts={created:0, revoked:0};
      const create=URL.createObjectURL.bind(URL),revoke=URL.revokeObjectURL.bind(URL);
      URL.createObjectURL=blob=>{resourceCounts.created++;return create(blob)};
      URL.revokeObjectURL=url=>{resourceCounts.revoked++;revoke(url)};
    }''')
    page.evaluate('''value => {
      const bytes=Uint8Array.from(atob(value), c=>c.charCodeAt(0));
      window.fixtureBuffer=bytes.buffer;
      window.fetch=async()=>new Response(bytes);
    }''',base64.b64encode(fixture.read_bytes()).decode())
    if initial_script: page.evaluate(initial_script)
    html=(assets/f'{fmt}.html').read_text(encoding='utf-8')
    for href in re.findall(r'<link[^>]+href="([^"]+)"',html): page.add_style_tag(content=(assets/href).read_text(encoding='utf-8'))
    for src in re.findall(r'<script[^>]+src="([^"]+)"',html):
        if src=='office.js' and fmt=='pptx': page.evaluate('() => {JSZipUtils.getBinaryContent=(url,callback)=>callback(null,fixtureBuffer)}')
        # The original host required a URL query; injected pages use data-format.
        code=(assets/src).read_text(encoding='utf-8').replace("const format = params.get('format');",f"const format = {fmt!r};")
        page.evaluate(code+'\n//# sourceURL='+src)
    page.wait_for_function('events.some(event=>event.type==="ready"||event.type==="error")',timeout=20000)
    page.wait_for_timeout(60)
    return page
