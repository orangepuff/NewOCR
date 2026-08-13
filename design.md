# NewOCR Design System

## Color Palette (`NewOCRMainPalette`)

| Token               | Value                        | Use                          |
|---------------------|------------------------------|------------------------------|
| `windowBackground`  | calibratedWhite 0.22         | Window chrome background     |
| `panelBackground`   | calibratedWhite 0.27         | Panels, popups, cards        |
| `headerBackground`  | calibratedWhite 0.24         | Section headers              |
| `rowBackground`     | calibratedWhite 0.33         | List rows                    |
| `alternateRowBackground` | calibratedWhite 0.29   | Alternating list rows        |
| `fieldBackground`   | calibratedWhite 0.20         | Input fields, detail boxes   |
| `stroke`            | white 16% opacity            | Borders and dividers         |
| `headingText`       | white 98% opacity            | Titles and headings          |
| `primaryText`       | white 92% opacity            | Body text                    |
| `secondaryText`     | white 74% opacity            | Subtitles, labels            |
| `tertiaryText`      | white 58% opacity            | Hints, placeholders          |

## Alert Button Colors (`AppAlertButtonStyle`)

All alert buttons are solid filled with white text and an SF Symbol icon.

| Variant  | Color             | Meaning                                        |
|----------|-------------------|------------------------------------------------|
| `.red`   | rgb(220, 50, 50)  | Close / dismiss / cancel                       |
| `.green` | rgb(40, 185, 70)  | Confirm / complete / primary action            |
| `.blue`  | rgb(0, 122, 255)  | Secondary or neutral action (OK, Send email…)  |

Gray is not a valid variant. The panel background is already gray — a gray button disappears against it. Use `.blue` for any action that is neither confirming nor closing.

Every alert button must include an SF Symbol icon using `Label("Title", systemImage: "icon")`.

## Alert Popup Patterns

Two patterns cover all app alerts. Use the shared SwiftUI components — never hand-roll a new popup layout.

---

### Pattern 1 — Success alert (`AppSuccessAlertContent` + `AppAlertPanel`)

Use for: non-destructive outcomes the user just triggered (EPUB created, save successful).

**Structure:**
- Large solid-colored circle (64pt) with white SF Symbol inside — centered
- Bold title (20pt) centered below the icon
- Optional subtitle (13pt secondary) — single line, truncated middle, centered
- Row of `AppAlertButton`s centered below

**Icon color:** green `rgb(53, 200, 90)` for success outcomes.

**Usage:**
```swift
AppAlertPanel {
    AppSuccessAlertContent(
        systemImage: "book.closed.fill",
        iconColor: Color(red: 53/255, green: 200/255, blue: 90/255),
        title: "EPUB created",
        subtitle: "filename.epub"         // optional
    ) {
        Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
            .buttonStyle(AppAlertButtonStyle(variant: .red))
        Button { openAction() } label: { Label("Open", systemImage: "book") }
            .buttonStyle(AppAlertButtonStyle(variant: .green))
    }
}
```

**Current uses:** EPUB built, OCR save success.

---

### Pattern 2 — Confirmation alert (`AppConfirmAlertContent` + `AppAlertPanel`)

Use for: destructive or irreversible actions that need user acknowledgment before proceeding.

**Structure:**
- Solid-colored circle (56pt) + title + subtitle — left-aligned horizontal header
- Dark field box listing what will happen (bullet labels with SF Symbol icons)
- Row of `AppAlertButton`s right-aligned: Close (red, `.cancelAction`) then confirm (green/color, `.defaultAction`)

**Icon color:** matches the severity — orange for warnings, red for destructive.

**Usage:**
```swift
AppAlertPanel(width: 560) {
    AppConfirmAlertContent(
        systemImage: "trash.fill",
        iconColor: Color(red: 220/255, green: 50/255, blue: 50/255),
        title: "Clear all OCR?",
        subtitle: "OCR files will be removed for all sections."
    ) {
        Label("Detail item one.", systemImage: "trash").foregroundStyle(NewOCRMainPalette.primaryText)
        Label("Detail item two.", systemImage: "doc.text").foregroundStyle(NewOCRMainPalette.primaryText)
    } buttons: {
        Button { cancel() } label: { Label("Close", systemImage: "xmark") }
            .buttonStyle(AppAlertButtonStyle(variant: .red))
            .keyboardShortcut(.cancelAction)
        Button { confirm() } label: { Label("Clear all", systemImage: "trash") }
            .buttonStyle(AppAlertButtonStyle(variant: .green))
            .keyboardShortcut(.defaultAction)
    }
}
```

**Current uses:** Crop reset, layout refresh, clear OCR, clear all OCR.

---

## Shared Components Reference

| Component                | File              | Purpose                                              |
|--------------------------|-------------------|------------------------------------------------------|
| `AppAlertButtonStyle`    | NewOCRApp.swift   | ButtonStyle for all alert dialog buttons             |
| `AppAlertPanel`          | NewOCRApp.swift   | Container: dark bg, 16pt corners, border, shadow     |
| `AppSuccessAlertContent` | NewOCRApp.swift   | Layout for success-type popups (centered icon+title) |
| `AppConfirmAlertContent` | NewOCRApp.swift   | Layout for confirmation dialogs (left-aligned)       |
| `NewOCRButtonStyle`      | NewOCRApp.swift   | Standard toolbar/inline buttons (not alert dialogs)  |
| `OCRIconButton`          | NewOCRApp.swift   | Icon-only square buttons for toolbars                |

## Rules

- **Every new popup must use one of the two alert patterns above** — do not create custom panel layouts.
- **Close is always red + xmark icon.** Keyboard shortcut `.cancelAction`.
- **Primary confirm action is always green.** Keyboard shortcut `.defaultAction`.
- **All alert buttons must have an icon** — use `Label("Title", systemImage:)`, never plain `Text`.
- **Titles use sentence case** — "Clear all OCR?" not "Clear All OCR?".
- **`AppAlertPanel` handles all container styling** — do not add `.background`, `.clipShape`, `.overlay`, or `.shadow` inside a panel.
- **Never use gray-toned button backgrounds.** The panel background is already gray (`calibratedWhite 0.27` ≈ `rgb(69,69,69)`). Any achromatic button color will blend into it. Use `.blue` for neutral secondary actions instead of gray.
