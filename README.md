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
is based on the source PDF name. After the user selects the source PDF, NewOCR
opens the Crop PDF window first. When the user saves the crop, the Crop PDF
window closes and the Add Split window opens for the same project.

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
- **Define Layout**: draw project-wide OCR layout-area rules manually for forcing
  header, blockquote, image, footnote, or ignore behavior across sections.
- **Build EPUB**: create EPUB from available section/manual Markdown.
- **Process OCR All**: OCR existing section PDF files that are not checked
  **Ready for EPUB**.
- **Scan Header All**: scan header/footer candidates for all existing section
  PDF files and open the shared Header/Footer Review.
- **Clear All OCR**: remove all OCR Markdown files and resources for every
  section and reset all Ready for EPUB flags. Shows a confirmation dialog before
  proceeding. Disabled when no sections have OCR output.

The project path display should stay compact and readable.

## Section List

The section list is the ordered book structure. It can contain:

- real section PDF files, for example `section-001.pdf`
- manual sections, stored under `ManualSections/`

Each section row supports:

- a user-controlled **Ready for EPUB** checkbox for personal tracking
- title editing in a flex field that fills the row
- **Preview** (eye icon, orange) — standalone icon button, enabled when Markdown output exists
- **More Actions** (ellipsis icon) — dropdown with all remaining actions:
  - **Scan Header** — scan header/footer candidates (PDF sections only)
  - **Process** — open/run OCR for that section
  - **Compare** — compare pure Apple Vision OCR against edited Markdown (PDF sections with a snapshot only)
  - **Clear OCR** — remove OCR Markdown files and reset the Ready for EPUB flag (destructive, shown in red)
- **+** to add a manual section after that item
- **X** to remove a section/manual section after confirmation
- **Clear All OCR** (main window, next to Scan Header All) to remove OCR for all sections at once with confirmation

Layout:

- **Preview** is enabled only when the section already has Markdown output
- **More Actions** dropdown is always enabled and adapts its items to the section's current state
- Manual sections hide **Scan Header** from the dropdown

Display names for real section PDFs include page count:

```text
Section 008 (10 pages)
```

Manual section rows use the manual title when available.

The **Ready for EPUB** checkbox starts unchecked for new sections. It is saved
with `book-sections.json` as user memory. Checked rows are skipped by
**Process OCR All** because the user has marked them complete, but the checkbox
must not affect EPUB build logic.

The section row **Title** field is book-structure metadata. It is saved in
`book-sections.json` and used as the first-choice chapter/TOC title when
building EPUB. It must not be passed into OCR, used to remove OCR lines, or
inserted/replaced as a heading when generated OCR Markdown is written. Saving
Markdown from the OCR editor writes the editor content as-is; it does not apply
the section row Title to the `.md` files.

When an existing project opens with split PDF files, the section list should
auto-scroll to the first row whose **Ready for EPUB** checkbox is not checked.
This helps resume work at the next unfinished section.

### Clear OCR

The **Clear OCR** button appears in the section row for any section (PDF or manual) that
has existing OCR Markdown output. Clicking **Clear OCR** shows a confirmation dialog. On
confirmation, NewOCR:

- Removes the section's `AppleVision/MD/<section>/` directory and all Markdown, images,
  and metadata
- Removes the pure OCR snapshot from `AppleVision/MD/<section>/OriginalOCR/`
- Removes line-cache entries for that section PDF from `AppleVision/LineCache/header-footer-lines.json`
- Resets the section's **Ready for EPUB** checkbox to unchecked
- Preserves `AppleVision/LineCache/header-footer-review.txt` so approved header/footer filters remain active

This allows reprocessing a section with new OCR settings or fixes without deleting the section PDF itself.

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

- Add Split is available only after the working PDF has passed the Crop step.
  The crop-completed marker is the backup PDF created beside the working PDF
  when Crop PDF is saved. Once that marker exists, Add Split should remain
  editable regardless of existing split ranges.
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
- When Add Split was opened from the **New** project route and the user closes
  it before creating any split files, warn that no split PDF exists yet. The
  user may continue splitting or exit anyway.
- Section output file names are sequential:

```text
section-001.pdf
section-002.pdf
...
```

Detect Split:

- The Add Split header has an icon-only **Detect Split** button next to the file
  name.
- Detect Split reads bookmark-derived ranges from the current working PDF. If
  the user already saved Crop PDF, this is the cropped working PDF, not
  `_original.pdf`. It should reload bookmarks from that working PDF when the
  Detect Split button is clicked so an already-open Split window does not use
  stale cached PDF state. If the working PDF returns no bookmark outline,
  Detect Split may fall back to `_bkp.pdf` or `_original.pdf` for bookmark page
  metadata only; generated section PDFs must still be split from the cropped
  working PDF.
- The popup shows a vertically scrollable list with Checkbox, editable Title,
  editable From, editable To, and a large thumbnail of each range's From page.
  Editing From should immediately refresh that row's preview thumbnail. Editable
  fields should use the same white, black-text, yellow-tint text-field style as
  Add Split fields, with a narrower text column so the preview stays prominent.
- Detect Split checkboxes use the same large icon-button checkbox style as the
  main Section List so they are easy to see and click. Selected checkboxes and
  selected row borders use blue. The header includes icon-only **Select All**
  and **Unselect All** buttons for checking or clearing every detected range.
- The first detected range's Title field should not appear focused/highlighted
  when the Detect Split window opens; clear the initial first responder after
  layout when this issue appears in new editable popup/list surfaces.
- **Split** creates checked ranges in batch as sequential `section-###.pdf`
  files. The editable **Title** value currently shown in each checked Detect
  Split row is the value that must be saved for the matching new section.
  NewOCR writes those edited titles directly to `book-sections.json` at split
  save time, then reloads the main section list from `book-sections.json` so the
  section row Title text fields show the saved values immediately. This must
  work both when Add Split is opened directly and when Add Split opens
  automatically after saving Crop PDF.
- `split-plan.json` also stores the created ranges and their titles for split
  history/debugging, but the main Section List title text fields should not rely
  on a later fallback from `split-plan.json`. Detect Split must persist the
  edited row titles into `book-sections.json` when the user clicks **Split**.
- **Close** only closes the Detect Split window.

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
working PDF. It should preserve `_original.pdf` and copy the PDF bookmark
outline into the cropped working PDF so Detect Split can still use bookmarks.

When the user clicks **Crop** and the project already has one or more
`section-###.pdf` files, NewOCR first shows a dark NewOCR-styled confirmation
popup. **Close** leaves the project unchanged and does not open Crop. **OK**
removes all section PDF files, clears saved split ranges, removes generated OCR
resources for those sections, resets their titles/Ready flags, and then opens
Crop for the working PDF.

The crop window may open full screen based on config.
It should use the same dark NewOCR window style as Add Split and OCR windows:
icon-only Save/Close buttons, larger readable labels, and the shared thick
NewOCR page slider instead of previous/next chevron buttons. The Crop page
slider uses slightly faster drag sensitivity so page changes feel responsive.

When Crop PDF is saved successfully, the Crop PDF window closes and Add Split
opens for the freshly cropped working PDF.

If Crop PDF was opened from the **New** project route and the user closes it
before saving a crop, warn that the crop is required before continuing to Add
Split. The user may return to cropping or close anyway; closing anyway leaves
Add Split unavailable until a crop is saved.

When saving a crop while one or more `section-###.pdf` split files already
exist, show a warning that saving the crop will remove those split files because
they were created from the previous page layout. If confirmed, remove the split
PDFs and clear stored split ranges so the user can split the newly cropped PDF
again.

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
The Section List **Title** field is not an OCR input. OCR must not use it to
remove matching title/header lines and must not insert it into generated
Markdown as a heading. Layout-area `header` rules and the recognized PDF text
itself are the mechanisms that can create headings in OCR output.

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

During OCR, two automatic cleanup passes run before layout rules are applied:

- **Superscript removal** — two complementary passes:
  - *Standalone line removal*: OCR observations that are geometrically elevated above neighbouring body text are silently dropped. A line is treated as a superscript when its height is less than 55 % of the page median line height, its text is 1–4 characters consisting only of digits, ASCII letters, or common footnote symbols (`*`, `†`, `‡`, `§`, `¶`, `°`, `+`, `-`), and its lower edge sits at or above the vertical midpoint of a horizontally-overlapping body-text line.
  - *Inline Unicode superscript stripping*: Apple Vision sometimes embeds superscript reference numbers directly inside a text observation rather than emitting a separate small line. Characters in the Unicode superscript digit block (⁰ ¹ ² ³ ⁴ ⁵ ⁶ ⁷ ⁸ ⁹) and common superscript letters (ⁱ ⁿ ᵃ ᵇ … ᶻ) are stripped from every OCR line before layout rules are applied. These characters are unambiguous — they never appear in normal body text.

- **Underscore artifact removal**: underscore characters that appear at word boundaries are removed from the text of each remaining line. This corrects a common Vision OCR artifact where italic-styled text is misread as Markdown italic syntax (e.g. `_บทที่ 1` → `บทที่ 1`).

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
- keep `AppleVision/LineCache/header-footer-review.txt`; it is shared review
  input used by OCR to remove approved header/footer lines
- replace existing Markdown with newly generated Markdown
- show finished successfully when done

### Scan Header All

The **Scan Header All** icon button appears next to **Process OCR All** near the
Sections count. It scans only real section PDFs that exist, skips manual
sections, updates the same header/footer scan progress area, saves detected
titles only when a section title is empty, and opens the shared
`AppleVision/LineCache/header-footer-review.txt` review after the batch
finishes.

## OCR Layout-Driven Special Areas

NewOCR does not automatically detect images, blockquotes, or footnotes during
OCR. Those special areas are controlled by **Edit PDF > Define Layout** so
the user can draw the exact page area that should become an image, image
description caption, quote, footnote, header, or ignored text.

Process OCR still detects large vertical gaps between OCR text lines as blank
paragraph breaks. The surrounding text paragraphs stay unchanged, and NewOCR
inserts a separate `<br/>` paragraph between them so the visible blank row is
preserved.

Paragraph boundaries are detected by `buildContinuousParagraphs`. A new
paragraph starts when a line is indented or has a blank-line gap above it.
The indent threshold is `max(0.015, columnWidth × indentFraction)` where
`indentFraction` is determined per PDF by a calibration pass that runs
automatically before the first OCR of each file.

A continuation line (non-indented, no blank gap) joins the previous line when
the previous line was "full" (reached within 8% of `normalRight`). In Thai
justified text the OCR may slightly under-report the right edge of the last
character, preventing a full-line detection. To handle short carry-over
fragments (e.g. a single word wrapping to the next line), a line shorter than
40% of `normalWidth` is always joined even if the previous line was not
detected as full.

**Short-line indent bypass**: when the previous line was full AND the current
line is short, the indent check is skipped and the line is always joined. In
Thai dialogue text the wrapped carry-over word (e.g. `ไหม"`) sits at the same
indentation level as the rest of the speech, which would otherwise trigger a
spurious new paragraph via the normal indent check.

**Indent calibration**: before the main OCR loop, the app samples up to 5 body
pages (skipping page 0) at scale 2.0, runs Vision OCR on each, and collects
`(line.left − normalLeft) / columnWidth` offsets. A histogram with 0.5%-wide
bins identifies the first repeating positive offset cluster — the paragraph
indent. The threshold is set at 65% of the detected indent center. The result
is cached in `AppleVision/indent-calibration.json` keyed by PDF filename and
reused on every subsequent OCR run of the same file. If detection fails or the
file is not yet calibrated, the fallback fraction is `0.04`.

Page-boundary paragraph merging must not merge Markdown blockquotes, images,
or HTML comments with normal body text. If either side of a possible
page-boundary merge starts with `>`, `![`, or `<!--`, NewOCR keeps the
paragraphs separate.

**Heading detection guards:** `isHeadingLine` requires all of:
- the line is in the first two OCR positions on the page (`index <= 1`)
- the line is near the top of the page (`bottom >= 0.42`)
- the line is short (≤ 74 % of column width for index 0, ≤ 65 % for index 1)
- the line is horizontally centered
- there is a large vertical gap below the line, OR it follows a chapter-number
  line or another centered title line — **this gap condition now applies to
  index 0 as well**; previously index 0 was exempt, which caused short dialogue
  lines at the top of a page to be misread as headings
- the line does **not** start with a quote character (`"`, `'`, `"`, `'`,
  `«`, `‟`, `「`, etc.) — dialogue lines are never chapter headings

When a page contains footnotes, OCR appends the footnote definitions and a
`<!-- page-break-after -->` marker after the last body-text paragraph. The
merge step must look past these trailing special paragraphs to find the last
real body-text paragraph. NewOCR searches backward through the previous page's
paragraphs, skipping any that start with `<!--` (page-break comments) or `[^`
(footnote definitions), and merges that body paragraph with the first paragraph
of the next page — leaving the footnote definitions and the page-break marker
in their original position after the merged text.

The page-boundary continuation flags (`lastTextLineCanContinueNextPage`,
`firstTextLineContinuesPreviousPage`) are computed from OCR lines before the
layout-rule substitutions run. When a page ends with footnote lines (which are
narrower than body text), the right-edge check on those lines would wrongly
prevent the preceding body paragraph from merging. To avoid this, footnote-area
OCR lines are excluded when computing these flags — only non-footnote body lines
are considered.

After the cross-page merge, the replaced paragraph range includes the trailing
`\n` of its last line. Without compensation, the following content (footnote
definitions, page-break comment) loses one `\n` of the blank-line separator and
collapses into the same paragraph. `replacingMarkdownParagraphAtRange` appends
`"\n"` to the replacement to keep the separator intact.

## OCR Layout Areas

### Define Layout

**Define Layout** (`Edit PDF > Define Layout`) is the editor for managing layout
rules. It is a manual editor for drawing rectangles and saving rules by hand — use
it for precise rules like marking an image region or ignoring a specific page
element. It is backed by `LayoutAreaEditorState` and writes rules to per-section JSON files under `AppleVision/`.

### `isAuto` Field in OCRLayoutAreaRule

Every layout area rule carries an optional `isAuto: Bool` field
(default `false`). Rules drawn in Define Layout are saved with `isAuto: false`.

**Migration**: when loading a layout-areas file, any rule where `isAuto` was never
written (older files, value `nil`) is treated as `isAuto: true` on load, so
pre-existing project files remain valid.

This field is informational — OCR processing ignores it.

---

**Edit PDF > Define Layout** opens a project-wide visual editor. Choose a
sample section/page, select **Section Title**, **Quote**, **Image**,
**Image Description**, **Footnote**, or **Ignore**, drag the rectangle over
the page area, then click **Save Area**. Define Layout saves rules as
page-scoped entries for the currently selected section/page.

The editor writes the project layout rules automatically to per-section files:

```text
AppleVision/layout-areas.json          ← all_sections rules
AppleVision/layout-areas-section-001.json  ← rules for section-001.pdf
AppleVision/layout-areas-section-002.json  ← rules for section-002.pdf
…
```

**Existing projects** with a single `layout-areas.json` are migrated automatically on first open: section-specific rules are split out into their per-section files and removed from the global file.

### Layout Area Rules Report

The **View Rules** button in the Define Layout header opens a formatted report of saved
layout area rules **for the currently selected section** (rules scoped to that specific
section or to all sections). The report is styled as a beautiful dark panel, consistent
with other NewOCR confirmations, and displays each rule with:

- **Type icon and label** (Section Title, Quote, Image, Image Description, Footnote, Ignore)
- **Scope information** (All Sections, specific section, or page number)
- **Load button** (blue pencil icon) to load the rule's settings for editing — closes View Rules and populates the editor controls with that rule's values; the header button changes to **Update Rule**
- **Delete button** (trash icon) to remove individual rules

**Cancel edit flow**: while a rule is loaded for editing (`state.loadedRule != nil`) a **Cancel** button (grey, `arrow.uturn.left`) appears in the Define Layout header to the left of **Update Rule**. Clicking it clears the loaded rule and re-opens the View Rules sheet so the user can pick a different rule without closing and re-opening the panel manually.

**Row Styling**: Each rule row features:
- **Alternating dark/light backgrounds** for visual rhythm and scannability
- **Colored borders** that swap between light and dark, matching the row background
- **Rounded corners** for a refined appearance
- Even rows use a darker background with lighter border; odd rows use lighter background with darker border

**Loading Rules for Editing**: Clicking the blue pencil icon loads that rule's settings into the editor:
- The rule type, scope, and rectangular selection are populated in the editor
- The correct scope button (All/Selected/Section/Page) is highlighted based on the rule's scope
- If the rule targets a specific section, `selectedLayoutSectionPaths` is set to `[pdfItem.url.path]` so that section stays checked and highlighted (no longer clears the selection)
- The PDF preview scrolls to the rule's page and shows the saved region rectangle
- While editing, the region rectangle is pinned to the rule's original page: `isActive` is `page == (loadedRule.page ?? 1)` instead of `page == selectedPage`, so scrolling through other pages does not move or hide the region — it stays until the user explicitly moves or redraws it
- Both `preview` and `statusBar` vars are `@ViewBuilder` (not `AnyView`) so SwiftUI preserves the `ScrollViewReader`/`ScrollView` structural identity across re-renders; previously, `AnyView` caused the scroll view to be recreated on every state change (sheet dismiss, etc.), resetting to page 1
- `onChange(of: state.selectedPDFPath)` scrolls to `state.selectedPage` (already set to `rule.page` synchronously by `loadRule`) rather than hardcoded 1
- Manual section clicks in `toggleSectionCheck` explicitly set `selectedPage = 1` so normal section switches still start at page 1
- The **View Rules** button becomes disabled (grayed out) to prevent opening another rule set while editing
- The **Save Area** button changes to **Update Rule** with an orange pencil icon
- After editing, click **Update Rule** to save changes or **Cancel** to return to View Rules

**Auto-load on page/section navigation**: When the user slides to a different page or switches
section, the editor automatically looks up any saved rule matching the current type + scope +
section + page and loads it into the area box. When an existing rule is auto-loaded:
- The rule's rectangle is shown in the preview area
- The **Save Area** / **Update Rule** button is replaced by a purple **New Rule** button
- Clicking **New Rule** clears the auto-loaded rule and resets the selection to the default
  rectangle, bringing back the **Save Area** button so a fresh rule can be drawn and saved
- This pattern also applies when switching rule type (Header → Quote → Image etc.)

**Duplicate Rule Detection**: When clicking Save Area or Update Rule, NewOCR checks if a rule with the
same type, scope, section, page, and rectangle position already exists. If a duplicate is found:
- A beautiful warning dialog appears with the yellow warning icon
- The dialog shows the existing duplicate rule's details (type, section, page)
- User must click **Close** to dismiss the warning and return to editing
- The rule is not saved, allowing the user to adjust the rectangle or change settings

**Deleting Rules**: When clicking the delete button, a confirmation popup appears showing:
- The rule type with icon
- The rule scope (section and/or page)
- A warning that the action cannot be undone
- Cancel and Delete buttons

The report uses consistent NewOCR dark styling with color-coded rule type icons for easy
scanning. The close button is distinct from delete buttons, preventing accidental closure
when attempting to delete a rule.

### Define Layout PDF Preview

The PDF preview in Define Layout shows **all pages stacked vertically** in a continuous-scroll view — like a real PDF viewer. Each page fills the available width; scrolling down reveals subsequent pages.

**Page navigation (two-way sync):**
- Scroll down/up through the main preview area — the thumbnail strip glides in sync, always keeping the current page centred
- Click any page card in the main view to activate it (blue border + rectangle editor appear)
- The **thumbnail strip** also lists all pages; clicking one scrolls the main view to that page
- The page slider in the controls row jumps directly to any page and the main view scrolls to it
- Programmatic scrolls (thumbnail click, slider, section change) set `isProgrammaticScroll` for 0.4 s to prevent write-back loops; user-initiated scroll sets `isUserScrollDriven` for one tick to suppress the reverse `scrollProxy.scrollTo` call

**Zoom:**
- A floating `− 75% +` pill is overlaid at the bottom-centre of the preview area (`previewZoomBar`)
- Steps are 25%; range is 25 %–400 %. Clicking the percentage label resets to 100%
- At > 100% pages exceed the container width and horizontal scrolling is enabled (`ScrollView([.vertical, .horizontal])`)
- Zoom is stored in `LayoutAreaEditorState.previewZoom` (`@Published`), saved to UserDefaults via `layoutEditorDefaultsKey("previewZoom")` when the window closes, and restored on next open — so each project remembers its own zoom level
- **Default zoom** comes from `config.txt` key `LAYOUT_PREVIEW_ZOOM` (integer percent, default 75, minimum 25). On first open of a project the config value is used; after that the saved UserDefaults value takes over
- The `pageWidth` inside `GeometryReader` is `max(container.size.width - 48, 100) * state.previewZoom`

**Rectangle editing:**
- The selection rectangle and resize handles are only active on the currently selected page
- Clicking a non-active page activates it; the editor then appears on that page
- Drawing the selection rectangle and moving/resizing handles work correctly at any zoom level (normalised 0–1 coordinates scale with `pageWidth`)

A small loading spinner appears in the top-right corner of the active page card while the cached thumbnail is being read.

When **Define Layout** is opened, NewOCR checks whether page thumbnails have been
cached for all section pages. If any are missing, a modal progress panel appears
on the main window ("Preparing Layout Thumbnails") while all pages are rendered
in the background at scale 2.0 and saved as JPEG files to:

```text
AppleVision/LayoutThumbs/<section-stem>-page<N>.jpg
```

On subsequent opens the thumbnails are loaded from disk instantly (in-memory
cache is also populated so the same session never re-reads disk). The cache is
used by the Define Layout preview. Delete the `LayoutThumbs/` folder to force a
full regeneration.

**Thread safety:** `layoutAreaPreviewCache` is accessed from both the main thread
(via `LayoutAreaPageCard.body` and the thumbnail strip) and background threads
(via `loadPreviewImageAsync`). Access is serialised with `layoutAreaPreviewCacheLock`
(`NSLock`) inside `layoutAreaPreviewImage` to prevent data-race crashes.

**Section selection / rule count consistency:** The "X saved" header count and
`filteredSavedRulesForSelectedScope` both return **0** when no sections are checked
(`selectedLayoutSectionPaths` is empty and scope is not `all_sections`). The old
`?? selectedPDFName` fallback that caused a non-zero count with nothing checked has
been removed. The blue "current preview" highlight on a section row is also cleared
when that section is not in `selectedLayoutSectionPaths` (e.g. after Unselect All).

`restoreLayoutEditorState` also ensures that if all previously saved section paths
are now invalid (files renamed/moved), it falls back to `[selectedPDFPath]` so the
state remains consistent after reopening.

Define Layout remembers the last-used selection state per project. When closed and
reopened, it restores: the previewed section, scope (All/Selected/Section/Page),
checked section paths, current page number, and selected rule type. Saved paths
that no longer exist (section removed) are silently dropped. State is stored in
UserDefaults keyed by project folder path, so different projects keep independent
preferences.

Define Layout is available only after at least one `section-###.pdf` split file
exists in the project folder. The **Define Layout** button in the main window is
disabled until at least one section PDF is created.

The Define Layout section list shows only sections that are **not** marked as
completed (ready for EPUB). Sections toggled as completed in the main window are
excluded from the list, from the "All" and "Selected" scopes, and from the View
Rules report opened within Define Layout. If all sections are completed the
editor shows an alert instead of opening.

The Define Layout editor only works with real `section-###.pdf` files from the
current project. Its preview is rendered from those section PDFs, which are
created from the cropped working PDF. It must not preview, save coordinates
from, or apply OCR layout rules against `_original.pdf`.

This is a main-window action because the same rules can apply across all
sections.

Supported rule types:

- `header` — shown in the UI tooltip as **Section Title**. OCR lines in the
  rectangle are written as Markdown level-2 headings, for example `## Title`.
  **Important:** If a header rule rectangle contains multiple lines, each line becomes
  its own heading with the same nesting level:
  ```
  ## Line 1
  ## Line 2
  ## Line 3
  ```
  Header rules (`header`, `h2`, `header3`) only apply to the first page of each
  section, never to subsequent pages. This prevents section titles from appearing
  on every page.
- `blockquote` — OCR lines in the rectangle are written as Markdown
  blockquotes with `>`. A blank paragraph (`<br/>`) is automatically inserted
  after every blockquote block so the following body text has visual separation.
- `image` — the rectangle is cropped from the rendered PDF page, saved to
  `Images/`, and inserted as Markdown image syntax. Enter an **Image label**
  in the label field (e.g. `Image#1`, `Fig 3`) — this label appears as the
  image's alt-text and is used to match with a corresponding `image_desc` rule.
  If left empty the system uses `Image N` (auto-numbered by position).
  A blank paragraph (`<br/>`) is automatically inserted after every image block
  (including after its description when one is matched) so the following body
  text has visual separation.
- `image_desc` — shown in the UI as **Image Description**. Draw this rectangle
  over the caption or description text for a specific image (e.g. a figure
  caption that appears at the bottom of the page, not immediately below the
  image). Enter the **same label** used in the matching `image` rule into the
  label field. During OCR:
  - The OCR text from the `image_desc` area is extracted and removed from the
    normal text flow.
  - It is placed in italics immediately after its matching image in the Markdown
    output, regardless of where the caption physically appears on the page.
  - A blank paragraph follows the image+description block:
    ```markdown
    ![Image#1](Images/page2-Image1.png)

    *ภาพที่ 1 แสดงให้เห็นถึงโครงสร้างหลักของอาคาร*

    <br/>

    body text continues here...
    ```
  - If no matching `image` label is found the description text is silently
    discarded (it was removed from normal flow but not placed anywhere).
- `footnote` — OCR lines in the rectangle are written as Markdown footnote
  definitions. When saving a Footnote area in Define Layout, enter a
  comma-separated list of labels in the **Labels** field (e.g. `1,2,3` or
  `*,†,‡`). During OCR, each captured line is paired with the corresponding
  label in order:
  ```
  line 0 + label "1"  →  [^1]: Archie's Pals 'n' Gals ...
  line 1 + label "2"  →  [^2]: Êmile Zola ...
  line 2 + label "3"  →  [^3]: Thérèse Raquin
  ```
  If no labels are entered, the system falls back to auto-detecting a leading
  superscript digit (¹ ² ³ …) or ASCII digit/symbol prefix (`1.`, `1)`, `*`,
  `†`) on each line.
- `refmark` — shown in the UI tooltip as **Ref Mark**. Draw this rectangle over
  the body-text paragraph that contains the inline reference for a specific
  footnote. Fill in two fields:
  - **Ref label** (e.g. `1` or `*`) — the footnote marker that will be inserted as `[^label]`.
  - **Word in area** — the exact word from the OCR text of that line after which
    `[^label]` is placed. Type the word exactly as it will appear in the OCR
    output (case-sensitive, character-exact). During OCR, NewOCR searches the
    recognized text for this word and inserts `[^label]` immediately after it.
    If the word is not found in the OCR line, the marker is **not inserted** for
    that line — the rectangle overlapped an adjacent line by accident, so skipping
    it avoids duplicate `[^label]` markers on nearby lines.
  Example: if the OCR line reads "อาร์ชี แต่เขากลับนึกถึงเอมีล" and the
  reference follows "เอมีล", enter **Ref label** `1` and **Word in area**
  `เอมีล` → OCR produces `อาร์ชี แต่เขากลับนึกถึงเอมีล[^1]`.
  Draw one Ref Mark rectangle per footnote reference location, each with its
  own label and anchor word, so multiple references on the same page each
  produce the correct `[^N]` marker.
  If no label is entered the text is kept unchanged.
  Old rules saved without an anchor word fall back to the previous
  superscript-artefact detection strategy.
- `ignore` — OCR lines in the rectangle are removed from Markdown.

Refmark lines are integrated into the normal text flow during OCR rendering. The
`[^label]` insertion is applied first, then the processed line is treated as a
regular body-text line by `buildContinuousParagraphs`. This ensures that a short
carry-over line that follows a refmark line (e.g. a word wrapping to the next
OCR line) is joined into the same paragraph rather than being split off.

### Codex Text Override (`codexText`)

The **View Rules** panel shows `codexText` when present for a rule. It appears
as an italic blue-tinted quoted block beneath the rule's scope metadata so the
saved Codex text is immediately visible without opening the editor.

When clicking the pencil **Edit** icon for a rule that has `codexText`, the
Define Layout editor shows a **Codex Text Override** panel below the type/scope
controls. The panel contains a multi-line text editor pre-filled with the saved
Codex text. The panel border highlights in the type's accent color when text is
present. A **Clear** button removes the override. Saving or Updating the rule
persists the current text in the panel back to the rule's layout-areas JSON file.

When a rule is created in Define Layout, the Codex Text Override panel is empty
by default and can be filled by typing or pasting text. This lets users manually
specify replacement text for any header, blockquote, footnote, or
image-description area.

### How OCR Uses `codexText`

A rule may carry an optional `codexText` field containing override text for that
area. During OCR:

- Any Apple Vision OCR lines that overlap the rule rectangle are **discarded**.
- The saved `codexText` is used verbatim in their place, split by newline into
  synthetic lines that are then classified by the same rule type (header → `##`,
  blockquote → `>`, footnote → `[^label]: …`, image_desc caption).
- Rules without `codexText` (the default for drawn rules) continue to use Apple
  Vision OCR as before.
- `codexText` may be edited directly in the rule's layout-areas JSON file when a correction is
  needed.

Advanced JSON example:

```json
{
  "rules": [
    {
      "type": "blockquote",
      "codexText": "The original quoted passage text.",
      "scope": "all_sections",
      "page": 1,
      "rect": {
        "left": 0.20,
        "right": 0.88,
        "top": 0.78,
        "bottom": 0.66
      }
    },
    {
      "type": "image",
      "scope": "all_sections",
      "page": 1,
      "rect": {
        "left": 0.14,
        "right": 0.86,
        "top": 0.64,
        "bottom": 0.40
      }
    },
    {
      "type": "header",
      "codexText": "Chapter 3: The Journey Begins",
      "section": "section-003.pdf",
      "page": 1,
      "rect": {
        "left": 0.18,
        "right": 0.90,
        "top": 0.90,
        "bottom": 0.80
      }
    }
  ]
}
```

Coordinates are normalized page coordinates from `0.0` to `1.0`, using the same
coordinate style as OCR boxes: `left`/`right` are horizontal positions, `top` is
near the top of the page, and `bottom` is below it. A rule matches a line when
the line overlaps the rectangle enough or the line center falls inside it.
These coordinates are relative to the rendered `.cropBox` of the selected
section PDF page. Because section PDFs are generated from the cropped working
PDF, layout-area coordinates are based on the cropped version of the page.
During OCR, NewOCR renders the same section PDF page with `.cropBox` and applies
the saved normalized coordinates to that render. `_original.pdf` may be used by
Detect Split only for bookmark metadata fallback; it must not be used for OCR
layout coordinate application or image crops.

Rule scope:

- **All** saves `scope: "all_sections"` with no `page`, so the rule applies to
  every page in every section.
- **Selected** opens a modal section picker with first-page previews, checkboxes
  unchecked by default, and Select All/Unselect All commands. Saving writes one
  filename-specific rule per checked section with no scope (section field only).
- **Section** saves the current section filename with no `page`, so the rule
  applies to every page in the current section (section field only, no scope).
- **Page** saves the current section filename plus the current `page`, so the
  rule applies only to that page of the current section (both section and page fields).
- `section: "section-003.pdf"` or `section: "section-003"` limits any saved
  rule to that section filename/stem.
- `page` limits a saved rule to a page number inside each matching section.

### Scope Usage During OCR

When OCR processes a section PDF, NewOCR:

1. Loads layout area rules from `layout-areas.json` (all_sections) and `layout-areas-{stem}.json` (section-specific)
2. For each page, filters rules using `matchingLayoutAreaRules()` which checks:
   - **Page number**: if the rule has a `page` field, it must match the current page
   - **Section filename**: if the rule has a `section` field, it must match the current PDF
   - **Scope**: if no section field exists, the rule applies to all sections only if `scope: "all_sections"`
3. Applies the filtered rules to recognize images, headers, blockquotes, footnotes, and ignored areas
4. Builds Markdown output with layout areas properly applied

This ensures rules respect their defined scope even when reprocessing multiple sections.

OCR priority:

1. Apply normal header/footer and user text filters.
2. Remove lines matched by `ignore` layout areas.
3. Crop image layout areas and remove OCR text that overlaps those image areas.
4. Force remaining lines matched by `header` / **Section Title** areas to
   Markdown `##` headings.
5. Force remaining lines matched by `blockquote` areas to blockquotes.
6. Force remaining lines matched by `footnote` areas to footnote definitions.
7. Run normal paragraph and blank-line Markdown behavior for the rest.

The visual editor is the recommended workflow. Direct JSON editing is intended
for debugging or unusual layout rules.

UI notes:

- Define Layout should stay visually consistent with Crop/Add Split/Detect
  Split windows: full-size dark working window, white header icon tile, large
  readable title/subtitle, `OCRIconButton` command icons, bordered dark panels,
  and a large expanding PDF preview area.
- Define Layout known-good window values: `NSWindow` content rect
  `1180x820`, `contentMinSize = NSSize(width: 900, height: 720)`,
  `NSHostingView.sizingOptions = []`, open with `window.setFrame(visibleFrame,
  display: true)`, root view top padding `44`, horizontal padding `36`, bottom
  padding `22`, and root minimum frame height `720` without forcing a fixed
  minimum width.
- Use a split working layout. The left panel is the section file list, about
  `300` points wide, with large clickable rows (`minHeight: 68`) for selecting
  the active section PDF. Do not use a compact Section dropdown for this window.
  The right side gets the remaining width and contains Scope controls,
  icon-only layout-type buttons, a compact page-nav row, and the expanding PDF
  preview.
- Keep the controls from being cut off: the layout-type icon buttons and wider
  Scope segmented control share one compact control row when space allows; the
  row may wrap before it overflows. Page navigation (⬆ X/Y ⬇) lives in its own
  status-bar row below. Define Layout does not show default instruction text in
  this control row; save/error status appears in the header area (below the
  Define Layout title) after an action, not in the page-nav row.
- Do not use the native AppKit segmented picker for Scope on this dark surface;
  its text can inherit dark colors and become unreadable. Use the custom
  SwiftUI segmented control style with explicit light text and a clear selected
  background.
- View Rules, Clear Rules, Save Area, and Close are top-header
  `OCRIconButton` commands, matching Crop/Split-style windows. Do not move
  primary commands to a bottom footer where an expanding preview can push them
  off-screen. Put the saved-rule count in this top header immediately before
  the command buttons, using large readable header text. The count and the
  **View Rules** popup both reflect the **selected scope on the left panel**:
  - When **All Sections** is selected: show total count of all saved rules;
    View Rules shows all rules (no section filter).
  - When a specific section is selected: show only rules that apply to that
    section (`scope: "all_sections"` or `section == currentPDFName`);
    View Rules shows the same filtered list.
  This keeps the header count and View Rules popup always consistent with
  what the user has selected on the left.
  When the View Rules panel is dismissed (after any deletions), the header
  count is refreshed immediately via `reloadAllSavedRules` so the badge
  always reflects the current on-disk state.
- The layout-type commands, Section Title, Quote, Image, Footnote, and Ignore,
  are icon-only buttons. Show their text labels in floating `NSPopover`
  tooltips on hover, matching the other NewOCR icon controls. Section Title is
  saved internally as rule type `header` for compatibility with existing
  layout-areas JSON files.
- Page navigation in Define Layout: the main preview shows all pages stacked and scrollable. The page slider and thumbnail strip both jump-and-scroll to any page. Action status text appears in the top header.
- Define Layout does not show scope tabs. The `Select All | Unselect All`
  strip above the left section list only controls the section list selection.
  Define Layout saves the rule as `scope: page` for the current section/page.
  Clicking **Unselect All** clears `selectedLayoutSectionPaths`. This is
  correctly restored on re-open: the section selection paths are set to empty
  even if the saved path list was empty
  (previously the `!restored.isEmpty` guard prevented this, leaving the initial
  PDF path checked alongside "All Sections"). Clicking **Selected**, **Section**,
  or **Page** tabs while "All Sections" is checked transitions out of
  all_sections scope — "Selected" checks all individual sections,
  "Section"/"Page" checks only the current preview section. Clicking a section
  row always updates the PDF preview to that section, in addition to toggling its
  checkbox. The last remaining checked section cannot be unchecked.
- Above the section list a **Single / Multiple** segmented control (default: Single)
  determines how many sections can be checked at once.
  - **Single**: clicking any row checks only that row and unchecks all others.
    **Select All** is disabled. The mode is saved per project and restored when
    Define Layout is reopened.
  - **Multiple**: original toggle behaviour — clicking a row adds or removes it
    from the checked set; **Select All** is enabled. Switching from Multiple back
    to Single trims the selection to the currently previewed section.
- When Define Layout opens fresh (no rule loaded), the default type is **Quote**
  and the default scope is **Page** (since Quote is a page-only type). Page-only
  types (Quote, Image, Image Description, Footnote, Ref Mark) always start with
  scope set to Page.
- The Define Layout PDF preview shows all pages stacked vertically (continuous scroll). Each page is fitted to the available width. Click any page to activate its rectangle editor. The thumbnail strip on the left auto-scrolls to track the active page. The page slider and thumbnail clicks both scroll the main view to the target page.

### User-Added Images

In the OCR paragraph editor, **Actions** supports **Add Image Before** and
**Add Image After**. The user chooses an image file, NewOCR copies it into the
current section's Markdown image folder:

```text
AppleVision/MD/<section>/Images/
```

Then NewOCR inserts an image paragraph before or after the current paragraph
using the same Markdown shape as layout-area images:

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

OCR must not remove text by comparing it to the Section List **Title** field.
That title is reserved for EPUB chapter/TOC metadata. Header/footer removal
should come only from user-entered filtered text and approved Scan Header
`REMOVE:` entries.

### Scan Header

Scan Header samples possible header/footer lines and writes review data.

Important rule:

- OCR must not automatically remove repeated header/footer candidates merely
  because `header-footer-lines.json` exists.
- Header/footer removal should only happen if `header-footer-review.txt` exists
  and contains `REMOVE:` entries.
- Multi-word `REMOVE:` entries should match like ordered wildcard tokens. For
  example, `REMOVE: guidance find your way` should also remove boundary lines
  such as `guidance find 01 your way`.

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

- header row (single line): OCR icon + title, then Files / View Rules / Run OCR /
  Log / Cancel (when running), then the selected file chip (expands to fill space),
  then Info / Preview / Compare / Save / Close — all on one line
- left pane: Search Text, badges, paragraph/plain-text editor
- right pane: PDF preview only
- the split is resizable so the user can give more width to the text editor or
  to the PDF preview as needed; the divider position is remembered across sessions
  via `NSSplitView.autosaveName` ("NewOCR.ocrEditorSplit")
- the PDF preview control row shows the current source page as
  `Page 3 / 12` style text, alongside up/down page and zoom buttons
- the `Page n / total` text updates when the user scrolls or drags the PDF
  preview between pages
- the PDF preview uses standard trackpad/scroll-wheel scrolling only — drag-to-pan is removed
- page/zoom updates preserve the user's horizontal PDF preview position;
  moving up/down must not recenter left/right unless the user scrolls horizontally
- editing paragraph text must not reset the PDF preview to the start of the
  source page; keep the current preview area when the source page is unchanged
- opening the OCR window should clear the paragraph search, focus/scroll the
  paragraph editor to paragraph 1, and show paragraph 1's source page in the PDF
  preview
- OCR PDF preview zoom is remembered per selected section PDF file and persists
  after closing and reopening the app. Default zoom is `100%` (fit to container
  width). If a section has no saved zoom yet, use the last OCR PDF preview zoom
  the user chose. The OCR PDF preview zoom range is `50%` to `220%`.
- Closed OCR and Compare windows must be removed from retained window lists and
  release their hosted views so editing many sections does not get slower over
  time.

Features:

- Preview Markdown, Compare, Save Markdown, Close, View Rules, Run OCR, Files, Log,
  Information, Replace, and Remove Search use icon-first buttons with hover help
- **View Rules** button (blue, next to Run OCR) opens a read-only popup showing all
  layout area rules that apply to the current section — includes rules scoped to
  all sections and rules targeting this specific section file. The load (pencil)
  button is hidden in this view since it is read-only; the delete button remains
  available. The popup title shows the section filename and how many rules apply.
- Search Text
- Replace All
- icon-only status/focus shortcuts for Image, Footnote, and Blockquote
- scrolling the paragraph list automatically updates the PDF preview page: as the
  user scrolls, the topmost visible paragraph's source page is sent to the PDF
  preview (debounced 180 ms). This sync is suppressed while search text is active.
- paragraph labels show source page numbers only for paragraphs known to come
  from OCR page output, for example `Paragraph 1 (Page 1)`; manual sections,
  newly inserted paragraphs, and paragraphs without a known OCR page keep the
  plain `Paragraph 1` label; this state is saved in
  `paragraph-source-pages.json` next to the section's `page*.md` files
- a small **page-jump button** (clipboard-arrow icon) appears in the paragraph
  header row when a source page is known; clicking it navigates the PDF preview
  on the right directly to that paragraph's source page
- pressing **Return/Enter** inside a paragraph textarea inserts a newline within
  that paragraph's text; it does **not** create a new paragraph. Paragraphs are
  only split on blank lines (double newline). Trailing newlines added by the
  Return key are stripped before paragraphs are joined into `ocrText` so the
  `\n` + `\n\n` separator combination never produces a spurious empty paragraph.
- paragraph editing actions:
  - add paragraph before/after
  - add user image before/after
  - add line break before/after
  - page break before/after
  - merge with paragraph above/below
  - remove paragraph
  - move paragraph up/down
  - add image description

After clicking Save, the success popup should show `Save successfully` with an
icon-only **Mark Completed** button before `OK`, then `Close`. **Mark
Completed** checks the current section's **Ready for EPUB** checkbox and closes
the OCR window plus any OCR Preview window. `OK` dismisses the popup and keeps
the OCR/editor windows open. `Close` dismisses the popup and closes the OCR
window plus any OCR Preview window, matching the previous save-success close
behavior.

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
page. Scrolling the paragraph list automatically updates the PDF preview page
(debounced 180 ms); while search text is active this sync is suppressed and the
PDF page only changes when a paragraph editor receives focus.

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
- footnotes (`a.fn-noteref` for reference marks, `aside.fn-aside` for popup
  definitions hidden from the main flow)
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
- use the saved Section List Title first for chapter/TOC title
- fall back to first Markdown heading
- fall back to display name
- copy `Styles/`
- copy `Fonts/`
- copy Markdown image assets
- include front/back covers if selected
- normalize selected/existing cover images to real JPEG files before building,
  so the EPUB manifest media type matches the image bytes
- mark the front cover with both EPUB 3 `cover-image` metadata and the older
  `meta name="cover"` metadata for reader compatibility
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
The app writes them as real JPEG files named `front-cover.jpg` and
`back-cover.jpg`, including when the selected source image uses another format
or has a misleading extension. **Build EPUB** also re-normalizes existing cover
files before creating the EPUB, so older project cover files are repaired during
the next build.

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
OCR_TITLE_MATCH_TOP_LINES=3
OCR_RENDER_SCALE=4.0
PREVIEW_TEXT_SCALE_PERCENT=170
FOOTNOTE_POPUP_FONT_PERCENT=120
CODEX_EXECUTABLE_PATH=/Applications/Codex.app/Contents/Resources/codex
CODEX_FINALIZE_PROMPT_FILE=codex-finalize-prompt.txt
CODEX_FINALIZE_MAX_SECTIONS=5
CODEX_FINALIZE_MODEL=gpt-5.4-mini
NEW_PROJECTS_FOLDER=~/Downloads
```

Width values may be numeric or `FULL` for full-screen opening.

Key notes:

- `OCR_RENDER_SCALE` — controls the pixel density used when rasterising PDF pages
  for Apple Vision OCR. PDF points are 72 pt/inch, so the effective DPI is
  `72 × scale`. The default `4.0` gives ≈ 288 DPI, which is enough for most
  scanned books. For 600 DPI source scans with small or italic text, try `6.0`
  (≈ 432 DPI) for better recognition accuracy. Range: 1.0–8.0. Higher values
  increase memory use and OCR time proportionally. The Define Layout preview
  thumbnails always render at 2.0 regardless of this setting.
- `CODEX_FINALIZE_MODEL` — model used by Finalize with Codex. If the key is
  missing or blank, NewOCR uses `gpt-5.4-mini`. Set another model name only when
  your Codex account and provider support it. ChatGPT accounts do not support API
  model names such as `gpt-4o-mini`; use names available in ChatGPT (e.g.
  `gpt-5.5`, `gpt-5.4-mini`). An unsupported name shows an error in the run log.
- `CODEX_FINALIZE_PROMPT_FILE` — path to the instruction file used by Finalize
  with Codex. Defaults to `codex-finalize-prompt.txt` in the project folder.
- `FOOTNOTE_POPUP_FONT_PERCENT` — font size percentage for the footnote popup
  shown in Preview when clicking a reference mark. Default `120`. Range: 60–300.
  The value is read each time Preview opens. Does not affect EPUB output.

## Current UI Principles

- Keep the app as a practical working tool, not a landing page.
- Buttons should be clear, friendly, and consistent.
- The main top bar groups commands into compact menus instead of many separate
  buttons: Project contains New, Open, Revert Original, and Open Config; Edit
  PDF contains Crop, Add Split, Define Layout,
  Apply CSS, Codex Review, and Clear Scan Report; Build EPUB and Close remain single top-level commands. View EPUB appears in Project when
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
- New command buttons should use the existing icon-button style by default,
  including Save actions, unless plain text is required for a native macOS
  control or the user explicitly asks for text.
- Do not let decorative UI reduce section-list space.
- Do not alter behavior while only making UI more beautiful.
- Main workflows should be reachable from the main window.
- Quitting/closing the application from the Dock or app-level termination path
  should force-close all NewOCR windows, including OCR, Preview, Compare, Log,
  Crop, Add Split, Detect Split, and popup/sheet windows. Modal sheets must be
  dismissed before their parent windows close so users do not need to close the
  sheet manually first.
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
- Any new editable list or popup with text fields should avoid opening with the
  first field visibly focused/highlighted. If this appears during testing, clear
  the initial first responder after layout while preserving normal click-to-edit
  behavior.
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
- New standalone tool windows should follow the Crop/Add Split/Detect Split
  dark-window pattern by default. Use these concrete implementation defaults:
  create an `NSWindow` with `contentRect: NSRect(x: 0, y: 0, width: 1180,
  height: 820)` unless the window has a documented reason for another size; set
  `styleMask` to `[.titled, .closable, .miniaturizable, .resizable]`; set
  `contentMinSize` to at least `NSSize(width: 900, height: 720)` for visual
  crop/preview tools or `NSSize(width: 1100, height: 620)` for split/list tools;
  create an `NSHostingView`, set `hostingView.sizingOptions = []`, assign it to
  `window.contentView`, then call `window.setFrame(visibleFrame, display: true)`
  when opening full-size. Do not set the SwiftUI view's fixed width equal to the
  screen width.
- New standalone tool views should use:
  `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)`,
  then explicit padding, then a minimum frame. For manually-created full-size
  windows whose content can sit under the macOS title bar, use an explicit top
  clearance. Define Layout uses `.padding(.top, 22)`,
  `.padding(.horizontal, 36)`, `.padding(.bottom, 22)`, and
  `.frame(minWidth: 0, minHeight: 720)`. This value was screenshot-tested; use
  it as the starting point for similar full-window tools.
- Use `NewOCRMainPalette.windowBackground` as the outer background,
  `panelBackground` plus `stroke` for command/status panels, and
  `fieldBackground` for the main preview/work area. Header layout should use a
  white rounded icon tile, normally `58x58`, with a black SF Symbol around 28pt,
  plus large readable title/subtitle text. Use `NewOCRMainPalette.primaryText`
  for primary text and `secondaryText` for subtitles on dark backgrounds.
- Primary commands such as Save, Close, Clear, Detect, Split, or Advanced should
  use `OCRIconButton` icon-only controls with floating tooltips, not text-heavy
  buttons. Put primary commands in the header/top command row so an expanding
  preview cannot push them off-screen. Destructive commands use red with white
  icons, Save/confirm uses green with black icons, close uses red with white X,
  and secondary/advanced commands can use the existing pastel pink treatment.
- For windows that operate across many section PDFs, prefer a left navigation
  panel over a dropdown. Use a narrow fixed-width list (`~280-320` points) with
  rows large enough to click comfortably (`~64-72` points high), then place the
  actual editing/preview surface in a flexible right pane. Keep summary text
  such as "`0 saved`" in the header command row, before the icon buttons, so it
  stays visible while the preview area grows.
- Do not put too many fixed-width controls in one horizontal command row. If a
  tool has several controls, split them into multiple rows or use an adaptive
  `LazyVGrid`/wrapping toolbar so controls never get cut off on smaller visible
  frames. Prefer flexible preview/work areas with
  `.frame(maxWidth: .infinity, maxHeight: .infinity)` so the usable surface grows
  when the window is large.
- Before finishing any new standalone window or significant window restyle,
  launch the rebuilt app, open the actual window, and inspect a real screenshot.
  Verify the header icon/title are fully visible below the macOS title bar, top
  commands are visible, controls are not clipped, and the preview/work area is
  using the available space. Do not rely only on compilation.
- The OCR editor layout: a single header row containing all controls (OCR icon/title,
  OCR action buttons, file chip, window action buttons), then an `HSplitView` with
  the Markdown editor on the left and the PDF preview panel on the right. Preserve
  this single-row header when making UI-only changes.
- The OCR header does not include a Load Markdown button. Existing Markdown is loaded
  when opening a processed section; the primary OCR actions are Files, View Rules,
  Run OCR, Log, and Cancel while running.
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
  controls live on one compact row. The PDF view uses standard scroll-wheel/trackpad
  scrolling only (no drag-to-pan). Default zoom is 100% (fit to container); zoom
  percent is stored per section PDF path so returning to a file restores that
  file's last OCR preview zoom.
- The OCR editor keeps an in-memory paragraph-to-source-page map when it loads
  `page*.md`. Scrolling the paragraph list updates the PDF preview page
  automatically (debounced 180 ms, suppressed while search is active).
  Saving edited Markdown should preserve known source pages by writing
  paragraphs back to their mapped `page*.md` files where possible.
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
- Add Split is enabled only after Crop PDF has been saved for the working PDF.
  Existing split files do not satisfy the crop-completed condition by
  themselves.
- Clicking Crop when section PDF files already exist asks for confirmation.
  OK removes those section files, clears split ranges, removes their generated
  OCR resources, resets their titles/Ready flags, and opens Crop; Close does
  nothing.
- Saving Crop PDF removes existing `section-###.pdf` files after confirmation,
  because old splits may no longer match the cropped page layout.
- Define Layout is enabled only when at least one real `section-###.pdf` file
  exists. The button is disabled if no section PDFs are present.
- When saving a layout rule, the system checks for duplicates by comparing type,
  scope, section, page, and rectangle position (with 0.01 tolerance). If a duplicate
  is found, a beautiful warning dialog appears with the yellow warning icon, showing
  the existing rule's details. Users can cancel or save anyway despite the duplicate.
- Define Layout coordinates are saved and applied relative to cropped
  `section-###.pdf` page `.cropBox` renders. OCR layout rules must not use
  `_original.pdf` coordinates.
- The **Ref Mark** layout area (`refmark` type) uses a low overlap threshold
  (10% of OCR line area) so that small, word-sized rectangles reliably match the
  full-width OCR line they sit on. Each Ref Mark rule has a **Ref label** (e.g. `1`)
  and an **Anchor word** — the exact word from the OCR text of that line after which
  `[^label]` is inserted. During OCR:
  1. NewOCR searches the recognized text for the anchor word using an exact
     unicode scalar match (case-sensitive).
  2. If the exact match fails, it retries after stripping Thai above-base diacritic
     marks (็ ่ ้ ๊ ๋ ์ ํ ๎, U+0E47–U+0E4E) from both the anchor word and the line.
     This tolerates the common OCR pattern of dropping or misreading Thai tone marks
     without the user needing to know the exact OCR output form.
  3. When a match is found (by either method), `[^label]` is inserted immediately
     after the anchor word AND any superscript artefact character within 20 characters
     of that position is also removed (the OCR residue of the original printed
     superscript number or symbol).
  4. If no match is found, the legacy artefact-detection strategy is used as a fallback:
     find the nearest superscript artefact character to the rectangle's horizontal
     centre and replace it with `[^label]`.
  Multiple Ref Mark rectangles on the same OCR line are all collected,
  sorted left-to-right, and applied right-to-left so earlier insertions do not
  shift later indices. Draw one Ref Mark rectangle per footnote reference
  location; each gets its own label and anchor word.
  Old rules saved without an anchor word use only the legacy artefact-detection strategy.
- The **Footnote** layout area supports two drawing styles:
  - **One rectangle per footnote line** (recommended): each rectangle has a
    single label (e.g. `1`, `2`, `3`). OCR uses that label directly regardless
    of position in the accumulated list.
  - **One rectangle for all footnote lines**: enter comma-separated labels (e.g.
    `1,2,3`). OCR assigns labels to captured lines in top-to-bottom order.
  Both styles strip any leading digit/superscript prefix that OCR may capture
  from the original text so it is not duplicated in the definition body.
  The `markers` field is saved in the rule's layout-areas JSON file.
- When a page's forced-layout OCR produces footnote definitions (from any
  `footnote` layout area rule), a `<!-- page-break-after -->` comment is
  automatically appended after the definitions. This keeps each PDF page's
  footnotes together with the body text that references them, instead of
  floating all definitions to the end of the chapter.
- Both the Preview renderer (Swift) and the EPUB builder (Python) render
  `[^N]:` definition lines at their literal position in the Markdown as popup
  footnotes rather than as inline blocks after the paragraph. Footnote
  definitions (`[^N]: text`) are rendered as hidden `<aside>` elements at
  their position in the markdown flow. Footnotes not rendered inline (whose
  definition paragraph did not appear before a `<!-- page-break-after -->`)
  are rendered as hidden asides at the end of the document. No footnote
  content is ever displayed as an inline `<section class="footnotes">` list.
- **Preview popup footnotes**: clicking a footnote reference mark (`[^N]` in
  body text, rendered as `<sup class="fn-ref" data-fn="fn-N">`) shows a
  floating popup centered on screen with the footnote text. The popup is
  created by JavaScript injected into `preview.html`. Clicking the same ref
  again, or anywhere outside the popup, closes it. The hidden
  `<aside id="fn-N" class="fn-aside">` elements provide the text to the popup
  via `getElementById`. The popup font size is controlled by
  `FOOTNOTE_POPUP_FONT_PERCENT` in `config.txt` (default 120, range 60–300).
  The config value is read when Preview opens, so changes take effect without
  rebuilding the app. The popup font size does not affect EPUB output.
- **EPUB popup footnotes**: the EPUB builder uses EPUB 3 popup footnote
  semantics. Reference marks are rendered as
  `<a epub:type="noteref" class="fn-noteref" href="#fn-N"><sup>N</sup></a>`
  and definitions as `<aside epub:type="footnote" class="fn-aside" id="fn-N">`.
  Apple Books reads `epub:type="noteref"` on a tap and shows the matching
  `epub:type="footnote"` aside as a native popup card. The EPUB chapter XHTML
  files include `xmlns:epub="http://www.idpf.org/2007/ops"` so the
  `epub:type` attributes are valid. The project stylesheet (via **Apply CSS**)
  sets `aside.fn-aside { display: none }` so the aside does not appear inline
  in readers that do not support EPUB 3 popup footnotes, and styles
  `a.fn-noteref` as a superscript reference mark.
- The `<!-- page-break-after -->` marker that follows footnote definition
  paragraphs in OCR output continues to be written by OCR and rendered in
  both Preview and EPUB unchanged. In the EPUB the aside preceding the page
  break is hidden by the reader, so the page break still fires cleanly at the
  end of each PDF page's content.
- **Rules can store `codexText`.** When a rule with a non-empty `codexText` override
  is saved, that text is stored in the `codexText` field of the rule in its
  layout-areas JSON file. During OCR, if `codexText` is present the Vision-recognized
  lines overlapping that rectangle are discarded and replaced by the saved text. For
  `image_desc` rules the saved `codexText` is returned directly as the caption without
  re-running Vision on the caption area. Rules with no `codexText` continue to use
  Vision OCR output as before.
- `split-plan.json` stores only created section files and includes `file`.
- Detect Split saves the current edited Title fields for checked rows directly
  into `book-sections.json` when creating section PDFs; do not defer this to a
  split-plan fallback during section-list loading. Preserve this behavior for
  both direct Add Split and Crop PDF -> Add Split flows.
- Add Split preview navigation updates From until Title is non-empty, then To.
- Set From updates only From. Set To updates only To.
- Split button remains clickable and validates title on click.
- Process OCR All deletes old Markdown/images/cache for each unchecked section
  before OCR. Sections checked **Ready for EPUB** are skipped.
- **Clear OCR** removes all OCR Markdown files and resources for a section and resets
  the **Ready for EPUB** flag. It preserves the header/footer review file so approved
  filters remain active. The section PDF itself is never deleted.
- Manual sections do not run OCR but can create/edit Markdown.
- OCR must use section PDF paths, not the original PDF.
- Section List Title is EPUB chapter/TOC metadata only. Run OCR, Process OCR
  All, and Save Markdown must not use it to remove OCR text or write headings
  into `.md` files.
- Define Layout's **Section Title** tool is stored as layout rule type `header`
  and writes matched OCR text as Markdown `##` headings. Header rules automatically
  apply only to the first page of each section PDF file, regardless of scope or
  explicit page settings. Other pages in the section ignore header rules to prevent
  titles from repeating on every page. When a header rule rectangle detects multiple
  lines, each line becomes its own heading with `##` prefix, allowing multi-line
  section titles to render as consecutive headings.
- Define Layout scope selection (All/Selected/Section/Page) determines which layout-areas
  JSON file the rule is written to and is used to filter rules during OCR. Rules respect their
  defined scope: All rules apply to all sections, Selected rules apply only to
  their specified sections, Section rules apply only to that section on all pages,
  and Page rules apply only to that specific page of that section.
- The **View Rules** button in Define Layout displays all saved rules in a formatted
  report styled as a dark panel. Each rule shows color-coded icon, type, and scope
  information. The close button (X in top-right) is visually distinct from delete
  buttons (trash icons on each rule). Deleting a rule shows a beautiful confirmation
  popup with the full rule details and cannot-be-undone warning, using the same
  popup style as crop and layout refresh confirmations. The report removes the need
  to understand raw JSON structure. Each rule has a blue pencil icon to load it for
  editing.

### Define Layout Section List — Click Behavior by Scope

Clicking a section row in the Define Layout section list behaves differently depending
on the current selection mode and scope:

**Single mode** (default):
- Clicking any row selects only that row and deselects all others. Scope stays at
  **Section** or **Page** (never **Selected**).

**Multiple mode**:
- **All Sections** checked: clicking a row transitions out of all-sections scope,
  sets the clicked section as the only checked item, and switches scope to **Section**.
- **Section** or **Page** scope: clicking a row switches the preview to that section
  and moves the single checkmark to it — **no additional sections are checked**.
- **Selected** scope: clicking a row toggles its checkbox. Checking a previously
  unchecked section adds it to the set. Unchecking is blocked on the last remaining
  checked section. When the set drops to one section, scope automatically reverts
  to **Section**.

**Save Area scope in Multiple mode**:
- When 2+ sections are checked (scope = **Selected**), pressing **Save Area** writes one
  rule per selected section to each section's own `layout-areas-{stem}.json` file.
  The saved rule has `scope: nil` and `page: nil`, so it matches every page of each
  target section during OCR.
- Page-only rule types (Quote, Image, Image Description, Footnote, Ref Mark) always force
  scope to **Page** when selected via the type buttons, so they are always saved to the
  current section/page regardless of how many sections are checked.
- Duplicate detection in **Selected** mode checks every selected section for an overlapping
  rule; if any section already has a duplicate it raises the warning before saving.
- When a rule is loaded for editing, the **View Rules** and **Clear Rules** buttons
  become disabled (grayed out) to prevent conflicting actions mid-edit. The user must
  save the current rule changes (**Update Rule**) or discard them (**Close**) before
  viewing the rules report or clearing all rules. This prevents confusing state where
  multiple rules might be loaded simultaneously or where a user might accidentally clear
  all rules while editing a specific one.
- The Save Area button no longer has a keyboard shortcut (Enter key); it must be
  clicked directly to avoid accidental saves while editing rule parameters.
- Empty paragraph slots from the paragraph editor should survive Preview and
  EPUB build.
- Header/footer removal requires `header-footer-review.txt` REMOVE entries.
- Process OCR All must preserve `header-footer-review.txt`; deleting it before
  OCR disables approved header/footer removal for that batch.
- Working folder changes clear filtered text and header/footer review state.
- Full-page scanned text images should not replace recognized OCR text.
- Save in OCR window shows `Save successfully`; the icon-only Mark Completed
  button appears before OK, checks **Ready for EPUB**, and closes the OCR window.
  OK stays in the OCR window, and Close closes the OCR window after save.
- Dock/app-level Quit force-closes all retained NewOCR windows before
  termination so auxiliary OCR, Compare, Preview, Log, Crop, and Add Split
  windows do not remain open. Detect Split is a retained standalone auxiliary
  window, not an attached sheet, so app-level close can close it directly.

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
- Every newly added feature, popup, button, control row, and visible state should
  follow the existing NewOCR style system by default. If a feature intentionally
  uses a different style, document why in the same README update.
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

It should remove section-specific `AppleVision/MD/<section>/` and that PDF's
line-cache entries before OCR, but it should not remove
`AppleVision/LineCache/header-footer-review.txt`. If stale images or Markdown
remain, inspect `removeAppleVisionResources(for:)`.

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

### EPUB cover does not appear

Check:

- cover paths in `EPUB/book-epub-manifest.json`
- `CoverImage/front-cover.jpg` and `CoverImage/back-cover.jpg` are real JPEG
  files, not WebP or another image format with a `.jpg` extension
- generated `OEBPS/content.opf` has `properties="cover-image"` on the front
  cover image item and `meta name="cover"`
- rebuild the EPUB after cover normalization changes, because an already-created
  `.epub` will still contain the old packaged image

## Define Layout PDF Preview

The PDF preview in `LayoutAreaEditorWindowView.preview` is a **continuous multi-page scroll view**.
All pages for the selected section are stacked vertically inside a `GeometryReader` →
`ScrollViewReader` → `ScrollView` → `LazyVStack`. Each page is rendered by `LayoutAreaPageCard`.

- Each `LayoutAreaPageCard` calls `appState.layoutAreaPreviewImage(pdfURL:pageNumber:)` to get the
  cached thumbnail and computes `pageHeight = pageWidth * (thumb.height / thumb.width)`.
- `LayoutAreaOverlayView` (selection rectangle + drag handles) appears **only on the active page**
  (`state.selectedPage`). Clicking a non-active page card updates `state.selectedPage`.
- `imageFrame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)` maps normalised
  coordinates directly to screen coordinates without any centering offset.
- When `state.selectedPage` changes (slider, thumbnail click, or card tap), the scroll view
  calls `scrollProxy.scrollTo(page, anchor: .top)` with a 0.25 s ease animation.
- The thumbnail strip (`statusBar`, 140 px wide) wraps its `ScrollView` in a `ScrollViewReader`
  and auto-scrolls (`.center` anchor) to keep the active thumbnail visible.

## OCR Editor PDF Preview

The PDF preview panel in the OCR editor uses `PDFView` via `OCRPDFPreviewView`.

- **Display mode**: `.singlePageContinuous` — all pages flow vertically in one continuous scrollable
  view. The user can scroll smoothly between pages with trackpad or mouse wheel. The page number
  counter updates automatically via `PDFViewPageChanged` as pages scroll into view.
- **Scale**: `scaleFactorForSizeToFit * zoomScale`. With `zoomScale = 1.0` (100%), each page fills
  the panel width. Zoom in/out buttons adjust `zoomScale` in 15% increments (min 100%, max 220%).
- **Navigation**: `pdfView.go(to: page)` at the clamped `pageIndex` for programmatic jumps (page
  buttons, paragraph jump button); the `Coordinator` listens to `PDFViewPageChanged` to sync the
  page counter back when the user scrolls.
- **Horizontal position preservation**: `DraggablePDFView` tracks only horizontal scroll origin
  (restored after zoom changes). Vertical position is managed entirely by PDFKit's continuous scroll.

## Performance Notes

### OCR Editor with Large PDFs (100+ pages)

The OCR editor paragraph list can be slow on large PDFs. Two key optimisations are in place:

1. **`ocrParagraphs` memoisation** — `ocrParagraphs` is a computed property on `AppState` backed by
   a private `_ocrParagraphsCache: [String]?`. The cache is cleared in `ocrText.didSet` and lazily
   rebuilt on first access within each render cycle. Without this, the full `splitParagraphs(ocrText)`
   scan (O(n) over the entire OCR text) ran on every property access — up to 40–60 times per render
   cycle when the `LazyVStack` rows each called `ocrParagraphs`.

2. **`applyHighlights` guard in `updateNSView`** — `HighlightingTextEditor.updateNSView` previously
   called `applyHighlights` on every SwiftUI update, even when neither the text nor the search query
   had changed. The `Coordinator` now tracks `lastHighlightedSearchText` and `lastHighlightedTextLength`;
   `updateNSView` skips the call if both are unchanged, eliminating redundant NSLayoutManager work on
   every unrelated state change.

## Glossary

- Working folder: the project folder created/opened by NewOCR.
- Source PDF: the copied PDF inside the working folder.
- Original backup: `_original.pdf`.
- Section PDF: `section-###.pdf`.
- Manual section: non-PDF book section with manually edited Markdown.
- AppleVision MD: OCR Markdown output under `AppleVision/MD/`.
- Line cache: OCR-derived header/footer sample data under
  `AppleVision/LineCache/`.
