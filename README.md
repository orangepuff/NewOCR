# NewOCR

NewOCR is a local macOS OCR and EPUB helper for PDF-based book projects. It uses
Apple Vision for OCR, PDFKit for PDF splitting/cropping, and a bundled Python
helper for Markdown-to-EPUB generation.

## Build

```sh
./build.sh
```

The build script compiles `Sources/NewOCRApp.swift` into
`NewOCR.app/Contents/MacOS/NewOCR` and bundles the icon, EPUB helper script,
default fonts, and stylesheet resources.

## Run

Open `NewOCR.app` from Finder, or run:

```sh
open NewOCR.app
```

The app keeps editable runtime settings in `config.txt`. If a key is missing,
NewOCR recreates it with a default value on launch.

## Project Flow

Use **New** to create a working folder from a source PDF. NewOCR copies the
source PDF, stores an `_original.pdf` backup, and creates `split-plan.json`.

Use **Crop** to crop the working PDF while keeping the original backup. Use
**Add Split** to create `section-###.pdf` files from page ranges. Use
**Revert Original** to restore the working PDF from the original backup and
clear generated section/OCR/EPUB output.
