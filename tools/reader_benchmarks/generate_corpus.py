"""Deterministic Folio reader corpus generator.

Generates `test/fixtures/reader_corpus/` (24 content files + failure
fixtures) and `tools/reader_benchmarks/corpus_manifest.json` with SHA-256
per file. Every file is synthetic and original: no private documents and
no redistributable fonts. Re-running the script must reproduce byte-
identical files, so all zip timestamps are pinned and PDF metadata uses
reportlab's invariant mode.

Usage (from repo root):
    python tools/reader_benchmarks/generate_corpus.py
"""

from __future__ import annotations

import hashlib
import json
import re
import zipfile
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageDraw
from docx import Document
from docx.enum.section import WD_SECTION
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor
from lxml import etree as ET
from pptx import Presentation
from pptx.chart.data import CategoryChartData
from pptx.dml.color import RGBColor as SlideColor
from pptx.enum.chart import XL_CHART_TYPE
from pptx.enum.shapes import MSO_SHAPE
from pptx.util import Inches as SlideInches, Pt as SlidePt
from reportlab.lib.pagesizes import A4
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas as pdf_canvas

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "test" / "fixtures" / "reader_corpus"
MANIFEST = Path(__file__).resolve().parent / "corpus_manifest.json"

# WordprocessingML / DrawingML namespaces used by the raw-XML edit helpers.
W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
A = "http://schemas.openxmlformats.org/drawingml/2006/main"
P = "http://schemas.openxmlformats.org/presentationml/2006/main"
WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
REL = "http://schemas.openxmlformats.org/package/2006/relationships"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
ASVG = "http://schemas.microsoft.com/office/drawing/2016/SVG/main"

# Pinned zip timestamp: without this, python-docx/pptx stamp wall-clock time
# into every entry and regenerating the corpus would change all SHA-256s.
FIXED_ZIP_DATE = (1980, 1, 1, 0, 0, 0)

manifest: list[dict] = []


def normalize_zip(path: Path) -> None:
    """Rewrite every zip entry with a pinned timestamp (determinism)."""
    with zipfile.ZipFile(path) as archive:
        entries = [(info.filename, archive.read(info.filename), info.compress_type)
                   for info in archive.infolist()]
    with zipfile.ZipFile(path, "w") as archive:
        for name, data, compress_type in entries:
            info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_DATE)
            info.compress_type = compress_type
            info.external_attr = 0o600 << 16
            archive.writestr(info, data)


def normalize_embedded_workbooks(path: Path) -> None:
    """Pin timestamps inside embedded XLSX parts (python-pptx charts embed one).

    Both the zip entry dates and the dcterms:created/modified values inside
    docProps/core.xml carry wall-clock time; both are pinned so regeneration
    is byte-identical.
    """
    with zipfile.ZipFile(path) as archive:
        parts = {name: archive.read(name) for name in archive.namelist()}
    changed = False
    for name, data in list(parts.items()):
        if not name.endswith(".xlsx"):
            continue
        buffer = BytesIO()
        with zipfile.ZipFile(BytesIO(data)) as inner:
            entries = [(info.filename, inner.read(info.filename), info.compress_type)
                       for info in inner.infolist()]
        with zipfile.ZipFile(buffer, "w") as inner:
            for entry_name, entry_data, compress_type in entries:
                if entry_name == "docProps/core.xml":
                    entry_data = re.sub(
                        rb"(<dcterms:(?:created|modified)[^>]*>)[^<]*(</dcterms:\w+>)",
                        rb"\g<1>2010-01-01T00:00:00Z\g<2>",
                        entry_data,
                    )
                info = zipfile.ZipInfo(entry_name, date_time=FIXED_ZIP_DATE)
                info.compress_type = compress_type
                info.external_attr = 0o600 << 16
                inner.writestr(info, entry_data)
        parts[name] = buffer.getvalue()
        changed = True
    if not changed:
        return
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in parts.items():
            archive.writestr(name, data)
    normalize_zip(path)


def edit_zip(source: Path, destination: Path, edit) -> None:
    with zipfile.ZipFile(source) as archive:
        parts = {name: archive.read(name) for name in archive.namelist()}
    edit(parts)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in parts.items():
            archive.writestr(name, data)
    normalize_zip(destination)


def xml_edit(parts: dict[str, bytes], path: str, edit) -> None:
    root = ET.fromstring(parts[path])
    edit(root)
    parts[path] = ET.tostring(root, xml_declaration=True, encoding="UTF-8", standalone=True)


def register(parts: dict[str, bytes], name: str, data: bytes, *, content_type: str) -> None:
    """Add a package part plus its [Content_Types].xml override."""
    parts[name] = data
    types = ET.fromstring(parts["[Content_Types].xml"])
    ET.SubElement(
        types,
        "{http://schemas.openxmlformats.org/package/2006/content-types}Override",
        PartName=f"/{name}",
        ContentType=content_type,
    )
    parts["[Content_Types].xml"] = ET.tostring(
        types, xml_declaration=True, encoding="UTF-8", standalone=True
    )


def gradient_png(size: tuple[int, int], left: tuple[int, int, int], right: tuple[int, int, int]) -> bytes:
    """Deterministic horizontal gradient: no clock, no RNG, no fonts."""
    width, height = size
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    for x in range(width):
        t = x / max(1, width - 1)
        colour = tuple(round(l + (r - l) * t) for l, r in zip(left, right))
        draw.line([(x, 0), (x, height)], fill=colour)
    buffer = BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def gradient_jpeg(size: tuple[int, int], seed: int) -> bytes:
    """Large deterministic photo-like image (banding pattern, no fonts)."""
    width, height = size
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    for y in range(0, height, 8):
        shade = (seed * 37 + y * 5) % 256
        draw.rectangle((0, y, width, y + 7), fill=(shade, (shade + 60) % 256, (shade + 120) % 256))
    for x in range(0, width, 120):
        draw.line([(x, 0), (x, height)], fill=(255, 255, 255), width=2)
    buffer = BytesIO()
    image.save(buffer, format="JPEG", quality=85)
    return buffer.getvalue()


def record(name: str, format: str, *, group: str, pages: int | None = None,
           slides: int | None = None, expect: list[str], notes: str,
           reference: str = "не оценено (нет экспорта из приложения-источника)") -> None:
    path = OUTPUT / name
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    entry: dict = {
        "file": f"test/fixtures/reader_corpus/{name}",
        "format": format,
        "group": group,
        "sizeBytes": path.stat().st_size,
        "sha256": digest,
        "origin": "синтетический, детерминированно сгенерирован tools/reader_benchmarks/generate_corpus.py",
        "license": "оригинальный синтетический контент; сторонние шрифты не встроены",
        "expect": {"textOrder": expect},
        "notes": notes,
        "reference": reference,
    }
    if pages is not None:
        entry["pages"] = pages
    if slides is not None:
        entry["slides"] = slides
    manifest.append(entry)


# --------------------------------------------------------------------------
# PDF
# --------------------------------------------------------------------------

def generate_pdf_corpus() -> None:
    def text_pdf(target: Path) -> None:
        pdf = pdf_canvas.Canvas(str(target), pagesize=A4, invariant=1, pageCompression=1)
        width, height = A4
        for page in range(1, 25):
            pdf.setFont("Helvetica-Bold", 18)
            pdf.drawString(54, height - 62, f"Corpus PDF fixture - page {page}")
            pdf.setFont("Helvetica", 11)
            for line in range(22):
                marker = " CORPUS-PDF-01" if line in (3, 17) else ""
                pdf.drawString(54, height - 98 - line * 28,
                               f"Line {line + 1}: continuous scroll and lazy render check.{marker}")
            pdf.setFont("Helvetica", 9)
            pdf.drawCentredString(width / 2, 28, f"{page} / 24")
            pdf.showPage()
        pdf.save()

    def image_only_pdf(target: Path) -> None:
        image = Image.open(BytesIO(gradient_jpeg((1600, 2263), 7)))
        pdf = pdf_canvas.Canvas(str(target), pagesize=A4, invariant=1, pageCompression=1)
        width, height = A4
        for page in range(1, 5):
            pdf.drawImage(ImageReader(image), 0, 0, width=width, height=height)
            pdf.showPage()
        pdf.save()

    text_pdf(OUTPUT / "text_searchable_24p.pdf")
    image_only_pdf(OUTPUT / "image_only_4p.pdf")
    record("text_searchable_24p.pdf", "pdf", group="content", pages=24,
           expect=["Corpus PDF fixture - page 1", "CORPUS-PDF-01", "page 24 / 24"],
           notes="Эталон задаётся самим генератором (текст из 24 страниц, метки на строках 4 и 18).")
    record("image_only_4p.pdf", "pdf", group="content", pages=4,
           expect=[],
           notes="Документ без текстового слоя: поиск обязан сообщить отсутствие слоя, а не «ничего не найдено».")


# --------------------------------------------------------------------------
# DOCX
# --------------------------------------------------------------------------

def _docx_section_defaults(doc: Document) -> None:
    section = doc.sections[0]
    section.page_width, section.page_height = Inches(8.5), Inches(11)


def generate_docx_corpus() -> None:
    basic = Document()
    _docx_section_defaults(basic)
    basic.sections[0].header.paragraphs[0].text = "Header – Колонтитул CORPUS-DOCX-01"
    basic.sections[0].footer.paragraphs[0].text = "Footer"
    background = OxmlElement("w:background")
    background.set(qn("w:color"), "FFF4CC")
    basic._element.insert(0, background)
    basic.add_heading("Word rendering", 0)
    basic.add_paragraph("Привет мир. CORPUS-DOCX-01 A page must fit mobile width and preserve its background.")
    basic.add_picture(BytesIO(gradient_png((400, 200), (255, 0, 0), (0, 0, 255))), width=Inches(4))
    for i in range(45):
        basic.add_paragraph(f"Paragraph-{i + 1:02d}: Text with a stable line spacing. Текст на русском языке. " * 2)
    basic.save(OUTPUT / "docx_basic.docx")
    normalize_zip(OUTPUT / "docx_basic.docx")

    long_doc = Document()
    _docx_section_defaults(long_doc)
    long_doc.add_heading("Long document CORPUS-DOCX-02", 0)
    for i in range(140):
        long_doc.add_paragraph(
            f"Block-{i + 1:03d}: continuity across page breaks. Каждый блок занимает одну–две строки."
        )
    long_doc.save(OUTPUT / "docx_long_text.docx")
    normalize_zip(OUTPUT / "docx_long_text.docx")

    table_doc = Document()
    _docx_section_defaults(table_doc)
    table_doc.sections[0].page_height = Inches(6)
    table_doc.add_paragraph("Tables with merges CORPUS-DOCX-03")
    table = table_doc.add_table(rows=40, cols=3)
    table.style = "Table Grid"
    for i, row in enumerate(table.rows):
        row.cells[0].text = f"Row-{i:02d}"
        row.cells[1].text = "Value column with enough words to force a wrapped line inside the cell"
        row.cells[2].text = f"Cell-{i:02d}"
    table.cell(5, 0).merge(table.cell(9, 0))
    table.cell(15, 1).merge(table.cell(15, 2))
    table_doc.save(OUTPUT / "docx_table_merges.docx")
    normalize_zip(OUTPUT / "docx_table_merges.docx")

    columns = Document()
    _docx_section_defaults(columns)
    columns.sections[0]._sectPr.find(qn("w:cols")).set(qn("w:num"), "2")
    columns.add_paragraph("Two-column section CORPUS-DOCX-04")
    for i in range(30):
        columns.add_paragraph(f"Column text {i} " * 8)
    columns.add_section(WD_SECTION.CONTINUOUS)
    columns.sections[-1]._sectPr.find(qn("w:cols")).set(qn("w:num"), "1")
    columns.add_paragraph("Continuous single-column section preserved")
    columns.save(OUTPUT / "docx_columns_sections.docx")
    normalize_zip(OUTPUT / "docx_columns_sections.docx")

    # Footnotes need a part python-docx cannot author: assemble it by raw XML
    # over the saved package (separator notes first, then the real footnote).
    edit_zip(OUTPUT / "docx_basic.docx", OUTPUT / "docx_headers_footnotes.docx", lambda parts: _add_footnotes(parts))

    lists_doc = Document()
    _docx_section_defaults(lists_doc)
    lists_doc.add_heading("Lists CORPUS-DOCX-06", 0)
    for i in range(3):
        lists_doc.add_paragraph(f"Numbered item {i + 1}", style="List Number")
    for i in range(3):
        lists_doc.add_paragraph(f"Bullet item {i + 1}", style="List Bullet")
    lists_doc.add_paragraph("Nested bullet 2.1", style="List Bullet 2")
    lists_doc.add_paragraph("Nested bullet 2.2", style="List Bullet 2")
    lists_doc.add_paragraph("Closing numbered item", style="List Number")
    lists_doc.save(OUTPUT / "docx_lists.docx")
    normalize_zip(OUTPUT / "docx_lists.docx")

    float_doc = Document()
    _docx_section_defaults(float_doc)
    float_doc.add_heading("Inline and floating images CORPUS-DOCX-07", 0)
    float_doc.add_picture(BytesIO(gradient_png((400, 200), (0, 255, 0), (255, 255, 0))), width=Inches(3))
    float_doc.add_paragraph("Text after the inline image.")
    for i in range(10):
        float_doc.add_paragraph(f"Body paragraph {i + 1} for the floating image to overlap.")
    float_doc.save(OUTPUT / "docx_images_float_inline.docx")
    anchor_picture(OUTPUT / "docx_images_float_inline.docx")

    rtl = Document()
    _docx_section_defaults(rtl)
    rtl.add_heading("Bidi and emoji CORPUS-DOCX-08", 0)
    rtl.add_paragraph("Mixed line: Привет 🚀 мир 🎉 and English.")
    rtl.add_paragraph("مرحبا بالعالم هذا نص عربي طويل للتغطية CORPUS-DOCX-08")
    rtl.add_paragraph("שלום עולם, פסקה בעברית")
    rtl.save(OUTPUT / "docx_rtl_emoji.docx")
    make_paragraphs_rtl(OUTPUT / "docx_rtl_emoji.docx")

    fonts = Document()
    _docx_section_defaults(fonts)
    fonts.add_heading("Missing fonts CORPUS-DOCX-09", 0)
    styled = fonts.add_paragraph()
    run = styled.add_run("This run requests 'No Such Font XYZ' and must fall back safely.")
    run.font.size = Pt(16)
    run.font.name = "No Such Font XYZ"
    fonts.add_paragraph("Follow-up paragraph in the default font CORPUS-DOCX-09.")
    fonts.save(OUTPUT / "docx_missing_font.docx")
    normalize_zip(OUTPUT / "docx_missing_font.docx")

    big = Document()
    _docx_section_defaults(big)
    big.add_heading("Large images CORPUS-DOCX-10", 0)
    big.add_picture(BytesIO(gradient_jpeg((2400, 1600), 3)), width=Inches(6))
    big.add_paragraph("Between two large images CORPUS-DOCX-10.")
    big.add_picture(BytesIO(gradient_jpeg((2400, 1600), 9)), width=Inches(6))
    big.save(OUTPUT / "docx_big_images.docx")
    normalize_zip(OUTPUT / "docx_big_images.docx")

    rows = [
        ("docx_basic.docx", "docx", "content", ["CORPUS-DOCX-01", "Привет мир", "Header – Колонтитул CORPUS-DOCX-01"],
         "Базовый поток: заголовок, кириллица, фоновый цвет страницы, встроенное изображение, колонтитулы."),
        ("docx_long_text.docx", "docx", "content", ["CORPUS-DOCX-02", "Block-001", "Block-140"],
         "Длинный документ: непрерывность пагинации и порядок блоков 1..140."),
        ("docx_table_merges.docx", "docx", "content", ["CORPUS-DOCX-03", "Row-00", "Row-39"],
         "Таблица 40×3: вертикальное слияние строк 6–10 первого столбца и горизонтальное слияние в строке 16."),
        ("docx_columns_sections.docx", "docx", "content", ["CORPUS-DOCX-04", "Continuous single-column section preserved"],
         "Две колонки, затем непрерывная секция с одной колонкой."),
        ("docx_headers_footnotes.docx", "docx", "content", ["CORPUS-DOCX-01", "CORPUS-DOCX-05 footnote"],
         "Колонтитулы + сноска на первой странице; сноска добавлена поверх docx_basic."),
        ("docx_lists.docx", "docx", "content", ["CORPUS-DOCX-06", "Numbered item 1", "Nested bullet 2.2"],
         "Многоуровневые нумерованные и маркированные списки."),
        ("docx_images_float_inline.docx", "docx", "content", ["CORPUS-DOCX-07", "Text after the inline image"],
         "Встроенное изображение + привязанное плавающее изображение behindDoc с позиционированием от страницы."),
        ("docx_rtl_emoji.docx", "docx", "content", ["CORPUS-DOCX-08", "مرحبا بالعالم"],
         "RTL-абзацы (арабский, иврит) с w:bidi/w:rtl, эмодзи, смешанное направление."),
        ("docx_missing_font.docx", "docx", "content", ["CORPUS-DOCX-09", "No Such Font XYZ"],
         "Запрос несуществующего шрифта: безопасный fallback, а не срыв вёрстки."),
        ("docx_big_images.docx", "docx", "content", ["CORPUS-DOCX-10"],
         "Два больших JPEG 2400×1600: память и задержка первого открытия."),
    ]
    for name, format, group, expect, notes in rows:
        record(name, format, group=group, expect=expect, notes=notes)


def _add_footnotes(parts: dict[str, bytes]) -> None:
    footnotes = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:footnotes xmlns:w="{W}">
  <w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>
  <w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>
  <w:footnote w:id="1"><w:p><w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:footnoteRef/></w:r>
    <w:r><w:t xml:space="preserve"> CORPUS-DOCX-05 footnote text</w:t></w:r></w:p></w:footnote>
</w:footnotes>'''
    register(parts, "word/footnotes.xml", footnotes.encode("utf-8"),
             content_type="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml")

    def rels(root):
        ET.SubElement(root, f"{{{REL}}}Relationship",
                      Id="rIdFootnotes", Type=f"{R}/footnotes", Target="footnotes.xml")

    xml_edit(parts, "word/_rels/document.xml.rels", rels)

    def document(root):
        paragraph = root.find(f".//{{{W}}}body/{{{W}}}p")
        reference_run = ET.Element(f"{{{W}}}r")
        props = ET.SubElement(reference_run, f"{{{W}}}rPr")
        ET.SubElement(props, f"{{{W}}}vertAlign", {f"{{{W}}}val": "superscript"})
        ET.SubElement(reference_run, f"{{{W}}}footnoteReference", {f"{{{W}}}id": "1"})
        paragraph.insert(1, reference_run)

    xml_edit(parts, "word/document.xml", document)


def anchor_picture(path: Path) -> None:
    def anchor(parts):
        def document(root):
            inline = root.find(f".//{{{WP}}}inline")
            inline.tag = f"{{{WP}}}anchor"
            inline.set("behindDoc", "1")
            inline.set("simplePos", "0")
            for name, value in [("positionH", "3657600"), ("positionV", "914400")]:
                axis = ET.SubElement(inline, f"{{{WP}}}{name}", relativeFrom="page")
                ET.SubElement(axis, f"{{{WP}}}posOffset").text = value
            ET.SubElement(inline, f"{{{WP}}}wrapNone")

        xml_edit(parts, "word/document.xml", document)

    edit_zip(path, path, anchor)


def make_paragraphs_rtl(path: Path) -> None:
    def rtl(parts):
        def document(root):
            for paragraph in root.findall(f".//{{{W}}}body/{{{W}}}p")[2:4]:
                props = paragraph.find(f"{{{W}}}pPr")
                if props is None:
                    props = ET.Element(f"{{{W}}}pPr")
                    paragraph.insert(0, props)
                ET.SubElement(props, f"{{{W}}}bidi")
                for run in paragraph.findall(f"{{{W}}}r"):
                    run_props = run.find(f"{{{W}}}rPr")
                    if run_props is None:
                        run_props = ET.Element(f"{{{W}}}rPr")
                        run.insert(0, run_props)
                    ET.SubElement(run_props, f"{{{W}}}rtl")

        xml_edit(parts, "word/document.xml", document)

    edit_zip(path, path, rtl)


# --------------------------------------------------------------------------
# PPTX
# --------------------------------------------------------------------------

def _base_deck() -> Presentation:
    deck = Presentation()
    deck.slide_width, deck.slide_height = SlideInches(10), SlideInches(5.625)
    return deck


def generate_pptx_corpus() -> None:
    deck = _base_deck()
    image_path = OUTPUT / "_tmp_two_colors.png"
    Image.open(BytesIO(gradient_png((400, 200), (255, 0, 0), (0, 0, 255)))).save(image_path)
    first = deck.slides.add_slide(deck.slide_layouts[6])
    first.background.fill.solid()
    first.background.fill.fore_color.rgb = SlideColor.from_string("16324F")
    title = first.shapes.add_textbox(SlideInches(.5), SlideInches(.3), SlideInches(9), SlideInches(.7))
    paragraph = title.text_frame.paragraphs[0]
    paragraph.text = "First slide / Первый слайд CORPUS-PPTX-01"
    paragraph.font.size, paragraph.font.color.rgb = SlidePt(30), SlideColor(255, 255, 255)
    picture = first.shapes.add_picture(str(image_path), SlideInches(.5), SlideInches(1.5), SlideInches(3), SlideInches(2))
    picture.crop_left = .5
    group = first.shapes.add_group_shape()
    for x, rgb in [(1, (0, 255, 0)), (2, (255, 255, 0))]:
        shape = group.shapes.add_shape(MSO_SHAPE.RECTANGLE, SlideInches(x), SlideInches(1), SlideInches(1), SlideInches(1))
        shape.fill.solid()
        shape.fill.fore_color.rgb = SlideColor(*rgb)
        shape.line.fill.background()
    group.left, group.top, group.width, group.height = SlideInches(5), SlideInches(1.5), SlideInches(4), SlideInches(2)
    second = deck.slides.add_slide(deck.slide_layouts[6])
    second.shapes.add_textbox(SlideInches(1), SlideInches(1), SlideInches(8), SlideInches(1)).text = \
        "Second slide with default white background"
    second.shapes.add_picture(str(image_path), SlideInches(1), SlideInches(2), SlideInches(2), SlideInches(1))
    third = deck.slides.add_slide(deck.slide_layouts[6])
    third.background.fill.solid()
    third.background.fill.fore_color.rgb = SlideColor.from_string("0B2E13")
    third.shapes.add_textbox(SlideInches(1), SlideInches(1), SlideInches(8), SlideInches(1)).text = \
        "Third slide with dark theme background"
    deck.save(OUTPUT / "pptx_basic_theme.pptx")
    normalize_zip(OUTPUT / "pptx_basic_theme.pptx")

    many = _base_deck()
    for i in range(60):
        slide = many.slides.add_slide(many.slide_layouts[6])
        box = slide.shapes.add_textbox(SlideInches(.5), SlideInches(2.4), SlideInches(9), SlideInches(.8))
        box.text_frame.paragraphs[0].text = f"Slide {i + 1} of 60 CORPUS-PPTX-02"
    many.save(OUTPUT / "pptx_many_slides.pptx")
    normalize_zip(OUTPUT / "pptx_many_slides.pptx")

    table_deck = _base_deck()
    slide = table_deck.slides.add_slide(table_deck.slide_layouts[6])
    table = slide.shapes.add_table(5, 3, SlideInches(1), SlideInches(1), SlideInches(7), SlideInches(3)).table
    for row in range(5):
        for column in range(3):
            table.cell(row, column).text = f"Cell {row},{column} CORPUS-PPTX-03"
            table.cell(row, column).fill.solid()
            table.cell(row, column).fill.fore_color.rgb = SlideColor.from_string("DDDD88")
    table_deck.save(OUTPUT / "pptx_table.pptx")
    normalize_zip(OUTPUT / "pptx_table.pptx")

    chart_deck = _base_deck()
    slide = chart_deck.slides.add_slide(chart_deck.slide_layouts[6])
    data = CategoryChartData()
    data.categories = ["Alpha", "Beta", "Gamma"]
    data.add_series("Values", (3, 7, 5))
    slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, SlideInches(1), SlideInches(1),
                           SlideInches(7), SlideInches(3.5), data)
    caption = slide.shapes.add_textbox(SlideInches(1), SlideInches(4.8), SlideInches(7), SlideInches(.5))
    caption.text_frame.paragraphs[0].text = "Chart preserved check CORPUS-PPTX-04"
    chart_deck.save(OUTPUT / "pptx_chart.pptx")
    normalize_embedded_workbooks(OUTPUT / "pptx_chart.pptx")
    normalize_zip(OUTPUT / "pptx_chart.pptx")

    svg_deck = _base_deck()
    slide = svg_deck.slides.add_slide(svg_deck.slide_layouts[6])
    slide.shapes.add_picture(str(image_path), SlideInches(2), SlideInches(1.5), SlideInches(4), SlideInches(2))
    label = slide.shapes.add_textbox(SlideInches(2), SlideInches(3.8), SlideInches(6), SlideInches(.5))
    label.text_frame.paragraphs[0].text = "SVG image with PNG fallback CORPUS-PPTX-05"
    svg_deck.save(OUTPUT / "pptx_svg_image.pptx")
    attach_svg(OUTPUT / "pptx_svg_image.pptx")

    rotated = Presentation(str(OUTPUT / "pptx_basic_theme.pptx"))
    rotated.save(OUTPUT / "_tmp_rotated_source.pptx")
    normalize_zip(OUTPUT / "_tmp_rotated_source.pptx")
    edit_zip(OUTPUT / "_tmp_rotated_source.pptx", OUTPUT / "pptx_rotated_group.pptx", rotate_group)

    gradient_deck = _base_deck()
    slide = gradient_deck.slides.add_slide(gradient_deck.slide_layouts[6])
    slide.background.fill.solid()  # ensures the <p:bg> element exists
    background = slide.background._cSld.find(f"{{{P}}}bg")
    background_pr = background.find(f"{{{P}}}bgPr")
    for element in list(background_pr):
        background_pr.remove(element)
    fill = ET.SubElement(background_pr, f"{{{A}}}gradFill")
    stops = ET.SubElement(fill, f"{{{A}}}gsLst")
    for position, colour in [("0", "FF0000"), ("100000", "0000FF")]:
        stop = ET.SubElement(stops, f"{{{A}}}gs", pos=position)
        ET.SubElement(stop, f"{{{A}}}srgbClr", val=colour)
    ET.SubElement(fill, f"{{{A}}}lin", ang="0", scaled="1")
    slide.shapes.add_textbox(SlideInches(1), SlideInches(2.5), SlideInches(8), SlideInches(.8)).text = \
        "Gradient background slide CORPUS-PPTX-07"
    second_slide = gradient_deck.slides.add_slide(gradient_deck.slide_layouts[6])
    second_slide.shapes.add_picture(str(image_path), SlideInches(3), SlideInches(2), SlideInches(4), SlideInches(2))
    second_note = second_slide.shapes.add_textbox(SlideInches(1), SlideInches(4.5), SlideInches(8), SlideInches(.5))
    second_note.text_frame.paragraphs[0].text = "Image slide above gradient master CORPUS-PPTX-07"
    gradient_deck.save(OUTPUT / "pptx_gradient_bg.pptx")
    normalize_zip(OUTPUT / "pptx_gradient_bg.pptx")

    runs = _base_deck()
    slide = runs.slides.add_slide(runs.slide_layouts[6])
    box = slide.shapes.add_textbox(SlideInches(.5), SlideInches(1.5), SlideInches(9), SlideInches(2.5))
    frame = box.text_frame
    frame.word_wrap = True
    paragraph = frame.paragraphs[0]
    paragraph.text = "Default run then emphasised run CORPUS-PPTX-08"
    run = paragraph.add_run()
    run.text = " Bold italic tail."
    run.font.bold, run.font.italic = True, True
    second_para = frame.add_paragraph()
    second_para.text = "Переносимый текст с длинными словами для проверки переноса " * 3
    runs.save(OUTPUT / "pptx_text_runs.pptx")
    normalize_zip(OUTPUT / "pptx_text_runs.pptx")
    edit_zip(OUTPUT / "pptx_text_runs.pptx", OUTPUT / "pptx_text_runs.pptx", tweak_text_properties)

    image_path.unlink()
    (OUTPUT / "_tmp_rotated_source.pptx").unlink()

    rows = [
        ("pptx_basic_theme.pptx", "pptx", "content", ["CORPUS-PPTX-01", "Second slide", "Third slide with dark theme background"],
         "Тема, группа фигур, обрезанное изображение, тёмный фон третьего слайда.", 3),
        ("pptx_many_slides.pptx", "pptx", "content", ["CORPUS-PPTX-02", "Slide 1 of 60", "Slide 60 of 60"],
         "Много слайдов: порядок и подписи 1..60.", 60),
        ("pptx_table.pptx", "pptx", "content", ["CORPUS-PPTX-03", "Cell 4,2"],
         "Таблица 5×3 с заливкой ячеек.", 1),
        ("pptx_chart.pptx", "pptx", "content", ["CORPUS-PPTX-04"],
         "Диаграмма (графический фрейм): сохранность объекта, а не точная отрисовка.", 1),
        ("pptx_svg_image.pptx", "pptx", "content", ["CORPUS-PPTX-05"],
         "svgBlip поверх PNG-fallback: движок без SVG обязан показать fallback.", 1),
        ("pptx_rotated_group.pptx", "pptx", "content", ["CORPUS-PPTX-01"],
         "Поворот группы на 90° и отражения внутри (rot/flipH/flipV).", 3),
        ("pptx_gradient_bg.pptx", "pptx", "content", ["CORPUS-PPTX-07"],
         "Градиентный фон слайда (gradFill вместо solid).", 2),
        ("pptx_text_runs.pptx", "pptx", "content", ["CORPUS-PPTX-08"],
         "Смешанные runs (bold/italic), normAutofit fontScale, перенос текста.", 1),
    ]
    for name, format, group, expect, notes, slides in rows:
        record(name, format, group=group, slides=slides, expect=expect, notes=notes)


def rotate_group(parts: dict[str, bytes]) -> None:
    def slide_xml(root):
        group = root.find(f".//{{{P}}}grpSp/{{{P}}}grpSpPr/{{{A}}}xfrm")
        group.set("rot", "5400000")
        group.set("flipH", "1")
        picture = root.find(f".//{{{P}}}pic/{{{P}}}spPr/{{{A}}}xfrm")
        picture.set("flipV", "1")

    xml_edit(parts, "ppt/slides/slide1.xml", slide_xml)


def tweak_text_properties(parts: dict[str, bytes]) -> None:
    def slide_xml(root):
        paragraph = root.find(f".//{{{P}}}sp/{{{P}}}txBody/{{{A}}}p")
        default = paragraph.find(f"{{{A}}}pPr/{{{A}}}defRPr")
        if default is not None:
            default.set("kern", "1200")
        body = root.find(f".//{{{P}}}sp/{{{P}}}txBody/{{{A}}}bodyPr")
        ET.SubElement(body, f"{{{A}}}normAutofit", fontScale="92500")

    xml_edit(parts, "ppt/slides/slide1.xml", slide_xml)


def attach_svg(path: Path) -> None:
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200">'
        '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0">'
        '<stop offset="0" stop-color="#00C2FF"/><stop offset="1" stop-color="#FF00C8"/>'
        "</linearGradient></defs>"
        '<rect width="400" height="200" fill="url(#g)"/>'
        '<circle cx="200" cy="100" r="70" fill="#111111"/></svg>'
    ).encode("utf-8")

    def extend(parts):
        parts["ppt/media/image2.svg"] = svg

        def rels(root):
            ET.SubElement(root, f"{{{REL}}}Relationship", Id="rIdSvgImage",
                          Type=f"{R}/image", Target="../media/image2.svg")

        xml_edit(parts, "ppt/slides/_rels/slide1.xml.rels", rels)

        def slide_xml(root):
            blip = root.find(f".//{{{P}}}pic/{{{P}}}blipFill/{{{A}}}blip")
            extension = ET.SubElement(ET.SubElement(blip, f"{{{A}}}extLst"), f"{{{A}}}ext",
                                      uri="{96DAC541-7B7A-43D3-8B79-37D633B846F1}")
            svg_blip = ET.SubElement(extension, f"{{{ASVG}}}svgBlip", {f"{{{R}}}embed": "rIdSvgImage"})

            assert svg_blip is not None

        xml_edit(parts, "ppt/slides/slide1.xml", slide_xml)

        types = ET.fromstring(parts["[Content_Types].xml"])
        ET.SubElement(
            types,
            "{http://schemas.openxmlformats.org/package/2006/content-types}Default",
            Extension="svg",
            ContentType="image/svg+xml",
        )
        parts["[Content_Types].xml"] = ET.tostring(
            types, xml_declaration=True, encoding="UTF-8", standalone=True
        )

    edit_zip(path, path, extend)


# --------------------------------------------------------------------------
# TXT / Markdown
# --------------------------------------------------------------------------

def generate_text_corpus() -> None:
    lines = [f"Line {i + 1:04d}: UTF-8 plain text page flow CORPUS-TXT-01" for i in range(600)]
    (OUTPUT / "sample_long.txt").write_bytes(("\n".join(lines) + "\n").encode("utf-8"))
    utf16 = "UTF-16 with BOM CORPUS-TXT-02\nВторая строка на русском.\nThird line.\n"
    (OUTPUT / "sample_utf16_bom.txt").write_bytes(utf16.encode("utf-16"))

    nested = """# Nested markdown CORPUS-MD-01

Paragraph with **bold**, *italic*, `inline code` and [a link](https://example.com).

## Lists

- item one
- item two
  - nested item

## Code fence

```dart
void main() => print('CORPUS-MD-01 fence');
```

## Table

| Col A | Col B |
| ----- | ----- |
| 1     | 2     |

> Blockquote with emoji 🚀 и кириллицей.
"""
    (OUTPUT / "sample_nested.md").write_bytes(nested.encode("utf-8"))
    long_md = "\n\n".join(
        f"## Section {i + 1} CORPUS-MD-02\n\nParagraph {i + 1} with enough text to fill several screens of reading."
        for i in range(120)
    )
    (OUTPUT / "sample_long.md").write_bytes((long_md + "\n").encode("utf-8"))

    rows = [
        ("sample_long.txt", "txt", "content", ["CORPUS-TXT-01", "Line 0600"],
         "600 строк: потоковая прокрутка, процент позиции."),
        ("sample_utf16_bom.txt", "txt", "content", ["CORPUS-TXT-02", "Вторая строка"],
         "UTF-16 с BOM: ветка декодера ридера."),
        ("sample_nested.md", "markdown", "content", ["CORPUS-MD-01", "Blockquote"],
         "Вложенные конструкции markdown: выделение/поиск поверх кода, таблиц, цитат."),
        ("sample_long.md", "markdown", "content", ["CORPUS-MD-02", "Section 120"],
         "120 секций: прокрутка и выделение в длинном документе."),
    ]
    for name, format, group, expect, notes in rows:
        record(name, format, group=group, expect=expect, notes=notes)


# --------------------------------------------------------------------------
# Failure fixtures
# --------------------------------------------------------------------------

def generate_failure_corpus() -> None:
    failure = OUTPUT / "failure"
    failure.mkdir(exist_ok=True)

    # A zip cut in the middle of the central directory: must fail closed.
    payload = bytearray((OUTPUT / "pptx_basic_theme.pptx").read_bytes())
    truncated = failure / "corrupt_truncated.pptx"
    truncated.write_bytes(bytes(payload[: len(payload) * 2 // 3]))

    def corrupt_xml(parts: dict[str, bytes]) -> None:
        parts["[Content_Types].xml"] = b"<Types xmlns=\"broken\""

    edit_zip(OUTPUT / "pptx_basic_theme.pptx", failure / "corrupt_xml.pptx", corrupt_xml)

    # 600 MB of zeros compress to ~600 KB: an engine that eagerly inflates
    # every part spikes memory; a streaming engine renders normally.
    def bomb(parts: dict[str, bytes]) -> None:
        parts["word/media/huge.bin"] = b"\x00" * (600 * 1024 * 1024)

    edit_zip(OUTPUT / "docx_basic.docx", failure / "zip_bomb.docx", bomb)

    def missing_media(parts: dict[str, bytes]) -> None:
        parts.pop("word/media/image1.png")

        def document(root):
            # Keep the drawing but relabel it so the expectation is explicit.
            pass

        xml_edit(parts, "word/document.xml", document)

    edit_zip(OUTPUT / "docx_basic.docx", failure / "missing_image_rel.docx", missing_media)

    def external_links(parts: dict[str, bytes]) -> None:
        def rels(root):
            ET.SubElement(root, f"{{{REL}}}Relationship", Id="rIdLink1",
                          Type=f"{R}/hyperlink",
                          Target="https://offline.example.com/page", TargetMode="External")

        xml_edit(parts, "word/_rels/document.xml.rels", rels)

        def document(root):
            paragraph = root.find(f".//{{{W}}}body/{{{W}}}p")
            link = ET.Element(f"{{{W}}}hyperlink", {f"{{{R}}}id": "rIdLink1"})
            run = ET.SubElement(link, f"{{{W}}}r")
            text = ET.SubElement(run, f"{{{W}}}t")
            text.text = "External link CORPUS-FAIL-EXT"
            paragraph.append(link)

        xml_edit(parts, "word/document.xml", document)

    edit_zip(OUTPUT / "docx_basic.docx", failure / "external_links.docx", external_links)

    rows = [
        ("failure/corrupt_truncated.pptx", "pptx", ["не оценено: ожидание — отказ с понятной ошибкой"],
         "ZIP усечён в центральном каталоге: не зависать, не терять данные молча."),
        ("failure/corrupt_xml.pptx", "pptx", ["не оценено: ожидание — отказ с понятной ошибкой"],
         "[Content_Types].xml повреждён."),
        ("failure/zip_bomb.docx", "docx", ["CORPUS-DOCX-01"],
         "600 МБ нулей внутри пакета: движок с жадной распаковкой обязан иметь лимит."),
        ("failure/missing_image_rel.docx", "docx", ["CORPUS-DOCX-01"],
         "Ссылка на отсутствующее изображение: деградация с плейсхолдером, не срыв открытия."),
        ("failure/external_links.docx", "docx", ["External link CORPUS-FAIL-EXT"],
         "Внешняя hyperlink-связь: офлайн-режим не делает сетевых запросов; переход — только явное действие."),
    ]
    for name, format, expect, notes in rows:
        record(name, format, group="failure", expect=expect, notes=notes)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    manifest.clear()
    generate_pdf_corpus()
    generate_docx_corpus()
    generate_pptx_corpus()
    generate_text_corpus()
    generate_failure_corpus()
    manifest.sort(key=lambda entry: entry["file"])
    document = {
        "version": 1,
        "generatedBy": "tools/reader_benchmarks/generate_corpus.py",
        "determinism": "zip-времена зафиксированы, PDF в invariant-режиме; повторный прогон воспроизводит SHA-256",
        "deviceClasses": [
            {"role": "primary", "model": "SM S938B (Galaxy S25 Ultra)", "status": "подключено (Задача 1)"},
            {"role": "lowResource", "status": "не оценено: устройство недоступно, пробел зафиксирован"},
        ],
        "referencePolicy": "сгенерированные файлы не объявляются эталоном только потому, что их создал тест; "
                           "Office-эталоны ждут экспорта из приложения-источника (записать версию и шрифты экспорта)",
        "files": manifest,
    }
    MANIFEST.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"corpus: {len(manifest)} files -> {OUTPUT}")
    print(f"manifest: {MANIFEST}")


if __name__ == "__main__":
    main()
