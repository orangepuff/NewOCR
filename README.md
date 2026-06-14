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

Runtime configuration defaults. The app reads this file as-is and does not
recreate it or append missing keys automatically.

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
- **Process OCR All**: OCR existing section PDF files that are not checked
  **Ready for EPUB**.
- **Scan Header All**: scan header/footer candidates for all existing section
  PDF files and open the shared Header/Footer Review.

The project path display should stay compact and readable.

## Section List

The section list is the ordered book structure. It can contain:

- real section PDF files, for example `section-001.pdf`
- manual sections, stored under `ManualSections/`

Each section row supports:

- a user-controlled **Ready for EPUB** checkbox for personal tracking
- title editing
- **Process** to open/run OCR for that section
- **Preview** to open the existing Markdown preview for that section
- **Compare** to compare pure Apple Vision OCR against edited Markdown for that
  section when a pure OCR snapshot exists
- **Scan Header** for section PDFs
- **+** to add a manual section after that item
- **X** to remove a section/manual section after confirmation

The command column uses fixed button positions:

- section PDFs reserve positions for **Scan Header**, **Process**, and **Preview**
- manual sections hide **Scan Header** but keep its space reserved, so **Process** and
  **Preview** align with PDF rows
- **Preview** is enabled only when the section already has Markdown output
- **Compare** appears as an icon next to **Preview** only for non-manual section
  PDFs that have already saved a pure OCR snapshot
- row action buttons use compact icon+text styling with consistent height and
  accent-colored borders

Display names for real section PDFs include page count:

```text
Section 008 (10 pages)
```

Manual section rows use the manual title when available.

The **Ready for EPUB** checkbox starts unchecked for new sections. It is saved
with `book-sections.json` as user memory. Checked rows are skipped by
**Process OCR All** because the user has marked them complete, but the checkbox
must not affect EPUB build logic.

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
- Newly added manual sections start with an empty editable title field.
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
- `Process OCR All` runs OCR on existing real section PDF files that are not
  checked **Ready for EPUB**
- manual sections and **Ready for EPUB** checked sections are skipped by
  `Process OCR All`

The OCR source must be the section file path, not the original PDF.

### OCR Output

OCR writes per-page Markdown:

```text
AppleVision/MD/section-001/page1.md
AppleVision/MD/section-001/page2.md
...
```

When OCR runs, NewOCR also saves an untouched pure OCR snapshot for comparison:

```text
AppleVision/MD/section-001/OriginalOCR/page1.md
AppleVision/MD/section-001/OriginalOCR/page2.md
...
```

The editable MD files remain the normal `page*.md` files. Saving from the OCR
editor should not modify `OriginalOCR/`.

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
- process only real section PDFs that exist and are not checked **Ready for EPUB**
- skip manual sections and **Ready for EPUB** checked sections
- before each section OCR, remove existing resources for that section:
  - `AppleVision/MD/<section>/`
  - old `.md` files
  - old `Images/`
  - line-cache entries for that PDF in `AppleVision/LineCache/header-footer-lines.json`
  - stale `header-footer-review.txt`
- replace existing Markdown with newly generated Markdown
- show finished successfully when done

### Scan Header All

The **Scan Header All** icon button appears next to **Process OCR All** near the
Sections count. It scans only real section PDFs that exist, skips manual
sections, updates the same header/footer scan progress area, saves detected
titles only when a section title is empty, and opens the shared
`AppleVision/LineCache/header-footer-review.txt` review after the batch
finishes.

## OCR Image Detection

NewOCR detects image regions from rendered PDF pages and can insert Markdown
image references such as:

```md
![Page 1 image 1](Images/page1-image1.png)
```

Important fix/behavior:

- OCR text is priority.
- If Apple Vision recognizes meaningful text on a page, NewOCR must not emit any
  OCR-detected image Markdown for that page.
- Image-region detection should run only for pages where no meaningful OCR text
  is detected.
- A full-page scanned text page must not be replaced by a full-page image.
- Real smaller images, figures, diagrams, and illustrations are extracted only
  on pages without meaningful OCR text. Users can still add images manually from
  the OCR editor when a text page also needs an image.

This prevents pages or paragraphs from becoming image-only Markdown when text
OCR succeeded.

### User-Added Images

In the OCR paragraph editor, **Actions** supports **Add Image Before** and
**Add Image After**. The user chooses an image file, NewOCR copies it into the
current section's Markdown image folder:

```text
AppleVision/MD/<section>/Images/
```

Then NewOCR inserts an image paragraph before or after the current paragraph
using the same Markdown shape as OCR-detected images:

```md
![Alt text](Images/image-file.png)
Caption:
  Optional caption text
```

Caption is optional. If the user skips or leaves the caption blank, only the
image Markdown line is inserted. The user still needs to click **Save** in the
OCR editor to write the updated Markdown files.

## OCR Compare

The Section List can show a **Compare** icon next to **Preview** for a split PDF
after Apple Vision OCR has saved an `OriginalOCR/` snapshot. Manual sections do
not show Compare.

Compare opens a dark NewOCR-styled report for only that one split file. The
report compares pure Apple Vision OCR in `OriginalOCR/page*.md` against the
current edited MD `page*.md` files and shows only differences, grouped by page:

- Missing from MD
- Added in MD
- Changed

The report is intended for verification, so it should avoid dumping unchanged
text.

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

The Header/Footer Review UI uses the same dark NewOCR shell as other windows:
white 58×58 icon tile, dark outer background, red rectangular close button with
white X, bordered panel surfaces, dark row backgrounds with light text, and
red rectangular X buttons for removing approved header/footer items.

## OCR Editor

The OCR editor can show Markdown as paragraphs or as plain text. It follows the
same dark visual system as the main window and Add Split window: dark gray outer
background, bordered gray panels, white headings, colorful filled icon buttons,
and larger OCR editing text.

The window is a split editor:

- left pane: Search Text, badges, paragraph/plain-text editor
- right pane: file/OCR controls, selected PDF chip, and PDF preview
- the split is resizable so the user can give more width to the text editor or
  to the OCR controls and preview as needed
- the PDF preview control row shows the current source page as
  `Page 3 / 12` style text, alongside up/down page and zoom buttons
- the `Page n / total` text updates when the user scrolls or drags the PDF
  preview between pages
- the PDF preview can be dragged with the mouse to pan around the zoomed page,
  in addition to normal scrolling
- OCR PDF preview zoom is remembered per selected section PDF file, not as one
  global app zoom value

Features:

- Preview Markdown, Compare, Save Markdown, Close, Run OCR, Files, Log,
  Information, Replace, and Remove Search use icon-first buttons with hover help
- Search Text
- Replace All
- icon-only status/focus shortcuts for Image, Footnote, and Blockquote
- when Search Text is empty, scrolling the paragraph list switches the PDF
  preview to the nearest visible paragraph's source page; focusing or editing a
  paragraph text box also switches to that paragraph's source page
- paragraph labels show source page numbers only for paragraphs known to come
  from OCR page output, for example `Paragraph 1 (Page 1)`; manual sections,
  newly inserted paragraphs, and paragraphs without a known OCR page keep the
  plain `Paragraph 1` label; this state is saved in
  `paragraph-source-pages.json` next to the section's `page*.md` files
- paragraph editing actions:
  - add paragraph before/after
  - add user image before/after
  - add line break before/after
  - page break before/after
  - merge with paragraph above/below
  - remove paragraph
  - move paragraph up/down
  - add image description

After clicking Save, the success popup should show only `Save successfully` with
`OK` and `Close`. `OK` dismisses the popup and keeps the OCR/editor windows
open. `Close` dismisses the popup and closes the OCR window plus any OCR Preview
window, matching the previous save-success close behavior.

If the OCR Preview window is open, closing the OCR window should also close the
Preview window. This applies to both the OCR window **Close** button and the
Save-success OK flow.

The OCR Preview window uses the same dark NewOCR window shell as other windows:
white 58×58 icon tile, dark outer background, red rectangular close button with
white X, and bordered content panel. Only the actual rendered preview/WebView
area should be white.

The OCR Log is opened from a Log icon button instead of living as a large panel
inside the OCR editor. Clicking Log opens or focuses a separate dark themed log
window with the OCR status and `logOutput`. Closing the OCR window should also
close the OCR Log window.

Paragraph-to-PDF preview sync uses the per-page Markdown files in
`AppleVision/MD/<section>/page*.md`. Re-running OCR recreates those page files
and gives the most accurate source-page mapping. Existing OCR output can still
drive the preview when the original `page*.md` files are present; if older edits
were previously flattened into one file, the preview falls back to that available
page. Search/filter results do not move the PDF preview while the filtered list
is scrolled; in search mode, the jump happens only when a paragraph editor
receives focus or is edited.

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

It uses the project stylesheet from `Styles/stylesheet.css` if available, plus
fallback CSS. This applies to both PDF sections and manual sections. Preview
supports the same NewOCR Markdown/HTML features as EPUB where practical:

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
PREVIEW_TEXT_SCALE_PERCENT=170
```

The default is 170%. Values below 80 are treated as 170, and values above 220
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
- apply the project `Styles/` assets to manual sections and PDF sections
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
- after a successful build, show a dark NewOCR-styled popup saying
  `EPUB was created successfully` with **Open** and **Close**, without showing
  the EPUB file path

The EPUB success popup's **Open** button should try to open the generated EPUB
with Apple Books first, then fall back to the system default EPUB opener if
Books is unavailable. **Close** only dismisses the popup.

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
PREVIEW_TEXT_SCALE_PERCENT=170
NEW_PROJECTS_FOLDER=~/Downloads
```

Width values may be numeric or `FULL` for full-screen opening.

## Current UI Principles

- Keep the app as a practical working tool, not a landing page.
- Buttons should be clear, friendly, and consistent.
- The main top bar groups commands into compact menus instead of many separate
  buttons: Project contains New, Open, Revert Original, and Open Config; Edit
  PDF contains Add Split, Crop, Apply CSS, and Clear Scan Report; Build EPUB
  and Close remain single top-level commands. View EPUB appears in Project when
  a built EPUB file exists. Top-bar dropdowns are custom popovers, not native
  macOS menus, so rows can use larger text and visible hover/pressed
  highlighting. Project and Edit PDF open immediately when the pointer enters
  the trigger and close 80 ms after the pointer leaves both the trigger and
  the popover panel. Hover is detected via NSTrackingArea (HoverArea
  NSViewRepresentable) instead of SwiftUI .onHover; .onHover is unreliable
  here because the popover lives in a separate NSPanel which breaks SwiftUI
  tracking. Close scheduling uses DispatchWorkItem inside a MenuHoverController
  stored in @State so cancellation never reads SwiftUI state inside an async
  closure. Moving from the trigger into the panel cancels the pending close;
  switching to the other trigger sets activeMenuID immediately and the old
  menu's 80 ms close fires harmlessly (activeMenuID no longer matches).
  Only one menu may be open at a time via a single shared activeMenuID string. Dropdown rows should clearly highlight the item currently under
  the pointer; destructive rows use a light coral text/icon color at rest, then
  white text/icons over a softer custom coral-red hover/pressed highlight for
  readability instead of the saturated system red.
- The main header uses an OCR/document icon instead of a large text title. The
  project chip shows only the PDF/project name, hides the full path, and opens
  the project folder when clicked with a pointing-hand cursor on hover.
- Cover controls live in a left sidebar under an external EPUB Covers heading,
  with compact Front and Back rows using larger thumbnails. The Section List
  sits to the right so it can use more vertical space.
- Cover row controls and existing cover thumbnails use a pointing-hand cursor.
  Clicking an existing cover thumbnail opens the image file with the macOS
  default image app instead of an in-app preview window.
- Enabled clickable controls in the main window should use a pointing-hand
  cursor on hover, including top-bar commands, section utility buttons, section
  command icons, project/folder chips, cover controls, and clickable file names.
  Section row X/+ utility buttons and section file-name buttons use direct
  hover cursor handling so the pointer changes reliably inside the scrollable
  Section List.
- Across the app, any visible button, menu trigger, thumbnail, file name, chip,
  icon, or other UI surface that performs an action or navigates somewhere when
  clicked should change to a pointing-hand cursor on hover. Non-clickable text,
  labels, disabled controls, and purely decorative elements should keep the
  normal cursor.
- Use icons where they help scanning.
- Do not let decorative UI reduce section-list space.
- Do not alter behavior while only making UI more beautiful.
- Main workflows should be reachable from the main window.
- Section area should have as much useful space as possible.
- Use restrained neutral surfaces, subtle borders, and small shadows to separate
  the main window, Section List surface, header row, and command/action lane.
  Avoid large colored panels for professional workflow areas.
- Main window text should use the larger `MainTypography` scale on darker gray
  surfaces for clearer contrast, while filled command buttons keep high-contrast
  icon/text colors. The main window typography should stay visually close to the
  OCR window scale.
- Keep the EPUB Covers sidebar compact so the Section List gets most of the
  available width. Covers use smaller thumbnails and tighter spacing than the
  section table.
- Section List rows should use clear table structure: even rows and odd rows use
  alternating dark gray backgrounds, with separators and a command/action lane
  that follows the same row background.
- Section List hides the table header row; the columns are visually implied by
  consistent row alignment and icon treatments.
- The first Section List title field should not appear focused/highlighted when
  the main window opens. The main window clears the initial first responder
  after layout; users can still click any title field to edit normally.
- Section List utility buttons should match the rectangular action-button style:
  remove uses a red rounded rectangle with a white X, add uses a green rounded
  rectangle with a dark plus, and both use the same approximate button size as
  other row controls.
- Section List file indicators should be easy to distinguish: PDF rows use a
  larger orange document icon in a 46×36 rounded slot, manual/section rows use a
  larger blue section icon in the same slot, and the MD badge uses a similarly
  sized pastel pink rounded rectangle with black text.
- Section List command buttons should be icon-only on white backgrounds with
  black icons, sized large enough to click comfortably, and should show the
  command name in a floating `NSPopover` tooltip below the control.
- Section List command buttons use per-action colors: Scan Header is brown with
  a white icon, Process is blue with a white play icon, and Preview is orange
  with a black icon.
- Process OCR All should follow the same icon-only button treatment and use a
  stacked-items icon to suggest batch processing.
- Section List should use a gray outer panel with darker row/header content
  inside it, so the list area is visibly separate from the main window.
- The main window should not have its own vertical scrollbar for the normal
  workflow; Section List owns the vertical scrolling and fills the remaining
  window height.
- OCR editor windows should follow the same visual structure as the main window:
  `NewOCRMainPalette.windowBackground` as the outer background,
  `panelBackground` for editor/control/status/preview panes, `fieldBackground` for text,
  log, and preview fields, `stroke` borders, white headings, and colorful icon-first
  buttons. The OCR header uses the same white 58×58 rounded icon tile pattern as
  the main and Add Split headers, but only shows the `OCR` title in-window; do
  not show the selected filename under the OCR title. OCR top actions and side-panel actions use SF
  Symbol icon buttons with floating `NSPopover` tooltips instead of text-heavy
  buttons or SwiftUI in-row tooltip labels.
- The OCR editor content uses `HSplitView`: the Markdown editor is the left
  pane and OCR controls/PDF preview are the right pane. Preserve this split-pane layout
  when making UI-only changes so the user can resize text vs. controls.
- The OCR side toolbar does not include a Load Markdown button. Existing
  Markdown is loaded when opening a processed section; the OCR editor's primary
  side actions are Files, Run OCR, Log, and Cancel while running.
- The OCR top toolbar includes a Compare icon before Save when the selected
  non-manual section has a pure OCR snapshot.
- The OCR search row uses a white rounded `Search Text` field with larger black
  text and a larger search icon. Search actions are icon buttons named Replace,
  Remove Search, and Information.
- The old embedded OCR log area is a PDF preview panel. It uses `PDFKit.PDFView`
  in vertical continuous-page mode, shows the selected section PDF, and starts
  zoomed in so the preview reads like a cropped page inspection view. The
  preview panel does not show a `PDF Preview` title or OCR status text such as
  "Loaded existing AppleVision Markdown"; keep vertical space for the PDF
  itself. Up/down page navigation, `Page n / total` text, and Zoom In/Zoom Out
  controls live on one compact row. The PDF view should support hand-style drag
  panning so the user can drag the zoomed page to inspect a specific area. Zoom
  percent is stored per section PDF path so returning to a file restores that
  file's last OCR preview zoom.
- The OCR editor keeps an in-memory paragraph-to-source-page map when it loads
  `page*.md`. With an empty search field, paragraph-list scrolling may request a
  preview jump to the nearest visible source page. Paragraph focus/editing always
  requests a preview jump. Search filtering must not request scroll-based
  preview jumps. Saving edited Markdown should preserve known source pages by
  writing paragraphs back to their mapped `page*.md` files where possible.
- Paragraph row titles use the known OCR source-page flag before appending
  `(Page n)`. Do not show a guessed page number for manual sections, newly
  inserted paragraphs, user-added images, or paragraphs without a known OCR page
  source. The editor persists these flags in `paragraph-source-pages.json` in
  the section Markdown folder and falls back to treating existing non-manual OCR
  `page*.md` content as OCR-sourced when older folders do not have metadata.
- Image, Footnote, and Blockquote detection controls are icon-only status
  buttons. They show a green circle-check when found and a red circle-X when not
  found, and their hover text is shown in a floating `NSPopover` tooltip.
- The OCR Log window follows the same visual structure as the main, OCR, and Add
  Split windows: dark outer background, white 58×58 icon tile, title/subtitle
  header, red rectangular close button with white X, bordered panel, and dark
  field background for the monospaced log text.
- OCR editing text is intentionally larger than default AppKit text. Plain text
  and paragraph text editors share `OCRTypography.editorFontSize` and
  `OCRTypography.editorInset`; paragraph auto-height calculations must stay in
  sync with those constants to avoid clipping.
- The Add Split window uses the same dark `NewOCRMainPalette` color system as the
  main window: `windowBackground` as the outer background, `panelBackground` for
  the controls bar, input row, and status bar (each with a `stroke` border),
  `fieldBackground` for text input fields and the PDF preview area, and palette
  text roles (`primaryText`, `secondaryText`, `tertiaryText`) for all labels.
  The divider between nav and action buttons is a `stroke`-colored Rectangle
  instead of SwiftUI Divider. Text fields use `.textFieldStyle(.plain)` with
  custom padding and `fieldBackground`/`stroke` styling to match the dark theme.
- The Add Split window header mirrors the main window header layout: a white
  58×58 rounded-rect box containing a scissors icon (no large text title), and
  the PDF name displayed in a `panelBackground`/`stroke` bordered chip alongside
  an orange `doc.richtext` icon and page count. The entire controls bar — nav
  chevrons (← X/Y →), From/To/Title set-buttons, and the title/from/to text
  fields plus the Split button — are all in one single horizontal panel on the
  same row as the icon and chip. The text fields have no caption labels above
  them. The Section title field uses white background, black text, 14pt medium
  weight, yellow tint — identical to the section title field in the main window.
  The From and To fields are 46px wide (3-digit max of 999), monospaced digit.
  The Close button is a red rounded rectangle with a white X, matching the OCR
  window close button style. The VStack uses
  `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  .padding(22)` (fills the content area, 22pt insets), then an outer
  `.frame(minWidth: 1100, minHeight: 620)` bounds the NSHostingView fitting
  size. An `.onAppear` block mirrors the main window: `DispatchQueue.main.async
  { window.setFrame(visibleFrame) }` to go full-screen after the view is
  presented. NSWindow has `contentMinSize = (1100, 620)`. Top padding is 22.

## Known Behavioral Decisions

These are intentional and should not be changed casually:

- Add Split uses actual created `section-###.pdf` files to determine next page,
  not only `split-plan.json`.
- `split-plan.json` stores only created section files and includes `file`.
- Add Split preview navigation updates From until Title is non-empty, then To.
- Set From updates only From. Set To updates only To.
- Split button remains clickable and validates title on click.
- Process OCR All deletes old Markdown/images/cache for each unchecked section
  before OCR. Sections checked **Ready for EPUB** are skipped.
- Manual sections do not run OCR but can create/edit Markdown.
- OCR must use section PDF paths, not the original PDF.
- Empty paragraph slots from the paragraph editor should survive Preview and
  EPUB build.
- Header/footer removal requires `header-footer-review.txt` REMOVE entries.
- Working folder changes clear filtered text and header/footer review state.
- Full-page scanned text images should not replace recognized OCR text.
- Save in OCR window shows `Save successfully`; OK stays in the OCR window,
  Close closes the OCR window after save.

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

- If you change, fix, add, or remove app behavior or visible UI, update this
  README in the same work session so it remains the current handoff reference.
- Keep UI styling consistent across windows. New windows and tool surfaces
  should reuse `NewOCRMainPalette`, the white 58×58 icon tile header pattern,
  rounded 7-8pt controls, colorful icon-first buttons, floating `NSPopover`
  tooltips, and red rectangular close buttons with white X unless the user asks
  for a different style.
- Floating tooltip popovers should size to their full text instead of clipping
  or truncating longer labels.
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
