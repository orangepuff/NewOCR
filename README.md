# NewOCR

NewOCR is a local macOS book-preparation app for turning PDF book scans into
editable Markdown and EPUB output. It is built as a SwiftUI/AppKit application
with PDFKit for PDF work, Apple Vision for OCR, and a bundled Python helper for
Markdown-to-EPUB generation.

This README is intended to be both user documentation and a handoff reference
for future ChatGPT/Codex sessions. When changing the app, keep behavior scoped
to the requested feature. The user has explicitly asked: do not fix or redesign
unrequested behavior.

## Build And Run

Build from the project root:

```sh
./build.sh
```

The script compiles `Sources/NewOCRApp.swift` and creates:

```text
NewOCR.app/Contents/MacOS/NewOCR
```

It also bundles:

- `Sources/apple_vision_convert.py`
- `Fonts/`
- `Styles/`
- the app icon resources
- `config.txt`
- `OCRInstruction`

Run the built app with:

```sh
open NewOCR.app
```

Useful verification commands after changes:

```sh
./build.sh
python3 -m py_compile Sources/apple_vision_convert.py NewOCR.app/Contents/Resources/apple_vision_convert.py
```

## Important Files

```text
Sources/NewOCRApp.swift
```

Main macOS app. Contains app state, main window, section list, OCR editor,
split/crop windows, preview, Markdown tools, OCR, CSS application, and EPUB
build orchestration.

```text
Sources/apple_vision_convert.py
```

Python EPUB builder. It converts Markdown files into XHTML, builds per-chapter
EPUB files, collects images, fonts, stylesheets, covers, and writes the final
EPUB package.

```text
Styles/stylesheet.css
```

Default EPUB stylesheet copied into new project folders and into the app
bundle during build.

```text
config.txt
```

Runtime configuration defaults. Missing keys are recreated by the app.

```text
OCRInstruction
```

Editable instruction/reference text shown by the app.

## App Purpose

NewOCR supports this book workflow:

1. Create a working project from a source PDF.
2. Optionally crop the working PDF.
3. Split the PDF into section PDFs.
4. Add manual sections where no PDF exists.
5. OCR each section into Markdown.
6. Review/edit Markdown in the OCR editor.
7. Apply EPUB CSS.
8. Build an EPUB with covers, TOC, Markdown content, images, footnotes, and
   styles.

The app should preserve user edits and avoid destructive actions unless the UI
clearly asks for confirmation.

## Project Folder Structure

When the user clicks **New**, NewOCR creates a working folder under
`NEW_PROJECTS_FOLDER` from `config.txt` (default `~/Downloads`). The folder name
is based on the source PDF name.

Typical project:

```text
Book Folder/
  Book.pdf
  _original.pdf
  split-plan.json
  book-sections.json
  section-001.pdf
  section-002.pdf
  ...
  AppleVision/
    MD/
      section-001/
        page1.md
        page2.md
        Images/
      section-002/
    LineCache/
      header-footer-lines.json
      header-footer-review.txt
  ManualSections/
    manual-UUID.manual
  EPUB/
    Book.epub
  CoverImage/
    front-cover.jpg
    back-cover.jpg
  Fonts/
  Styles/
    stylesheet.css
```

### Source PDF And Original Backup

- The working PDF is copied into the project folder.
- `_original.pdf` is kept as the backup source for **Revert Original**.
- Cropping modifies the working PDF, not `_original.pdf`.
- Revert Original restores the working PDF from `_original.pdf`.

### Revert Original Behavior

**Revert Original** asks for confirmation and then removes generated output:

- section PDFs
- `AppleVision/`
- `ManualSections/`
- `CoverImage/`
- `EPUB/`
- `book-sections.json`
- `split-plan.json`

It restores the working PDF from `_original.pdf`.

## Main Window

The main window contains project controls, cover controls, and the section list.

Important actions:

- **New**: create a new project from a PDF.
- **Open Folder**: load an existing working folder.
- **Add Split**: open the split planner for the current project.
- **Crop**: open the crop window for the working PDF.
- **Revert Original**: restore from `_original.pdf` and clear generated output.
- **Apply CSS**: update `Styles/stylesheet.css` with NewOCR required CSS blocks.
- **Build EPUB**: create EPUB from available section/manual Markdown.
- **Process OCR All**: OCR all existing section PDF files.

The project path display should stay compact and readable.

## Section List

The section list is the ordered book structure. It can contain:

- real section PDF files, for example `section-001.pdf`
- manual sections, stored under `ManualSections/`

Each section row supports:

- title editing
- **Process** to open/run OCR for that section
- **Preview** to open the existing Markdown preview for that section
- **Scan Header** for section PDFs
- **+** to add a manual section after that item
- **X** to remove a section/manual section after confirmation

The command column uses fixed button positions:

- section PDFs reserve positions for **Scan Header**, **Process**, and **Preview**
- manual sections hide **Scan Header** but keep its space reserved, so **Process** and
  **Preview** align with PDF rows
- **Preview** is enabled only when the section already has Markdown output
- row action buttons use compact icon+text styling with consistent height and
  accent-colored borders

Display names for real section PDFs include page count:

```text
Section 008 (10 pages)
```

Manual section rows use the manual title when available.

### Removing Section Files

For real section PDFs:

- ask for confirmation
- delete the section PDF
- remove that file's entry from `split-plan.json`
- update `book-sections.json`

For manual sections:

- ask for confirmation using the manual title
- delete the manual `.manual` file if present
- delete related Markdown/resources under `AppleVision/MD/<manual-id>/`
- update `book-sections.json`

## Add Split Window

Add Split creates `section-###.pdf` files from page ranges of the working PDF.

Expected behavior:

- If no section files exist, default **From** to page 1.
- If section files exist, default **From** to the last created section page
  count plus 1.
- If the next page is beyond the original PDF page count, show:

```text
All pages have already been split.
```

- Do not disable Add Split merely because `split-plan.json` ranges cover the
  document; actual created section PDFs are the source of truth.
- `Split` must validate title on click and show `Title is required.` when the
  title is empty.
- After successful split, the Split button should become active again.
- Section output file names are sequential:

```text
section-001.pdf
section-002.pdf
...
```

### Add Split Navigation Rules

The preview arrow buttons update range fields:

- If Title is empty, preview navigation updates **From**.
- Once Title is not empty, preview navigation updates **To**.
- **Set From** updates only **From**.
- **Set To** updates only **To**.

Do not change this behavior when adjusting UI styling.

### split-plan.json

`split-plan.json` stores source PDF bookmark/path data and created split ranges.

Important rules:

- `splitRanges` should represent only created section files.
- Each saved split range should include a `file` property.
- Old/fallback/bookmark-derived ranges without `file` should not be saved as
  real created sections.
- Removing a section file must also remove the matching split-plan entry.

Example:

```json
{
  "splitRanges": [
    {
      "file": "section-001.pdf",
      "title": "Preface",
      "pageFrom": "1",
      "pageTo": "6"
    }
  ]
}
```

## Crop Window

Crop PDF lets the user select a crop rectangle visually and save a cropped
working PDF. It should preserve `_original.pdf`.

The crop window may open full screen based on config.

## Manual Sections

Manual sections exist for content that has no PDF section.

Rules:

- Manual sections are part of `book-sections.json`.
- Manual sections should be removable.
- Manual sections do not run Apple Vision OCR because they have no PDF.
- Clicking **Process** for a manual section opens the OCR editor.
- If no Markdown exists, NewOCR creates:

```text
AppleVision/MD/<manual-id>/page1.md
```

with:

```md
## Title
```

where `Title` is the manual section title, or `Manual Section` if empty.

Manual Markdown page naming must stay consistent with EPUB build logic.

Manual sections must be included in EPUB and TOC when they have Markdown.

## OCR

NewOCR uses Apple's local Vision framework, not an external OCR API, for the
current OCR path.

For real section PDFs:

- clicking **Process** selects that section PDF path
- clicking **Run OCR** runs OCR on that selected section PDF
- `Process OCR All` runs OCR on all existing real section PDF files
- manual sections are skipped by `Process OCR All`

The OCR source must be the section file path, not the original PDF.

### OCR Output

OCR writes per-page Markdown:

```text
AppleVision/MD/section-001/page1.md
AppleVision/MD/section-001/page2.md
...
```

Image crops are written to:

```text
AppleVision/MD/section-001/Images/
```

### Process OCR All

The button appears next to the Sections count:

```text
Sections 34 [Process OCR All]
```

Expected behavior:

- show a progress popup with the file currently being processed
- process only real section PDFs that exist
- skip manual sections
- before each section OCR, remove existing resources for that section:
  - `AppleVision/MD/<section>/`
  - old `.md` files
  - old `Images/`
  - line-cache entries for that PDF in `AppleVision/LineCache/header-footer-lines.json`
  - stale `header-footer-review.txt`
- replace existing Markdown with newly generated Markdown
- show finished successfully when done

## OCR Image Detection

NewOCR detects image regions from rendered PDF pages and can insert Markdown
image references such as:

```md
![Page 1 image 1](Images/page1-image1.png)
```

Important fix/behavior:

- OCR text is priority.
- A full-page scanned text page must not be replaced by a full-page image.
- If Apple Vision recognizes meaningful text, large page-sized image regions
  that overlap many OCR lines should be ignored.
- Real smaller images, figures, diagrams, and illustrations should still be
  extracted.

This prevents pages from becoming image-only Markdown when text OCR succeeded.

## Header/Footer Filtering

There are two independent filter mechanisms:

1. User-entered filtered text.
2. Header/footer scan review.

### User Filtered Text

The OCR window has "Filtered text" controls:

- text to remove, separated by comma
- Top line count
- Bottom line count

This should only remove top/bottom lines that match the entered filter text.

When the working folder changes, filtered text should be cleared so a filter
from one book does not affect another book.

### Scan Header

Scan Header samples possible header/footer lines and writes review data.

Important rule:

- OCR must not automatically remove repeated header/footer candidates merely
  because `header-footer-lines.json` exists.
- Header/footer removal should only happen if `header-footer-review.txt` exists
  and contains `REMOVE:` entries.

This prevents false removal of real text such as a sentence containing a book
title phrase also found in footers.

When the working folder changes, the current folder's
`AppleVision/LineCache/header-footer-review.txt` should be removed/cleared.

## OCR Editor

The OCR editor can show Markdown as paragraphs or as plain text.

Features:

- Preview Markdown
- Save Markdown
- Close after successful save alert
- Load Markdown
- Run OCR
- Cancel OCR
- Search Markdown
- Replace All
- badges/focus shortcuts for Image, Footnote, and Blockquote
- paragraph editing actions:
  - add paragraph before/after
  - add line break before/after
  - page break before/after
  - merge with paragraph above/below
  - remove paragraph
  - move paragraph up/down
  - add image description

After clicking Save and confirming the success popup, the OCR window should
close.

If the OCR Preview window is open, closing the OCR window should also close the
Preview window. This applies to both the OCR window **Close** button and the
Save-success OK flow.

## Markdown And Supported HTML

The editor saves `.md` files. It supports Markdown plus a small set of
NewOCR-supported HTML.

Supported Markdown examples:

```md
# Heading 1
## Heading 2
### Heading 3

> Blockquote

**bold**
*italic*

![Alt text](Images/example.png)
Caption:
  Image description

Text with note.[^1]

[^1]: Footnote text
```

Page breaks:

```md
<!-- page-break-before -->
<!-- page-break-after -->
```

Preview should not show these comments as raw text. Preview renders them as a
subtle horizontal page-break separator so the user can see where the marker is.
EPUB build converts them into real page-break helper elements:

```html
<div class="page-break-before"></div>
<div class="page-break-after"></div>
```

Apply CSS/default CSS must define these classes so EPUB readers treat them as
real page breaks, not visible text.

Line break:

```md
Line one<br/>Line two
```

### Empty Paragraphs

The paragraph editor can create an empty paragraph, for example by clicking
**Add Paragraph After** and leaving it blank. NewOCR should preserve that empty
paragraph in Preview and EPUB instead of dropping it.

In saved Markdown this appears as extra blank paragraph spacing. Preview and
EPUB build convert that editor-created empty slot into:

```html
<p class="empty-paragraph"><br/></p>
```

Apply CSS/default CSS must define `.empty-paragraph` so it has visible paragraph
height and no text indent.

### Alignment

Standard Markdown has no native syntax for left/right/center alignment. NewOCR
uses supported inline HTML paragraph tags:

```html
<p class="left">Text</p>
<p class="center">Text</p>
<p class="right">Text</p>
```

The OCR editor selection popover has:

- LEFT
- CENTER
- RIGHT

The popover shows these as icon-only graphical alignment buttons with tooltips.
Selecting text and clicking one of these writes the matching `<p class="...">`
wrapper into the `.md` file.

Selection popover command buttons should use a consistent visual height. Widths
may vary by command label, but Bold, Italic, Quote, H1, H2, H3, Left, Center,
and Right should align as one compact toolbar.

Apply CSS adds:

```css
.center {
  text-align: center;
  text-indent: 0;
}

.right {
  text-align: right;
  text-indent: 0;
}

.left {
  text-align: left;
  text-indent: 0;
}
```

Preview and EPUB build both preserve these classes.

## Preview

Preview creates:

```text
AppleVision/MD/<section>/preview.html
```

It uses the project stylesheet if available, plus fallback CSS. Preview supports
the same NewOCR Markdown/HTML features as EPUB where practical:

- headings
- paragraphs
- blockquotes
- images and captions
- footnotes
- page-break markers
- left/right/center paragraph classes
- inline bold/italic

Preview text size is configurable in `config.txt`:

```text
PREVIEW_TEXT_SCALE_PERCENT=130
```

The default is 130%. Values below 80 are treated as 130, and values above 220
are capped at 220. The app reloads this config value when Preview opens. The
scale is applied to a preview-only content wrapper inside `preview.html`, on top
of the project stylesheet; EPUB output must not inherit this preview-only font
size.

## Apply CSS

Apply CSS updates:

```text
Styles/stylesheet.css
```

It upserts NewOCR-managed CSS blocks for:

- image pages
- footnotes
- blockquotes
- alignment classes
- page-break helpers
- empty paragraphs

It should preserve unrelated user CSS where possible and replace only NewOCR
managed legacy/marked blocks.

The app reports whether each block was added, replaced, or already up to date.
The Apply CSS popup should explicitly mention that the included CSS blocks cover
images, footnotes, blockquotes, Left/Center/Right alignment, and page breaks.

## EPUB Build

**Build EPUB** uses `Sources/apple_vision_convert.py`, bundled into the app as:

```text
NewOCR.app/Contents/Resources/apple_vision_convert.py
```

It builds from `book-sections.json` and the section/manual Markdown files.

EPUB output goes under:

```text
EPUB/
```

Expected EPUB behavior:

- include all sections with Markdown
- include manual sections with Markdown
- include manual sections in TOC
- use saved UI title first for chapter title
- fall back to first Markdown heading
- fall back to display name
- copy `Styles/`
- copy `Fonts/`
- copy Markdown image assets
- include front/back covers if selected
- create per-chapter XHTML files
- create navigation/TOC
- preserve supported Markdown and supported HTML classes

The Python converter supports:

- headings
- paragraphs
- blockquotes
- Markdown images and captions
- footnotes
- page break markers
- empty paragraphs as `<p class="empty-paragraph"><br/></p>`
- `<p class="left|center|right">...</p>`

## Covers

Front and back covers are copied into the project folder under `CoverImage/`.

The main window should keep cover thumbnails centered and compact so the section
list has enough vertical space.

## Config

`config.txt` controls window sizes, preview scale, and new project location.
When a feature is made configurable, the setting should be added to `config.txt`
and documented here so it is visible and hand-editable.

Important keys:

```text
PDF_LIST_MIN_HEIGHT=420
MAIN_WINDOW_WIDTH=FULL
MAIN_WINDOW_HEIGHT=FULL
OCR_WINDOW_WIDTH=FULL
OCR_WINDOW_HEIGHT=FULL
CROP_PDF_WINDOW_WIDTH=FULL
CROP_PDF_WINDOW_HEIGHT=720
ADD_SPLIT_WINDOW_WIDTH=FULL
ADD_SPLIT_WINDOW_HEIGHT=720
OCR_PARAGRAPH_TEXTAREA_MIN_HEIGHT=58
PREVIEW_TEXT_SCALE_PERCENT=130
NEW_PROJECTS_FOLDER=~/Downloads
```

Width values may be numeric or `FULL` for full-screen opening.

## Current UI Principles

- Keep the app as a practical working tool, not a landing page.
- Buttons should be clear, friendly, and consistent.
- Main toolbar buttons use the regular NewOCR bordered style. Section List
  command buttons use a filled accent background with white text so actions are
  easy to scan. Destructive buttons such as Revert Original keep the red style.
- Use icons where they help scanning.
- Do not let decorative UI reduce section-list space.
- Do not alter behavior while only making UI more beautiful.
- Main workflows should be reachable from the main window.
- Section area should have as much useful space as possible.
- Use restrained neutral surfaces, subtle borders, and small shadows to separate
  the main window, Section List surface, header row, and command/action lane.
  Avoid large colored panels for professional workflow areas.
- Main window text should use larger white text on darker gray surfaces for
  clearer contrast, while filled command buttons keep white text.
- Section List rows should use clear table structure: even rows and odd rows use
  alternating dark gray backgrounds, with separators and a command/action lane
  that follows the same row background.
- Section List hides the table header row; the columns are visually implied by
  consistent row alignment and icon treatments.
- Section List utility icons should stay high-contrast on dark rows: remove uses
  a red circular background with a black X, add uses a white circular background
  with a black plus, file/status badges use light foregrounds, and title fields
  use white backgrounds with black text.
- Section List command buttons should be icon-only on white backgrounds with
  black icons, sized large enough to click comfortably, and should show the
  command name in a custom hover popover.
- Process OCR All should follow the same icon-only button treatment and use a
  stacked-items icon to suggest batch processing.
- Section List should use a gray outer panel with darker row/header content
  inside it, so the list area is visibly separate from the main window.
- The main window should not have its own vertical scrollbar for the normal
  workflow; Section List owns the vertical scrolling and fills the remaining
  window height.
- OCR editor windows should follow the same visual structure: gray outer editor
  panels, light/darker alternating paragraph rows, and filled accent action
  buttons with white text.

## Known Behavioral Decisions

These are intentional and should not be changed casually:

- Add Split uses actual created `section-###.pdf` files to determine next page,
  not only `split-plan.json`.
- `split-plan.json` stores only created section files and includes `file`.
- Add Split preview navigation updates From until Title is non-empty, then To.
- Set From updates only From. Set To updates only To.
- Split button remains clickable and validates title on click.
- Process OCR All deletes old Markdown/images/cache for each section before OCR.
- Manual sections do not run OCR but can create/edit Markdown.
- OCR must use section PDF paths, not the original PDF.
- Empty paragraph slots from the paragraph editor should survive Preview and
  EPUB build.
- Header/footer removal requires `header-footer-review.txt` REMOVE entries.
- Working folder changes clear filtered text and header/footer review state.
- Full-page scanned text images should not replace recognized OCR text.
- Save in OCR window closes the OCR window after success popup OK.

## Development Notes For Future Assistants

Before changing behavior:

1. Read the existing code path in `Sources/NewOCRApp.swift`.
2. Confirm whether the request is UI-only or behavior-changing.
3. Keep edits narrow.
4. Do not revert unrelated changes.
5. Build with `./build.sh`.
6. If EPUB builder changes, run `python3 -m py_compile` on both source and
   bundled converter after build.

Maintenance rule:

- If you change, fix, add, or remove app behavior, update this README in the
  same work session so it remains the current handoff reference.
- If you make a feature configurable, keep the configurable value in
  `config.txt`; do not store it only in hidden app state or only in UI controls.
- If the change is intentionally too small to affect documented behavior, say
  that clearly in the final response.
- Keep README updates factual and specific. Document what the app now does, not
  just what was changed.

When editing files manually, prefer `apply_patch`.

Do not use destructive commands such as `git reset --hard` unless the user
explicitly asks.

## Troubleshooting Reference

### OCR returns images instead of text

Check whether image-region detection classified a scanned text page as a large
image. OCR may have recognized text correctly, but post-processing may have
filtered text overlapping an image region. The intended behavior is to keep text
when meaningful OCR lines exist.

### A first line disappeared

Check:

- raw OCR output
- user filtered text
- header/footer review entries
- page-boundary merge behavior

If no Scan Header review exists, repeated header/footer auto-detection must not
remove text.

### Process OCR All seems stale

It should remove section-specific `AppleVision/MD/<section>/` and line-cache
entries before OCR. If stale images or Markdown remain, inspect
`removeAppleVisionResources(for:)`.

### EPUB misses a manual section

Check:

- `book-sections.json`
- manual section Markdown folder
- page file name, usually `page1.md`
- `buildBookEPUB()`
- `chapterTitle(for:markdownFiles:)`
- Python chapter collection in `apple_vision_convert.py`

### Alignment not visible in EPUB

Check:

- Markdown contains `<p class="left|center|right">...</p>`
- `Apply CSS` was run or default stylesheet includes the classes
- Python converter preserved the class
- generated XHTML contains `class="left"`, `class="center"`, or `class="right"`

## Glossary

- Working folder: the project folder created/opened by NewOCR.
- Source PDF: the copied PDF inside the working folder.
- Original backup: `_original.pdf`.
- Section PDF: `section-###.pdf`.
- Manual section: non-PDF book section with manually edited Markdown.
- AppleVision MD: OCR Markdown output under `AppleVision/MD/`.
- Line cache: OCR-derived header/footer sample data under
  `AppleVision/LineCache/`.
