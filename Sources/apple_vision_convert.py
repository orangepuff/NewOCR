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
    return pdf_path.parent / "AppleVision" / "EPUB"


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
        (pdf_path.parent / "Styles", "Styles/OEBPStyles", {".css"}),
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


def page_number_from_path(path):
    match = re.search(r"page(\d+)$", path.stem, re.IGNORECASE)
    return int(match.group(1)) if match else 10**9


def slugify_epub_id(text, fallback):
    slug = re.sub(r"[^A-Za-z0-9_-]+", "-", text.strip()).strip("-").lower()
    return slug or fallback


def markdown_inline_to_html(text):
    escaped = html.escape(text)
    escaped = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", escaped)
    escaped = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", r"<em>\1</em>", escaped)
    return escaped


def markdown_to_xhtml_body(text, fallback_title):
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    body_parts = []
    toc = []
    paragraph_lines = []
    heading_count = 0

    def flush_paragraph():
        if not paragraph_lines:
            return
        paragraph_text = " ".join(line.strip() for line in paragraph_lines if line.strip())
        if paragraph_text:
            body_parts.append(f"<p>{markdown_inline_to_html(paragraph_text)}</p>")
        paragraph_lines.clear()

    for line in lines:
        stripped = line.strip()
        if not stripped:
            flush_paragraph()
            continue

        heading_match = re.match(r"^(#{1,6})\s+(.+?)\s*$", stripped)
        if heading_match:
            flush_paragraph()
            level = min(len(heading_match.group(1)), 6)
            title = heading_match.group(2).strip()
            heading_count += 1
            anchor = slugify_epub_id(title, f"heading-{heading_count}")
            toc.append({"id": anchor, "title": re.sub(r"[*_`]+", "", title).strip() or fallback_title, "level": level})
            body_parts.append(f'<h{level} id="{anchor}">{markdown_inline_to_html(title)}</h{level}>')
        else:
            paragraph_lines.append(stripped)

    flush_paragraph()

    if not body_parts:
        body_parts.append(f"<p>{html.escape(fallback_title)}</p>")

    if not toc:
        toc.append({"id": "start", "title": fallback_title, "level": 1})
        body_parts.insert(0, f'<h1 id="start">{html.escape(fallback_title)}</h1>')

    return "\n".join(body_parts), toc


def markdown_to_body_without_toc(text):
    body_html, _ = markdown_to_xhtml_body(text, "")
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
            body_parts.append(markdown_to_body_without_toc(chapter_text))
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
        chapter_body = markdown_to_body_without_toc(chapter["markdown"].strip()) if chapter["markdown"].strip() else ""
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
    front_spine = '<itemref idref="front-cover" linear="yes"/>\n' if any(cover["xhtml_id"] == "front-cover" for cover in covers) else ""
    back_spine = '\n<itemref idref="back-cover" linear="yes"/>' if any(cover["xhtml_id"] == "back-cover" for cover in covers) else ""
    return f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="book-id">{identifier}</dc:identifier>
<dc:title>{html.escape(book_title)}</dc:title>
<dc:language>th</dc:language>
<meta property="dcterms:modified">{modified}</meta>
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
    if asset["kind"].startswith("Styles") and asset["href"].lower().endswith(".css"):
        css = asset["path"].read_text(encoding="utf-8")
        css = css.replace('url("../Fonts/', 'url("../../Fonts/')
        css = css.replace("url('../Fonts/", "url('../../Fonts/")
        archive.writestr(target, css, compress_type=zipfile.ZIP_DEFLATED)
        return
    archive.write(asset["path"], target, compress_type=zipfile.ZIP_DEFLATED)


def build_epub_from_apple_vision_markdown(pdf_path, title="", front_cover="", back_cover=""):
    markdown_folder, markdown_paths = apple_vision_markdown_paths(pdf_path)
    text = "\n\n".join(path.read_text(encoding="utf-8").strip() for path in markdown_paths)
    if not text.strip():
        raise RuntimeError(f"AppleVision Markdown files are empty: {markdown_folder}")

    fallback_title = title.strip() or pdf_path.stem
    body_html, toc = markdown_to_xhtml_body(text, fallback_title)
    book_title = toc[0]["title"] if toc else fallback_title
    output_folder = apple_vision_epub_folder(pdf_path)
    output_folder.mkdir(parents=True, exist_ok=True)
    epub_path = output_folder / f"{pdf_path.stem}.epub"
    identifier = f"urn:uuid:{uuid4()}"
    covers = cover_manifest_items(
        checked_image_path(front_cover, "Front cover"),
        checked_image_path(back_cover, "Back cover"),
    )
    assets = collect_epub_assets(pdf_path)

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
        "frontCover": str(covers[0]["path"]) if covers and covers[0]["xhtml_id"] == "front-cover" else "",
        "backCover": next((str(cover["path"]) for cover in covers if cover["xhtml_id"] == "back-cover"), ""),
        "message": "EPUB built from AppleVision Markdown files.",
    }


def read_manifest_chapters(manifest):
    chapters = []
    for chapter in manifest.get("chapters", []):
        title = str(chapter.get("title", "")).strip()
        markdown_parts = []
        for value in chapter.get("markdownFiles", []):
            path = Path(value).expanduser()
            if not path.exists() or not path.is_file():
                raise RuntimeError(f"Markdown file not found: {path}")
            markdown_parts.append(path.read_text(encoding="utf-8").strip())
        markdown = "\n\n".join(part for part in markdown_parts if part)
        if markdown:
            chapters.append({"title": title, "markdown": markdown})
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

    documents, toc = chapters_to_xhtml_documents(chapters, book_title)
    output_folder = book_folder / "AppleVision" / "EPUB"
    output_folder.mkdir(parents=True, exist_ok=True)
    epub_path = output_folder / f"{output_stem}.epub"
    identifier = f"urn:uuid:{uuid4()}"
    covers = cover_manifest_items(
        checked_image_path(manifest.get("frontCover", ""), "Front cover"),
        checked_image_path(manifest.get("backCover", ""), "Back cover"),
    )
    assets = collect_epub_assets(book_folder / "__book__.pdf")

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
