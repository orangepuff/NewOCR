#!/usr/bin/env python3
import argparse
import html
import json
import mimetypes
import re
import sys
import time
import zipfile
from pathlib import Path
from uuid import uuid4


def apple_vision_output_folder(pdf_path):
    return pdf_path.parent / "AppleVision" / "MD" / pdf_path.stem


def apple_vision_epub_folder(pdf_path):
    return pdf_path.parent / "EPUB"


def media_type_for_path(path):
    suffix = path.suffix.lower()
    if suffix == ".css":
        return "text/css"
    if suffix == ".ttf":
        return "font/ttf"
    if suffix == ".otf":
        return "font/otf"
    if suffix == ".woff":
        return "font/woff"
    if suffix == ".woff2":
        return "font/woff2"
    return mimetypes.guess_type(str(path))[0] or "application/octet-stream"


def collect_epub_assets(pdf_path):
    assets = []
    asset_specs = [
        (pdf_path.parent / "Styles", "Styles", {".css"}),
        (pdf_path.parent / "Fonts", "Fonts", {".ttf", ".otf", ".woff", ".woff2"}),
    ]

    for source_folder, epub_folder, extensions in asset_specs:
        if not source_folder.exists() or not source_folder.is_dir():
            continue
        for path in sorted(source_folder.rglob("*")):
            if not path.is_file() or path.suffix.lower() not in extensions:
                continue
            relative_path = path.relative_to(source_folder)
            href = str(Path(epub_folder) / relative_path).replace("\\", "/")
            item_id = re.sub(r"[^A-Za-z0-9_-]+", "-", f"{epub_folder}-{relative_path}").strip("-").lower()
            assets.append({
                "id": item_id or f"asset-{len(assets) + 1}",
                "href": href,
                "media_type": media_type_for_path(path),
                "path": path,
                "kind": epub_folder,
            })

    return assets


def stylesheet_links(assets, prefix=""):
    return "\n".join(
        f'<link rel="stylesheet" type="text/css" href="{html.escape(prefix + asset["href"])}"/>'
        for asset in assets
        if asset["kind"].startswith("Styles") and asset["href"].lower().endswith(".css")
    )


MARKDOWN_IMAGE_RE = re.compile(r"^!\[([^\]]*)\]\(([^)]+)\)\s*$")
IMAGE_CAPTION_RE = re.compile(r"^(?:Caption|Description):\s*(.*)$", re.IGNORECASE)
FOOTNOTE_DEF_RE = re.compile(r"^\[\^([A-Za-z0-9_-]+)\]:\s*(.*)$")
FOOTNOTE_REF_RE = re.compile(r"\[\^([A-Za-z0-9_-]+)\]")


def clean_markdown_link_target(value):
    value = value.strip()
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        value = value[1:-1].strip()
    return value


def safe_asset_name(value, fallback):
    stem = re.sub(r"[^A-Za-z0-9_-]+", "-", Path(value).stem).strip("-").lower() or fallback
    suffix = Path(value).suffix.lower()
    return f"{stem}{suffix}"


def collect_markdown_image_assets(markdown_paths, prefix=""):
    assets = []
    image_map = {}
    used_hrefs = set()

    for path in markdown_paths:
        text = path.read_text(encoding="utf-8")
        for match in re.finditer(r"!\[[^\]]*\]\(([^)]+)\)", text):
            raw_target = clean_markdown_link_target(match.group(1))
            if not raw_target or raw_target.lower().startswith(("http://", "https://", "data:")):
                continue

            image_path = Path(raw_target)
            if not image_path.is_absolute():
                image_path = path.parent / image_path
            image_path = image_path.resolve()
            if not image_path.exists() or not image_path.is_file():
                continue

            media_type = media_type_for_path(image_path)
            if not media_type.startswith("image/"):
                continue

            asset_name = safe_asset_name(raw_target, f"image-{len(assets) + 1}")
            href = f"Images/{prefix}{asset_name}"
            counter = 2
            while href in used_hrefs:
                href = f"Images/{prefix}{Path(asset_name).stem}-{counter}{Path(asset_name).suffix}"
                counter += 1
            used_hrefs.add(href)

            image_map[(str(path.resolve()), raw_target)] = href
            assets.append({
                "id": re.sub(r"[^A-Za-z0-9_-]+", "-", href).strip("-").lower() or f"image-{len(assets) + 1}",
                "href": href,
                "media_type": media_type,
                "path": image_path,
                "kind": "Images",
            })

    return assets, image_map


def page_number_from_path(path):
    match = re.search(r"page(\d+)$", path.stem, re.IGNORECASE)
    return int(match.group(1)) if match else 10**9


def slugify_epub_id(text, fallback):
    slug = re.sub(r"[^A-Za-z0-9_-]+", "-", text.strip()).strip("-").lower()
    return slug or fallback


def footnote_fragment_id(label, fallback):
    return slugify_epub_id(label, fallback)


def extract_markdown_footnotes(text):
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    content_lines = []
    definitions = {}
    active_label = None

    for line in lines:
        match = FOOTNOTE_DEF_RE.match(line)
        if match:
            active_label = match.group(1)
            definitions[active_label] = [match.group(2).strip()]
            continue

        if active_label and (line.startswith("    ") or line.startswith("\t")):
            definitions[active_label].append(line.strip())
            continue

        active_label = None
        content_lines.append(line)

    cleaned_definitions = {}
    for label, parts in definitions.items():
        text_value = " ".join(part for part in parts if part).strip()
        if text_value:
            cleaned_definitions[label] = text_value

    return "\n".join(content_lines), cleaned_definitions


def markdown_inline_to_html(text, footnote_state=None):
    escaped = html.escape(text)
    escaped = re.sub(r"&lt;br\s*/?&gt;", "<br/>", escaped, flags=re.IGNORECASE)
    escaped = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", escaped)
    escaped = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", r"<em>\1</em>", escaped)

    if footnote_state is not None:
        def replace_footnote(match):
            label = match.group(1)
            fragment = footnote_fragment_id(label, f"note-{len(footnote_state['used']) + 1}")
            if label not in footnote_state["used"]:
                footnote_state["used"].append(label)
            return (
                f'<sup id="fnref-{html.escape(fragment)}" class="footnote-ref">'
                f'<a href="#fn-{html.escape(fragment)}">{html.escape(label)}</a>'
                f'</sup>'
            )

        escaped = FOOTNOTE_REF_RE.sub(replace_footnote, escaped)

    return escaped


def page_break_html(kind):
    if kind == "before":
        return '<div class="page-break-before"></div>'
    return '<div class="page-break-after"></div>'


def footnotes_to_html(footnote_state):
    items = []
    for index, label in enumerate(footnote_state["used"], start=1):
        note_text = footnote_state["definitions"].get(label)
        if not note_text:
            continue
        fragment = footnote_fragment_id(label, f"note-{index}")
        items.append(
            f'<li id="fn-{html.escape(fragment)}">'
            f'{markdown_inline_to_html(note_text)} '
            f'<a href="#fnref-{html.escape(fragment)}" class="footnote-back">&#8617;</a>'
            f'</li>'
        )

    if not items:
        return ""

    return '<section class="footnotes">\n<ol>\n' + "\n".join(items) + "\n</ol>\n</section>"


def markdown_image_to_html(stripped, source_path=None, image_map=None, image_prefix="", caption=""):
    match = MARKDOWN_IMAGE_RE.match(stripped)
    if not match:
        return None
    alt = match.group(1).strip()
    raw_target = clean_markdown_link_target(match.group(2))
    href = raw_target
    if image_map is not None and source_path is not None:
        href = image_map.get((str(source_path.resolve()), raw_target), raw_target)
    if image_map is not None and href == raw_target:
        href = next((value for (path_value, target), value in image_map.items() if target == raw_target), raw_target)
    caption_html = ""
    if caption:
        caption_lines = [markdown_inline_to_html(line) for line in caption.split("\n") if line.strip()]
        caption_html = "\n<figcaption>" + "<br/>".join(caption_lines) + "</figcaption>"
    return f'<figure class="image-figure"><img src="{html.escape(image_prefix + href)}" alt="{html.escape(alt)}"/>{caption_html}</figure>'


def image_caption_from_lines(lines, start_index):
    caption_parts = []
    next_index = start_index + 1
    found_caption = False
    while next_index < len(lines):
        raw_line = lines[next_index]
        stripped = raw_line.strip()
        caption_match = IMAGE_CAPTION_RE.match(stripped)
        if caption_match:
            found_caption = True
            caption_parts.append(caption_match.group(1).strip())
            next_index += 1
            continue
        if found_caption and (raw_line.startswith("  ") or raw_line.startswith("    ") or raw_line.startswith("\t")):
            caption_parts.append(stripped)
            next_index += 1
            continue
        if found_caption and not stripped:
            break
        if found_caption and (
            MARKDOWN_IMAGE_RE.match(stripped)
            or FOOTNOTE_DEF_RE.match(stripped)
            or re.match(r"^#{1,6}\s+.+", stripped)
        ):
            break
        if found_caption:
            caption_parts.append(stripped)
            next_index += 1
            continue
        if not caption_match:
            break
    return "\n".join(part for part in caption_parts if part).strip(), next_index


def markdown_heading_parts(stripped):
    match = re.match(r"^(#{1,6})\s+(.+?)\s*$", stripped)
    if not match:
        return None
    level = min(len(match.group(1)), 6)
    title = re.sub(r"\s+#{1,6}\s*$", "", match.group(2).strip()).strip()
    return (level, title) if title else None


def markdown_blockquote_lines(lines, start_index):
    quote_lines = []
    next_index = start_index
    while next_index < len(lines):
        stripped = lines[next_index].strip()
        if not stripped:
            break
        if not stripped.startswith(">"):
            break
        quote_lines.append(stripped[1:].strip())
        next_index += 1
    return quote_lines, next_index


def markdown_aligned_paragraph_parts(stripped):
    match = re.match(r"(?is)^<p\s+class\s*=\s*['\"](left|right|center)['\"]\s*>(.*?)</p>$", stripped)
    if not match:
        return None
    alignment = match.group(1).lower()
    content = match.group(2).strip()
    return (alignment, content) if content else None


def markdown_to_xhtml_body(text, fallback_title, source_path=None, image_map=None, image_prefix=""):
    # Extract the definitions dict but keep original text so definition lines remain
    # in their position and can be rendered inline before any page-break-after marker.
    _, footnote_definitions = extract_markdown_footnotes(text)
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    body_parts = []
    toc = []
    paragraph_lines = []
    heading_count = 0
    footnote_state = {"definitions": footnote_definitions, "used": []}
    inline_rendered: set = set()
    blank_line_count = 0

    def flush_paragraph():
        if not paragraph_lines:
            return
        paragraph_text = " ".join(line.strip() for line in paragraph_lines if line.strip())
        if paragraph_text:
            body_parts.append(f"<p>{markdown_inline_to_html(paragraph_text, footnote_state)}</p>")
        paragraph_lines.clear()

    def flush_empty_paragraphs():
        nonlocal blank_line_count
        if blank_line_count > 1:
            for _ in range(blank_line_count // 2):
                body_parts.append('<p class="empty-paragraph"><br/></p>')
        blank_line_count = 0

    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        if not stripped:
            if paragraph_lines:
                flush_paragraph()
                blank_line_count = 1
            else:
                blank_line_count += 1
            index += 1
            continue

        flush_empty_paragraphs()

        if stripped in {"<!-- page-break-before -->", "[[page-break-before]]"}:
            flush_paragraph()
            body_parts.append(page_break_html("before"))
            index += 1
            continue

        if stripped in {"<!-- page-break-after -->", "[[page-break-after]]"}:
            flush_paragraph()
            body_parts.append(page_break_html("after"))
            index += 1
            continue

        caption, next_index = image_caption_from_lines(lines, index)
        image_html = markdown_image_to_html(stripped, source_path, image_map, image_prefix, caption)
        if image_html:
            flush_paragraph()
            body_parts.append(image_html)
            index = next_index
            continue

        blockquote_lines, next_index = markdown_blockquote_lines(lines, index)
        if blockquote_lines:
            flush_paragraph()
            quote_text = "<br/>".join(markdown_inline_to_html(part, footnote_state) for part in blockquote_lines if part)
            if quote_text:
                body_parts.append(f'<blockquote class="blockquote"><p>{quote_text}</p></blockquote>')
            index = next_index
            continue

        aligned_parts = markdown_aligned_paragraph_parts(stripped)
        if aligned_parts:
            flush_paragraph()
            alignment, content = aligned_parts
            aligned_text = content.replace("\n", "<br/>")
            body_parts.append(f'<p class="{alignment}">{markdown_inline_to_html(aligned_text, footnote_state)}</p>')
            index += 1
            continue

        heading_parts = markdown_heading_parts(stripped)
        if heading_parts:
            flush_paragraph()
            level, first_title = heading_parts
            title_parts = [first_title]
            next_index = index + 1
            while next_index < len(lines):
                next_heading_parts = markdown_heading_parts(lines[next_index].strip())
                if not next_heading_parts or next_heading_parts[0] != level:
                    break
                title_parts.append(next_heading_parts[1])
                next_index += 1
            title = "<br/>".join(markdown_inline_to_html(part, footnote_state) for part in title_parts)
            toc_title = " ".join(re.sub(r"[*_`]+", "", part).strip() for part in title_parts).strip()
            heading_count += 1
            anchor = slugify_epub_id(" ".join(title_parts), f"heading-{heading_count}")
            if level == 1:
                toc.append({"id": anchor, "title": toc_title or fallback_title, "level": level})
            body_parts.append(f'<h{level} id="{anchor}">{title}</h{level}>')
            index = next_index
            continue

        # Render [^N]: definition lines inline at their position in the text rather
        # than collecting them for the end of the document.
        def_match = FOOTNOTE_DEF_RE.match(stripped)
        if def_match:
            flush_paragraph()
            flush_empty_paragraphs()
            items = []
            while index < len(lines):
                s = lines[index].strip()
                m = FOOTNOTE_DEF_RE.match(s)
                if m:
                    label = m.group(1)
                    note_text = footnote_definitions.get(label) or m.group(2).strip()
                    fragment = footnote_fragment_id(label, f"fn-{label}")
                    items.append(
                        f'<li id="fn-{html.escape(fragment)}">'
                        f'{markdown_inline_to_html(note_text, footnote_state)} '
                        f'<a href="#fnref-{html.escape(fragment)}" class="footnote-back">&#8617;</a>'
                        f'</li>'
                    )
                    inline_rendered.add(label)
                    index += 1
                elif s.startswith("    ") or s.startswith("\t"):
                    index += 1  # continuation indent line — skip
                else:
                    break
            if items:
                body_parts.append('<section class="footnotes">\n<ol>\n' + "\n".join(items) + "\n</ol>\n</section>")
            continue

        paragraph_lines.append(stripped)
        index += 1

    flush_paragraph()
    flush_empty_paragraphs()
    # Only append end-of-document footnotes for labels not already rendered inline.
    remaining_used = [l for l in footnote_state["used"] if l not in inline_rendered]
    if remaining_used:
        remaining_state = {"definitions": footnote_definitions, "used": remaining_used}
        footnotes_html = footnotes_to_html(remaining_state)
        if footnotes_html:
            body_parts.append(footnotes_html)

    if not body_parts:
        body_parts.append(f"<p>{html.escape(fallback_title)}</p>")

    if not toc:
        toc.append({"id": "start", "title": fallback_title, "level": 1})
        body_parts.insert(0, f'<h1 id="start">{html.escape(fallback_title)}</h1>')

    return "\n".join(body_parts), toc


def markdown_to_body_without_toc(text, source_path=None, image_map=None, image_prefix=""):
    body_html, _ = markdown_to_xhtml_body(text, "", source_path, image_map, image_prefix)
    return body_html


def chapters_to_xhtml_body(chapters, fallback_title):
    body_parts = []
    toc = []
    for index, chapter in enumerate(chapters, start=1):
        title = chapter["title"].strip() or f"{fallback_title} {index}"
        anchor = slugify_epub_id(title, f"chapter-{index}")
        if any(item["id"] == anchor for item in toc):
            anchor = f"{anchor}-{index}"
        toc.append({"id": anchor, "title": title, "level": 2})
        body_parts.append(f'<section id="{anchor}">')
        chapter_text = chapter["markdown"].strip()
        if chapter_text:
            body_parts.append(markdown_to_body_without_toc(
                chapter_text,
                chapter.get("sourcePath"),
                chapter.get("imageMap"),
                chapter.get("imagePrefix", ""),
            ))
        body_parts.append("</section>")

    if not body_parts:
        toc.append({"id": "start", "title": fallback_title, "level": 1})
        body_parts.append(f'<h1 id="start">{html.escape(fallback_title)}</h1>')

    return "\n".join(body_parts), toc


def chapters_to_xhtml_documents(chapters, fallback_title):
    documents = []
    toc = []
    for index, chapter in enumerate(chapters, start=1):
        title = chapter["title"].strip() or f"{fallback_title} {index}"
        anchor = slugify_epub_id(title, f"chapter-{index}")
        if any(item["id"] == anchor for item in toc):
            anchor = f"{anchor}-{index}"
        href = f"Text/chapter-{index:03d}.xhtml"
        toc.append({"id": anchor, "title": title, "level": 2, "href": href})
        chapter_body = markdown_to_body_without_toc(
            chapter["markdown"].strip(),
            chapter.get("sourcePath"),
            chapter.get("imageMap"),
            chapter.get("imagePrefix", ""),
        ) if chapter["markdown"].strip() else ""
        body_html = f'<section id="{anchor}">\n{chapter_body}\n</section>'
        documents.append({
            "id": f"chapter-{index:03d}",
            "href": href,
            "title": title,
            "body": body_html,
        })

    if not documents:
        href = "Text/chapter-001.xhtml"
        toc.append({"id": "start", "title": fallback_title, "level": 1, "href": href})
        documents.append({
            "id": "chapter-001",
            "href": href,
            "title": fallback_title,
            "body": f'<h1 id="start">{html.escape(fallback_title)}</h1>',
        })

    return documents, toc


def make_nav_xhtml(book_title, toc, assets=None):
    styles = stylesheet_links(assets or [])
    nav_items = "\n".join(
        f'<li><a href="{html.escape(item.get("href", "content.xhtml"))}#{html.escape(item["id"])}">{html.escape(item["title"])}</a></li>'
        for item in toc
    )
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="th" xml:lang="th">
<head>
<title>{html.escape(book_title)} TOC</title>
{styles}
</head>
<body>
<nav epub:type="toc" id="toc">
<h1>Table of Contents</h1>
<ol>
{nav_items}
</ol>
</nav>
</body>
</html>
"""


def make_content_xhtml(book_title, body_html, assets=None, stylesheet_prefix=""):
    styles = stylesheet_links(assets or [], prefix=stylesheet_prefix)
    fallback_style = "" if styles else """<style>
body { font-family: serif; line-height: 1.55; }
p { margin: 0 0 1em 0; }
</style>"""
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="th" xml:lang="th">
<head>
<title>{html.escape(book_title)}</title>
{styles}
{fallback_style}
</head>
<body>
{body_html}
</body>
</html>
"""


def make_cover_xhtml(book_title, image_href, label, assets=None):
    styles = stylesheet_links(assets or [])
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="th" xml:lang="th">
<head>
<title>{html.escape(book_title)} {html.escape(label)}</title>
{styles}
<style>
html, body {{ margin: 0; padding: 0; height: 100%; }}
body {{ text-align: center; }}
img {{ max-width: 100%; max-height: 100%; }}
</style>
</head>
<body>
<img src="{html.escape(image_href)}" alt="{html.escape(label)}"/>
</body>
</html>
"""


def cover_manifest_items(front_cover_path=None, back_cover_path=None):
    items = []
    if front_cover_path:
        media_type = mimetypes.guess_type(str(front_cover_path))[0] or "image/jpeg"
        items.append({
            "id": "front-cover-image",
            "href": f"images/front-cover{front_cover_path.suffix.lower()}",
            "media_type": media_type,
            "properties": "cover-image",
            "path": front_cover_path,
            "xhtml_id": "front-cover",
            "xhtml_href": "front-cover.xhtml",
            "label": "Front Cover",
        })
    if back_cover_path:
        media_type = mimetypes.guess_type(str(back_cover_path))[0] or "image/jpeg"
        items.append({
            "id": "back-cover-image",
            "href": f"images/back-cover{back_cover_path.suffix.lower()}",
            "media_type": media_type,
            "properties": "",
            "path": back_cover_path,
            "xhtml_id": "back-cover",
            "xhtml_href": "back-cover.xhtml",
            "label": "Back Cover",
        })
    return items


def make_content_opf(book_title, identifier, covers=None, assets=None, documents=None):
    covers = covers or []
    assets = assets or []
    documents = documents or [{"id": "content", "href": "content.xhtml"}]
    modified = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    cover_manifest = "\n".join(
        f'<item id="{cover["id"]}" href="{cover["href"]}" media-type="{cover["media_type"]}"'
        + (f' properties="{cover["properties"]}"' if cover["properties"] else "")
        + "/>\n"
        + f'<item id="{cover["xhtml_id"]}" href="{cover["xhtml_href"]}" media-type="application/xhtml+xml"/>'
        for cover in covers
    )
    asset_manifest = "\n".join(
        f'<item id="{asset["id"]}" href="{asset["href"]}" media-type="{asset["media_type"]}"/>'
        for asset in assets
    )
    document_manifest = "\n".join(
        f'<item id="{document["id"]}" href="{document["href"]}" media-type="application/xhtml+xml"/>'
        for document in documents
    )
    document_spine = "\n".join(
        f'<itemref idref="{document["id"]}"/>'
        for document in documents
    )
    front_cover_id = next((cover["id"] for cover in covers if cover["xhtml_id"] == "front-cover"), "")
    cover_meta = f'<meta name="cover" content="{html.escape(front_cover_id, quote=True)}"/>' if front_cover_id else ""
    front_spine = '<itemref idref="front-cover" linear="yes"/>\n' if any(cover["xhtml_id"] == "front-cover" for cover in covers) else ""
    back_spine = '\n<itemref idref="back-cover" linear="yes"/>' if any(cover["xhtml_id"] == "back-cover" for cover in covers) else ""
    return f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="book-id">{identifier}</dc:identifier>
<dc:title>{html.escape(book_title)}</dc:title>
<dc:language>th</dc:language>
<meta property="dcterms:modified">{modified}</meta>
{cover_meta}
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
{document_manifest}
{cover_manifest}
{asset_manifest}
</manifest>
<spine>
{front_spine}{document_spine}{back_spine}
</spine>
</package>
"""


def apple_vision_markdown_paths(pdf_path):
    output_folder = apple_vision_output_folder(pdf_path)
    if not output_folder.exists() or not output_folder.is_dir():
        raise RuntimeError(f"AppleVision Markdown folder not found: {output_folder}")

    page_paths = sorted(output_folder.glob("page*.md"), key=page_number_from_path)
    output_paths = page_paths or sorted(output_folder.glob("*.md"))
    if not output_paths:
        raise RuntimeError(f"No AppleVision Markdown files found in: {output_folder}")
    return output_folder, output_paths


def checked_image_path(value, label):
    if not value:
        return None
    path = Path(value).expanduser()
    if not path.exists() or not path.is_file():
        raise RuntimeError(f"{label} image not found: {path}")
    media_type = mimetypes.guess_type(str(path))[0] or ""
    if not media_type.startswith("image/"):
        raise RuntimeError(f"{label} file is not an image: {path}")
    return path


def write_epub_asset(archive, asset):
    target = f"OEBPS/{asset['href']}"
    archive.write(asset["path"], target, compress_type=zipfile.ZIP_DEFLATED)


def build_epub_from_apple_vision_markdown(pdf_path, title="", front_cover="", back_cover=""):
    markdown_folder, markdown_paths = apple_vision_markdown_paths(pdf_path)
    text = "\n\n".join(path.read_text(encoding="utf-8").strip() for path in markdown_paths)
    if not text.strip():
        raise RuntimeError(f"AppleVision Markdown files are empty: {markdown_folder}")

    fallback_title = title.strip() or pdf_path.stem
    markdown_image_assets, markdown_image_map = collect_markdown_image_assets(markdown_paths)
    body_html, toc = markdown_to_xhtml_body(text, fallback_title, markdown_paths[0], markdown_image_map)
    book_title = toc[0]["title"] if toc else fallback_title
    output_folder = apple_vision_epub_folder(pdf_path)
    output_folder.mkdir(parents=True, exist_ok=True)
    epub_path = output_folder / f"{pdf_path.stem}.epub"
    identifier = f"urn:uuid:{uuid4()}"
    covers = cover_manifest_items(
        checked_image_path(front_cover, "Front cover"),
        checked_image_path(back_cover, "Back cover"),
    )
    assets = collect_epub_assets(pdf_path) + markdown_image_assets

    container_xml = """<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles>
<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
</rootfiles>
</container>
"""

    with zipfile.ZipFile(epub_path, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", container_xml, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/content.opf", make_content_opf(book_title, identifier, covers, assets), compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/nav.xhtml", make_nav_xhtml(book_title, toc, assets), compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/content.xhtml", make_content_xhtml(book_title, body_html, assets), compress_type=zipfile.ZIP_DEFLATED)
        for cover in covers:
            archive.writestr(
                f"OEBPS/{cover['xhtml_href']}",
                make_cover_xhtml(book_title, cover["href"], cover["label"], assets),
                compress_type=zipfile.ZIP_DEFLATED,
            )
            archive.write(cover["path"], f"OEBPS/{cover['href']}", compress_type=zipfile.ZIP_DEFLATED)
        for asset in assets:
            write_epub_asset(archive, asset)

    return {
        "status": "completed",
        "pdf": str(pdf_path),
        "appleVisionMarkdownFolder": str(markdown_folder),
        "appleVisionMarkdownFiles": [str(path) for path in markdown_paths],
        "epubFile": str(epub_path),
        "title": book_title,
        "tocItems": len(toc),
        "characters": len(text),
        "stylesheets": [asset["href"] for asset in assets if asset["kind"] == "Styles"],
        "fonts": [asset["href"] for asset in assets if asset["kind"] == "Fonts"],
        "images": [asset["href"] for asset in assets if asset["kind"] == "Images"],
        "frontCover": str(covers[0]["path"]) if covers and covers[0]["xhtml_id"] == "front-cover" else "",
        "backCover": next((str(cover["path"]) for cover in covers if cover["xhtml_id"] == "back-cover"), ""),
        "message": "EPUB built from AppleVision Markdown files.",
    }


def read_manifest_chapters(manifest):
    chapters = []
    for chapter in manifest.get("chapters", []):
        title = str(chapter.get("title", "")).strip()
        markdown_parts = []
        markdown_paths = []
        for value in chapter.get("markdownFiles", []):
            path = Path(value).expanduser()
            if not path.exists() or not path.is_file():
                raise RuntimeError(f"Markdown file not found: {path}")
            markdown_paths.append(path)
            markdown_parts.append(path.read_text(encoding="utf-8").strip())
        markdown = "\n\n".join(part for part in markdown_parts if part)
        if markdown:
            chapters.append({"title": title, "markdown": markdown, "markdownPaths": markdown_paths, "sourcePath": markdown_paths[0] if markdown_paths else None})
    return chapters


def build_epub_from_chapter_manifest(manifest_path):
    manifest_path = Path(manifest_path).expanduser()
    if not manifest_path.exists():
        raise RuntimeError(f"Chapter manifest not found: {manifest_path}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    book_folder = Path(manifest["bookFolder"]).expanduser()
    if not book_folder.exists() or not book_folder.is_dir():
        raise RuntimeError(f"Book folder not found: {book_folder}")

    book_title = str(manifest.get("bookTitle", "")).strip() or book_folder.name
    output_stem = str(manifest.get("outputStem", "")).strip() or book_folder.name
    chapters = read_manifest_chapters(manifest)
    if not chapters:
        raise RuntimeError("No Markdown chapters found for EPUB.")

    markdown_image_assets = []
    for index, chapter in enumerate(chapters, start=1):
        chapter_assets, chapter_image_map = collect_markdown_image_assets(chapter.get("markdownPaths", []), prefix=f"chapter-{index:03d}-")
        markdown_image_assets.extend(chapter_assets)
        chapter["imageMap"] = chapter_image_map
        chapter["imagePrefix"] = "../"

    documents, toc = chapters_to_xhtml_documents(chapters, book_title)
    output_folder = book_folder / "EPUB"
    output_folder.mkdir(parents=True, exist_ok=True)
    epub_path = output_folder / f"{output_stem}.epub"
    identifier = f"urn:uuid:{uuid4()}"
    covers = cover_manifest_items(
        checked_image_path(manifest.get("frontCover", ""), "Front cover"),
        checked_image_path(manifest.get("backCover", ""), "Back cover"),
    )
    assets = collect_epub_assets(book_folder / "__book__.pdf") + markdown_image_assets

    container_xml = """<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles>
<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
</rootfiles>
</container>
"""

    with zipfile.ZipFile(epub_path, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", container_xml, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/content.opf", make_content_opf(book_title, identifier, covers, assets, documents), compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/nav.xhtml", make_nav_xhtml(book_title, toc, assets), compress_type=zipfile.ZIP_DEFLATED)
        for document in documents:
            archive.writestr(
                f"OEBPS/{document['href']}",
                make_content_xhtml(document["title"], document["body"], assets, stylesheet_prefix="../"),
                compress_type=zipfile.ZIP_DEFLATED,
            )
        for cover in covers:
            archive.writestr(
                f"OEBPS/{cover['xhtml_href']}",
                make_cover_xhtml(book_title, cover["href"], cover["label"], assets),
                compress_type=zipfile.ZIP_DEFLATED,
            )
            archive.write(cover["path"], f"OEBPS/{cover['href']}", compress_type=zipfile.ZIP_DEFLATED)
        for asset in assets:
            write_epub_asset(archive, asset)

    return {
        "status": "completed",
        "bookFolder": str(book_folder),
        "epubFile": str(epub_path),
        "title": book_title,
        "chapters": len(chapters),
        "xhtmlFiles": [document["href"] for document in documents],
        "tocItems": len(toc),
        "stylesheets": [asset["href"] for asset in assets if asset["kind"] == "Styles"],
        "fonts": [asset["href"] for asset in assets if asset["kind"] == "Fonts"],
        "images": [asset["href"] for asset in assets if asset["kind"] == "Images"],
        "frontCover": str(covers[0]["path"]) if covers and covers[0]["xhtml_id"] == "front-cover" else "",
        "backCover": next((str(cover["path"]) for cover in covers if cover["xhtml_id"] == "back-cover"), ""),
        "message": "EPUB built from Markdown chapter manifest.",
    }


def main():
    parser = argparse.ArgumentParser(description="Convert AppleVision Markdown OCR output.")
    parser.add_argument("--config")
    parser.add_argument("--pdf")
    parser.add_argument("--chapter-manifest")
    parser.add_argument("--build-epub-only", action="store_true")
    parser.add_argument("--title", default="")
    parser.add_argument("--front-cover", default="")
    parser.add_argument("--back-cover", default="")
    args = parser.parse_args()

    if args.chapter_manifest:
        result = build_epub_from_chapter_manifest(args.chapter_manifest)
    elif args.build_epub_only:
        if not args.pdf:
            raise RuntimeError("--pdf is required with --build-epub-only.")
        pdf_path = Path(args.pdf).expanduser()
        if not pdf_path.exists():
            raise RuntimeError(f"PDF file not found: {pdf_path}")
        if pdf_path.suffix.lower() != ".pdf":
            raise RuntimeError(f"Selected file is not a PDF: {pdf_path}")
        result = build_epub_from_apple_vision_markdown(pdf_path, args.title, args.front_cover, args.back_cover)
    else:
        raise RuntimeError("Choose --chapter-manifest or --build-epub-only.")

    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"status": "error", "message": str(exc)}, indent=2, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
