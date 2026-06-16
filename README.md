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
- **Define Layout**: draw project-wide OCR layout-area rules for forcing
  header, blockquote, image, footnote, or ignore behavior across sections.
- **Codex Review**: run local Codex on selected sections to edit their
  existing page Markdown files in place.
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
- title editing
- **Process** to open/run OCR for that section
- **Preview** to open the existing Markdown preview for that section
- **Compare** to compare pure Apple Vision OCR against edited Markdown for that
  section when a pure OCR snapshot exists
- **Scan Header** for section PDFs
- **+** to add a manual section after that item
- **X** to remove a section/manual section after confirmation
- **Clear OCR** to remove OCR Markdown files and reset the Ready for EPUB flag for that section
- **Clear All OCR** (main window, next to Scan Header All) to remove OCR for all sections at once with confirmation

The command column uses fixed button positions:

- section PDFs reserve positions for **Scan Header**, **Process**, and **Preview**
- manual sections hide **Scan Header** but keep its space reserved, so **Process** and
  **Preview** align with PDF rows
- **Preview** is enabled only when the section already has Markdown output
- **Compare** appears as an icon next to **Preview** only for non-manual section
  PDFs that have already saved a pure OCR snapshot
- **Clear OCR** appears as a red button when Markdown output exists, allowing the user to
  remove all OCR Markdown files, images, and related resources, and reset the **Ready for EPUB** flag
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
the user can draw the exact page area that should become an image, quote,
footnote, header, or ignored text.

Process OCR still detects large vertical gaps between OCR text lines as blank
paragraph breaks. The surrounding text paragraphs stay unchanged, and NewOCR
inserts a separate `<br/>` paragraph between them so the visible blank row is
preserved.

Page-boundary paragraph merging must not merge Markdown blockquotes or images
with normal body text. If either side of a possible page-boundary merge starts
with `>` or `![`, NewOCR keeps the paragraphs separate.

## OCR Layout Areas

**Edit PDF > Define Layout** opens a project-wide visual editor. Choose a
sample section/page, select **Section Title**, **Quote**, **Image**,
**Footnote**, or **Ignore**, drag the rectangle over the page area, choose
whether it applies to **All Sections** or only **This Section**, then click
**Save Area**.

The editor writes the project layout rules automatically to:

```text
AppleVision/layout-areas.json
```

### Layout Area Rules Report

The **View Rules** button in the Define Layout header opens a formatted report of all saved
layout area rules. The report is styled as a beautiful dark panel, consistent with other
NewOCR confirmations, and displays each rule with:

- **Type icon and label** (Section Title, Quote, Image, Footnote, Ignore)
- **Scope information** (All Sections, specific section, or page number)
- **Load button** (blue pencil icon) to load the rule's settings for editing
- **Delete button** (trash icon) to remove individual rules

**Row Styling**: Each rule row features:
- **Alternating dark/light backgrounds** for visual rhythm and scannability
- **Colored borders** that swap between light and dark, matching the row background
- **Rounded corners** for a refined appearance
- Even rows use a darker background with lighter border; odd rows use lighter background with darker border

**Loading Rules for Editing**: Clicking the blue pencil icon loads that rule's settings into the editor:
- The rule type, scope, and rectangular selection are populated in the editor
- The correct scope button (All/Selected/Section/Page) is highlighted based on the rule's scope
- If the rule targets a specific section, that section is selected in the section list
- The **View Rules** button becomes disabled (grayed out) to prevent opening another rule set while editing
- The **Save Area** button changes to **Update Rule** with an orange pencil icon
- After editing, click **Update Rule** to save changes or **Close** to discard
- Once saved or discarded, the **View Rules** button becomes enabled again

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

Define Layout is available only after at least one `section-###.pdf` split file
exists in the project folder. The **Define Layout** button in the main window is
disabled until at least one section PDF is created.

The Define Layout editor only works with real `section-###.pdf` files from the
current project. Its preview is rendered from those section PDFs, which are
created from the cropped working PDF. It must not preview, save coordinates
from, or apply OCR layout rules against `_original.pdf`.

This is a main-window action because the same rules can apply across all
sections. The JSON file is still available from the editor's **Advanced** button
for debugging or manual adjustment. Advanced JSON opens in a separate retained
dark editor window and must not close or dismiss the Define Layout window.

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
  Header rules only apply to the first page of each section, never to subsequent pages.
  This prevents section titles from appearing on every page.
- `blockquote` — OCR lines in the rectangle are written as Markdown
  blockquotes with `>`.
- `image` — the rectangle is cropped from the rendered PDF page, saved to
  `Images/`, and inserted as Markdown image syntax.
- `footnote` — OCR lines in the rectangle are written as Markdown footnote
  definitions.
- `ignore` — OCR lines in the rectangle are removed from Markdown.

Advanced JSON example:

```json
{
  "rules": [
    {
      "type": "blockquote",
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

1. Loads all layout area rules from `layout-areas.json`
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
  icon-only layout-type buttons, a large Page slider, and the expanding PDF
  preview.
- Keep the controls from being cut off: the layout-type icon buttons and wider
  Scope segmented control share one compact control row when space allows; the
  row may wrap before it overflows. Page navigation lives in its own slider row
  below. Define Layout does not show default instruction text in this control
  row; save/error status appears in the page slider row only after an action.
- Do not use the native AppKit segmented picker for Scope on this dark surface;
  its text can inherit dark colors and become unreadable. Use the custom
  SwiftUI segmented control style with explicit light text and a clear selected
  background.
- Advanced JSON, Clear Rules, Save Area, and Close are top-header
  `OCRIconButton` commands, matching Crop/Split-style windows. Do not move
  primary commands to a bottom footer where an expanding preview can push them
  off-screen. Put the saved-rule count in this top header immediately before
  the command buttons, using large readable header text.
- The layout-type commands, Section Title, Quote, Image, Footnote, and Ignore,
  are icon-only buttons. Show their text labels in floating `NSPopover`
  tooltips on hover, matching the other NewOCR icon controls. Section Title is
  saved internally as rule type `header` for compatibility with existing
  `layout-areas.json` files.
- Page navigation in Define Layout uses a large custom slider with a
  thicker track and a `Page n / total` readout. Action status text appears in
  this page slider row when needed.
- Define Layout scope options are **All**, **Selected**, **Section**, and
  **Page**. Selected opens a dark modal sheet listing section filenames with
  preview thumbnails, checkboxes, Select All, Unselect All, OK, and Close buttons.
  The **OK** button confirms the selected sections and closes the modal; **Close**
  also closes the modal. Users click **OK** to confirm their section selection.
- The Define Layout PDF preview renders slightly zoomed in by default so the
  working page is easier to inspect while drawing layout areas.

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
- page/zoom updates should preserve the user's horizontal PDF preview position;
  moving up/down must not recenter left/right unless the user pans horizontally
- editing paragraph text must not reset the PDF preview to the start of the
  source page; keep the current preview area when the source page is unchanged
- opening the OCR window should clear the paragraph search, focus/scroll the
  paragraph editor to paragraph 1, and show paragraph 1's source page in the PDF
  preview
- OCR PDF preview zoom is remembered per selected section PDF file and persists
  after closing and reopening the app. If a section has no saved zoom yet, use
  the last OCR PDF preview zoom the user chose instead of resetting to `145%`.
  The OCR PDF preview zoom range is `100%` to `220%`.
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
- scrolling, focusing, or editing the paragraph list must not switch the PDF
  preview page
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

## Codex Review

**Edit PDF > Codex Review** opens a dark NewOCR-styled auxiliary window
for local Codex Markdown correction. This workflow does not use Safari or manual
file uploads. It runs `codex exec` against the current project folder and edits
the selected section's existing `page*.md` files in place. It is a correction
workflow, not a second OCR pass: Codex should use the existing Markdown as the
source text and inspect the PDF only to verify text corrections, blank paragraph
gaps, blockquotes, and footnotes. Image detection belongs to the OCR process,
not Codex Review.

### Window Controls

- show each section/manual section with all existing Markdown page files from
  its Markdown folder, usually `AppleVision/MD/<section>/page*.md`
- show a large checkbox for each section; selecting a section includes all of
  that section's page Markdown files
- allow selecting more than one section, capped by `CODEX_FINALIZE_MAX_SECTIONS`
  from `config.txt` (default `5`)
- provide an **Open PDF** icon button for each section
- provide a **Preview** icon button for each Markdown file
- provide a **Show Files** icon button that reveals the Markdown file and
  matching section PDF in Finder
- provide a **Codex Instruction** icon button that opens the configured prompt
  file from `CODEX_FINALIZE_PROMPT_FILE`; this editor hides the prompt file
  path in the header, uses an icon-only Save button, opens as a separate
  retained auxiliary window, and must not close the Codex Review window
- provide an **Info (i)** icon button that opens the Codex Log window at any
  time, including after a run has finished
- provide a **Run Codex** icon button that runs local Codex on the selected
  sections; clicking Run also opens the Codex Log window automatically

### Codex Log Window

The Codex Log window shows real-time output streamed from the `codex exec`
process. It opens automatically when Run Codex is clicked and can also be
opened at any time with the Info button in the Codex Review header.

The log header shows:

```text
Starting Codex on N section(s)...
Executable: /Applications/Codex.app/Contents/Resources/codex
Model: gpt-5.4-mini  (or the value of CODEX_FINALIZE_MODEL)
Project: /path/to/project
```

The log scrolls automatically as output arrives. A spinner appears while Codex
is running. A `--- Done ---` or `--- Error ---` footer is appended when the
process exits, then the log is saved automatically. The log is the verbose
debug/investigation artifact, not the normal user-facing result.

On a successful run, Codex returns a concise `NEWOCR_REPORT_BEGIN` /
`NEWOCR_REPORT_END` report block. NewOCR extracts only that report text and
shows it to the user in a **Codex Review Finished** dialog. The report should
summarize edited files, text corrections, blank paragraphs, blockquotes,
footnotes, and uncertain/skipped items without including debug logs or command
output.

When the run finishes, NewOCR automatically writes the current log text to:

```text
AppleVision/codex-review-log.txt
```

inside the active project folder.

**Download Log** (blue download button) — reveals the automatically saved log
file in Finder. Enabled only after the current run has finished and the log has
been saved.

Each time Run Codex starts, any existing `codex-review-log.txt` is deleted and
`savedLogURL` is cleared so the Download Log button resets. This keeps the
project folder from accumulating old log files. Only one Codex Review log is
kept for the current process. To keep a particular log, copy or rename the file
before running Codex again.

### Codex Exec Command

NewOCR launches Codex as:

```sh
codex exec \
  --skip-git-repo-check \
  --sandbox workspace-write \
  -c shell_environment_policy.inherit=all \
  -m <effective CODEX_FINALIZE_MODEL> \
  --cd <project-folder> \
  "<prompt>"
```

- `--skip-git-repo-check` allows running outside a Git repository.
- `--sandbox workspace-write` restricts Codex's shell commands to write only
  within the project folder and `/tmp`; reads are unrestricted.
- `-c shell_environment_policy.inherit=all` passes the full login-shell
  environment (Homebrew PATH, etc.) to every command Codex runs.
- `-m <model>` is always added. If `CODEX_FINALIZE_MODEL` is missing or blank,
  NewOCR uses its built-in default `gpt-5.4-mini`.
- `stdin` is set to `/dev/null` so Codex never blocks waiting for interactive
  input.

The process environment is enriched before launch so that `HOME`, `TMPDIR`,
`CODEX_HOME`, and `PATH` (including `/opt/homebrew/bin`) are always set even
when the app is opened from Finder or the Dock.

### Model Selection

`CODEX_FINALIZE_MODEL` in `config.txt` controls which model Codex uses:

```text
CODEX_FINALIZE_MODEL=gpt-5.4-mini
```

- **Leave blank or omit the key** — NewOCR uses its built-in default
  `gpt-5.4-mini`.
- **Set a model name** — only set a value if your account and provider support
  it. API-key accounts can use names like `gpt-4o` or `gpt-4o-mini`. ChatGPT
  accounts support names like `gpt-5.5` or `gpt-5.4-mini` but not API-specific
  names; an unsupported name produces an error visible in the Codex Log.

### Prompt File

The prompt file (`CODEX_FINALIZE_PROMPT_FILE`, default `codex-finalize-prompt.txt`
in the project folder) is created with NewOCR's default instructions on first
use. The user can edit and save it from the **Codex Instruction** window. The
Codex Review window reloads it fresh before every run.

NewOCR always appends a system task block to the prompt at runtime. This block
includes:

- The exact path of each section PDF.
- The list of Markdown page files to edit.

The user-editable prompt file controls correction rules: text cleanup, blank
paragraph gaps, blockquote formatting, and footnote formatting. It also tells
Codex to return a concise marked completion report instead of a verbose
transcript. The system task block controls file paths and is not editable from
the Codex Instruction window. Codex Review must not detect, extract, crop, add,
remove, or rename images; image areas are controlled by NewOCR layout areas or
manual OCR editor actions.

### Known Behavioral Decisions — Codex Review

- Finalize edits Markdown files directly; there is no proposed-copy/apply step.
  If the result is bad, re-run OCR for that section to regenerate clean files.
- The system task block (file paths and Markdown file list) is always appended
  at runtime and cannot be disabled from the Codex Instruction window.
- Codex Review does not perform image detection or extraction. Use Define
  Layout Areas for OCR-time image crops, or use the OCR editor's manual image
  tools for corrections.
- `stdin` is `/dev/null` so Codex always runs non-interactively.
- The Codex Log window stays open after a run finishes so the user can review
  output. It is closed when the main Codex Review window closes or when the app
  quits.
- Each new run deletes the previous `AppleVision/codex-review-log.txt`,
  clears `savedLogURL`, and creates a fresh log automatically when the run
  finishes. Only one log file is kept at a time.
- The log window has no manual Save Log button. The Download Log button is
  disabled until the current run's log has been saved automatically.
- Successful runs show a concise completion report extracted from Codex's
  `NEWOCR_REPORT_BEGIN` / `NEWOCR_REPORT_END` output. The raw Codex log remains
  available only through Download Log for debugging.

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
PREVIEW_TEXT_SCALE_PERCENT=170
CODEX_EXECUTABLE_PATH=/Applications/Codex.app/Contents/Resources/codex
CODEX_FINALIZE_PROMPT_FILE=codex-finalize-prompt.txt
CODEX_FINALIZE_MAX_SECTIONS=5
CODEX_FINALIZE_MODEL=gpt-5.4-mini
NEW_PROJECTS_FOLDER=~/Downloads
```

Width values may be numeric or `FULL` for full-screen opening.

Key notes:

- `CODEX_FINALIZE_MODEL` — configurable model for Codex Review. If the key is
  missing or blank, NewOCR uses `gpt-5.4-mini`. Set another model name only when
  your Codex account and provider support it. ChatGPT accounts do not support
  API model names such as `gpt-4o-mini`; use names available in ChatGPT (e.g.
  `gpt-5.5`, `gpt-5.4-mini`). An unsupported name shows an error in the Codex
  Log.
- `CODEX_FINALIZE_PROMPT_FILE` — path to the editable instruction file used by
  Codex Review. Relative paths are resolved from the project folder.
  The file is created with default instructions if it does not exist.

## Current UI Principles

- Keep the app as a practical working tool, not a landing page.
- Buttons should be clear, friendly, and consistent.
- The main top bar groups commands into compact menus instead of many separate
  buttons: Project contains New, Open, Revert Original, and Open Config; Edit
  PDF contains Crop, Add Split, Define Layout, Apply CSS, Codex Review,
  and Clear Scan Report; Build EPUB and Close remain single top-level commands. View EPUB appears in Project when
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
  `page*.md`. Paragraph-list scrolling must not request a PDF preview jump.
  Paragraph text focus/editing must not request a PDF preview jump either.
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
- Opening Define Layout does not show a confirmation popup, even if the project
  has existing OCR output or sections marked **Ready for EPUB**. The layout editor
  opens directly. Users can then modify layout rules without warning about clearing
  existing OCR data.
- When saving a layout rule, the system checks for duplicates by comparing type,
  scope, section, page, and rectangle position (with 0.01 tolerance). If a duplicate
  is found, a beautiful warning dialog appears with the yellow warning icon, showing
  the existing rule's details. Users can cancel or save anyway despite the duplicate.
- Opening Define Layout with existing OCR output or PDF sections marked
  **Ready for EPUB** asks for confirmation. OK clears PDF-section OCR resources
  and resets PDF-section Ready flags; Close does nothing.
- Define Layout coordinates are saved and applied relative to cropped
  `section-###.pdf` page `.cropBox` renders. OCR layout rules must not use
  `_original.pdf` coordinates.
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
- Define Layout scope selection (All/Selected/Section/Page) is saved in
  `layout-areas.json` and used to filter rules during OCR. Rules respect their
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
- When a rule is loaded for editing, the **View Rules**, **Clear Rules**, and
  **Advanced JSON** buttons become disabled (grayed out) to prevent conflicting actions
  mid-edit. The user must save the current rule changes (**Update Rule**) or discard
  them (**Close**) before viewing the rules report, clearing all rules, or editing raw
  JSON. This prevents confusing state where multiple rules might be loaded
  simultaneously or where a user might accidentally clear/modify all rules while
  editing a specific one.
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

## Glossary

- Working folder: the project folder created/opened by NewOCR.
- Source PDF: the copied PDF inside the working folder.
- Original backup: `_original.pdf`.
- Section PDF: `section-###.pdf`.
- Manual section: non-PDF book section with manually edited Markdown.
- AppleVision MD: OCR Markdown output under `AppleVision/MD/`.
- Line cache: OCR-derived header/footer sample data under
  `AppleVision/LineCache/`.
