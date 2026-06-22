import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision
import WebKit

struct PDFFileItem: Identifiable, Equatable {
    let id: String
    let url: URL

    var fileName: String {
        url.lastPathComponent
    }

    var isManualSection: Bool {
        url.pathExtension.localizedCaseInsensitiveCompare("manual") == .orderedSame
    }
}

private struct BookSectionEntry: Codable {
    var id: String
    var type: String
    var path: String?
    var title: String?
    var readyForEPUB: Bool?
}

struct FinalizeAIFileItem: Identifiable, Equatable {
    let id: String
    let markdownURL: URL
    let sectionURL: URL
    let sectionTitle: String

    var displayName: String {
        "\(sectionTitle) / \(markdownURL.lastPathComponent)"
    }

    var folderPath: String {
        markdownURL.deletingLastPathComponent().path
    }
}

final class FinalizeAISelectionState: ObservableObject {
    @Published var items: [FinalizeAIFileItem]
    @Published var selectedSectionTitles: Set<String> = []
    @Published var status: String = ""
    @Published var isRunning: Bool = false
    @Published var codexLog: String = ""
    @Published var codexReport: String = ""
    @Published var savedLogURL: URL? = nil

    init(items: [FinalizeAIFileItem]) {
        self.items = items
    }

    var selectedItems: [FinalizeAIFileItem] {
        items.filter { selectedSectionTitles.contains($0.sectionTitle) }
    }

    var selectedSectionCount: Int {
        selectedSectionTitles.count
    }

    var sectionTitles: [String] {
        var titles: [String] = []
        for item in items where !titles.contains(item.sectionTitle) {
            titles.append(item.sectionTitle)
        }
        return titles
    }

    func items(in sectionTitle: String) -> [FinalizeAIFileItem] {
        items.filter { $0.sectionTitle == sectionTitle }
    }
}


private let defaultCodexFinalizePrompt = """
You are correcting existing OCR Markdown files for a scanned book EPUB workflow.
This is a correction task, not a new OCR task.

Do not ask follow-up questions.
Do not explain, summarize, or include notes.
Edit the actual listed page*.md files in place only.
Do not create extra files.
Do not edit PDFs or unrelated files.
When finished successfully, reply only with this concise report format:

NEWOCR_REPORT_BEGIN
Edited files:
- page1.md
Changes:
- Text corrections: short summary or "None"
- Blank paragraphs added: short summary or "None"
- Blockquotes fixed: short summary or "None"
- Footnotes fixed: short summary or "None"
Uncertain or skipped:
- short summary or "None"
NEWOCR_REPORT_END

Do not include reasoning, debug logs, command transcripts, or OCR output in the report.

Use the existing Markdown as the source text. Do not OCR the PDF again, do not transcribe full pages from scratch, and do not rebuild the Markdown structure wholesale. Inspect the matching PDF page only to verify or correct the existing Markdown and to identify missing layout features. Make only changes that are clearly supported by the PDF. If a word, line, note, or layout feature is uncertain, leave the existing Markdown unchanged.

Do not detect, extract, crop, add, remove, or rename images. Image detection belongs to NewOCR's OCR process, not Codex Review. Preserve existing image Markdown unless the PDF clearly shows its surrounding text/caption formatting is wrong.

Tasks:
1. Correct OCR spelling, punctuation, spacing, capitalization, and broken word joins when the intended text is unambiguous.
2. Preserve visibly empty paragraph gaps between text blocks. Add only a blank paragraph marker, represented as a separate Markdown paragraph containing exactly:
<br/>
3. Detect blockquotes only when the PDF clearly shows quoted/excerpted layout, such as deeper indentation, narrower text width, distinct spacing, different font style, or a quotation marker, and format them with `>`.
4. Detect footnotes and fix footnote formatting when the PDF clearly shows note markers and matching note text. Preserve or convert footnotes to Markdown footnote syntax, for example `text[^1]` and `[^1]: note text`. Do not invent missing note text or renumber notes unless the PDF clearly supports it.

Rules:
- Preserve the author's exact meaning and wording.
- Do not rewrite, paraphrase, modernize, translate, simplify, or replace valid words.
- If uncertain, leave the Markdown unchanged.
- Preserve existing Markdown features unless the PDF clearly shows they are wrong.
"""

private let defaultLayoutAreasJSON = """
{
  "rules": []
}
"""

private struct SavedSplitRange: Codable {
    var title: String
    var pageFrom: String
    var pageTo: String
    var file: String?
}

private func isSectionPDFURL(_ url: URL) -> Bool {
    guard url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame else {
        return false
    }
    let stem = url.deletingPathExtension().lastPathComponent
    return stem.range(of: #"^section-\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
}

private func sectionPDFIndex(_ url: URL) -> Int? {
    guard isSectionPDFURL(url) else { return nil }
    let stem = url.deletingPathExtension().lastPathComponent
    let numberText = stem.replacingOccurrences(
        of: #"(?i)^section-"#,
        with: "",
        options: .regularExpression
    )
    return Int(numberText)
}

private struct OCRLine: Codable {
    let text: String
    let left: CGFloat
    let right: CGFloat
    let bottom: CGFloat
    let top: CGFloat
    var confidence: Float = 1.0

    var width: CGFloat {
        right - left
    }

    var height: CGFloat {
        top - bottom
    }

    var centerX: CGFloat {
        (left + right) / 2
    }
}


private struct OCRLineCachePage: Codable {
    let key: String
    let pdfName: String
    let pageNumber: Int
    let lines: [OCRLine]
}

private struct HeaderFooterGroup {
    var keys: Set<String>
    var pageKeys: Set<String>
    var countsByKey: [String: Int]
    var displayKey: String = ""
}

private struct OCRImageRegion {
    let label: String
    let markdown: String
    var description: String?
    let imageURL: URL
    let left: CGFloat
    let right: CGFloat
    let bottom: CGFloat
    let top: CGFloat
}

struct OCRLayoutAreasFile: Codable {
    var rules: [OCRLayoutAreaRule]
}

struct OCRLayoutAreaRule: Codable, Equatable, Identifiable {
    var id: String { "\(type)-\(scope ?? "")-\(section ?? "")-\(page.map(String.init) ?? "")-\(rect.left)-\(rect.top)" }
    var type: String
    var scope: String?
    var section: String?
    var page: Int?
    var rect: OCRLayoutAreaRect
    // Comma-separated marker labels for footnote areas (e.g. "1,2,3" or "*,†").
    // Single marker label for refmark areas (e.g. "1" or "*").
    var markers: String?
    // For refmark: the exact word in the selected area after which [^markers] is inserted.
    var anchorWord: String?
    // Codex-detected text for this area. When present, OCR uses this text directly
    // instead of re-running Apple Vision on the area rectangle.
    var codexText: String? = nil
    var isAuto: Bool? = nil
}

struct OCRLayoutAreaRect: Codable, Equatable {
    var left: CGFloat
    var right: CGFloat
    var top: CGFloat
    var bottom: CGFloat
}

final class LayoutAreaEditorState: ObservableObject {
    @Published var pdfItems: [PDFFileItem]
    @Published var selectedPDFPath: String
    @Published var selectedPage: Int
    @Published var pageCount: Int
    @Published var selectedType: String = "blockquote"
    @Published var selectedScope: String = "page"
    @Published var selectedLayoutSectionPaths: Set<String> = []
    @Published var sectionSelectionMode: String = "single"
    @Published var previewZoom: CGFloat = 0.75
    @Published var selectionRect: CGRect = CGRect(x: 0.18, y: 0.18, width: 0.64, height: 0.18)
    @Published var status: String = ""
    @Published var savedRuleCount: Int = 0
    @Published var allSavedRules: [OCRLayoutAreaRule] = []
    @Published var loadedRule: OCRLayoutAreaRule?
    @Published var markers: String = ""
    @Published var anchorWord: String = ""
    // Codex-detected text override for the current rule (shown and editable in the editor)
    @Published var codexText: String = ""

    private var pdfPageCounts: [String: Int] = [:]

    init(pdfItems: [PDFFileItem], initialPDF: PDFFileItem, initialPage: Int = 1) {
        self.pdfItems = pdfItems
        pdfPageCounts = Dictionary(uniqueKeysWithValues: pdfItems.map { item in
            (item.url.path, max(PDFDocument(url: item.url)?.pageCount ?? 1, 1))
        })
        selectedPDFPath = initialPDF.url.path
        selectedLayoutSectionPaths = [initialPDF.url.path]
        selectedPage = max(initialPage, 1)
        pageCount = pdfPageCounts[initialPDF.url.path] ?? 1
        selectedPage = min(selectedPage, pageCount)
    }

    var selectedPDFURL: URL? {
        pdfItems.first { $0.url.path == selectedPDFPath }?.url
    }

    var selectedPDFName: String {
        selectedPDFURL?.lastPathComponent ?? "No PDF"
    }

    var selectedPDFItem: PDFFileItem? {
        pdfItems.first { $0.url.path == selectedPDFPath }
    }

    func selectPDFPath(_ path: String) {
        selectedPDFPath = path
        updatePageCount()
    }

    func updatePageCount() {
        guard let url = selectedPDFURL else {
            pageCount = 1
            selectedPage = 1
            return
        }
        if let cachedPageCount = pdfPageCounts[url.path] {
            pageCount = cachedPageCount
        } else {
            pageCount = max(PDFDocument(url: url)?.pageCount ?? 1, 1)
            pdfPageCounts[url.path] = pageCount
        }
        selectedPage = min(max(selectedPage, 1), pageCount)
    }

    func pageCount(for item: PDFFileItem) -> Int {
        pdfPageCounts[item.url.path] ?? 1
    }

    func setAllLayoutSectionsSelected(_ isSelected: Bool) {
        selectedLayoutSectionPaths = isSelected ? Set(pdfItems.map(\.url.path)) : []
    }

    func isLayoutSectionSelected(_ item: PDFFileItem) -> Bool {
        selectedLayoutSectionPaths.contains(item.url.path)
    }

    func setLayoutSection(_ item: PDFFileItem, selected: Bool) {
        if selected {
            selectedLayoutSectionPaths.insert(item.url.path)
        } else {
            selectedLayoutSectionPaths.remove(item.url.path)
        }
    }

    var selectedLayoutSectionItems: [PDFFileItem] {
        pdfItems.filter { selectedLayoutSectionPaths.contains($0.url.path) }
    }

    var selectedLayoutSectionNames: [String] {
        selectedLayoutSectionItems
            .map { $0.url.lastPathComponent }
            .sorted()
    }

    var primarySelectedLayoutSectionName: String? {
        if selectedLayoutSectionPaths.contains(selectedPDFPath) {
            return selectedPDFName
        }
        return selectedLayoutSectionNames.first
    }

    func filteredSavedRulesForSelectedScope(_ rules: [OCRLayoutAreaRule]) -> [OCRLayoutAreaRule] {
        switch selectedScope {
        case "all_sections":
            return rules
        case "selected_sections":
            let selectedNames = Set(selectedLayoutSectionNames)
            guard !selectedNames.isEmpty else { return [] }
            return rules.filter { rule in
                if rule.scope == "all_sections" { return true }
                guard let section = rule.section else { return false }
                return selectedNames.contains(section)
            }
        default:
            guard let sectionName = primarySelectedLayoutSectionName else { return [] }
            return rules.filter { rule in
                rule.scope == "all_sections" || rule.section == sectionName
            }
        }
    }

    var visibleSavedRuleCount: Int {
        filteredSavedRulesForSelectedScope(allSavedRules).count
    }

    var normalizedOCRRect: OCRLayoutAreaRect {
        let clamped = LayoutAreaEditorState.clampedSelection(selectionRect)
        return OCRLayoutAreaRect(
            left: clamped.minX,
            right: clamped.maxX,
            top: 1 - clamped.minY,
            bottom: 1 - clamped.maxY
        )
    }

    static func clampedSelection(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, 0.02), 1)
        let height = min(max(rect.height, 0.02), 1)
        let x = min(max(rect.minX, 0), 1 - width)
        let y = min(max(rect.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func loadRule(_ rule: OCRLayoutAreaRule) {
        self.loadedRule = rule
        self.selectedType = rule.type

        if let scope = rule.scope {
            self.selectedScope = scope
            // all_sections rules don't need a specific section checked
        } else if let section = rule.section {
            self.selectedScope = rule.page != nil ? "page" : "section"
            if let pdfItem = pdfItems.first(where: { $0.url.lastPathComponent == section }) {
                self.selectedLayoutSectionPaths = [pdfItem.url.path]
                self.selectPDFPath(pdfItem.url.path)
            }
        }

        if let page = rule.page {
            self.selectedPage = page
        } else {
            self.selectedPage = 1
        }

        let ocrRect = rule.rect
        let selRect = CGRect(
            x: ocrRect.left,
            y: 1 - ocrRect.top,
            width: ocrRect.right - ocrRect.left,
            height: ocrRect.top - ocrRect.bottom
        )
        self.selectionRect = selRect
        self.markers = rule.markers ?? ""
        self.anchorWord = rule.anchorWord ?? ""
        self.codexText = rule.codexText ?? ""
    }

    func clearLoadedRule() {
        self.loadedRule = nil
    }
}

private struct OCRPageMarkdown {
    let pageNumber: Int
    var text: String
    let firstTextLineContinuesPreviousPage: Bool
    let lastTextLineCanContinueNextPage: Bool
}

private struct OCRParagraphSourcePageRecord: Codable {
    let page: Int
    let hasOCRSourcePage: Bool
}

private enum OCRCompareDifferenceKind {
    case missingFromEdited
    case addedInEdited
    case changed

    var title: String {
        switch self {
        case .missingFromEdited:
            return "Missing from MD"
        case .addedInEdited:
            return "Added in MD"
        case .changed:
            return "Changed"
        }
    }

    var systemImage: String {
        switch self {
        case .missingFromEdited:
            return "minus.circle.fill"
        case .addedInEdited:
            return "plus.circle.fill"
        case .changed:
            return "arrow.triangle.2.circlepath.circle.fill"
        }
    }
}

private struct OCRCompareDifference: Identifiable {
    let id = UUID()
    let page: Int
    let kind: OCRCompareDifferenceKind
    let pureText: String
    let editedText: String
}

private final class WindowCleanupDelegate: NSObject, NSWindowDelegate {
    private let onClose: (NSWindow) -> Void
    private let onShouldClose: ((NSWindow) -> Bool)?

    init(onShouldClose: ((NSWindow) -> Bool)? = nil, onClose: @escaping (NSWindow) -> Void) {
        self.onShouldClose = onShouldClose
        self.onClose = onClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onClose(window)
    }
}

private func forceCloseWindowAndAttachedSheets(_ window: NSWindow) {
    while let sheet = window.attachedSheet {
        window.endSheet(sheet)
        sheet.close()
    }
    window.close()
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    func trimmingLeadingCharacters(in characterSet: CharacterSet) -> String {
        guard let index = firstIndex(where: { character in
            !character.unicodeScalars.allSatisfy { characterSet.contains($0) }
        }) else {
            return ""
        }
        return String(self[index...])
    }

    func trimmingTrailingCharacters(in characterSet: CharacterSet) -> String {
        guard let index = lastIndex(where: { character in
            !character.unicodeScalars.allSatisfy { characterSet.contains($0) }
        }) else {
            return ""
        }
        return String(self[...index])
    }
}

final class AppState: ObservableObject {
    @Published var currentStep: Int = 1 {
        didSet {
            if !isRestoring {
                save()
            }
        }
    }

    @Published var selectedFolderPath: String = "" {
        didSet {
            if !isRestoring, selectedFolderPath != oldValue {
                resetOCRFilterStateForFolderChange()
            }
            loadPDFFiles()
            refreshCoverImagePathsForSelectedFolder()
            if !isRestoring {
                save()
            }
        }
    }

    @Published var selectedPDFPath: String = "" {
        didSet {
            if !isRestoring {
                save()
            }
        }
    }

    @Published var ocrText: String = "" {
        didSet {
            _ocrParagraphsCache = nil
        }
    }
    private var _ocrParagraphsCache: [String]? = nil

    @Published var skipProcessOCREngine: Bool = false {
        didSet {
            if !isRestoring {
                save()
            }
        }
    }

    @Published var filterTopLines: String = "1" {
        didSet {
            if !isRestoring {
                save()
            }
        }
    }

    @Published var filterBottomLines: String = "1" {
        didSet {
            if !isRestoring {
                save()
            }
        }
    }

    @Published var filteredText: String = "" {
        didSet {
            if !isRestoring {
                save()
            }
        }
    }

    @Published var isConfigEditorPresented: Bool = false
    @Published var configText: String = ""
    @Published var configStatus: String = "Config file is ready."
    @Published var configEditorTitle: String = "Config File"
    @Published var isHeaderFooterScanRunning: Bool = false
    @Published var activeHeaderFooterScanFileID: String? = nil
    @Published var headerFooterScanStatus: String = ""
    @Published var headerFooterScanProgressPercent: Double? = nil
    @Published var isOCRRunning: Bool = false
    @Published var ocrProgressPercent: Double? = nil
    @Published var isOCRCancelling: Bool = false
    @Published var isBulkOCRProgressPresented: Bool = false
    @Published var bulkOCRProgressTitle: String = "Process OCR All"
    @Published var bulkOCRProgressMessage: String = ""
    @Published var bulkOCRCurrentFile: String = ""
    @Published var bulkOCRCompletedCount: Int = 0
    @Published var bulkOCRTotalCount: Int = 0
    @Published var isBulkOCRFinished: Bool = false
    @Published var ocrStatus: String = "No OCR job has been sent yet." {
        didSet {
            if !isRestoring {
                save()
            }
        }
    }

    @Published var logOutput: String = "" {
        didSet {}
    }

    @Published var ocrSearchText: String = ""
    @Published var paragraphScrollTargetIndex: Int = 0
    @Published var paragraphScrollRequestID: Int = 0
    @Published var ocrWindowOpenFocusRequestID: Int = 0
    @Published var ocrParagraphSourcePages: [Int] = []
    @Published var ocrParagraphHasOCRSourcePage: [Bool] = []
    @Published var ocrParagraphEditRevision: Int = 0
    @Published var ocrPDFPreviewPageRequestIndex: Int = 0
    @Published var ocrPDFPreviewPageRequestID: Int = 0
    @Published var ocrPDFPreviewZoomPercents: [String: Double] = [:]
    @Published var ocrPDFPreviewLastZoomPercent: Double = 100

    @Published var pdfTitles: [String: String] = [:] {
        didSet {
            if !isRestoring {
                save()
            }
        }
    }
    @Published var epubReadySectionIDs: Set<String> = []

    @Published var frontCoverImagePath: String = "" {
        didSet {
            if !isRestoring {
                save()
            }
        }
    }

    @Published var backCoverImagePath: String = "" {
        didSet {
            if !isRestoring {
                save()
            }
        }
    }

    @Published var epubStatus: String = ""
    @Published var builtEPUBPath: String = ""
    @Published var isEPUBBuiltAlertPresented: Bool = false
    @Published var isOCRSaveAlertPresented: Bool = false
    @Published var ocrSaveAlertMessage: String = ""
    @Published var isCSSAppliedAlertPresented: Bool = false
    @Published var cssApplyAlertTitle: String = "CSS"
    @Published var cssApplyAlertMessage: String = ""
    @Published var isLayoutRefreshConfirmationPresented: Bool = false
    @Published var isPreparingLayoutThumbnails: Bool = false
    @Published var layoutThumbnailProgress: String = ""
    @Published var layoutThumbnailProgressCurrent: Int = 0
    @Published var layoutThumbnailProgressTotal: Int = 0
    @Published var isCropResetConfirmationPresented: Bool = false
    @Published var isClearOCRConfirmationPresented: Bool = false
    @Published var pendingClearOCRItem: PDFFileItem?
    @Published var isClearAllOCRConfirmationPresented: Bool = false

    @Published var ocrRenderScale: CGFloat = 4.0
    @Published var pdfListMinHeight: CGFloat = 420
    var layoutPreviewZoomDefault: CGFloat = 0.75
    @Published var mainWindowWidth: CGFloat = 780
    @Published var mainWindowHeight: CGFloat = 520
    @Published var shouldOpenMainWindowFullScreen: Bool = false
    @Published var ocrParagraphTextAreaMinHeight: CGFloat = 58
    @Published var ocrTitleMatchTopLineCount: Int = 3
    @Published var ocrWindowWidth: CGFloat = 820
    @Published var ocrWindowHeight: CGFloat = 620
    @Published var shouldOpenOCRWindowFullScreen: Bool = false
    @Published var previewTextScalePercent: Double = 130
    @Published var footnotePopupFontPercent: Double = 120
    @Published var cropPDFWindowWidth: CGFloat = 920
    @Published var cropPDFWindowHeight: CGFloat = 720
    @Published var shouldOpenCropPDFWindowFullScreen: Bool = true
    @Published var addSplitWindowWidth: CGFloat = 920
    @Published var addSplitWindowHeight: CGFloat = 720
    @Published var shouldOpenAddSplitWindowFullScreen: Bool = true
    @Published var codexFinalizePromptFile: String = "codex-finalize-prompt.txt"
    @Published var codexFinalizeMaxSections: Int = 5
    @Published var codexExecutablePath: String = "/Applications/Codex.app/Contents/Resources/codex"
    private let defaultCodexFinalizeModel = "gpt-5.4-mini"
    @Published var codexFinalizeModel: String = "gpt-5.4-mini"
    @Published var newProjectsFolderPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)
        .path

    @Published private(set) var pdfFiles: [PDFFileItem] = []

    private let defaults = UserDefaults.standard
    private var isRestoring = false
    private var ocrWindows: [NSWindow] = []
    private var ocrCompareWindows: [NSWindow] = []
    private var finalizeAIWindows: [NSWindow] = []
    private var finalizeAIInstructionWindows: [NSWindow] = []
    private var layoutAreaWindows: [NSWindow] = []
    private var configEditorWindows: [NSWindow] = []
    private weak var codexFinalizeLogWindow: NSWindow?
    private var retainedWindowDelegates: [ObjectIdentifier: WindowCleanupDelegate] = [:]
    private weak var ocrPreviewWindow: NSWindow?
    private weak var ocrLogWindow: NSWindow?
    private var detachedSplitPlannerStates: [SplitPlannerState] = []
    private var activeConfigFileURL: URL?
    private var pendingLayoutAreaSectionItems: [PDFFileItem] = []
    private var pendingLayoutAreaInitialPDFPath: String?
    private var pendingCropBookmarkData: Data?
    private var pendingCropSourcePDFURL: URL?
    private var pendingCropProjectFolderURL: URL?

    init() {
        restore()
    }

    var selectedPDFName: String {
        guard !selectedPDFPath.isEmpty else { return "No PDF selected" }
        if selectedItemIsManualSection {
            let title = selectedPDFTitle
            return title.isEmpty ? "Manual Section" : title
        }
        return URL(fileURLWithPath: selectedPDFPath).lastPathComponent
    }

    var selectedPDFTitle: String {
        guard !selectedPDFPath.isEmpty else { return "" }
        return pdfTitles[selectedPDFPath]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var selectedItemIsManualSection: Bool {
        guard !selectedPDFPath.isEmpty else { return false }
        return URL(fileURLWithPath: selectedPDFPath).pathExtension.localizedCaseInsensitiveCompare("manual") == .orderedSame
    }

    var selectedPDFFileItem: PDFFileItem? {
        guard !selectedPDFPath.isEmpty else { return nil }
        return pdfFiles.first { $0.url.path == selectedPDFPath }
            ?? PDFFileItem(id: selectedPDFPath, url: URL(fileURLWithPath: selectedPDFPath))
    }

    var configFileURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("config.txt")
    }

    var configEditorPath: String {
        (activeConfigFileURL ?? configFileURL).path
    }

    var isHeaderFooterReviewOpen: Bool {
        configEditorTitle == "Header/Footer Review"
    }

    var isCodexFinalizeInstructionOpen: Bool {
        configEditorTitle == "Codex Finalize Instruction"
    }

    var headerFooterReviewRemoveItems: [String] {
        parseHeaderFooterReviewRemoveItems(from: configText)
    }

    var conversionHelperURL: URL {
        if let bundledURL = Bundle.main.url(forResource: "apple_vision_convert", withExtension: "py") {
            return bundledURL
        }
        return appFolderURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("apple_vision_convert.py")
    }

    var appFolderURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
    }

    var localAppleVisionOutputFolderURL: URL? {
        guard !selectedPDFPath.isEmpty else { return nil }
        let pdfURL = URL(fileURLWithPath: selectedPDFPath)
        if selectedItemIsManualSection {
            guard !selectedFolderPath.isEmpty else { return nil }
            return manualMarkdownFolderURL(for: pdfURL)
        }
        return appleVisionOutputFolderURL(for: pdfURL)
            .appendingPathComponent(pdfURL.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    var bookEPUBFileURL: URL? {
        guard !selectedFolderPath.isEmpty else { return nil }
        let folderURL = URL(fileURLWithPath: selectedFolderPath)
        return folderURL
            .appendingPathComponent("EPUB", isDirectory: true)
            .appendingPathComponent(folderURL.lastPathComponent + ".epub")
    }

    var bookEPUBFilePathIfExists: String? {
        guard let epubURL = bookEPUBFileURL,
              FileManager.default.fileExists(atPath: epubURL.path) else {
            return nil
        }
        return epubURL.path
    }

    var canOpenSplitPlannerForSelectedFolder: Bool {
        !selectedFolderPath.isEmpty
    }

    var canAddSplitForSelectedFolder: Bool {
        guard !selectedFolderPath.isEmpty else { return false }
        let projectFolderURL = URL(fileURLWithPath: selectedFolderPath, isDirectory: true)
        let planURL = splitPlanURL(for: projectFolderURL)
        let sourcePDFURL: URL?
        if FileManager.default.fileExists(atPath: planURL.path) {
            sourcePDFURL = try? loadSplitPlan(from: projectFolderURL).sourcePDFURL
        } else {
            sourcePDFURL = firstPDFInFolder(projectFolderURL)
        }
        guard let sourcePDFURL,
              FileManager.default.fileExists(atPath: backupPDFURL(for: sourcePDFURL).path) else {
            return false
        }

        return true
    }

    var canDefineLayoutForSelectedFolder: Bool {
        guard !selectedFolderPath.isEmpty else { return false }
        let projectFolderURL = URL(fileURLWithPath: selectedFolderPath, isDirectory: true)
        return hasSectionPDFs(in: projectFolderURL)
    }

    var localAppleVisionOutputFolderPathIfExists: String? {
        guard let folderURL = localAppleVisionOutputFolderURL else {
            return nil
        }

        if selectedItemIsManualSection {
            return folderURL.path
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return folderURL.path
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Folder With PDF Files"
        panel.message = "Choose a folder. PDF files in that folder will be loaded by file name."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if !selectedFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: selectedFolderPath)
        }

        if panel.runModal() == .OK, let url = panel.url {
            selectedFolderPath = url.path
            currentStep = 1
        }
    }

    func newSplitPlan() {
        let panel = NSOpenPanel()
        panel.title = "Select PDF To Split Later"
        panel.message = "Choose one PDF. NewOCR will open a planning window with editable page ranges."
        panel.prompt = "New"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]

        if !selectedFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: selectedFolderPath)
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let project = try createNewProjectFolder(for: url)
            let bookmarkData = try project.sourcePDFURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try saveSplitPlan(bookmarkData: bookmarkData, sourcePDFURL: project.sourcePDFURL, projectFolderURL: project.folderURL)
            selectedFolderPath = project.folderURL.path
            openAddSplitPDFWindow(
                bookmarkData: bookmarkData,
                fallbackURL: project.sourcePDFURL,
                projectFolderURL: project.folderURL,
                shouldOpenCropWindowBeforeAddSplit: true
            )
        } catch {
            configStatus = "Could not create new project: \(error.localizedDescription)"
        }
    }

    func openSelectedFolderAddSplit() {
        guard !selectedFolderPath.isEmpty else {
            configStatus = "No working folder selected."
            showAlert(title: "No Working Folder", message: configStatus)
            return
        }

        let projectFolderURL = URL(fileURLWithPath: selectedFolderPath, isDirectory: true)
        do {
            let plan = try loadOrCreateSplitPlan(from: projectFolderURL)
            guard FileManager.default.fileExists(atPath: backupPDFURL(for: plan.sourcePDFURL).path) else {
                showAlert(title: "Crop Required", message: "Save a crop for the working PDF before opening Add Split.")
                return
            }
            openAddSplitPDFWindow(bookmarkData: plan.bookmarkData, fallbackURL: plan.sourcePDFURL, projectFolderURL: projectFolderURL)
        } catch {
            configStatus = "Could not open add split: \(error.localizedDescription)"
            showAlert(title: "Could Not Open Add Split", message: error.localizedDescription)
        }
    }

    func openSelectedFolderCropPDF() {
        guard !selectedFolderPath.isEmpty else {
            configStatus = "No working folder selected."
            showAlert(title: "No Working Folder", message: configStatus)
            return
        }

        let projectFolderURL = URL(fileURLWithPath: selectedFolderPath, isDirectory: true)
        do {
            let plan = try loadOrCreateSplitPlan(from: projectFolderURL)
            if hasSectionPDFs(in: projectFolderURL) {
                pendingCropBookmarkData = plan.bookmarkData
                pendingCropSourcePDFURL = plan.sourcePDFURL
                pendingCropProjectFolderURL = projectFolderURL
                isCropResetConfirmationPresented = true
                return
            }
            openCropPDFWindow(bookmarkData: plan.bookmarkData, fallbackURL: plan.sourcePDFURL, projectFolderURL: projectFolderURL)
        } catch {
            configStatus = "Could not open crop PDF: \(error.localizedDescription)"
            showAlert(title: "Could Not Open Crop", message: error.localizedDescription)
        }
    }

    func confirmCropResetAndOpenCrop() {
        guard let bookmarkData = pendingCropBookmarkData,
              let sourcePDFURL = pendingCropSourcePDFURL,
              let projectFolderURL = pendingCropProjectFolderURL else {
            closeCropResetConfirmation()
            return
        }

        isCropResetConfirmationPresented = false
        do {
            try removeSectionFilesAndResourcesBeforeCrop(projectFolderURL: projectFolderURL, bookmarkData: bookmarkData, sourcePDFURL: sourcePDFURL)
            pendingCropBookmarkData = nil
            pendingCropSourcePDFURL = nil
            pendingCropProjectFolderURL = nil
            openCropPDFWindow(bookmarkData: bookmarkData, fallbackURL: sourcePDFURL, projectFolderURL: projectFolderURL)
        } catch {
            showAlert(title: "Could Not Prepare Crop", message: error.localizedDescription)
        }
    }

    func closeCropResetConfirmation() {
        isCropResetConfirmationPresented = false
        pendingCropBookmarkData = nil
        pendingCropSourcePDFURL = nil
        pendingCropProjectFolderURL = nil
    }

    private func removeSectionFilesAndResourcesBeforeCrop(projectFolderURL: URL, bookmarkData: Data, sourcePDFURL: URL) throws {
        let sectionURLs = sectionPDFURLs(in: projectFolderURL)
        for url in sectionURLs {
            try removeAppleVisionResources(for: url)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            pdfTitles.removeValue(forKey: url.path)
            epubReadySectionIDs.remove(url.path)
        }

        try saveSplitPlan(bookmarkData: bookmarkData, sourcePDFURL: sourcePDFURL, projectFolderURL: projectFolderURL, splitRanges: [])
        if selectedFolderPath == projectFolderURL.path {
            loadPDFFiles()
            saveBookSections()
        }
    }

    private func sectionPDFURLs(in projectFolderURL: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: projectFolderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .nameKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter(isSectionPDFURL)
            .sorted { left, right in
                let leftIndex = sectionPDFIndex(left) ?? 0
                let rightIndex = sectionPDFIndex(right) ?? 0
                if leftIndex != rightIndex {
                    return leftIndex < rightIndex
                }
                return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
            }
    }

    func confirmAndRevertSelectedFolderToOriginalPDF() {
        guard !selectedFolderPath.isEmpty else {
            configStatus = "No working folder selected."
            showAlert(title: "No Working Folder", message: configStatus)
            return
        }

        let projectFolderURL = URL(fileURLWithPath: selectedFolderPath, isDirectory: true)
        do {
            let plan = try loadOrCreateSplitPlan(from: projectFolderURL)
            let originalURL = originalPDFURL(for: plan.sourcePDFURL)
            guard FileManager.default.fileExists(atPath: originalURL.path) else {
                let message = "Original PDF not found: \(originalURL.lastPathComponent)"
                configStatus = message
                showAlert(title: "Could Not Revert", message: message)
                return
            }

            let alert = NSAlert()
            alert.messageText = "Revert to original PDF?"
            alert.informativeText = "This will restore the working PDF from the _original file and remove split plan data, generated section PDFs, OCR Markdown, scan text, manual sections, cover images, and EPUB output."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Revert")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }

            revertSelectedFolderToOriginalPDF(
                projectFolderURL: projectFolderURL,
                sourceURL: plan.sourcePDFURL,
                originalURL: originalURL
            )
        } catch {
            configStatus = "Could not prepare revert: \(error.localizedDescription)"
            showAlert(title: "Could Not Revert", message: error.localizedDescription)
        }
    }

    private func revertSelectedFolderToOriginalPDF(projectFolderURL: URL, sourceURL: URL, originalURL: URL) {
        configStatus = "Reverting to original PDF..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.removeGeneratedProjectOutputs(projectFolderURL: projectFolderURL, sourceURL: sourceURL)
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("pdf")
                try FileManager.default.copyItem(at: originalURL, to: temporaryURL)
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    try FileManager.default.removeItem(at: sourceURL)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: sourceURL)

                DispatchQueue.main.async {
                    let projectPath = projectFolderURL.standardizedFileURL.path + "/"
                    self.pdfTitles = self.pdfTitles.filter { key, _ in
                        !key.hasPrefix(projectPath)
                    }
                    if self.selectedPDFPath.hasPrefix(projectPath) {
                        self.selectedPDFPath = ""
                        self.ocrText = ""
                        self.ocrParagraphSourcePages = []
                        self.ocrParagraphHasOCRSourcePage = []
                    }
                    self.builtEPUBPath = ""
                    self.frontCoverImagePath = ""
                    self.backCoverImagePath = ""
                    self.loadPDFFiles()
                    self.configStatus = "Reverted to original PDF and removed split plan data, cover images, and generated output."
                }
            } catch {
                DispatchQueue.main.async {
                    self.configStatus = "Could not revert original PDF: \(error.localizedDescription)"
                    self.showAlert(title: "Could Not Revert", message: error.localizedDescription)
                }
            }
        }
    }

    private func createNewProjectFolder(for pdfURL: URL) throws -> (folderURL: URL, sourcePDFURL: URL) {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: expandedPath(newProjectsFolderPath), isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let baseName = sanitizedFolderName(from: pdfURL.deletingPathExtension().lastPathComponent)
        let projectFolderURL = rootURL.appendingPathComponent(baseName, isDirectory: true)
        let temporaryPDFURL = try temporaryCopyIfNeeded(for: pdfURL, beforeClearing: projectFolderURL)
        try clearFolderIfExists(projectFolderURL)
        try fileManager.createDirectory(at: projectFolderURL, withIntermediateDirectories: true)

        try copyProjectResourceFolder(named: "Fonts", to: projectFolderURL)
        try copyProjectResourceFolder(named: "Styles", to: projectFolderURL)

        let copiedPDFURL = projectFolderURL.appendingPathComponent(pdfURL.lastPathComponent)
        let sourceForCopy = temporaryPDFURL ?? pdfURL
        try fileManager.copyItem(at: sourceForCopy, to: copiedPDFURL)
        try fileManager.copyItem(at: sourceForCopy, to: originalPDFURL(for: copiedPDFURL))
        if let temporaryPDFURL {
            try? fileManager.removeItem(at: temporaryPDFURL)
        }
        return (projectFolderURL, copiedPDFURL)
    }

    private func saveSplitPlan(bookmarkData: Data, sourcePDFURL: URL, projectFolderURL: URL, splitRanges: [SavedSplitRange]? = nil) throws {
        let existingRanges = splitRanges ?? loadSavedSplitRanges(from: projectFolderURL)
        let payload: [String: Any] = [
            "sourcePDFName": sourcePDFURL.lastPathComponent,
            "sourcePDFPath": sourcePDFURL.path,
            "sourcePDFBookmark": bookmarkData.base64EncodedString(),
            "splitRanges": existingRanges.compactMap { range -> [String: String]? in
                guard let file = range.file else { return nil }
                return [
                    "file": file,
                    "title": range.title,
                    "pageFrom": range.pageFrom,
                    "pageTo": range.pageTo,
                ]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: splitPlanURL(for: projectFolderURL), options: .atomic)
    }

    private func loadSplitPlan(from projectFolderURL: URL) throws -> (bookmarkData: Data, sourcePDFURL: URL) {
        let data = try Data(contentsOf: splitPlanURL(for: projectFolderURL))
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bookmarkText = payload["sourcePDFBookmark"] as? String,
              let bookmarkData = Data(base64Encoded: bookmarkText) else {
            throw NSError(domain: "NewOCR", code: 20, userInfo: [NSLocalizedDescriptionKey: "Split plan is missing source PDF bookmark."])
        }

        let fallbackPath = payload["sourcePDFPath"] as? String ?? ""
        let fallbackURL = fallbackPath.isEmpty ? projectFolderURL : URL(fileURLWithPath: fallbackPath)
        return (bookmarkData, fallbackURL)
    }

    private func loadOrCreateSplitPlan(from projectFolderURL: URL) throws -> (bookmarkData: Data, sourcePDFURL: URL) {
        if FileManager.default.fileExists(atPath: splitPlanURL(for: projectFolderURL).path) {
            return try loadSplitPlan(from: projectFolderURL)
        }

        guard let sourcePDFURL = firstPDFInFolder(projectFolderURL) else {
            throw NSError(domain: "NewOCR", code: 21, userInfo: [NSLocalizedDescriptionKey: "No split-plan.json or PDF file was found in this working folder."])
        }

        let bookmarkData = try sourcePDFURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try saveSplitPlan(bookmarkData: bookmarkData, sourcePDFURL: sourcePDFURL, projectFolderURL: projectFolderURL)
        return (bookmarkData, sourcePDFURL)
    }

    private func firstPDFInFolder(_ folderURL: URL) -> URL? {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame }
            .filter { !isSectionPDFURL($0) }
            .filter { !$0.deletingPathExtension().lastPathComponent.hasSuffix("_bkp") }
            .filter { !$0.deletingPathExtension().lastPathComponent.hasSuffix("_original") }
            .sorted { left, right in
                let leftSize = ((try? left.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let rightSize = ((try? right.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if leftSize != rightSize {
                    return leftSize > rightSize
                }
                return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
            }
            .first
    }

    private func splitPlanURL(for projectFolderURL: URL) -> URL {
        projectFolderURL.appendingPathComponent("split-plan.json")
    }

    private func loadSavedSplitRanges(from projectFolderURL: URL) -> [SavedSplitRange] {
        guard let data = try? Data(contentsOf: splitPlanURL(for: projectFolderURL)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRanges = payload["splitRanges"] as? [[String: Any]] else {
            return []
        }

        return rawRanges.compactMap { item in
            let title = item["title"] as? String ?? ""
            let pageFrom = item["pageFrom"] as? String ?? ""
            let pageTo = item["pageTo"] as? String ?? ""
            let file = item["file"] as? String
            guard Int(pageFrom) != nil, Int(pageTo) != nil else {
                return nil
            }
            return SavedSplitRange(title: title, pageFrom: pageFrom, pageTo: pageTo, file: file)
        }
    }

    private func originalPDFURL(for sourceURL: URL) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + "_original")
            .appendingPathExtension("pdf")
    }

    private func backupPDFURL(for sourceURL: URL) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + "_bkp")
            .appendingPathExtension("pdf")
    }

    private func removeGeneratedProjectOutputs(projectFolderURL: URL, sourceURL: URL) throws {
        let fileManager = FileManager.default
        let sourcePath = sourceURL.standardizedFileURL.path
        let backupPath = backupPDFURL(for: sourceURL).standardizedFileURL.path
        let originalPath = originalPDFURL(for: sourceURL).standardizedFileURL.path
        let pdfURLs = (try? fileManager.contentsOfDirectory(
            at: projectFolderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in pdfURLs where url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame {
            guard url.standardizedFileURL.path != sourcePath else { continue }
            guard url.standardizedFileURL.path != backupPath else { continue }
            guard url.standardizedFileURL.path != originalPath else { continue }
            try fileManager.removeItem(at: url)
        }

        for folderName in ["AppleVision", "ManualSections", "EPUB", "CoverImage"] {
            let url = projectFolderURL.appendingPathComponent(folderName, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }

        let bookSectionsURL = projectFolderURL.appendingPathComponent("book-sections.json")
        if fileManager.fileExists(atPath: bookSectionsURL.path) {
            try fileManager.removeItem(at: bookSectionsURL)
        }

        let planURL = splitPlanURL(for: projectFolderURL)
        if fileManager.fileExists(atPath: planURL.path) {
            try fileManager.removeItem(at: planURL)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func clearFolderIfExists(_ folderURL: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            try fileManager.removeItem(at: folderURL)
            return
        }

        let contents = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        for itemURL in contents {
            try fileManager.removeItem(at: itemURL)
        }
    }

    private func temporaryCopyIfNeeded(for sourceURL: URL, beforeClearing folderURL: URL) throws -> URL? {
        let sourcePath = sourceURL.standardizedFileURL.path
        let folderPath = folderURL.standardizedFileURL.path
        guard sourcePath == folderPath || sourcePath.hasPrefix(folderPath + "/") else {
            return nil
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension)
        try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
        return temporaryURL
    }

    private func copyProjectResourceFolder(named name: String, to projectFolderURL: URL) throws {
        let fileManager = FileManager.default
        let bundledSourceURL = Bundle.main.resourceURL?.appendingPathComponent(name, isDirectory: true)
        let fallbackSourceURL = appFolderURL.appendingPathComponent(name, isDirectory: true)
        let sourceURL = bundledSourceURL.flatMap { url -> URL? in
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
            return nil
        } ?? fallbackSourceURL
        let targetURL = projectFolderURL.appendingPathComponent(name, isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.copyItem(at: sourceURL, to: targetURL)
    }

    private func uniqueFolderURL(in rootURL: URL, baseName: String) -> URL {
        let fileManager = FileManager.default
        var candidateURL = rootURL.appendingPathComponent(baseName, isDirectory: true)
        var counter = 2

        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = rootURL.appendingPathComponent("\(baseName)-\(counter)", isDirectory: true)
            counter += 1
        }

        return candidateURL
    }

    private func sanitizedFolderName(from value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)
        let cleaned = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "NewOCR Project" : cleaned
    }

    private func expandedPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
                .path
        }
        return (trimmed as NSString).expandingTildeInPath
    }

    private func openCropPDFWindow(bookmarkData: Data, fallbackURL: URL, projectFolderURL: URL) {
        let plannerState = SplitPlannerState(
            bookmarkData: bookmarkData,
            fallbackURL: fallbackURL,
            projectFolderURL: projectFolderURL,
            cropWindowWidth: cropPDFWindowWidth,
            cropWindowHeight: cropPDFWindowHeight,
            shouldOpenCropWindowFullScreen: shouldOpenCropPDFWindowFullScreen,
            addSplitWindowWidth: addSplitWindowWidth,
            addSplitWindowHeight: addSplitWindowHeight,
            shouldOpenAddSplitWindowFullScreen: shouldOpenAddSplitWindowFullScreen,
            shouldOpenCropWindowAfterLoad: true
        ) { savedTitles in
            self.saveDetectedSplitTitles(savedTitles, projectFolderURL: projectFolderURL)
            if self.projectFolderMatchesSelected(projectFolderURL) {
                self.loadPDFFiles()
            }
        }
        detachedSplitPlannerStates.append(plannerState)
    }

    private func openAddSplitPDFWindow(
        bookmarkData: Data,
        fallbackURL: URL,
        projectFolderURL: URL,
        shouldOpenCropWindowBeforeAddSplit: Bool = false
    ) {
        let plannerState = SplitPlannerState(
            bookmarkData: bookmarkData,
            fallbackURL: fallbackURL,
            projectFolderURL: projectFolderURL,
            cropWindowWidth: cropPDFWindowWidth,
            cropWindowHeight: cropPDFWindowHeight,
            shouldOpenCropWindowFullScreen: shouldOpenCropPDFWindowFullScreen,
            addSplitWindowWidth: addSplitWindowWidth,
            addSplitWindowHeight: addSplitWindowHeight,
            shouldOpenAddSplitWindowFullScreen: shouldOpenAddSplitWindowFullScreen,
            shouldOpenCropWindowAfterLoad: shouldOpenCropWindowBeforeAddSplit,
            shouldOpenAddSplitWindowAfterLoad: true
        ) { savedTitles in
            self.saveDetectedSplitTitles(savedTitles, projectFolderURL: projectFolderURL)
            if self.projectFolderMatchesSelected(projectFolderURL) {
                self.loadPDFFiles()
            }
        }
        detachedSplitPlannerStates.append(plannerState)
    }

    func beginOCR(for item: PDFFileItem) {
        selectedPDFPath = item.url.path
        currentStep = 1
        isOCRRunning = false
        logOutput = ""
        prepareOCRWindowInitialFocus()

        if item.isManualSection {
            if let markdownText = loadAppleVisionMarkdownText() {
                ocrText = markdownText
                updateSelectedPDFTitleFromOCRText(markdownText)
                ocrStatus = "Loaded existing Markdown."
                logOutput = "Loaded Markdown:\n\(localAppleVisionOutputFolderURL?.path ?? "")"
            } else {
                let title = pdfTitles[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "Manual Section"
                let markdownText = "## \(title.isEmpty ? "Manual Section" : title)"
                do {
                    let markdownFolderURL = manualMarkdownFolderURL(for: item.url)
                    ocrParagraphSourcePages = []
                    ocrParagraphHasOCRSourcePage = []
                    try saveAppleVisionMarkdownText(markdownText, folderURL: markdownFolderURL)
                    ocrText = markdownText
                    ocrStatus = "Created manual Markdown."
                    logOutput = "Created Markdown:\n\(markdownFolderURL.appendingPathComponent("page1.md").path)"
                } catch {
                    ocrText = markdownText
                    ocrStatus = "Could not create manual Markdown."
                    logOutput = error.localizedDescription
                }
            }
            skipProcessOCREngine = true
            openOCRWindow()
            return
        }

        if let markdownText = loadAppleVisionMarkdownText() {
            ocrText = markdownText
            updateSelectedPDFTitleFromOCRText(markdownText)
            skipProcessOCREngine = true
            ocrStatus = "Loaded existing AppleVision Markdown."
            logOutput = "Loaded Markdown:\n\(localAppleVisionOutputFolderURL?.path ?? "")"
        } else {
            ocrText = ""
            ocrParagraphSourcePages = []
            ocrParagraphHasOCRSourcePage = []
            skipProcessOCREngine = false
            ocrStatus = "Ready. Click OCR to start."
        }
        openOCRWindow()
    }

    private func prepareOCRWindowInitialFocus() {
        ocrSearchText = ""
        paragraphScrollTargetIndex = 0
        paragraphScrollRequestID += 1
        ocrWindowOpenFocusRequestID += 1
    }

    func previewMarkdown(for item: PDFFileItem) {
        selectedPDFPath = item.url.path
        currentStep = 1
        isOCRRunning = false

        guard let markdownText = loadAppleVisionMarkdownText() else {
            showAlert(title: "No Markdown Found", message: "Process this section before opening Preview.")
            return
        }

        ocrText = markdownText
        ocrStatus = "Previewing existing Markdown."
        logOutput = "Loaded Markdown:\n\(localAppleVisionOutputFolderURL?.path ?? "")"
        openOCRMarkdownPreviewWindow()
    }

    func openOCRWindow() {
        let initialRect: NSRect
        if shouldOpenOCRWindowFullScreen, let visibleFrame = NSScreen.main?.visibleFrame {
            initialRect = visibleFrame
        } else {
            initialRect = NSRect(x: 0, y: 0, width: ocrWindowWidth, height: ocrWindowHeight)
        }

        let window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OCR - \(selectedPDFName)"
        if shouldOpenOCRWindowFullScreen {
            window.setFrame(initialRect, display: true)
        } else {
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: StepTwoOCRView()
                .environmentObject(self)
        )
        ocrWindows.append(window)
        trackRetainedWindow(window)
        window.makeKeyAndOrderFront(nil)
    }

    func closeOCRWindowsAndPreview(_ window: NSWindow?) {
        closeOCRMarkdownPreviewWindow()
        closeOCRLogWindow()
        window?.close()
    }

    func closeAllApplicationWindows() {
        closeOCRMarkdownPreviewWindow()
        closeOCRLogWindow()

        for window in ocrWindows {
            forceCloseWindowAndAttachedSheets(window)
        }
        ocrWindows.removeAll()

        for window in ocrCompareWindows {
            forceCloseWindowAndAttachedSheets(window)
        }
        ocrCompareWindows.removeAll()

        for window in finalizeAIWindows {
            forceCloseWindowAndAttachedSheets(window)
        }
        finalizeAIWindows.removeAll()

        for window in finalizeAIInstructionWindows {
            forceCloseWindowAndAttachedSheets(window)
        }
        finalizeAIInstructionWindows.removeAll()

        for window in layoutAreaWindows {
            forceCloseWindowAndAttachedSheets(window)
        }
        layoutAreaWindows.removeAll()

        for window in configEditorWindows {
            forceCloseWindowAndAttachedSheets(window)
        }
        configEditorWindows.removeAll()

        if let logWin = codexFinalizeLogWindow {
            forceCloseWindowAndAttachedSheets(logWin)
            codexFinalizeLogWindow = nil
        }

        for plannerState in detachedSplitPlannerStates {
            plannerState.closeAllWindows()
        }
        detachedSplitPlannerStates.removeAll()

        for window in NSApp.windows {
            forceCloseWindowAndAttachedSheets(window)
        }
    }

    func closeOCRMarkdownPreviewWindow() {
        ocrPreviewWindow?.close()
        ocrPreviewWindow = nil
    }

    func closeOCRLogWindow() {
        ocrLogWindow?.close()
        ocrLogWindow = nil
    }

    func openCodexFinalizeLogWindow(state: FinalizeAISelectionState) {
        if let codexFinalizeLogWindow {
            codexFinalizeLogWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Log"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: CodexFinalizeLogWindowView(state: state)
                .environmentObject(self)
        )
        codexFinalizeLogWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func closeCodexFinalizeLogWindow() {
        codexFinalizeLogWindow?.close()
        codexFinalizeLogWindow = nil
    }

    private func codexReviewLogURL() -> URL? {
        guard !selectedFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: selectedFolderPath)
            .appendingPathComponent("AppleVision")
            .appendingPathComponent("codex-review-log.txt")
    }

    private func writeCodexLog(_ log: String) throws -> URL {
        guard let url = codexReviewLogURL() else {
            throw NSError(
                domain: "NewOCR.CodexFinalize",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No project folder selected."]
            )
        }
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try log.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func autoSaveCodexLog(state: FinalizeAISelectionState, finishedStatus: String) {
        do {
            let url = try writeCodexLog(state.codexLog)
            state.savedLogURL = url
            state.status = "\(finishedStatus) Log saved."
        } catch {
            state.savedLogURL = nil
            state.status = "\(finishedStatus) Could not save log: \(error.localizedDescription)"
            state.codexLog += "\n\n--- Log Save Error ---\n\(error.localizedDescription)"
        }
    }

    func clearCodexLogFile() {
        guard let url = codexReviewLogURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func openConfigEditor() {
        openTextConfig(title: "Config File", url: configFileURL)
    }

    func openCodexFinalizeInstruction() {
        do {
            let url = try ensureCodexFinalizePromptFile()
            openCodexFinalizeInstructionWindow(url: url)
        } catch {
            configStatus = "Could not open Codex instruction: \(error.localizedDescription)"
        }
    }

    private func openCodexFinalizeInstructionWindow(url: URL) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Finalize Instruction"
        window.contentMinSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: CodexFinalizeInstructionWindowView(promptURL: url)
                .environmentObject(self)
        )
        window.center()
        finalizeAIInstructionWindows.append(window)
        trackRetainedWindow(window)
        window.makeKeyAndOrderFront(nil)
    }

    func openFinalizeAIWindow() {
        loadAppConfigValues()
        guard !selectedFolderPath.isEmpty else {
            showAlert(title: "No Project Selected", message: "Open a NewOCR project folder before finalizing Markdown with Codex.")
            return
        }

        do {
            _ = try ensureCodexFinalizePromptFile()
        } catch {
            showAlert(title: "Codex Instruction Not Ready", message: error.localizedDescription)
            return
        }

        let items = finalizeAIFileItems()
        guard !items.isEmpty else {
            showAlert(title: "No Markdown Files", message: "Process OCR first so NewOCR has page Markdown files to finalize.")
            return
        }

        let state = FinalizeAISelectionState(items: items)
        state.status = "Select up to \(codexFinalizeMaxSections) sections."

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Review"
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: FinalizeAIWindowView(state: state)
                .environmentObject(self)
        )
        window.center()
        finalizeAIWindows.append(window)
        trackRetainedWindow(window)
        window.makeKeyAndOrderFront(nil)
    }

    func finalizeAIFileItems() -> [FinalizeAIFileItem] {
        pdfFiles.flatMap { item -> [FinalizeAIFileItem] in
            let folderURL = markdownFolderURL(for: item)
            let files = appleVisionMarkdownPageFiles(in: folderURL)
            guard !files.isEmpty else { return [] }
            let sectionTitle = sectionListDisplayName(for: item)
            return files.map { fileURL in
                FinalizeAIFileItem(
                    id: fileURL.path,
                    markdownURL: fileURL,
                    sectionURL: item.url,
                    sectionTitle: sectionTitle
                )
            }
        }
    }

    func canSelectFinalizeAISection(_ sectionTitle: String, in state: FinalizeAISelectionState) -> Bool {
        state.selectedSectionTitles.contains(sectionTitle) || state.selectedSectionTitles.count < max(1, codexFinalizeMaxSections)
    }

    func toggleFinalizeAISection(_ sectionTitle: String, in state: FinalizeAISelectionState) {
        if state.selectedSectionTitles.contains(sectionTitle) {
            state.selectedSectionTitles.remove(sectionTitle)
            state.status = "\(state.selectedSectionCount) sections selected."
        } else if state.selectedSectionTitles.count < max(1, codexFinalizeMaxSections) {
            state.selectedSectionTitles.insert(sectionTitle)
            state.status = "\(state.selectedSectionCount) sections selected."
        } else {
            state.status = "Select up to \(max(1, codexFinalizeMaxSections)) sections."
        }
    }

    func openFinalizeAIFolder(for item: FinalizeAIFileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.markdownURL, item.sectionURL])
    }

    func openFinalizeAIPDF(for item: FinalizeAIFileItem) {
        NSWorkspace.shared.open(item.sectionURL)
    }

    func previewFinalizeAIFile(_ item: FinalizeAIFileItem) {
        do {
            loadAppConfigValues()
            let markdown = try String(contentsOf: item.markdownURL, encoding: .utf8)
            let previewURL = item.markdownURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(item.markdownURL.deletingPathExtension().lastPathComponent)-codex-preview.html")
            try previewHTML(for: markdown).write(to: previewURL, atomically: true, encoding: .utf8)
            closeOCRMarkdownPreviewWindow()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Preview - \(item.markdownURL.lastPathComponent)"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: OCRMarkdownPreviewWindowView(
                    previewURL: previewURL,
                    readAccessURL: item.markdownURL.deletingLastPathComponent()
                )
            )
            ocrPreviewWindow = window
            window.makeKeyAndOrderFront(nil)
        } catch {
            showAlert(title: "Preview Failed", message: error.localizedDescription)
        }
    }

    func runCodexFinalize(for items: [FinalizeAIFileItem], state: FinalizeAISelectionState) {
        let limit = max(1, codexFinalizeMaxSections)
        guard !items.isEmpty else {
            state.status = "Select at least one section."
            return
        }
        guard state.selectedSectionCount <= limit else {
            state.status = "Select up to \(limit) sections."
            return
        }
        guard !state.isRunning else { return }

        do {
            let prompt = try codexFinalizePrompt(for: items)
            let selectedFolderPath = selectedFolderPath
            let executable = codexExecutablePath
            let model = codexFinalizeModel
            clearCodexLogFile()
            state.isRunning = true
            state.savedLogURL = nil
            state.codexReport = ""
            state.codexLog = "Starting Codex on \(state.selectedSectionCount) section(s)...\nExecutable: \(executable)\nModel: \(model)\nProject: \(selectedFolderPath)\n\n"
            state.status = "Running Codex on \(state.selectedSectionCount) section(s)..."
            openCodexFinalizeLogWindow(state: state)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runCodexExec(prompt: prompt, projectPath: selectedFolderPath, executablePath: executable, model: model) { text in
                    DispatchQueue.main.async {
                        state.codexLog += text
                    }
                }
                DispatchQueue.main.async {
                    state.isRunning = false
                    switch result {
                    case .success(let output):
                        let summary = output.isEmpty ? "Codex finished. Markdown files were edited in place." : "Codex finished."
                        state.status = summary
                        state.codexReport = self.codexFinalizeReport(from: output)
                        if !output.isEmpty {
                            state.codexLog += "\n\n--- Done ---\n\(output)"
                        } else {
                            state.codexLog += "\n\n--- Done ---"
                        }
                        self.autoSaveCodexLog(state: state, finishedStatus: summary)
                        self.showAlert(title: "Codex Review Finished", message: state.codexReport)
                    case .failure(let error):
                        let summary = "Codex failed: \(error.localizedDescription)"
                        state.status = summary
                        state.codexLog += "\n\n--- Error ---\n\(error.localizedDescription)"
                        self.autoSaveCodexLog(state: state, finishedStatus: summary)
                    }
                }
            }
        } catch {
            state.status = "Could not run Codex: \(error.localizedDescription)"
        }
    }

    // MARK: - Auto Detect Footnote

    private func codexFinalizeReport(from output: String) -> String {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            return "Codex finished. Markdown files were edited in place."
        }

        let beginMarker = "NEWOCR_REPORT_BEGIN"
        let endMarker = "NEWOCR_REPORT_END"
        if let beginRange = trimmedOutput.range(of: beginMarker),
           let endRange = trimmedOutput.range(of: endMarker, range: beginRange.upperBound..<trimmedOutput.endIndex) {
            let report = trimmedOutput[beginRange.upperBound..<endRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !report.isEmpty {
                return report
            }
        }

        return "Codex finished. Markdown files were edited in place.\n\nNo concise report block was found. Use Download Log to inspect the full Codex output."
    }

    private func runCodexExec(prompt: String, projectPath: String, executablePath: String, model: String = "", onOutput: ((String) -> Void)? = nil) -> Result<String, Error> {
        do {
            let process = Process()
            let expandedExecutable = (executablePath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath

            var codexArgs = [
                "exec",
                "--skip-git-repo-check",
                "--sandbox", "workspace-write",
                "-c", "shell_environment_policy.inherit=all",
            ]
            if !model.isEmpty {
                codexArgs += ["-m", model]
            }
            codexArgs += ["--cd", projectPath, prompt]

            if expandedExecutable.hasPrefix("/") {
                process.executableURL = URL(fileURLWithPath: expandedExecutable)
                process.arguments = codexArgs
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [expandedExecutable.isEmpty ? "codex" : expandedExecutable] + codexArgs
            }
            process.currentDirectoryURL = URL(fileURLWithPath: projectPath, isDirectory: true)

            // Inherit a richer environment than what Launch Services provides.
            // Pull HOME, USER, TMPDIR, PATH, and CODEX_HOME so auth and temp
            // dirs resolve correctly when the app is opened from Finder/Dock.
            var env = ProcessInfo.processInfo.environment
            if env["HOME"] == nil {
                env["HOME"] = NSHomeDirectory()
            }
            if env["TMPDIR"] == nil {
                env["TMPDIR"] = NSTemporaryDirectory()
            }
            if env["CODEX_HOME"] == nil {
                env["CODEX_HOME"] = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
            }
            // Broaden PATH so Codex can locate Homebrew binaries.
            let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            let existingPath = env["PATH"] ?? ""
            let mergedPath = (extraPaths + existingPath.split(separator: ":").map(String.init))
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: ":")
            env["PATH"] = mergedPath
            process.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            var accumulatedOutput = ""
            var accumulatedError = ""
            let lock = NSLock()
            let pipeGroup = DispatchGroup()

            // Close stdin so Codex does not block waiting for interactive input.
            process.standardInput = FileHandle.nullDevice

            pipeGroup.enter()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    // EOF — all stdout data has been delivered
                    stdout.fileHandleForReading.readabilityHandler = nil
                    pipeGroup.leave()
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    lock.lock()
                    accumulatedOutput += text
                    lock.unlock()
                    onOutput?(text)
                }
            }

            pipeGroup.enter()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    // EOF — all stderr data has been delivered
                    stderr.fileHandleForReading.readabilityHandler = nil
                    pipeGroup.leave()
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    lock.lock()
                    accumulatedError += text
                    lock.unlock()
                    onOutput?("[stderr] " + text)
                }
            }

            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()

            // Wait for both pipe handlers to reach EOF so no data is lost.
            _ = pipeGroup.wait(timeout: .now() + 30)

            let output = accumulatedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorOutput = accumulatedError.trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "NewOCR.CodexFinalize",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errorOutput.isEmpty ? "Codex exited with status \(process.terminationStatus)." : errorOutput]
                )
            }
            return .success(output)
        } catch {
            return .failure(error)
        }
    }

    private func codexFinalizePrompt(for items: [FinalizeAIFileItem]) throws -> String {
        let instructionURL = try ensureCodexFinalizePromptFile()
        let instruction = try String(contentsOf: instructionURL, encoding: .utf8)
        let grouped = Dictionary(grouping: items, by: \.sectionTitle)
        let sectionList = grouped.keys.sorted().map { sectionTitle in
            let sectionItems = (grouped[sectionTitle] ?? []).sorted { left, right in
                left.markdownURL.lastPathComponent.localizedStandardCompare(right.markdownURL.lastPathComponent) == .orderedAscending
            }
            let markdownList = sectionItems.map { "    - \($0.markdownURL.path)" }.joined(separator: "\n")
            let pdfURL = sectionItems.first?.sectionURL

            return """
            - Section: \(sectionTitle)
              PDF path: \(pdfURL?.path ?? "")
              Markdown page files to edit in place:
            \(markdownList)
            """
        }.joined(separator: "\n")

        return """
        \(instruction)

        NewOCR Codex finalize task:
        You can access the local filesystem. Edit only the listed Markdown files directly in place. Do not create alternate files.

        Selected sections:
        \(sectionList)
        """
    }

    private var codexFinalizePromptURL: URL {
        let rawValue = codexFinalizePromptFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = rawValue.isEmpty ? "codex-finalize-prompt.txt" : rawValue
        let expanded = (fileName as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        } else {
            return configFileURL.deletingLastPathComponent().appendingPathComponent(fileName)
        }
    }

    private func ensureCodexFinalizePromptFile() throws -> URL {
        let url = codexFinalizePromptURL
        if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try defaultCodexFinalizePrompt.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    func chooseFrontCoverImage() {
        chooseCoverImage(title: "Select Front Cover Image", outputStem: "front-cover") { path in
            self.frontCoverImagePath = path
        }
    }

    func chooseBackCoverImage() {
        chooseCoverImage(title: "Select Back Cover Image", outputStem: "back-cover") { path in
            self.backCoverImagePath = path
        }
    }

    private func chooseCoverImage(title: String, outputStem: String, assign: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Select Image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        if let folderURL = coverPanelDirectoryURL {
            panel.directoryURL = folderURL
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let copiedURL = try copyCoverImageToSelectedFolder(url, outputStem: outputStem)
            assign(copiedURL.path)
        } catch {
            configStatus = "Could not copy cover image: \(error.localizedDescription)"
            assign(url.path)
        }
    }

    private func copyCoverImageToSelectedFolder(_ sourceURL: URL, outputStem: String) throws -> URL {
        guard !selectedFolderPath.isEmpty else {
            return sourceURL
        }

        let jpegData = try coverJPEGData(from: sourceURL)
        let folderURL = URL(fileURLWithPath: selectedFolderPath)
            .appendingPathComponent("CoverImage", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let destinationURL = folderURL.appendingPathComponent("\(outputStem).jpg")

        let existingCoverFiles = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        for fileURL in existingCoverFiles where fileURL.deletingPathExtension().lastPathComponent == outputStem {
            if fileURL.standardizedFileURL.path == destinationURL.standardizedFileURL.path {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)
        }

        try jpegData.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    private func normalizedCoverImagePath(_ path: String, outputStem: String) throws -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return ""
        }
        guard !selectedFolderPath.isEmpty else {
            return trimmedPath
        }

        let sourceURL = URL(fileURLWithPath: trimmedPath)
        let copiedURL = try copyCoverImageToSelectedFolder(sourceURL, outputStem: outputStem)
        return copiedURL.path
    }

    private func coverJPEGData(from sourceURL: URL) throws -> Data {
        guard let image = NSImage(contentsOf: sourceURL),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw NSError(
                domain: "NewOCR.CoverImage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not read this cover image as a supported image."]
            )
        }
        return jpegData
    }

    private var coverPanelDirectoryURL: URL? {
        if !frontCoverImagePath.isEmpty {
            return URL(fileURLWithPath: frontCoverImagePath).deletingLastPathComponent()
        }
        if !backCoverImagePath.isEmpty {
            return URL(fileURLWithPath: backCoverImagePath).deletingLastPathComponent()
        }
        if !selectedFolderPath.isEmpty {
            return URL(fileURLWithPath: selectedFolderPath)
        }
        return nil
    }

    private func refreshCoverImagePathsForSelectedFolder() {
        guard !selectedFolderPath.isEmpty else {
            frontCoverImagePath = ""
            backCoverImagePath = ""
            return
        }

        let coverFolderURL = URL(fileURLWithPath: selectedFolderPath)
            .appendingPathComponent("CoverImage", isDirectory: true)
        frontCoverImagePath = existingCoverImagePath(in: coverFolderURL, stem: "front-cover") ?? ""
        backCoverImagePath = existingCoverImagePath(in: coverFolderURL, stem: "back-cover") ?? ""
    }

    private func existingCoverImagePath(in folderURL: URL, stem: String) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let preferredExtensions = ["jpg", "jpeg", "png", "webp", "tif", "tiff", "gif"]
        return files
            .filter { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(stem) == .orderedSame }
            .sorted { left, right in
                let leftRank = preferredExtensions.firstIndex(of: left.pathExtension.lowercased()) ?? preferredExtensions.count
                let rightRank = preferredExtensions.firstIndex(of: right.pathExtension.lowercased()) ?? preferredExtensions.count
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
            }
            .first?
            .path
    }

    func scanHeaderFooterSampleFiles() {
        guard !isHeaderFooterScanRunning else { return }

        let panel = NSOpenPanel()
        panel.title = "Select Sample PDFs"
        panel.message = "Choose a few representative PDFs to learn repeated page headers, footers, and page numbers."
        panel.prompt = "Scan Samples"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]

        if !selectedFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: selectedFolderPath)
        }

        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }

        isHeaderFooterScanRunning = true
        activeHeaderFooterScanFileID = nil
        headerFooterScanProgressPercent = 0
        headerFooterScanStatus = "Scanning \(panel.urls.count) sample PDFs..."
        configStatus = headerFooterScanStatus

        let sampleURLs = panel.urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                for (fileIndex, pdfURL) in sampleURLs.enumerated() {
                    let detectedTitle = try self.scanHeaderFooterSample(pdfURL: pdfURL) { pageIndex, pageCount in
                        DispatchQueue.main.async {
                            let fileProgress = (Double(pageIndex + 1) / Double(max(1, pageCount))) / Double(sampleURLs.count)
                            let completedFiles = Double(fileIndex) / Double(sampleURLs.count)
                            self.headerFooterScanProgressPercent = (completedFiles + fileProgress) * 100
                            self.headerFooterScanStatus = "Scanning \(pdfURL.lastPathComponent): \(pageIndex + 1)/\(pageCount)"
                            self.configStatus = self.headerFooterScanStatus
                        }
                    }
                    DispatchQueue.main.async {
                        if let detectedTitle,
                           self.pdfTitles[pdfURL.path, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.pdfTitles[pdfURL.path] = detectedTitle
                        }
                        self.headerFooterScanStatus = "Scanned \(fileIndex + 1)/\(sampleURLs.count): \(pdfURL.lastPathComponent)"
                        self.configStatus = self.headerFooterScanStatus
                    }
                }

                let reportURL = try self.writeHeaderFooterReview(for: sampleURLs[0])
                let reportText = try String(contentsOf: reportURL, encoding: .utf8)

                DispatchQueue.main.async {
                    self.isHeaderFooterScanRunning = false
                    self.activeHeaderFooterScanFileID = nil
                    self.headerFooterScanProgressPercent = 100
                    self.headerFooterScanStatus = "Header/footer scan finished."
                    self.configStatus = self.headerFooterScanStatus
                    self.activeConfigFileURL = reportURL
                    self.configEditorTitle = "Header/Footer Review"
                    self.configText = reportText
                    self.isConfigEditorPresented = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.isHeaderFooterScanRunning = false
                    self.activeHeaderFooterScanFileID = nil
                    self.headerFooterScanProgressPercent = nil
                    self.headerFooterScanStatus = "Header/footer scan failed."
                    self.configStatus = "\(self.headerFooterScanStatus) \(error.localizedDescription)"
                }
            }
        }
    }

    func scanHeaderFooterSample(for item: PDFFileItem) {
        guard !isHeaderFooterScanRunning else { return }

        isHeaderFooterScanRunning = true
        activeHeaderFooterScanFileID = item.id
        headerFooterScanProgressPercent = 0
        headerFooterScanStatus = "Scanning \(item.fileName)..."
        configStatus = headerFooterScanStatus

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let detectedTitle = try self.scanHeaderFooterSample(pdfURL: item.url) { pageIndex, pageCount in
                    DispatchQueue.main.async {
                        self.headerFooterScanProgressPercent = (Double(pageIndex + 1) / Double(max(1, pageCount))) * 100
                        self.headerFooterScanStatus = "Scanning \(item.fileName): \(pageIndex + 1)/\(pageCount)"
                        self.configStatus = self.headerFooterScanStatus
                    }
                }
                let reportURL = try self.writeHeaderFooterReview(for: item.url)
                let reportText = try String(contentsOf: reportURL, encoding: .utf8)

                DispatchQueue.main.async {
                    if let detectedTitle,
                       self.pdfTitles[item.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.pdfTitles[item.id] = detectedTitle
                    }

                    self.isHeaderFooterScanRunning = false
                    self.activeHeaderFooterScanFileID = nil
                    self.headerFooterScanProgressPercent = 100
                    self.headerFooterScanStatus = "Scanned \(item.fileName). Review the detected headers, footers, and title."
                    self.configStatus = self.headerFooterScanStatus
                    self.activeConfigFileURL = reportURL
                    self.configEditorTitle = "Header/Footer Review"
                    self.configText = reportText
                    self.isConfigEditorPresented = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.isHeaderFooterScanRunning = false
                    self.activeHeaderFooterScanFileID = nil
                    self.headerFooterScanProgressPercent = nil
                    self.headerFooterScanStatus = "Header/footer scan failed for \(item.fileName)."
                    self.configStatus = "\(self.headerFooterScanStatus) \(error.localizedDescription)"
                }
            }
        }
    }

    func scanHeaderFooterAllSections() {
        guard canScanHeaderAllSections else { return }

        let sectionItems = pdfFiles.filter { !($0.isManualSection) && FileManager.default.fileExists(atPath: $0.url.path) }
        guard !sectionItems.isEmpty else {
            headerFooterScanStatus = "No section PDF files to scan."
            configStatus = headerFooterScanStatus
            return
        }

        isHeaderFooterScanRunning = true
        activeHeaderFooterScanFileID = nil
        headerFooterScanProgressPercent = 0
        headerFooterScanStatus = "Scanning headers for \(sectionItems.count) sections..."
        configStatus = headerFooterScanStatus

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                for (fileIndex, item) in sectionItems.enumerated() {
                    DispatchQueue.main.async {
                        self.activeHeaderFooterScanFileID = item.id
                        self.headerFooterScanStatus = "Scanning \(fileIndex + 1)/\(sectionItems.count): \(item.fileName)"
                        self.configStatus = self.headerFooterScanStatus
                    }

                    let detectedTitle = try self.scanHeaderFooterSample(pdfURL: item.url) { pageIndex, pageCount in
                        DispatchQueue.main.async {
                            let completedFiles = Double(fileIndex) / Double(sectionItems.count)
                            let fileProgress = (Double(pageIndex + 1) / Double(max(1, pageCount))) / Double(sectionItems.count)
                            self.headerFooterScanProgressPercent = (completedFiles + fileProgress) * 100
                            self.headerFooterScanStatus = "Scanning \(item.fileName): \(pageIndex + 1)/\(pageCount)"
                            self.configStatus = self.headerFooterScanStatus
                        }
                    }

                    DispatchQueue.main.async {
                        if let detectedTitle,
                           self.pdfTitles[item.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.pdfTitles[item.id] = detectedTitle
                        }
                        self.headerFooterScanStatus = "Scanned \(fileIndex + 1)/\(sectionItems.count): \(item.fileName)"
                        self.configStatus = self.headerFooterScanStatus
                    }
                }

                let reportURL = try self.writeHeaderFooterReview(for: sectionItems[0].url)
                let reportText = try String(contentsOf: reportURL, encoding: .utf8)

                DispatchQueue.main.async {
                    self.isHeaderFooterScanRunning = false
                    self.activeHeaderFooterScanFileID = nil
                    self.headerFooterScanProgressPercent = 100
                    self.headerFooterScanStatus = "Scanned headers for \(sectionItems.count) sections."
                    self.configStatus = self.headerFooterScanStatus
                    self.activeConfigFileURL = reportURL
                    self.configEditorTitle = "Header/Footer Review"
                    self.configText = reportText
                    self.saveBookSections()
                    self.isConfigEditorPresented = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.isHeaderFooterScanRunning = false
                    self.activeHeaderFooterScanFileID = nil
                    self.headerFooterScanProgressPercent = nil
                    self.headerFooterScanStatus = "Batch scan header failed."
                    self.configStatus = "\(self.headerFooterScanStatus) \(error.localizedDescription)"
                }
            }
        }
    }

    func headerFooterScanned(for item: PDFFileItem) -> Bool {
        loadAppleVisionLineCache(for: item.url).contains { $0.pdfName == item.url.lastPathComponent }
    }

    func clearAllHeaderFooterScans() {
        guard !selectedFolderPath.isEmpty else {
            headerFooterScanStatus = "No folder selected."
            configStatus = headerFooterScanStatus
            return
        }

        do {
            let lineCacheFolder = URL(fileURLWithPath: selectedFolderPath)
                .appendingPathComponent("AppleVision", isDirectory: true)
                .appendingPathComponent("LineCache", isDirectory: true)
            let cacheURL = lineCacheFolder.appendingPathComponent("header-footer-lines.json")
            let reviewURL = lineCacheFolder.appendingPathComponent("header-footer-review.txt")

            if FileManager.default.fileExists(atPath: cacheURL.path) {
                try FileManager.default.removeItem(at: cacheURL)
            }
            if FileManager.default.fileExists(atPath: reviewURL.path) {
                try FileManager.default.removeItem(at: reviewURL)
            }

            activeConfigFileURL = nil
            configText = ""
            headerFooterScanStatus = "Cleared all scan header results."
            configStatus = headerFooterScanStatus
        } catch {
            headerFooterScanStatus = "Could not clear scan header results."
            configStatus = "\(headerFooterScanStatus) \(error.localizedDescription)"
        }
    }

    func isScanningHeaderFooter(for item: PDFFileItem) -> Bool {
        activeHeaderFooterScanFileID == item.id
    }

    private func openTextConfig(title: String, url: URL) {
        activeConfigFileURL = url
        configEditorTitle = title
        configText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        configStatus = "Editing \(url.path)"
        isConfigEditorPresented = true
    }

    func saveConfigFile() {
        let targetURL = activeConfigFileURL ?? configFileURL

        do {
            try configText.write(to: targetURL, atomically: true, encoding: .utf8)
            configStatus = "Saved \(targetURL.lastPathComponent)."
            if targetURL == configFileURL {
                loadAppConfigValues()
            }
        } catch {
            configStatus = "Could not save config: \(error.localizedDescription)"
        }
    }

    func openLayoutAreasEditor() {
        guard !selectedFolderPath.isEmpty else {
            showAlert(title: "No Project Selected", message: "Open a NewOCR project folder before defining layout areas.")
            return
        }
        let projectFolderURL = URL(fileURLWithPath: selectedFolderPath, isDirectory: true)
        guard hasSectionPDFs(in: projectFolderURL) else {
            showAlert(title: "No PDF Sections", message: "Create at least one split PDF before defining layout areas.")
            return
        }

        do {
            _ = try ensureLayoutAreasFile()
            let selectableItems = pdfFiles.filter { item in
                isSectionPDFURL(item.url)
                    && FileManager.default.fileExists(atPath: item.url.path)
                    && !epubReadySectionIDs.contains(item.id)
            }
            guard let initialItem = selectableItems.first(where: { $0.url.path == selectedPDFPath }) ?? selectableItems.first else {
                showAlert(title: "No PDF Sections", message: "All sections are marked as completed, or no PDF sections found.")
                return
            }

            prepareLayoutThumbnailsAndOpen(sectionItems: selectableItems, initialItem: initialItem)
        } catch {
            showAlert(title: "Could Not Open Layout Areas", message: error.localizedDescription)
        }
    }

    private func layoutDefinitionNeedsRefresh(sectionItems: [PDFFileItem]) -> Bool {
        let hasExistingOCRResources = sectionItems.contains { hasAppleVisionResources(for: $0.url) }
        let hasReadySections = sectionItems.contains { epubReadySectionIDs.contains($0.id) }
        return hasExistingOCRResources || hasReadySections
    }

    func confirmLayoutRefreshAndOpenEditor() {
        let sectionItems = pendingLayoutAreaSectionItems
        let initialPath = pendingLayoutAreaInitialPDFPath
        guard !sectionItems.isEmpty else {
            closeLayoutRefreshConfirmation()
            return
        }

        isLayoutRefreshConfirmationPresented = false
        do {
            for item in sectionItems {
                try removeAppleVisionResources(for: item.url)
                epubReadySectionIDs.remove(item.id)
            }
            saveBookSections()
            loadPDFFiles()
            let refreshedSectionItems = pdfFiles.filter { item in
                isSectionPDFURL(item.url)
                    && FileManager.default.fileExists(atPath: item.url.path)
                    && !epubReadySectionIDs.contains(item.id)
            }
            let initialItem = refreshedSectionItems.first(where: { $0.url.path == initialPath }) ?? refreshedSectionItems.first
            pendingLayoutAreaSectionItems = []
            pendingLayoutAreaInitialPDFPath = nil
            guard let initialItem else {
                showAlert(title: "No PDF Sections", message: "Add or split a PDF before defining layout areas.")
                return
            }
            prepareLayoutThumbnailsAndOpen(sectionItems: refreshedSectionItems, initialItem: initialItem)
        } catch {
            showAlert(title: "Could Not Refresh OCR Data", message: error.localizedDescription)
        }
    }

    func closeLayoutRefreshConfirmation() {
        isLayoutRefreshConfirmationPresented = false
        pendingLayoutAreaSectionItems = []
        pendingLayoutAreaInitialPDFPath = nil
    }

    private func openLayoutAreasEditorWindow(sectionItems: [PDFFileItem], initialItem: PDFFileItem) {
        let state = LayoutAreaEditorState(pdfItems: sectionItems, initialPDF: initialItem)
        state.savedRuleCount = currentLayoutAreaRuleCount()
        reloadAllSavedRules(into: state)
        restoreLayoutEditorState(into: state)
        state.selectedScope = "page"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Define Layout"
        window.contentMinSize = NSSize(width: 900, height: 720)
        window.isReleasedWhenClosed = false

        let hostingView = NSHostingView(
            rootView: LayoutAreaEditorWindowView(state: state)
                .environmentObject(self)
        )
        hostingView.sizingOptions = []
        window.contentView = hostingView

        if let visibleFrame = NSScreen.main?.visibleFrame {
            window.setFrame(visibleFrame, display: true)
        } else {
            window.center()
        }
        layoutAreaWindows.append(window)
        trackRetainedWindow(window)

        // Save selection state when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak state] _ in
            guard let self, let state else { return }
            self.saveLayoutEditorState(state)
        }

        window.makeKeyAndOrderFront(nil)
    }

    private func hasAppleVisionResources(for pdfURL: URL) -> Bool {
        let mdFolder = appleVisionOutputFolderURL(for: pdfURL)
            .appendingPathComponent(pdfURL.deletingPathExtension().lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: mdFolder.path) {
            return true
        }

        let cacheURL = appleVisionLineCacheURL(for: pdfURL)
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let data = try? Data(contentsOf: cacheURL),
           let pages = try? JSONDecoder().decode([OCRLineCachePage].self, from: data) {
            return pages.contains { $0.pdfName == pdfURL.lastPathComponent }
        }

        return false
    }

    func openLayoutAreasJSONEditor() {
        do {
            let url = try ensureLayoutAreasFile()
            openStandaloneTextConfig(title: "Layout Areas", url: url)
        } catch {
            showAlert(title: "Could Not Open Layout Areas", message: error.localizedDescription)
        }
    }

    private func openStandaloneTextConfig(title: String, url: URL) {
        activeConfigFileURL = url
        configEditorTitle = title
        configText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        configStatus = "Editing \(url.path)"

        var window: NSWindow!
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ConfigEditorView {
                window.close()
            }
            .environmentObject(self)
        )
        window.center()
        configEditorWindows.append(window)
        trackRetainedWindow(window)
        window.makeKeyAndOrderFront(nil)
    }

    // Global file — holds only all_sections rules.
    func layoutAreasFileURL() -> URL? {
        guard !selectedFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: selectedFolderPath)
            .appendingPathComponent("AppleVision", isDirectory: true)
            .appendingPathComponent("layout-areas.json")
    }

    // Per-section file — holds rules that target a specific section PDF.
    func layoutAreasSectionFileURL(forStem stem: String) -> URL? {
        guard !selectedFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: selectedFolderPath)
            .appendingPathComponent("AppleVision", isDirectory: true)
            .appendingPathComponent("layout-areas-\(stem).json")
    }

    // All layout-areas*.json files that currently exist on disk.
    private func allLayoutAreaFileURLs() -> [URL] {
        guard !selectedFolderPath.isEmpty else { return [] }
        let dir = URL(fileURLWithPath: selectedFolderPath)
            .appendingPathComponent("AppleVision", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return contents.filter { url in
            let name = url.lastPathComponent
            return (name == "layout-areas.json" || name.hasPrefix("layout-areas-"))
                && url.pathExtension == "json"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // Load all rules from every layout-areas file, migrating old single-file format first.
    func loadAllLayoutAreaRules() -> [OCRLayoutAreaRule] {
        migrateLayoutAreasFileIfNeeded()
        return allLayoutAreaFileURLs().flatMap { url in
            (try? loadLayoutAreasFileForEditing(from: url))?.rules ?? []
        }
    }

    // One-time migration: if the global layout-areas.json contains section-specific rules,
    // split them into per-section files.
    private func migrateLayoutAreasFileIfNeeded() {
        guard let globalURL = layoutAreasFileURL(),
              FileManager.default.fileExists(atPath: globalURL.path) else { return }
        guard var globalAreas = try? loadLayoutAreasFileForEditing(from: globalURL) else { return }
        let sectionRules = globalAreas.rules.filter { $0.section != nil }
        guard !sectionRules.isEmpty else { return }
        globalAreas.rules.removeAll { $0.section != nil }
        try? writeLayoutAreasFile(globalAreas, to: globalURL)
        var bySection: [String: [OCRLayoutAreaRule]] = [:]
        for rule in sectionRules {
            guard let section = rule.section else { continue }
            let stem = URL(fileURLWithPath: section).deletingPathExtension().lastPathComponent
            bySection[stem, default: []].append(rule)
        }
        for (stem, rules) in bySection {
            guard let url = layoutAreasSectionFileURL(forStem: stem) else { continue }
            var existing = (try? loadLayoutAreasFileForEditing(from: url)) ?? OCRLayoutAreasFile(rules: [])
            existing.rules.append(contentsOf: rules)
            try? writeLayoutAreasFile(existing, to: url)
        }
    }

    private func ensureLayoutAreasDir() throws -> URL {
        guard !selectedFolderPath.isEmpty else {
            throw NSError(domain: "NewOCR.LayoutAreas", code: 1, userInfo: [NSLocalizedDescriptionKey: "No project folder selected."])
        }
        let dir = URL(fileURLWithPath: selectedFolderPath)
            .appendingPathComponent("AppleVision", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func ensureLayoutAreasFile() throws -> URL {
        let dir = try ensureLayoutAreasDir()
        let url = dir.appendingPathComponent("layout-areas.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            try defaultLayoutAreasJSON.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    private func ensureLayoutAreasSectionFile(stem: String) throws -> URL {
        let dir = try ensureLayoutAreasDir()
        let url = dir.appendingPathComponent("layout-areas-\(stem).json")
        if !FileManager.default.fileExists(atPath: url.path) {
            let empty = try JSONEncoder().encode(OCRLayoutAreasFile(rules: []))
            try empty.write(to: url, options: .atomic)
        }
        return url
    }

    private func hasSectionPDFs(in projectFolderURL: URL) -> Bool {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: projectFolderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .nameKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.contains { sectionPDFIndex($0) != nil }
    }

    private var layoutAreaPreviewCache: [String: NSImage] = [:]
    private let layoutAreaPreviewCacheLock = NSLock()

    private func layoutThumbCacheDir() -> URL? {
        guard !selectedFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: selectedFolderPath)
            .appendingPathComponent("AppleVision/LayoutThumbs", isDirectory: true)
    }

    private func layoutThumbFileURL(pdfURL: URL, pageNumber: Int) -> URL? {
        guard let dir = layoutThumbCacheDir() else { return nil }
        let stem = pdfURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(stem)-page\(pageNumber).jpg")
    }

    private func saveLayoutThumbToDisk(_ image: NSImage, pdfURL: URL, pageNumber: Int) {
        guard let dir = layoutThumbCacheDir(),
              let fileURL = layoutThumbFileURL(pdfURL: pdfURL, pageNumber: pageNumber) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        try? jpeg.write(to: fileURL)
    }

    func layoutAreaPreviewImage(pdfURL: URL, pageNumber: Int) -> NSImage? {
        let key = "\(pdfURL.path):\(pageNumber)"
        layoutAreaPreviewCacheLock.lock()
        if let cached = layoutAreaPreviewCache[key] {
            layoutAreaPreviewCacheLock.unlock()
            return cached
        }
        layoutAreaPreviewCacheLock.unlock()
        // Check disk cache
        if let diskURL = layoutThumbFileURL(pdfURL: pdfURL, pageNumber: pageNumber),
           FileManager.default.fileExists(atPath: diskURL.path),
           let data = try? Data(contentsOf: diskURL),
           let image = NSImage(data: data) {
            layoutAreaPreviewCacheLock.lock()
            layoutAreaPreviewCache[key] = image
            layoutAreaPreviewCacheLock.unlock()
            return image
        }
        // Render and cache
        guard let document = PDFDocument(url: pdfURL),
              let page = document.page(at: max(pageNumber - 1, 0)),
              let cgImage = try? renderPDFPageToCGImage(page, scale: 2.0) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        layoutAreaPreviewCacheLock.lock()
        layoutAreaPreviewCache[key] = nsImage
        layoutAreaPreviewCacheLock.unlock()
        saveLayoutThumbToDisk(nsImage, pdfURL: pdfURL, pageNumber: pageNumber)
        return nsImage
    }

    func prepareLayoutThumbnailsAndOpen(sectionItems: [PDFFileItem], initialItem: PDFFileItem) {
        // Collect all section+page combos that have no disk cache yet
        var missing: [(URL, Int)] = []
        for item in sectionItems {
            let pageCount = max(PDFDocument(url: item.url)?.pageCount ?? 1, 1)
            for p in 1...pageCount {
                if let url = layoutThumbFileURL(pdfURL: item.url, pageNumber: p),
                   !FileManager.default.fileExists(atPath: url.path) {
                    missing.append((item.url, p))
                }
            }
        }

        guard !missing.isEmpty else {
            openLayoutAreasEditorWindow(sectionItems: sectionItems, initialItem: initialItem)
            return
        }

        isPreparingLayoutThumbnails = true
        layoutThumbnailProgressCurrent = 0
        layoutThumbnailProgressTotal = missing.count
        layoutThumbnailProgress = "Preparing page thumbnails…"

        DispatchQueue.global(qos: .userInitiated).async {
            // Group by PDF to avoid reopening the same document repeatedly
            var byPDF: [URL: [Int]] = [:]
            for (url, page) in missing { byPDF[url, default: []].append(page) }

            var done = 0
            for (pdfURL, pages) in byPDF {
                guard let doc = PDFDocument(url: pdfURL) else { continue }
                let stem = pdfURL.deletingPathExtension().lastPathComponent
                for pageNumber in pages.sorted() {
                    guard let page = doc.page(at: max(pageNumber - 1, 0)),
                          let cgImage = try? self.renderPDFPageToCGImage(page, scale: 2.0) else { continue }
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    let key = "\(pdfURL.path):\(pageNumber)"
                    self.saveLayoutThumbToDisk(nsImage, pdfURL: pdfURL, pageNumber: pageNumber)
                    done += 1
                    let d = done, t = missing.count
                    DispatchQueue.main.async {
                        self.layoutAreaPreviewCache[key] = nsImage
                        self.layoutThumbnailProgressCurrent = d
                        self.layoutThumbnailProgress = "Preparing \(stem) page \(pageNumber)… (\(d)/\(t))"
                    }
                }
            }
            DispatchQueue.main.async {
                self.isPreparingLayoutThumbnails = false
                self.openLayoutAreasEditorWindow(sectionItems: sectionItems, initialItem: initialItem)
            }
        }
    }

    func saveLayoutAreaRules(type: String, scope: String, currentSectionURL: URL, selectedSectionURLs: [URL], pageNumber: Int, rect: OCRLayoutAreaRect, markers: String? = nil, anchorWord: String? = nil, codexText: String? = nil, isAuto: Bool = false) throws -> Int {
        let cleanScope = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanMarkers = markers.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cleanAnchorWord = anchorWord.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cleanCodexText = codexText.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch cleanScope {
        case "all_sections":
            let url = try ensureLayoutAreasFile()
            var areas = try loadLayoutAreasFileForEditing(from: url)
            areas.rules.append(OCRLayoutAreaRule(type: type, scope: "all_sections", section: nil, page: nil, rect: rect, markers: cleanMarkers, anchorWord: cleanAnchorWord, codexText: cleanCodexText, isAuto: isAuto))
            try writeLayoutAreasFile(areas, to: url)
        case "selected_sections":
            for sectionURL in selectedSectionURLs {
                let stem = sectionURL.deletingPathExtension().lastPathComponent
                let url = try ensureLayoutAreasSectionFile(stem: stem)
                var areas = try loadLayoutAreasFileForEditing(from: url)
                areas.rules.append(OCRLayoutAreaRule(type: type, scope: nil, section: sectionURL.lastPathComponent, page: nil, rect: rect, markers: cleanMarkers, anchorWord: cleanAnchorWord, codexText: cleanCodexText, isAuto: isAuto))
                try writeLayoutAreasFile(areas, to: url)
            }
        case "page":
            let stem = currentSectionURL.deletingPathExtension().lastPathComponent
            let url = try ensureLayoutAreasSectionFile(stem: stem)
            var areas = try loadLayoutAreasFileForEditing(from: url)
            areas.rules.append(OCRLayoutAreaRule(type: type, scope: nil, section: currentSectionURL.lastPathComponent, page: pageNumber, rect: rect, markers: cleanMarkers, anchorWord: cleanAnchorWord, codexText: cleanCodexText, isAuto: isAuto))
            try writeLayoutAreasFile(areas, to: url)
        default: // "section"
            let stem = currentSectionURL.deletingPathExtension().lastPathComponent
            let url = try ensureLayoutAreasSectionFile(stem: stem)
            var areas = try loadLayoutAreasFileForEditing(from: url)
            areas.rules.append(OCRLayoutAreaRule(type: type, scope: nil, section: currentSectionURL.lastPathComponent, page: nil, rect: rect, markers: cleanMarkers, anchorWord: cleanAnchorWord, codexText: cleanCodexText, isAuto: isAuto))
            try writeLayoutAreasFile(areas, to: url)
        }
        return loadAllLayoutAreaRules().count
    }

    func updateLayoutAreaRule(_ oldRule: OCRLayoutAreaRule, with newType: String, newScope: String, newCurrentSectionURL: URL, newSelectedSectionURLs: [URL], newPageNumber: Int, newRect: OCRLayoutAreaRect, newMarkers: String? = nil, newAnchorWord: String? = nil, newCodexText: String? = nil, isAuto: Bool = false) throws -> Int {
        // Remove the old rule from its file.
        try deleteLayoutAreaRule(oldRule)
        // Save the replacement using the standard per-file logic.
        return try saveLayoutAreaRules(
            type: newType, scope: newScope,
            currentSectionURL: newCurrentSectionURL,
            selectedSectionURLs: newSelectedSectionURLs,
            pageNumber: newPageNumber, rect: newRect,
            markers: newMarkers, anchorWord: newAnchorWord,
            codexText: newCodexText, isAuto: isAuto)
    }

    func patchRuleRect(matching oldRule: OCRLayoutAreaRule, newRect: OCRLayoutAreaRect) throws {
        let url: URL
        if let section = oldRule.section {
            let stem = URL(fileURLWithPath: section).deletingPathExtension().lastPathComponent
            guard let sectionURL = layoutAreasSectionFileURL(forStem: stem) else { return }
            url = sectionURL
        } else {
            url = try ensureLayoutAreasFile()
        }
        var areas = try loadLayoutAreasFileForEditing(from: url)
        if let index = areas.rules.firstIndex(of: oldRule) {
            areas.rules[index].rect = newRect
        }
        try writeLayoutAreasFile(areas, to: url)
    }

    func clearLayoutAreaRules() throws {
        for url in allLayoutAreaFileURLs() {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func deleteLayoutAreaRule(_ rule: OCRLayoutAreaRule) throws {
        let url: URL
        if let section = rule.section {
            let stem = URL(fileURLWithPath: section).deletingPathExtension().lastPathComponent
            guard let sectionURL = layoutAreasSectionFileURL(forStem: stem) else { return }
            url = sectionURL
        } else {
            url = try ensureLayoutAreasFile()
        }
        var areas = try loadLayoutAreasFileForEditing(from: url)
        areas.rules.removeAll { $0 == rule }
        try writeLayoutAreasFile(areas, to: url)
    }

    func findDuplicateRule(type: String, scope: String?, section: String?, page: Int?, rect: OCRLayoutAreaRect, excludingRule: OCRLayoutAreaRule? = nil) -> OCRLayoutAreaRule? {
        let allRules = loadAllLayoutAreaRules()

        print("[DupCheck] Looking for: type=\(type) scope=\(scope ?? "nil") section=\(section ?? "nil") page=\(page.map(String.init) ?? "nil") rect=(\(rect.left),\(rect.right),\(rect.top),\(rect.bottom))")
        for rule in allRules {
            print("[DupCheck] Existing: type=\(rule.type) scope=\(rule.scope ?? "nil") section=\(rule.section ?? "nil") page=\(rule.page.map(String.init) ?? "nil") rect=(\(rule.rect.left),\(rule.rect.right),\(rule.rect.top),\(rule.rect.bottom))")
        }

        return allRules.first { rule in
            if let excludingRule = excludingRule, rule == excludingRule {
                return false
            }
            if rule.type != type { return false }
            if rule.scope != scope { return false }
            if rule.section != section { return false }
            if rule.page != page { return false }
            let rectTolerance: CGFloat = 0.01
            return abs(rule.rect.left - rect.left) <= rectTolerance &&
                   abs(rule.rect.right - rect.right) <= rectTolerance &&
                   abs(rule.rect.top - rect.top) <= rectTolerance &&
                   abs(rule.rect.bottom - rect.bottom) <= rectTolerance
        }
    }

    func currentLayoutAreaRuleCount() -> Int {
        loadAllLayoutAreaRules().count
    }

    // MARK: - Layout Editor Preference Persistence

    private func layoutEditorDefaultsKey(_ suffix: String) -> String {
        "layoutEditor_\(selectedFolderPath)_\(suffix)"
    }

    func saveLayoutEditorState(_ state: LayoutAreaEditorState) {
        let d = UserDefaults.standard
        d.set(state.selectedPDFPath, forKey: layoutEditorDefaultsKey("selectedPDFPath"))
        d.set(state.selectedScope, forKey: layoutEditorDefaultsKey("selectedScope"))
        d.set(state.selectedPage, forKey: layoutEditorDefaultsKey("selectedPage"))
        d.set(state.selectedType, forKey: layoutEditorDefaultsKey("selectedType"))
        d.set(Array(state.selectedLayoutSectionPaths), forKey: layoutEditorDefaultsKey("selectedLayoutSectionPaths"))
        d.set(state.sectionSelectionMode, forKey: layoutEditorDefaultsKey("sectionSelectionMode"))
        d.set(Double(state.previewZoom), forKey: layoutEditorDefaultsKey("previewZoom"))
    }

    func restoreLayoutEditorState(into state: LayoutAreaEditorState) {
        let d = UserDefaults.standard
        let validPaths = Set(state.pdfItems.map(\.url.path))

        // Restore selected PDF path (preview section)
        if let path = d.string(forKey: layoutEditorDefaultsKey("selectedPDFPath")),
           validPaths.contains(path) {
            state.selectPDFPath(path)
        }

        // Restore scope
        if let scope = d.string(forKey: layoutEditorDefaultsKey("selectedScope")) {
            state.selectedScope = scope
        }

        // Restore page
        let savedPage = d.integer(forKey: layoutEditorDefaultsKey("selectedPage"))
        if savedPage > 0 {
            state.selectedPage = min(max(savedPage, 1), max(state.pageCount, 1))
        }

        // Restore type
        if let type = d.string(forKey: layoutEditorDefaultsKey("selectedType")), !type.isEmpty {
            state.selectedType = type
        }

        // Restore checked section paths (only those still valid).
        if let paths = d.stringArray(forKey: layoutEditorDefaultsKey("selectedLayoutSectionPaths")) {
            let restored = Set(paths).intersection(validPaths)
            // If all saved paths are now invalid (e.g. files renamed), fall back to the
            // current preview section so "X of Y selected" and the rule count stay in sync.
            if restored.isEmpty && state.selectedScope != "all_sections" {
                state.selectedLayoutSectionPaths = validPaths.contains(state.selectedPDFPath)
                    ? [state.selectedPDFPath] : []
            } else {
                state.selectedLayoutSectionPaths = restored
            }
        } else if state.selectedScope == "all_sections" {
            state.selectedLayoutSectionPaths = []
        }

        // Restore section selection mode (single/multiple).
        if let mode = d.string(forKey: layoutEditorDefaultsKey("sectionSelectionMode")),
           mode == "single" || mode == "multiple" {
            state.sectionSelectionMode = mode
        }

        // Restore zoom (falls back to config default if never saved)
        let savedZoom = d.double(forKey: layoutEditorDefaultsKey("previewZoom"))
        state.previewZoom = savedZoom > 0 ? CGFloat(savedZoom) : layoutPreviewZoomDefault
    }

    func reloadAllSavedRules(into state: LayoutAreaEditorState) {
        state.allSavedRules = loadAllLayoutAreaRules()
    }

    func loadLayoutAreasFilePublic(from url: URL) throws -> OCRLayoutAreasFile {
        try loadLayoutAreasFileForEditing(from: url)
    }

    private func loadLayoutAreasFileForEditing(from url: URL) throws -> OCRLayoutAreasFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return OCRLayoutAreasFile(rules: [])
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return OCRLayoutAreasFile(rules: [])
        }
        var decoded = try JSONDecoder().decode(OCRLayoutAreasFile.self, from: data)
        // Migrate: rules where isAuto was never written (nil) → mark as auto
        decoded.rules = decoded.rules.map { rule in
            var r = rule
            if r.isAuto == nil {
                r.isAuto = true
            }
            return r
        }
        return decoded
    }

    func writeLayoutAreasFile(_ areas: OCRLayoutAreasFile, to url: URL? = nil) throws {
        let targetURL: URL
        if let providedURL = url {
            targetURL = providedURL
        } else if let fileURL = layoutAreasFileURL() {
            targetURL = fileURL
        } else {
            throw NSError(domain: "NewOCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not determine layout areas file URL"])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(areas)
        try data.write(to: targetURL, options: .atomic)
    }

    func removeHeaderFooterReviewItem(_ item: String) {
        var lines = configText.components(separatedBy: .newlines)
        lines.removeAll { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines) == "REMOVE: \(item)"
        }
        let count = lines.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("REMOVE:") }.count
        lines = lines.map { line in
            line.hasPrefix("Repeated candidates:") ? "Repeated candidates: \(count)" : line
        }
        configText = lines.joined(separator: "\n")

        guard let activeConfigFileURL else {
            configStatus = "Removed \(item)."
            return
        }

        do {
            try configText.write(to: activeConfigFileURL, atomically: true, encoding: .utf8)
            configStatus = "Removed \(item)."
        } catch {
            configStatus = "Could not update scan report: \(error.localizedDescription)"
        }
    }

    func runOCRFromDialog() {
        if skipProcessOCREngine {
            loadExistingMarkdown()
        } else {
            sendSelectedPDFToOCREngine()
        }
    }

    func cancelOCR() {
        guard isOCRRunning else { return }
        isOCRCancelling = true
        ocrStatus = "Cancelling OCR..."
    }

    func loadExistingMarkdown() {
        if let markdownText = loadAppleVisionMarkdownText() {
            ocrText = markdownText
            updateSelectedPDFTitleFromOCRText(markdownText)
            ocrStatus = "Loaded existing AppleVision Markdown."
            logOutput = "Loaded Markdown:\n\(localAppleVisionOutputFolderURL?.path ?? "")"
            return
        }

        ocrStatus = "No AppleVision Markdown found."
        logOutput = selectedItemIsManualSection ? "Add text, then save Markdown." : "Run OCR first to create Markdown files."
        ocrParagraphSourcePages = []
        ocrParagraphHasOCRSourcePage = []
    }

    func loadExistingMarkdownAsync() {
        if let markdownText = loadAppleVisionMarkdownText() {
            ocrText = markdownText
            updateSelectedPDFTitleFromOCRText(markdownText)
            ocrStatus = "Loaded existing AppleVision Markdown."
            logOutput = "Loaded Markdown:\n\(localAppleVisionOutputFolderURL?.path ?? "")"
            return
        }

        ocrStatus = "No AppleVision Markdown found."
        logOutput = selectedItemIsManualSection ? "Add text, then save Markdown." : "Run OCR first to create Markdown files."
        ocrParagraphSourcePages = []
        ocrParagraphHasOCRSourcePage = []
    }

    func saveOCRTextFile() -> Bool {
        guard let markdownFolderURL = localAppleVisionOutputFolderURL else {
            ocrStatus = "No PDF selected."
            logOutput = ""
            return false
        }

        do {
            try saveAppleVisionMarkdownText(ocrText, folderURL: markdownFolderURL)
            ocrStatus = "Saved Markdown."
            logOutput = """
            Saved Markdown:
            \(markdownFolderURL.path)
            """
            ocrSaveAlertMessage = "Save successfully"
            return true
        } catch {
            ocrStatus = "Could not save Markdown."
            logOutput = error.localizedDescription
            return false
        }
    }

    func buildBookEPUB() {
        guard !selectedFolderPath.isEmpty else {
            epubStatus = "No folder selected."
            return
        }

        let chapters = pdfFiles.compactMap { item -> [String: Any]? in
            let markdownFolder = markdownFolderURL(for: item)
            let markdownFiles = appleVisionMarkdownPageFiles(in: markdownFolder)
            guard !markdownFiles.isEmpty else {
                return nil
            }
            let title = chapterTitle(for: item, markdownFiles: markdownFiles)
            return [
                "pdf": item.url.path,
                "title": title,
                "markdownFiles": markdownFiles.map(\.path),
            ]
        }

        guard !chapters.isEmpty else {
            epubStatus = "No Markdown chapters found. Run OCR first."
            return
        }

        isOCRRunning = true
        ocrStatus = "Building EPUB from Markdown..."
        epubStatus = "Building one EPUB from \(chapters.count) chapters..."
        logOutput = ""

        let folderURL = URL(fileURLWithPath: selectedFolderPath)
        let configPath = configFileURL.path
        let helperPath = conversionHelperURL.path
        let frontCoverPath: String
        let backCoverPath: String
        do {
            frontCoverPath = try normalizedCoverImagePath(frontCoverImagePath, outputStem: "front-cover")
            backCoverPath = try normalizedCoverImagePath(backCoverImagePath, outputStem: "back-cover")
            frontCoverImagePath = frontCoverPath
            backCoverImagePath = backCoverPath
        } catch {
            epubStatus = "Could not prepare cover image."
            ocrStatus = "Could not prepare cover image."
            logOutput = error.localizedDescription
            return
        }
        let bookTitle = folderURL.lastPathComponent
        let manifestURL = folderURL
            .appendingPathComponent("EPUB", isDirectory: true)
            .appendingPathComponent("book-epub-manifest.json")

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let manifest: [String: Any] = [
                    "bookFolder": folderURL.path,
                    "bookTitle": bookTitle,
                    "outputStem": bookTitle,
                    "frontCover": frontCoverPath,
                    "backCover": backCoverPath,
                    "chapters": chapters,
                ]
                let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                try manifestData.write(to: manifestURL, options: .atomic)

                process.arguments = [
                    helperPath,
                    "--config",
                    configPath,
                    "--chapter-manifest",
                    manifestURL.path,
                ]
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let error = String(data: errorData, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    self.isOCRRunning = false
                    if process.terminationStatus == 0 {
                        let epubPath = self.epubPathFromBuilderOutput(output) ?? self.bookEPUBFileURL?.path ?? ""
                        self.ocrStatus = "EPUB built from Markdown."
                        self.builtEPUBPath = epubPath
                        self.epubStatus = ""
                        self.logOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.isEPUBBuiltAlertPresented = true
                    } else {
                        self.ocrStatus = "Could not build EPUB."
                        self.epubStatus = "Could not build EPUB."
                        self.logOutput = (error.isEmpty ? output : error).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isOCRRunning = false
                    self.ocrStatus = "Could not run EPUB builder."
                    self.epubStatus = "Could not run EPUB builder."
                    self.logOutput = error.localizedDescription
                }
            }
        }
    }

    private func chapterTitle(for item: PDFFileItem, markdownFiles: [URL]) -> String {
        let savedTitle = pdfTitles[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !savedTitle.isEmpty {
            return savedTitle
        }

        for markdownFile in markdownFiles {
            guard let text = try? String(contentsOf: markdownFile, encoding: .utf8),
                  let heading = firstMarkdownHeading(in: text) else {
                continue
            }
            return heading
        }

        return displayName(for: item)
    }

    func applyStylesheet() {
        guard !selectedFolderPath.isEmpty else {
            epubStatus = "No folder selected."
            cssApplyAlertTitle = "Apply CSS"
            cssApplyAlertMessage = "No folder selected."
            isCSSAppliedAlertPresented = true
            return
        }

        let folderURL = URL(fileURLWithPath: selectedFolderPath)
        let stylesFolderURL = folderURL.appendingPathComponent("Styles", isDirectory: true)
        let stylesheetURL = stylesFolderURL.appendingPathComponent("stylesheet.css")

        do {
            try FileManager.default.createDirectory(at: stylesFolderURL, withIntermediateDirectories: true)
            let existingCSS = (try? String(contentsOf: stylesheetURL, encoding: .utf8)) ?? ""
            let imageResult = upsertingImagePageStyles(in: existingCSS)
            let footnoteResult = upsertingFootnoteStyles(in: imageResult.css)
            let blockquoteResult = upsertingBlockquoteStyles(in: footnoteResult.css)
            let alignmentResult = upsertingAlignmentStyles(in: blockquoteResult.css)
            let pageBreakResult = upsertingPageBreakStyles(in: alignmentResult.css)
            let emptyParagraphResult = upsertingEmptyParagraphStyles(in: pageBreakResult.css)
            let updatedCSS = emptyParagraphResult.css
            let progressLines = [
                "Image CSS: \(imageResult.status)",
                "Footnote CSS: \(footnoteResult.status)",
                "Blockquote CSS: \(blockquoteResult.status)",
                "Left/Center/Right CSS: \(alignmentResult.status)",
                "Page break CSS: \(pageBreakResult.status)",
                "Empty paragraph CSS: \(emptyParagraphResult.status)",
            ]
            if updatedCSS == existingCSS {
                epubStatus = "CSS already up to date."
                let message = """
                Stylesheet already matches NewOCR CSS:
                \(stylesheetURL.path)

                Included CSS blocks: images, footnotes, blockquotes, Left/Center/Right alignment, page breaks, and empty paragraphs.

                \(progressLines.joined(separator: "\n"))
                """
                logOutput = message
                cssApplyAlertTitle = "CSS Already Up To Date"
                cssApplyAlertMessage = message
                isCSSAppliedAlertPresented = true
                return
            }
            try updatedCSS.write(to: stylesheetURL, atomically: true, encoding: .utf8)
            epubStatus = "Applied CSS."
            let message = """
            Updated stylesheet:
            \(stylesheetURL.path)

            Included CSS blocks: images, footnotes, blockquotes, Left/Center/Right alignment, page breaks, and empty paragraphs.

            \(progressLines.joined(separator: "\n"))
            """
            logOutput = message
            cssApplyAlertTitle = "Applied CSS"
            cssApplyAlertMessage = message
            isCSSAppliedAlertPresented = true
        } catch {
            epubStatus = "Could not apply CSS."
            logOutput = error.localizedDescription
            cssApplyAlertTitle = "Could Not Apply CSS"
            cssApplyAlertMessage = error.localizedDescription
            isCSSAppliedAlertPresented = true
        }
    }

    private func upsertingImagePageStyles(in css: String) -> (css: String, status: String) {
        let block = imagePageStylesheetBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        let markerPattern = #"(?s)/\* NewOCR image page stylesheet: begin \*/.*?/\* NewOCR image page stylesheet: end \*/"#

        if css.range(of: markerPattern, options: .regularExpression) != nil {
            let updatedCSS = css.replacingOccurrences(of: markerPattern, with: block, options: .regularExpression)
            return (updatedCSS, updatedCSS == css ? "already up to date" : "replaced")
        }

        var cleanedCSS = css
        let legacyImagesSectionPattern = #"(?s)\n*/\* Images \*/\s*(?:img\s*\{.*?\}\s*)?(?:\.image-figure\s*\{.*?\}\s*)?(?:\.image-figure\s+img\s*\{.*?\}\s*)?(?:\.image-figure\s+figcaption\s*\{.*?\}\s*)?"#
        cleanedCSS = cleanedCSS.replacingOccurrences(of: legacyImagesSectionPattern, with: "\n", options: .regularExpression)

        for pattern in [
            #"(?s)\n*\.image-figure\s*\{.*?\}\s*"#,
            #"(?s)\n*\.image-figure\s+img\s*\{.*?\}\s*"#,
            #"(?s)\n*\.image-figure\s+figcaption\s*\{.*?\}\s*"#,
        ] {
            cleanedCSS = cleanedCSS.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
        }

        let status = cleanedCSS == css ? "added" : "replaced legacy rules"
        return (cleanedCSS.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n", status)
    }

    private func upsertingFootnoteStyles(in css: String) -> (css: String, status: String) {
        let block = footnoteStylesheetBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        let markerPattern = #"(?s)/\* NewOCR footnote stylesheet: begin \*/.*?/\* NewOCR footnote stylesheet: end \*/"#

        if css.range(of: markerPattern, options: .regularExpression) != nil {
            let updatedCSS = css.replacingOccurrences(of: markerPattern, with: block, options: .regularExpression)
            return (updatedCSS, updatedCSS == css ? "already up to date" : "replaced")
        }

        var cleanedCSS = css
        for pattern in [
            #"(?s)\n*\.footnote-ref\s*\{.*?\}\s*"#,
            #"(?s)\n*\.footnote-ref\s+a\s*\{.*?\}\s*"#,
            #"(?s)\n*\.footnotes\s*\{.*?\}\s*"#,
            #"(?s)\n*\.footnotes\s+ol\s*\{.*?\}\s*"#,
            #"(?s)\n*\.footnotes\s+li\s*\{.*?\}\s*"#,
            #"(?s)\n*\.footnotes\s+p\s*\{.*?\}\s*"#,
            #"(?s)\n*\.footnote-back\s*\{.*?\}\s*"#,
        ] {
            cleanedCSS = cleanedCSS.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
        }

        let status = cleanedCSS == css ? "added" : "replaced legacy rules"
        return (cleanedCSS.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n", status)
    }

    private func upsertingBlockquoteStyles(in css: String) -> (css: String, status: String) {
        let block = blockquoteStylesheetBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        let markerPattern = #"(?s)/\* NewOCR blockquote stylesheet: begin \*/.*?/\* NewOCR blockquote stylesheet: end \*/"#

        if css.range(of: markerPattern, options: .regularExpression) != nil {
            let updatedCSS = css.replacingOccurrences(of: markerPattern, with: block, options: .regularExpression)
            return (updatedCSS, updatedCSS == css ? "already up to date" : "replaced")
        }

        var cleanedCSS = css
        for pattern in [
            #"(?s)\n*\.blockquote\s*\{.*?\}\s*"#,
            #"(?s)\n*blockquote\s*\{.*?\}\s*"#,
            #"(?s)\n*blockquote\s+p\s*\{.*?\}\s*"#,
        ] {
            cleanedCSS = cleanedCSS.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
        }

        let status = cleanedCSS == css ? "added" : "replaced legacy rules"
        return (cleanedCSS.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n", status)
    }

    private func upsertingAlignmentStyles(in css: String) -> (css: String, status: String) {
        let block = alignmentStylesheetBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        let markerPattern = #"(?s)/\* NewOCR alignment stylesheet: begin \*/.*?/\* NewOCR alignment stylesheet: end \*/"#

        if css.range(of: markerPattern, options: .regularExpression) != nil {
            let updatedCSS = css.replacingOccurrences(of: markerPattern, with: block, options: .regularExpression)
            return (updatedCSS, updatedCSS == css ? "already up to date" : "replaced")
        }

        var cleanedCSS = css
        for pattern in [
            #"(?s)\n*\.center\s*\{.*?\}\s*"#,
            #"(?s)\n*\.right\s*\{.*?\}\s*"#,
            #"(?s)\n*\.left\s*\{.*?\}\s*"#,
        ] {
            cleanedCSS = cleanedCSS.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
        }

        let status = cleanedCSS == css ? "added" : "replaced legacy rules"
        return (cleanedCSS.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n", status)
    }

    private func upsertingPageBreakStyles(in css: String) -> (css: String, status: String) {
        let block = pageBreakStylesheetBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        let markerPattern = #"(?s)/\* NewOCR page break stylesheet: begin \*/.*?/\* NewOCR page break stylesheet: end \*/"#

        if css.range(of: markerPattern, options: .regularExpression) != nil {
            let updatedCSS = css.replacingOccurrences(of: markerPattern, with: block, options: .regularExpression)
            return (updatedCSS, updatedCSS == css ? "already up to date" : "replaced")
        }

        var cleanedCSS = css
        for pattern in [
            #"(?s)\n*\.page-break-before\s*\{.*?\}\s*"#,
            #"(?s)\n*\.page-break-after\s*\{.*?\}\s*"#,
        ] {
            cleanedCSS = cleanedCSS.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
        }

        let status = cleanedCSS == css ? "added" : "replaced legacy rules"
        return (cleanedCSS.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n", status)
    }

    private func upsertingEmptyParagraphStyles(in css: String) -> (css: String, status: String) {
        let block = emptyParagraphStylesheetBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        let markerPattern = #"(?s)/\* NewOCR empty paragraph stylesheet: begin \*/.*?/\* NewOCR empty paragraph stylesheet: end \*/"#

        if css.range(of: markerPattern, options: .regularExpression) != nil {
            let updatedCSS = css.replacingOccurrences(of: markerPattern, with: block, options: .regularExpression)
            return (updatedCSS, updatedCSS == css ? "already up to date" : "replaced")
        }

        var cleanedCSS = css
        cleanedCSS = cleanedCSS.replacingOccurrences(
            of: #"(?s)\n*\.empty-paragraph\s*\{.*?\}\s*"#,
            with: "\n",
            options: .regularExpression
        )

        let status = cleanedCSS == css ? "added" : "replaced legacy rules"
        return (cleanedCSS.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n", status)
    }

    private var imagePageStylesheetBlock: String {
        """
        /* NewOCR image page stylesheet: begin */
        img {
          max-width: 100%;
          height: auto;
        }

        .image-figure {
          page-break-before: always;
          page-break-after: always;
          page-break-inside: avoid;
          break-before: page;
          break-after: page;
          break-inside: avoid;
          margin: 0;
          padding: 0;
          text-align: center;
        }

        .image-figure img {
          max-width: 100%;
          max-height: 82vh;
          width: auto;
          height: auto;
          object-fit: contain;
        }

        .image-figure figcaption {
          margin-top: 0.6em;
          font-size: 0.9em;
          line-height: 1.4;
          text-align: center;
          text-indent: 0;
          color: #555;
        }
        /* NewOCR image page stylesheet: end */
        """
    }

    private var footnoteStylesheetBlock: String {
        """
        /* NewOCR footnote stylesheet: begin */
        a.fn-noteref {
          font-size: 0.75em;
          line-height: 0;
          vertical-align: super;
          text-decoration: none;
          color: inherit;
        }

        a.fn-noteref sup {
          font-size: 1em;
        }

        aside.fn-aside {
          display: none;
        }

        aside.fn-aside p {
          margin: 0;
          font-size: 0.9em;
          line-height: 1.5;
        }
        /* NewOCR footnote stylesheet: end */
        """
    }

    private var blockquoteStylesheetBlock: String {
        """
        /* NewOCR blockquote stylesheet: begin */
        .blockquote,
        blockquote {
          margin: 1em 1.5em;
          padding: 0.6em 1em;
          border-left: 0.18em solid #999;
          font-style: italic;
          line-height: 1.55;
          text-indent: 0;
          break-inside: avoid;
          page-break-inside: avoid;
        }

        .blockquote p,
        blockquote p {
          margin: 0;
          text-indent: 0;
        }
        /* NewOCR blockquote stylesheet: end */
        """
    }

    private var alignmentStylesheetBlock: String {
        """
        /* NewOCR alignment stylesheet: begin */
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
        /* NewOCR alignment stylesheet: end */
        """
    }

    private var pageBreakStylesheetBlock: String {
        """
        /* NewOCR page break stylesheet: begin */
        .page-break-before {
          break-before: page;
          page-break-before: always;
          height: 0;
          margin: 0;
          padding: 0;
        }

        .page-break-after {
          break-after: page;
          page-break-after: always;
          height: 0;
          margin: 0;
          padding: 0;
        }
        /* NewOCR page break stylesheet: end */
        """
    }

    private var emptyParagraphStylesheetBlock: String {
        """
        /* NewOCR empty paragraph stylesheet: begin */
        .empty-paragraph {
          min-height: 1.65em;
          text-indent: 0;
        }
        /* NewOCR empty paragraph stylesheet: end */
        """
    }

    private func epubPathFromBuilderOutput(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["epubFile"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return path
    }

    func openBuiltEPUBFile() {
        let path = !builtEPUBPath.isEmpty ? builtEPUBPath : (bookEPUBFilePathIfExists ?? "")
        guard !path.isEmpty else {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openBuiltEPUBInBooks() {
        let path = !builtEPUBPath.isEmpty ? builtEPUBPath : (bookEPUBFilePathIfExists ?? "")
        guard !path.isEmpty else {
            return
        }

        let epubURL = URL(fileURLWithPath: path)
        if let booksURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([epubURL], withApplicationAt: booksURL, configuration: configuration) { _, error in
                if error != nil {
                    NSWorkspace.shared.open(epubURL)
                }
            }
        } else {
            NSWorkspace.shared.open(epubURL)
        }
    }

    func openOCRMarkdownPreviewWindow() {
        guard let markdownFolderURL = localAppleVisionOutputFolderURL else {
            ocrStatus = "No PDF selected."
            return
        }

        do {
            loadAppConfigValues()
            let previewURL = markdownFolderURL.appendingPathComponent("preview.html")
            try previewHTML(for: ocrText).write(to: previewURL, atomically: true, encoding: .utf8)

            closeOCRMarkdownPreviewWindow()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Preview - \(selectedPDFName)"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: OCRMarkdownPreviewWindowView(previewURL: previewURL, readAccessURL: markdownFolderURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
            )
            ocrPreviewWindow = window
            window.makeKeyAndOrderFront(nil)
        } catch {
            ocrStatus = "Could not open preview."
            logOutput = error.localizedDescription
        }
    }

    func openOCRLogWindow() {
        if let ocrLogWindow {
            ocrLogWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Log - \(selectedPDFName)"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: OCRLogWindowView()
                .environmentObject(self)
        )
        ocrLogWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func openOCRCompareReport(for item: PDFFileItem) {
        guard !item.isManualSection else {
            showAlert(title: "Compare Not Available", message: "Manual sections do not have a pure Apple Vision OCR result.")
            return
        }

        guard pureOCRSnapshotExists(for: item) else {
            showAlert(title: "Compare Not Available", message: "Run OCR for this section first to create a pure Apple Vision OCR snapshot.")
            return
        }

        let differences = ocrCompareDifferences(for: item)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Compare - \(sectionListDisplayName(for: item))"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: OCRCompareReportWindowView(
                sectionTitle: sectionListDisplayName(for: item),
                differences: differences
            )
        )
        ocrCompareWindows.append(window)
        trackRetainedWindow(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func trackRetainedWindow(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        let delegate = WindowCleanupDelegate { [weak self] closedWindow in
            guard let self else { return }
            closedWindow.contentView = nil
            self.ocrWindows.removeAll { $0 === closedWindow }
            self.ocrCompareWindows.removeAll { $0 === closedWindow }
            self.finalizeAIWindows.removeAll { $0 === closedWindow }
            self.finalizeAIInstructionWindows.removeAll { $0 === closedWindow }
            self.layoutAreaWindows.removeAll { $0 === closedWindow }
            self.configEditorWindows.removeAll { $0 === closedWindow }
            self.retainedWindowDelegates.removeValue(forKey: ObjectIdentifier(closedWindow))
        }
        retainedWindowDelegates[key] = delegate
        window.delegate = delegate
    }

    private func previewHTML(for markdown: String) -> String {
        let escapedTitle = htmlEscaped(selectedPDFName)
        let styles = previewStylesHTML()

        return """
        <!doctype html>
        <html lang="th">
        <head>
        <meta charset="utf-8">
        <title>\(escapedTitle)</title>
        \(styles)
        </head>
        <body>
        <main class="newocr-preview-content">
        \(markdownToPreviewHTML(markdown))
        </main>
        <script>
        (function() {
          var pop = null;
          document.addEventListener('click', function(e) {
            var ref = e.target.closest ? e.target.closest('.fn-ref') : null;
            if (ref) {
              e.stopPropagation();
              var id = ref.getAttribute('data-fn');
              var aside = document.getElementById(id);
              if (!aside) return;
              if (pop && pop.getAttribute('data-fn-id') === id) { pop.remove(); pop = null; return; }
              if (pop) { pop.remove(); pop = null; }
              pop = document.createElement('div');
              pop.className = 'fn-popup';
              pop.setAttribute('data-fn-id', id);
              pop.innerHTML = aside.innerHTML;
              document.body.appendChild(pop);
              return;
            }
            if (pop && !pop.contains(e.target)) { pop.remove(); pop = null; }
          });
        })();
        </script>
        </body>
        </html>
        """
    }

    private func previewStylesHTML() -> String {
        let scalePercent = Int(previewTextScalePercent.rounded())
        let popupFontPercent = Int(footnotePopupFontPercent.rounded())
        guard !selectedPDFPath.isEmpty else {
            return fallbackPreviewStyleHTML()
        }

        let projectFolderURL = URL(fileURLWithPath: selectedFolderPath)
        let stylesheetURL = projectFolderURL
            .appendingPathComponent("Styles", isDirectory: true)
            .appendingPathComponent("stylesheet.css")

        if FileManager.default.fileExists(atPath: stylesheetURL.path) {
            return """
            <link rel="stylesheet" type="text/css" href="../../../Styles/stylesheet.css">
        <style>
        .newocr-preview-content { font-size: \(scalePercent)% !important; }
        img { max-width: 100%; height: auto; }
        figure { margin: 1em 0; }
        figcaption { margin-top: 0.5em; }
        blockquote, .blockquote { margin: 1em 1.5em; padding: 0.6em 1em; border-left: 3px solid #999; font-style: italic; }
        blockquote p, .blockquote p { margin: 0; text-indent: 0; }
        .center { text-align: center; text-indent: 0; }
        .right { text-align: right; text-indent: 0; }
        .left { text-align: left; text-indent: 0; }
        .page-break-before, .page-break-after { border-top: 1px solid #b8b8b8; height: 0; margin: 1.4em 0; position: relative; break-before: auto; break-after: auto; page-break-before: auto; page-break-after: auto; }
        .page-break-before::after { content: "Page break before"; position: absolute; top: -0.75em; left: 50%; transform: translateX(-50%); background: Canvas; color: #666; font-size: 0.78em; padding: 0 0.6em; }
        .page-break-after::after { content: "Page break after"; position: absolute; top: -0.75em; left: 50%; transform: translateX(-50%); background: Canvas; color: #666; font-size: 0.78em; padding: 0 0.6em; }
        .empty-paragraph { min-height: 1.65em; text-indent: 0; }
        .fn-ref { cursor: pointer; font-size: 0.75em; line-height: 0; vertical-align: super; }
        .fn-popup { position: fixed; left: 50%; top: 50%; transform: translate(-50%, -50%); background: #fff; border: 1px solid #ccc; border-radius: 8px; box-shadow: 0 4px 24px rgba(0,0,0,0.22); padding: 14px 18px; max-width: 420px; width: calc(100vw - 48px); font-size: \(popupFontPercent)%; line-height: 1.6; z-index: 9999; color: #222; }
        </style>
        """
        }

        return fallbackPreviewStyleHTML()
    }

    private func fallbackPreviewStyleHTML() -> String {
        let scalePercent = Int(previewTextScalePercent.rounded())
        let popupFontPercent = Int(footnotePopupFontPercent.rounded())
        return """
        <style>
        body { font-family: serif; line-height: 1.55; padding: 24px; }
        .newocr-preview-content { font-size: \(scalePercent)% !important; }
        p { margin: 0 0 1em 0; }
        img { max-width: 100%; height: auto; }
        figure { margin: 1em 0; }
        figcaption { margin-top: 0.5em; font-size: 0.9em; color: #555; }
        blockquote, .blockquote { margin: 1em 1.5em; padding: 0.6em 1em; border-left: 3px solid #999; font-style: italic; }
        blockquote p, .blockquote p { margin: 0; text-indent: 0; }
        .center { text-align: center; text-indent: 0; }
        .right { text-align: right; text-indent: 0; }
        .left { text-align: left; text-indent: 0; }
        .page-break-before, .page-break-after { border-top: 1px solid #b8b8b8; height: 0; margin: 1.4em 0; position: relative; }
        .page-break-before::after { content: "Page break before"; position: absolute; top: -0.75em; left: 50%; transform: translateX(-50%); background: Canvas; color: #666; font-size: 0.78em; padding: 0 0.6em; }
        .page-break-after::after { content: "Page break after"; position: absolute; top: -0.75em; left: 50%; transform: translateX(-50%); background: Canvas; color: #666; font-size: 0.78em; padding: 0 0.6em; }
        .empty-paragraph { min-height: 1.65em; text-indent: 0; }
        .fn-ref { cursor: pointer; font-size: 0.75em; line-height: 0; vertical-align: super; }
        .fn-popup { position: fixed; left: 50%; top: 50%; transform: translate(-50%, -50%); background: #fff; border: 1px solid #ccc; border-radius: 8px; box-shadow: 0 4px 24px rgba(0,0,0,0.22); padding: 14px 18px; max-width: 420px; width: calc(100vw - 48px); font-size: \(popupFontPercent)%; line-height: 1.6; z-index: 9999; color: #222; }
        </style>
        """
    }

    private func markdownToPreviewHTML(_ markdown: String) -> String {
        var parts: [String] = []
        let extracted = extractMarkdownFootnotes(from: markdown)
        var usedFootnotes: [String] = []
        var inlineRenderedLabels: Set<String> = []
        // Use original markdown (not stripped) so footnote definitions stay at their
        // position in the paragraph flow instead of all floating to the end.
        let paragraphs = splitParagraphs(markdown)
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                parts.append("<p class=\"empty-paragraph\"><br/></p>")
                continue
            }

            // Render a paragraph that consists entirely of [^N]: definition lines
            // inline at this position rather than collecting them for the end.
            if let inlineHTML = markdownInlineFootnoteDefinitionsHTML(
                from: trimmed,
                definitions: extracted.footnotes,
                renderedLabels: &inlineRenderedLabels,
                usedFootnotes: &usedFootnotes
            ) {
                parts.append(inlineHTML)
                continue
            }

            if let pageBreak = markdownPageBreakPreviewHTML(from: trimmed) {
                parts.append(pageBreak)
                continue
            }

            if let imageHTML = markdownImagePreviewHTML(from: trimmed) {
                parts.append(imageHTML)
                continue
            }

            if let heading = markdownHeadingHTML(from: trimmed, usedFootnotes: &usedFootnotes) {
                parts.append(heading)
                continue
            }

            if let blockquote = markdownBlockquotePreviewHTML(from: trimmed, usedFootnotes: &usedFootnotes) {
                parts.append(blockquote)
                continue
            }

            if let aligned = markdownAlignedParagraphPreviewHTML(from: trimmed, usedFootnotes: &usedFootnotes) {
                parts.append(aligned)
                continue
            }

            parts.append("<p>\(markdownInlinePreviewHTML(trimmed.replacingOccurrences(of: "\n", with: " "), usedFootnotes: &usedFootnotes))</p>")
        }
        // Any footnotes not rendered inline (traditional end-of-document placement).
        let remainingUsed = usedFootnotes.filter { !inlineRenderedLabels.contains($0) }
        if let footnotesHTML = footnotesPreviewHTML(definitions: extracted.footnotes, usedLabels: remainingUsed) {
            parts.append(footnotesHTML)
        }
        return parts.joined(separator: "\n")
    }

    // Returns an inline footnotes section HTML if every line in the paragraph is a
    // [^label]: definition. Returns nil if ANY line is not a definition (so the
    // paragraph falls through to normal rendering).
    private func markdownInlineFootnoteDefinitionsHTML(
        from paragraph: String,
        definitions: [String: String],
        renderedLabels: inout Set<String>,
        usedFootnotes: inout [String]
    ) -> String? {
        let lines = paragraph.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let defRegex = try? NSRegularExpression(pattern: #"^\[\^([^\]]+)\]:\s*(.*)"#)
        var items: [String] = []
        for line in lines {
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = defRegex?.firstMatch(in: line, range: nsRange),
                  match.numberOfRanges > 2,
                  let labelRange = Range(match.range(at: 1), in: line) else {
                return nil  // non-definition line in this paragraph — don't handle it here
            }
            let label = String(line[labelRange])
            let noteText = definitions[label] ?? {
                if let bodyRange = Range(match.range(at: 2), in: line) { return String(line[bodyRange]) }
                return ""
            }()
            let fragment = footnoteFragmentID(label, fallback: "fn-\(label)")
            items.append("<aside id=\"fn-\(htmlEscaped(fragment))\" class=\"fn-aside\" hidden>\(markdownInlinePreviewHTML(noteText, usedFootnotes: &usedFootnotes))</aside>")
            renderedLabels.insert(label)
        }
        guard !items.isEmpty else { return nil }
        return items.joined(separator: "\n")
    }

    private func markdownHeadingHTML(from text: String, usedFootnotes: inout [String]) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let firstHeading = markdownHeadingParts(from: lines.first ?? "") else { return nil }
        let level = firstHeading.level
        var titleParts = [firstHeading.title]

        for line in lines.dropFirst() {
            guard let heading = markdownHeadingParts(from: line),
                  heading.level == level else {
                break
            }
            titleParts.append(heading.title)
        }

        let titleHTML = titleParts.map { markdownInlinePreviewHTML($0, usedFootnotes: &usedFootnotes) }.joined(separator: "<br>")
        return "<h\(level)>\(titleHTML)</h\(level)>"
    }

    private func markdownHeadingParts(from text: String) -> (level: Int, title: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"^(#{1,6})(\s*)(.+?)\s*$"#),
              let nsMatch = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
              nsMatch.numberOfRanges >= 4,
              let hashRange = Range(nsMatch.range(at: 1), in: trimmed),
              let spaceRange = Range(nsMatch.range(at: 2), in: trimmed),
              let titleRange = Range(nsMatch.range(at: 3), in: trimmed) else {
            return nil
        }
        let level = min(trimmed[hashRange].count, 6)
        let space = trimmed[spaceRange]
        var title = String(trimmed[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasSuffix("#") {
            title = title.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if space.isEmpty, title.allSatisfy(\.isNumber) {
            return title.isEmpty ? nil : (max(level, 3), title)
        }
        return title.isEmpty ? nil : (level, title)
    }

    private func markdownBlockquotePreviewHTML(from text: String, usedFootnotes: inout [String]) -> String? {
        let quoteLines = text.components(separatedBy: .newlines).compactMap { rawLine -> String? in
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(">") else { return nil }
            let quote = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            return quote.isEmpty ? nil : String(quote)
        }
        guard !quoteLines.isEmpty else { return nil }
        let quoteHTML = quoteLines.map { markdownInlinePreviewHTML($0, usedFootnotes: &usedFootnotes) }.joined(separator: "<br>")
        return "<blockquote class=\"blockquote\"><p>\(quoteHTML)</p></blockquote>"
    }

    private func markdownAlignedParagraphPreviewHTML(from text: String, usedFootnotes: inout [String]) -> String? {
        guard let parsed = markdownAlignedParagraphParts(from: text) else {
            return nil
        }
        let content = parsed.content.replacingOccurrences(of: "\n", with: "<br/>")
        return "<p class=\"\(parsed.alignment)\">\(markdownInlinePreviewHTML(content, usedFootnotes: &usedFootnotes))</p>"
    }

    private func markdownPageBreakPreviewHTML(from text: String) -> String? {
        switch text {
        case "<!-- page-break-before -->", "[[page-break-before]]":
            return "<div class=\"page-break-before\" aria-label=\"Page break before\"></div>"
        case "<!-- page-break-after -->", "[[page-break-after]]":
            return "<div class=\"page-break-after\" aria-label=\"Page break after\"></div>"
        default:
            return nil
        }
    }

    private func markdownAlignedParagraphParts(from text: String) -> (alignment: String, content: String)? {
        let pattern = #"(?is)^<p\s+class\s*=\s*["'](left|right|center)["']\s*>(.*?)</p>$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let alignmentRange = Range(match.range(at: 1), in: text),
              let contentRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        let alignment = String(text[alignmentRange]).lowercased()
        let content = String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : (alignment, content)
    }

    private func markdownImagePreviewHTML(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              firstLine.hasPrefix("!["),
              let closeBracket = firstLine.firstIndex(of: "]"),
              let openParen = firstLine.firstIndex(of: "("),
              let closeParen = firstLine.lastIndex(of: ")"),
              closeBracket < openParen,
              openParen < closeParen else {
            return nil
        }
        let alt = String(firstLine[firstLine.index(firstLine.startIndex, offsetBy: 2)..<closeBracket])
        let path = String(firstLine[firstLine.index(after: openParen)..<closeParen])
        let captionLines = imageCaptionLines(from: lines)
        let captionHTML = captionLines.isEmpty ? "" : "\n<figcaption>\(captionLines.map { markdownInlinePreviewHTML($0) }.joined(separator: "<br>"))</figcaption>"
        return "<figure class=\"image-figure\"><img src=\"\(htmlEscaped(path))\" alt=\"\(htmlEscaped(alt))\">\(captionHTML)</figure>"
    }

    private func imageCaption(from lines: [String]) -> String {
        imageCaptionLines(from: lines).joined(separator: "\n")
    }

    private func imageCaptionLines(from lines: [String]) -> [String] {
        var foundCaption = false
        return lines.dropFirst().compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = line.lowercased()
            if lowercased.hasPrefix("caption:") {
                foundCaption = true
                return String(line.dropFirst("caption:".count)).trimmingCharacters(in: .whitespaces)
            }
            if lowercased.hasPrefix("description:") {
                foundCaption = true
                return String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
            }
            if foundCaption && (rawLine.hasPrefix("  ") || rawLine.hasPrefix("    ") || rawLine.hasPrefix("\t")) {
                return line
            }
            if foundCaption && !line.isEmpty && !isMarkdownBlockStart(line) {
                return line
            }
            return nil
        }
        .filter { !$0.isEmpty }
    }

    private func isMarkdownBlockStart(_ line: String) -> Bool {
        line.hasPrefix("![")
        || line.hasPrefix("[^")
        || line.range(of: #"^#{1,6}\s+.+"#, options: .regularExpression) != nil
    }

    private func extractMarkdownFootnotes(from markdown: String) -> (markdown: String, footnotes: [String: String]) {
        var contentLines: [String] = []
        var footnotes: [String: [String]] = [:]
        var activeLabel: String?

        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("[^"), let closeIndex = line.firstIndex(of: "]") {
                let afterClose = line[line.index(after: closeIndex)...]
                if afterClose.hasPrefix(":") {
                    let labelStart = line.index(line.startIndex, offsetBy: 2)
                    let label = String(line[labelStart..<closeIndex])
                    let noteStart = afterClose.index(after: afterClose.startIndex)
                    activeLabel = label
                    footnotes[label] = [String(afterClose[noteStart...]).trimmingCharacters(in: .whitespaces)]
                    continue
                }
            }

            if let label = activeLabel, line.hasPrefix("    ") || line.hasPrefix("\t") {
                footnotes[label, default: []].append(line.trimmingCharacters(in: .whitespaces))
                continue
            }

            activeLabel = nil
            contentLines.append(line)
        }

        let cleaned = footnotes.mapValues { parts in
            parts.filter { !$0.isEmpty }.joined(separator: " ")
        }.filter { !$0.value.isEmpty }

        return (contentLines.joined(separator: "\n"), cleaned)
    }

    private func footnoteFragmentID(_ label: String, fallback: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let scalars = label.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let slug = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_")).lowercased()
        return slug.isEmpty ? fallback : slug
    }

    // Returns " start=\"N\"" when the label is a positive integer > 1, otherwise "".
    private func olStartAttribute(for firstLabel: String?) -> String {
        guard let label = firstLabel,
              let n = Int(label.trimmingCharacters(in: .whitespacesAndNewlines)),
              n > 1 else { return "" }
        return " start=\"\(n)\""
    }

    private func footnotesPreviewHTML(definitions: [String: String], usedLabels: [String]) -> String? {
        var items: [String] = []
        for (index, label) in usedLabels.enumerated() {
            guard let noteText = definitions[label] else { continue }
            let fragment = footnoteFragmentID(label, fallback: "note-\(index + 1)")
            items.append("<aside id=\"fn-\(htmlEscaped(fragment))\" class=\"fn-aside\" hidden>\(markdownInlinePreviewHTML(noteText))</aside>")
        }
        guard !items.isEmpty else { return nil }
        return items.joined(separator: "\n")
    }

    private func markdownInlinePreviewHTML(_ text: String) -> String {
        var usedFootnotes: [String] = []
        return markdownInlinePreviewHTML(text, usedFootnotes: &usedFootnotes)
    }

    private func markdownInlinePreviewHTML(_ text: String, usedFootnotes: inout [String]) -> String {
        var escaped = htmlEscaped(text)
        escaped = escaped.replacingOccurrences(of: #"&lt;br\s*/?&gt;"#, with: "<br>", options: [.regularExpression, .caseInsensitive])
        escaped = escaped.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        escaped = escaped.replacingOccurrences(of: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, with: "<em>$1</em>", options: .regularExpression)
        let pattern = #"\[\^([A-Za-z0-9_-]+)\]"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsRange = NSRange(escaped.startIndex..<escaped.endIndex, in: escaped)
            let matches = regex.matches(in: escaped, range: nsRange)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let labelRange = Range(match.range(at: 1), in: escaped) else { continue }
                let label = String(escaped[labelRange])
                if !usedFootnotes.contains(label) {
                    usedFootnotes.append(label)
                }
            }
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let fullRange = Range(match.range(at: 0), in: escaped),
                      let labelRange = Range(match.range(at: 1), in: escaped) else { continue }
                let label = String(escaped[labelRange])
                let fragment = footnoteFragmentID(label, fallback: "note-\(usedFootnotes.count)")
                let replacement = "<sup class=\"fn-ref\" data-fn=\"fn-\(htmlEscaped(fragment))\">\(htmlEscaped(label))</sup>"
                escaped.replaceSubrange(fullRange, with: replacement)
            }
        }
        return escaped
    }

    private func htmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    func appleVisionMarkdownExists(for item: PDFFileItem) -> Bool {
        let folderURL = markdownFolderURL(for: item)
        let pageFiles = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        return pageFiles.contains { $0.pathExtension.lowercased() == "md" }
    }

    func pureOCRSnapshotExists(for item: PDFFileItem) -> Bool {
        guard !item.isManualSection else { return false }
        let folderURL = pureOCRSnapshotFolderURL(in: markdownFolderURL(for: item))
        let pageFiles = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        return pageFiles.contains { $0.pathExtension.lowercased() == "md" }
    }

    var markdownChapterCount: Int {
        pdfFiles.filter { appleVisionMarkdownExists(for: $0) }.count
    }

    var canProcessOCRAllSections: Bool {
        !isOCRRunning && pdfFiles.contains {
            !($0.isManualSection)
                && !epubReadySectionIDs.contains($0.id)
                && FileManager.default.fileExists(atPath: $0.url.path)
        }
    }

    var firstNotReadySectionID: String? {
        pdfFiles.first { !epubReadySectionIDs.contains($0.id) }?.id
    }

    var canScanHeaderAllSections: Bool {
        !isHeaderFooterScanRunning && !isOCRRunning && pdfFiles.contains { !($0.isManualSection) && FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func markdownFolderURL(for item: PDFFileItem) -> URL {
        if item.isManualSection {
            return manualMarkdownFolderURL(for: item.url)
        }

        return appleVisionOutputFolderURL(for: item.url)
            .appendingPathComponent(item.url.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    private func pureOCRSnapshotFolderURL(in markdownFolderURL: URL) -> URL {
        markdownFolderURL.appendingPathComponent("OriginalOCR", isDirectory: true)
    }

    private func manualMarkdownFolderURL(for url: URL) -> URL {
        let folderURL = URL(fileURLWithPath: selectedFolderPath)
        return folderURL
            .appendingPathComponent("AppleVision", isDirectory: true)
            .appendingPathComponent("MD", isDirectory: true)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    private func loadAppleVisionMarkdownText() -> String? {
        guard let loaded = loadAppleVisionMarkdown() else {
            return nil
        }
        ocrParagraphSourcePages = loaded.sourcePages
        ocrParagraphHasOCRSourcePage = loaded.ocrSourcePageFlags
        return loaded.text
    }

    private func loadAppleVisionMarkdown() -> (text: String, sourcePages: [Int], ocrSourcePageFlags: [Bool])? {
        guard let folderURL = localAppleVisionOutputFolderURL else {
            return nil
        }

        let files = appleVisionMarkdownPageFiles(in: folderURL)
        guard !files.isEmpty else {
            return nil
        }

        var paragraphs: [String] = []
        var sourcePages: [Int] = []
        for (fileIndex, fileURL) in files.enumerated() {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }

            let page = normalizedPageNumber(from: fileURL, fallbackIndex: fileIndex)
            let pageParagraphs = splitParagraphs(text)
            paragraphs.append(contentsOf: pageParagraphs)
            sourcePages.append(contentsOf: Array(repeating: page, count: pageParagraphs.count))
        }

        let text = paragraphs.joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }

        let flags = loadOCRParagraphSourcePageFlags(in: folderURL, paragraphCount: paragraphs.count)
            ?? Array(repeating: !selectedItemIsManualSection, count: paragraphs.count)
        return (text, sourcePages, flags)
    }

    private func saveAppleVisionMarkdownText(_ text: String, folderURL: URL) throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let paragraphs = splitParagraphs(text)
        let sourcePages = normalizedSourcePages(
            ocrParagraphSourcePages.isEmpty ? nil : ocrParagraphSourcePages,
            paragraphCount: paragraphs.count
        )
        let sourcePageFlags = normalizedOCRSourcePageFlags(ocrParagraphHasOCRSourcePage, paragraphCount: paragraphs.count)
        let grouped = Dictionary(grouping: Array(zip(paragraphs.indices, paragraphs)), by: { sourcePages[$0.0] })
        let pageNumbers = Set(grouped.keys)
        let savedPageNumbers = pageNumbers.isEmpty ? Set([1]) : pageNumbers

        let existingFiles = appleVisionMarkdownPageFiles(in: folderURL)
        for fileURL in existingFiles {
            let page = normalizedPageNumber(from: fileURL, fallbackIndex: 0)
            guard !savedPageNumbers.contains(page) else { continue }
            let backupURL = fileURL.deletingPathExtension().appendingPathExtension("md.bak")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
            } else {
                try FileManager.default.removeItem(at: fileURL)
            }
        }

        for page in savedPageNumbers.sorted() {
            let pageParagraphs = grouped[page, default: []]
                .sorted { $0.0 < $1.0 }
                .map(\.1)
            let pageText = pageParagraphs.joined(separator: "\n\n")
            let pageURL = folderURL.appendingPathComponent("page\(page).md")
            try pageText.trimmingCharacters(in: .whitespacesAndNewlines).write(to: pageURL, atomically: true, encoding: .utf8)
        }

        ocrParagraphSourcePages = paragraphs.isEmpty ? [] : sourcePages
        ocrParagraphHasOCRSourcePage = paragraphs.isEmpty ? [] : sourcePageFlags
        try saveOCRParagraphSourcePageFlags(pages: sourcePages, flags: sourcePageFlags, in: folderURL)
    }

    private func loadOCRParagraphSourcePageFlags(in folderURL: URL, paragraphCount: Int) -> [Bool]? {
        let metadataURL = ocrParagraphSourcePageMetadataURL(in: folderURL)
        guard let data = try? Data(contentsOf: metadataURL),
              let records = try? JSONDecoder().decode([OCRParagraphSourcePageRecord].self, from: data),
              records.count == paragraphCount else {
            return nil
        }
        return records.map(\.hasOCRSourcePage)
    }

    private func saveOCRParagraphSourcePageFlags(pages: [Int], flags: [Bool], in folderURL: URL) throws {
        let records = zip(pages, flags).map { OCRParagraphSourcePageRecord(page: $0.0, hasOCRSourcePage: $0.1) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: ocrParagraphSourcePageMetadataURL(in: folderURL), options: .atomic)
    }

    private func savePureOCRSnapshot(_ pageMarkdownItems: [OCRPageMarkdown], in markdownFolderURL: URL) throws {
        let snapshotFolderURL = pureOCRSnapshotFolderURL(in: markdownFolderURL)
        if FileManager.default.fileExists(atPath: snapshotFolderURL.path) {
            try FileManager.default.removeItem(at: snapshotFolderURL)
        }
        try FileManager.default.createDirectory(at: snapshotFolderURL, withIntermediateDirectories: true)
        for pageMarkdown in pageMarkdownItems {
            let pageURL = snapshotFolderURL.appendingPathComponent("page\(pageMarkdown.pageNumber).md")
            try pageMarkdown.text.write(to: pageURL, atomically: true, encoding: .utf8)
        }
    }

    private func ocrParagraphSourcePageMetadataURL(in folderURL: URL) -> URL {
        folderURL.appendingPathComponent("paragraph-source-pages.json")
    }

    private func ocrCompareDifferences(for item: PDFFileItem) -> [OCRCompareDifference] {
        let markdownFolderURL = markdownFolderURL(for: item)
        let purePages = markdownPageTexts(in: pureOCRSnapshotFolderURL(in: markdownFolderURL))
        let editedPages = markdownPageTexts(in: markdownFolderURL)
        let pageNumbers = Set(purePages.keys).union(editedPages.keys).sorted()

        return pageNumbers.flatMap { page in
            paragraphDifferences(
                page: page,
                pureParagraphs: splitParagraphs(purePages[page] ?? ""),
                editedParagraphs: splitParagraphs(editedPages[page] ?? "")
            )
        }
    }

    private func markdownPageTexts(in folderURL: URL) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: appleVisionMarkdownPageFiles(in: folderURL).map { fileURL in
            let page = normalizedPageNumber(from: fileURL, fallbackIndex: 0)
            let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            return (page, text.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    private func paragraphDifferences(page: Int, pureParagraphs: [String], editedParagraphs: [String]) -> [OCRCompareDifference] {
        let pureNormalized = pureParagraphs.map(compareNormalizedText)
        let editedNormalized = editedParagraphs.map(compareNormalizedText)
        let operations = paragraphDiffOperations(pureNormalized: pureNormalized, editedNormalized: editedNormalized)
        var differences: [OCRCompareDifference] = []
        var missing: [String] = []
        var added: [String] = []

        func flushPending() {
            let pairedCount = min(missing.count, added.count)
            if pairedCount > 0 {
                for offset in 0..<pairedCount {
                    differences.append(
                        OCRCompareDifference(
                            page: page,
                            kind: .changed,
                            pureText: missing[offset],
                            editedText: added[offset]
                        )
                    )
                }
            }
            if missing.count > pairedCount {
                for text in missing.dropFirst(pairedCount) {
                    differences.append(
                        OCRCompareDifference(
                            page: page,
                            kind: .missingFromEdited,
                            pureText: text,
                            editedText: ""
                        )
                    )
                }
            }
            if added.count > pairedCount {
                for text in added.dropFirst(pairedCount) {
                    differences.append(
                        OCRCompareDifference(
                            page: page,
                            kind: .addedInEdited,
                            pureText: "",
                            editedText: text
                        )
                    )
                }
            }
            missing = []
            added = []
        }

        for operation in operations {
            switch operation {
            case .equal:
                flushPending()
            case .delete(let index):
                if pureParagraphs.indices.contains(index) {
                    missing.append(pureParagraphs[index])
                }
            case .insert(let index):
                if editedParagraphs.indices.contains(index) {
                    added.append(editedParagraphs[index])
                }
            }
        }
        flushPending()
        return differences
    }

    private enum ParagraphDiffOperation {
        case equal
        case delete(Int)
        case insert(Int)
    }

    private func paragraphDiffOperations(pureNormalized: [String], editedNormalized: [String]) -> [ParagraphDiffOperation] {
        let pureCount = pureNormalized.count
        let editedCount = editedNormalized.count
        var lengths = Array(repeating: Array(repeating: 0, count: editedCount + 1), count: pureCount + 1)

        if pureCount > 0 && editedCount > 0 {
            for pureIndex in stride(from: pureCount - 1, through: 0, by: -1) {
                for editedIndex in stride(from: editedCount - 1, through: 0, by: -1) {
                    if pureNormalized[pureIndex] == editedNormalized[editedIndex] {
                        lengths[pureIndex][editedIndex] = lengths[pureIndex + 1][editedIndex + 1] + 1
                    } else {
                        lengths[pureIndex][editedIndex] = max(lengths[pureIndex + 1][editedIndex], lengths[pureIndex][editedIndex + 1])
                    }
                }
            }
        }

        var operations: [ParagraphDiffOperation] = []
        var pureIndex = 0
        var editedIndex = 0
        while pureIndex < pureCount || editedIndex < editedCount {
            if pureIndex < pureCount,
               editedIndex < editedCount,
               pureNormalized[pureIndex] == editedNormalized[editedIndex] {
                operations.append(.equal)
                pureIndex += 1
                editedIndex += 1
            } else if editedIndex >= editedCount || (pureIndex < pureCount && lengths[pureIndex + 1][editedIndex] >= lengths[pureIndex][editedIndex + 1]) {
                operations.append(.delete(pureIndex))
                pureIndex += 1
            } else {
                operations.append(.insert(editedIndex))
                editedIndex += 1
            }
        }
        return operations
    }

    private func compareNormalizedText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appleVisionMarkdownPageFiles(in folderURL: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        let markdownFiles = files.filter { $0.pathExtension.lowercased() == "md" }
        let pageFiles = markdownFiles.filter { $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix("page") }
        return (pageFiles.isEmpty ? markdownFiles : pageFiles).sorted {
            pageNumber(from: $0) < pageNumber(from: $1)
        }
    }

    private func pageNumber(from url: URL) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let digits = stem.drop(while: { !$0.isNumber })
        return Int(digits) ?? Int.max
    }

    private func normalizedPageNumber(from url: URL, fallbackIndex: Int) -> Int {
        let page = pageNumber(from: url)
        return page == Int.max ? fallbackIndex + 1 : max(page, 1)
    }

    func titleBinding(for item: PDFFileItem) -> Binding<String> {
        Binding(
            get: {
                self.pdfTitles[item.id] ?? ""
            },
            set: { value in
                self.pdfTitles[item.id] = value
                if item.isManualSection {
                    self.saveBookSections()
                }
            }
        )
    }

    func epubReadyBinding(for item: PDFFileItem) -> Binding<Bool> {
        Binding(
            get: {
                self.epubReadySectionIDs.contains(item.id)
            },
            set: { isReady in
                if isReady {
                    self.epubReadySectionIDs.insert(item.id)
                } else {
                    self.epubReadySectionIDs.remove(item.id)
                }
                self.saveBookSections()
            }
        )
    }

    var selectedSectionCanBeMarkedReady: Bool {
        guard let item = pdfFiles.first(where: { $0.url.path == selectedPDFPath }) else {
            return false
        }
        return !epubReadySectionIDs.contains(item.id)
    }

    func markSelectedSectionReadyForEPUB() {
        guard let item = pdfFiles.first(where: { $0.url.path == selectedPDFPath }) else {
            return
        }
        epubReadySectionIDs.insert(item.id)
        saveBookSections()
    }

    func addManualSection(after item: PDFFileItem) {
        guard !selectedFolderPath.isEmpty else { return }
        let id = "manual-\(UUID().uuidString)"
        let url = manualSectionURL(id: id)
        let newItem = PDFFileItem(id: url.path, url: url)
        let insertIndex = (pdfFiles.firstIndex(of: item) ?? (pdfFiles.count - 1)) + 1

        pdfFiles.insert(newItem, at: min(insertIndex, pdfFiles.count))
        pdfTitles[newItem.id] = ""
        saveBookSections()
        save()
    }

    func addManualSectionAtEnd() {
        guard !selectedFolderPath.isEmpty else { return }
        let id = "manual-\(UUID().uuidString)"
        let url = manualSectionURL(id: id)
        let newItem = PDFFileItem(id: url.path, url: url)
        pdfFiles.append(newItem)
        pdfTitles[newItem.id] = ""
        saveBookSections()
        save()
    }

    func removeSectionItem(_ item: PDFFileItem) {
        guard item.isManualSection || isSectionPDFURL(item.url) else { return }
        let title = sectionRemovalTitle(for: item)

        let alert = NSAlert()
        alert.messageText = "Remove \(title)?"
        alert.informativeText = "Are you sure you want to remove \(title)?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            if item.isManualSection {
                let markdownFolderURL = manualMarkdownFolderURL(for: item.url)
                if FileManager.default.fileExists(atPath: markdownFolderURL.path) {
                    try FileManager.default.removeItem(at: markdownFolderURL)
                }
                if FileManager.default.fileExists(atPath: item.url.path) {
                    try FileManager.default.removeItem(at: item.url)
                }
            } else {
                if FileManager.default.fileExists(atPath: item.url.path) {
                    try FileManager.default.removeItem(at: item.url)
                }
                removeSplitPlanEntry(forFile: item.url.lastPathComponent)
            }
            pdfFiles.removeAll { $0 == item }
            pdfTitles.removeValue(forKey: item.id)
            epubReadySectionIDs.remove(item.id)
            saveBookSections()
            save()
        } catch {
            configStatus = "Could not remove section: \(error.localizedDescription)"
            showAlert(title: "Could Not Remove Section", message: error.localizedDescription)
        }
    }

    func clearOCRForSection(_ item: PDFFileItem) {
        pendingClearOCRItem = item
        isClearOCRConfirmationPresented = true
    }

    func confirmClearOCRAndProceed() {
        guard let item = pendingClearOCRItem else { return }
        do {
            try removeAppleVisionResources(for: item.url)
            epubReadySectionIDs.remove(item.id)
            saveBookSections()
            save()
            configStatus = "OCR cleared for \(sectionRemovalTitle(for: item))"
        } catch {
            configStatus = "Could not clear OCR: \(error.localizedDescription)"
            showAlert(title: "Could Not Clear OCR", message: error.localizedDescription)
        }
        isClearOCRConfirmationPresented = false
        pendingClearOCRItem = nil
    }

    func closeClearOCRConfirmation() {
        isClearOCRConfirmationPresented = false
        pendingClearOCRItem = nil
    }

    var canClearAllOCR: Bool {
        pdfFiles.contains { hasAppleVisionResources(for: $0.url) || (!$0.isManualSection && epubReadySectionIDs.contains($0.id)) }
    }

    func clearAllOCR() {
        isClearAllOCRConfirmationPresented = true
    }

    func confirmClearAllOCRAndProceed() {
        let items = pdfFiles
        var cleared = 0
        for item in items {
            do {
                try removeAppleVisionResources(for: item.url)
                epubReadySectionIDs.remove(item.id)
                cleared += 1
            } catch {
                configStatus = "Could not clear OCR for \(item.url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        saveBookSections()
        save()
        isClearAllOCRConfirmationPresented = false
        configStatus = "Cleared OCR for \(cleared) section(s)."
    }

    func closeClearAllOCRConfirmation() {
        isClearAllOCRConfirmationPresented = false
    }

    func sectionRemovalTitle(for item: PDFFileItem) -> String {
        let title = pdfTitles[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        return item.isManualSection ? "Manual Section" : item.url.lastPathComponent
    }

    func displayName(for item: PDFFileItem) -> String {
        if item.isManualSection {
            return "Section"
        }

        let stem = item.url.deletingPathExtension().lastPathComponent
        guard stem.range(of: #"^section-\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return item.fileName
        }

        let numberText = stem.replacingOccurrences(
            of: #"(?i)^section-"#,
            with: "",
            options: .regularExpression
        )
        return "Section \(numberText)"
    }

    func sectionListDisplayName(for item: PDFFileItem) -> String {
        let name = displayName(for: item)
        guard !item.isManualSection,
              let document = PDFDocument(url: item.url),
              document.pageCount > 0 else {
            return name
        }
        return "\(name) (\(document.pageCount) pages)"
    }

    private func updateSelectedPDFTitleFromOCRText(_ text: String) {
        guard !selectedPDFPath.isEmpty,
              selectedPDFTitle.isEmpty,
              let title = firstMarkdownHeading(in: text) else {
            return
        }
        pdfTitles[selectedPDFPath] = title
    }

    private func firstMarkdownHeading(in text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let regex = try? NSRegularExpression(pattern: #"^(#{1,6})(\s*)(.+?)\s*$"#),
                  let nsMatch = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                  nsMatch.numberOfRanges >= 4,
                  let titleRange = Range(nsMatch.range(at: 3), in: line) else {
                continue
            }
            let title = String(line[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }

    var ocrParagraphs: [String] {
        if let cached = _ocrParagraphsCache { return cached }
        let result = splitParagraphs(ocrText)
        _ocrParagraphsCache = result
        return result
    }

    var shouldUsePlainOCRTextEditor: Bool {
        ocrText.count > 80_000
    }

    var shouldFilterOCRImagesOnly: Bool {
        ocrSearchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Image") == .orderedSame
    }

    var shouldFilterOCRFootnotesOnly: Bool {
        ocrSearchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Footnote") == .orderedSame
    }

    var shouldFilterOCRBlockquotesOnly: Bool {
        ocrSearchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Blockquote") == .orderedSame
    }

    var hasOCRMarkdownImages: Bool {
        ocrParagraphs.contains { markdownImageURL(from: $0) != nil }
    }

    var hasOCRMarkdownFootnotes: Bool {
        footnoteParagraphIndexes().isEmpty == false
    }

    var hasOCRMarkdownBlockquotes: Bool {
        blockquoteParagraphIndexes().isEmpty == false
    }

    func focusFirstOCRMarkdownImage() {
        guard let index = ocrParagraphs.indices.first(where: { markdownImageURL(from: ocrParagraphs[$0]) != nil }) else {
            return
        }
        ocrSearchText = "Image"
        paragraphScrollTargetIndex = index
        paragraphScrollRequestID += 1
    }

    func focusFirstOCRMarkdownFootnote() {
        guard let index = footnoteParagraphIndexes().first else {
            return
        }
        ocrSearchText = "Footnote"
        paragraphScrollTargetIndex = index
        paragraphScrollRequestID += 1
    }

    func focusFirstOCRMarkdownBlockquote() {
        guard let index = blockquoteParagraphIndexes().first else {
            return
        }
        ocrSearchText = "Blockquote"
        paragraphScrollTargetIndex = index
        paragraphScrollRequestID += 1
    }

    var ocrSearchResultText: String {
        let query = ocrSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "" }

        if shouldFilterOCRImagesOnly {
            let count = ocrParagraphs.filter { markdownImageURL(from: $0) != nil }.count
            return count == 0 ? "Found 0 image paragraphs" : "Showing \(count) image paragraphs"
        }

        if shouldFilterOCRFootnotesOnly {
            let count = footnoteParagraphIndexes().count
            return count == 0 ? "Found 0 footnote paragraphs" : "Showing \(count) footnote paragraphs"
        }

        if shouldFilterOCRBlockquotesOnly {
            let count = blockquoteParagraphIndexes().count
            return count == 0 ? "Found 0 blockquote paragraphs" : "Showing \(count) blockquote paragraphs"
        }

        let matches = ocrParagraphSearchMatches(query: query).map { match -> (Int, Int) in
            (match.index + 1, match.count)
        }
        let total = matches.reduce(0) { $0 + $1.1 }

        guard total > 0 else {
            return "Found 0 times"
        }

        let paragraphList = matches.map { "\($0.0)" }.joined(separator: ", ")
        return "Found \(total) times in p#\(paragraphList)"
    }

    var visibleOCRParagraphIndexes: [Int] {
        let query = ocrSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Array(ocrParagraphs.indices)
        }
        if shouldFilterOCRImagesOnly {
            return ocrParagraphs.indices.filter { markdownImageURL(from: ocrParagraphs[$0]) != nil }
        }
        if shouldFilterOCRFootnotesOnly {
            return footnoteParagraphIndexes()
        }
        if shouldFilterOCRBlockquotesOnly {
            return blockquoteParagraphIndexes()
        }
        return ocrParagraphSearchMatches(query: query).map(\.index)
    }

    private func footnoteParagraphIndexes() -> [Int] {
        ocrParagraphs.indices.filter { index in
            let paragraph = ocrParagraphs[index]
            return markdownFootnoteLabel(from: paragraph) != nil || markdownFootnoteReferenceLabels(in: paragraph).isEmpty == false
        }
    }

    private func blockquoteParagraphIndexes() -> [Int] {
        ocrParagraphs.indices.filter { index in
            isMarkdownBlockquote(ocrParagraphs[index])
        }
    }

    private func ocrParagraphSearchMatches(query: String) -> [(index: Int, count: Int)] {
        ocrParagraphs.enumerated().compactMap { index, paragraph -> (index: Int, count: Int)? in
            guard markdownImageURL(from: paragraph) == nil else {
                return nil
            }
            let count = countOccurrences(of: query, in: paragraph)
            return count > 0 ? (index: index, count: count) : nil
        }
    }

    func paragraphBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                let paragraphs = self.ocrParagraphs
                guard paragraphs.indices.contains(index) else { return "" }
                return paragraphs[index]
            },
            set: { value in
                var paragraphs = self.ocrParagraphs
                guard paragraphs.indices.contains(index) else { return }
                paragraphs[index] = value
                self.ocrParagraphEditRevision += 1
                self.setOCRParagraphs(paragraphs)
            }
        )
    }

    func addParagraphBefore(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index, paragraphs.count))
        paragraphs.insert("", at: insertIndex)
        setOCRParagraphs(
            paragraphs,
            sourcePages: sourcePagesByInserting(at: insertIndex, page: sourcePageForParagraph(at: index)),
            ocrSourcePageFlags: ocrSourcePageFlagsByInsertingManualParagraph(at: insertIndex)
        )
        finishParagraphAction(focusIndex: insertIndex)
    }

    func addParagraphAfter(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index + 1, paragraphs.count))
        paragraphs.insert("", at: insertIndex)
        setOCRParagraphs(
            paragraphs,
            sourcePages: sourcePagesByInserting(at: insertIndex, page: sourcePageForParagraph(at: index)),
            ocrSourcePageFlags: ocrSourcePageFlagsByInsertingManualParagraph(at: insertIndex)
        )
        finishParagraphAction(focusIndex: insertIndex)
    }

    func addLineBreakBefore(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index, paragraphs.count))
        paragraphs.insert("<br/>", at: insertIndex)
        setOCRParagraphs(
            paragraphs,
            sourcePages: sourcePagesByInserting(at: insertIndex, page: sourcePageForParagraph(at: index)),
            ocrSourcePageFlags: ocrSourcePageFlagsByInsertingManualParagraph(at: insertIndex)
        )
        finishParagraphAction(focusIndex: insertIndex)
    }

    func addLineBreakAfter(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index + 1, paragraphs.count))
        paragraphs.insert("<br/>", at: insertIndex)
        setOCRParagraphs(
            paragraphs,
            sourcePages: sourcePagesByInserting(at: insertIndex, page: sourcePageForParagraph(at: index)),
            ocrSourcePageFlags: ocrSourcePageFlagsByInsertingManualParagraph(at: insertIndex)
        )
        finishParagraphAction(focusIndex: insertIndex)
    }

    func addPageBreakBefore(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index, paragraphs.count))
        paragraphs.insert("<!-- page-break-before -->", at: insertIndex)
        setOCRParagraphs(
            paragraphs,
            sourcePages: sourcePagesByInserting(at: insertIndex, page: sourcePageForParagraph(at: index)),
            ocrSourcePageFlags: ocrSourcePageFlagsByInsertingManualParagraph(at: insertIndex)
        )
        finishParagraphAction(focusIndex: insertIndex)
    }

    func addPageBreakAfter(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index + 1, paragraphs.count))
        paragraphs.insert("<!-- page-break-after -->", at: insertIndex)
        setOCRParagraphs(
            paragraphs,
            sourcePages: sourcePagesByInserting(at: insertIndex, page: sourcePageForParagraph(at: index)),
            ocrSourcePageFlags: ocrSourcePageFlagsByInsertingManualParagraph(at: insertIndex)
        )
        finishParagraphAction(focusIndex: insertIndex)
    }

    func mergeParagraphBefore(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard index > 0, paragraphs.indices.contains(index) else { return }
        var sourcePages = currentOCRParagraphSourcePages(for: paragraphs.count)
        var sourcePageFlags = currentOCRSourcePageFlags(for: paragraphs.count)
        if sourcePageFlags.indices.contains(index - 1), sourcePageFlags.indices.contains(index) {
            if !sourcePageFlags[index - 1], sourcePageFlags[index], sourcePages.indices.contains(index) {
                sourcePages[index - 1] = sourcePages[index]
            }
            sourcePageFlags[index - 1] = sourcePageFlags[index - 1] || sourcePageFlags[index]
        }
        paragraphs[index - 1] = mergeParagraphText(paragraphs[index - 1], paragraphs[index])
        paragraphs.remove(at: index)
        if sourcePages.indices.contains(index) {
            sourcePages.remove(at: index)
        }
        if sourcePageFlags.indices.contains(index) {
            sourcePageFlags.remove(at: index)
        }
        setOCRParagraphs(paragraphs, sourcePages: sourcePages, ocrSourcePageFlags: sourcePageFlags)
        finishParagraphAction(focusIndex: index - 1)
    }

    func mergeParagraphAfter(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index), index + 1 < paragraphs.count else { return }
        var sourcePages = currentOCRParagraphSourcePages(for: paragraphs.count)
        var sourcePageFlags = currentOCRSourcePageFlags(for: paragraphs.count)
        if sourcePageFlags.indices.contains(index), sourcePageFlags.indices.contains(index + 1) {
            sourcePageFlags[index] = sourcePageFlags[index] || sourcePageFlags[index + 1]
        }
        paragraphs[index] = mergeParagraphText(paragraphs[index], paragraphs[index + 1])
        paragraphs.remove(at: index + 1)
        if sourcePages.indices.contains(index + 1) {
            sourcePages.remove(at: index + 1)
        }
        if sourcePageFlags.indices.contains(index + 1) {
            sourcePageFlags.remove(at: index + 1)
        }
        setOCRParagraphs(paragraphs, sourcePages: sourcePages, ocrSourcePageFlags: sourcePageFlags)
        finishParagraphAction(focusIndex: index)
    }

    func removeParagraph(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index) else { return }
        var sourcePages = currentOCRParagraphSourcePages(for: paragraphs.count)
        var sourcePageFlags = currentOCRSourcePageFlags(for: paragraphs.count)
        paragraphs.remove(at: index)
        if sourcePages.indices.contains(index) {
            sourcePages.remove(at: index)
        }
        if sourcePageFlags.indices.contains(index) {
            sourcePageFlags.remove(at: index)
        }
        setOCRParagraphs(paragraphs, sourcePages: sourcePages, ocrSourcePageFlags: sourcePageFlags)
        finishParagraphAction(focusIndex: min(index, max(0, paragraphs.count - 1)))
    }

    func imageParagraphHasDescription(at index: Int) -> Bool {
        let paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index),
              markdownImageURL(from: paragraphs[index]) != nil else {
            return false
        }
        return markdownImageDescription(from: paragraphs[index]).isEmpty == false
    }

    func addImageDescription(at index: Int) {
        var paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index),
              markdownImageURL(from: paragraphs[index]) != nil,
              markdownImageDescription(from: paragraphs[index]).isEmpty else {
            return
        }
        let trimmed = paragraphs[index].trimmingTrailingCharacters(in: .whitespacesAndNewlines)
        paragraphs[index] = "\(trimmed)\nCaption:\n  "
        setOCRParagraphs(paragraphs)
        finishParagraphAction(focusIndex: index)
    }

    func addUserImage(before index: Int) {
        addUserImage(near: index, insertBefore: true)
    }

    func addUserImage(after index: Int) {
        addUserImage(near: index, insertBefore: false)
    }

    private func addUserImage(near index: Int, insertBefore: Bool) {
        guard let markdownFolderURL = localAppleVisionOutputFolderURL else {
            ocrStatus = "No Markdown folder selected."
            return
        }

        let panel = NSOpenPanel()
        panel.title = insertBefore ? "Add Image Before" : "Add Image After"
        panel.prompt = "Add Image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK, let sourceURL = panel.url else {
            return
        }

        let caption = promptForOptionalImageCaption()

        do {
            let imagesFolderURL = markdownFolderURL.appendingPathComponent("Images", isDirectory: true)
            try FileManager.default.createDirectory(at: imagesFolderURL, withIntermediateDirectories: true)

            let imageExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
            let baseName = sanitizedImageFileStem(from: sourceURL.deletingPathExtension().lastPathComponent)
            let destinationURL = uniqueImageURL(in: imagesFolderURL, baseName: baseName, fileExtension: imageExtension)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let imageMarkdown = userImageMarkdown(
                fileName: destinationURL.lastPathComponent,
                altText: sourceURL.deletingPathExtension().lastPathComponent,
                caption: caption
            )

            var paragraphs = ocrParagraphs
            let insertIndex = insertBefore ? max(0, min(index, paragraphs.count)) : max(0, min(index + 1, paragraphs.count))
            paragraphs.insert(imageMarkdown, at: insertIndex)
            setOCRParagraphs(
                paragraphs,
                sourcePages: sourcePagesByInserting(at: insertIndex, page: sourcePageForParagraph(at: index)),
                ocrSourcePageFlags: ocrSourcePageFlagsByInsertingManualParagraph(at: insertIndex)
            )
            finishParagraphAction(focusIndex: insertIndex)
            ocrStatus = "Added image \(destinationURL.lastPathComponent). Click Save to update Markdown."
            logOutput = "Added image:\n\(destinationURL.path)"
        } catch {
            ocrStatus = "Could not add image."
            logOutput = error.localizedDescription
        }
    }

    private func promptForOptionalImageCaption() -> String {
        let alert = NSAlert()
        alert.messageText = "Image Caption"
        alert.informativeText = "Optional. Leave blank to insert the image without a caption."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Skip Caption")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        textField.placeholderString = "Caption"
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return ""
        }
        return textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func userImageMarkdown(fileName: String, altText: String, caption: String) -> String {
        let cleanAltText = altText.trimmingCharacters(in: .whitespacesAndNewlines)
        let alt = cleanAltText.isEmpty ? "User image" : cleanAltText
        let imageLine = "![\(alt)](Images/\(fileName))"
        guard !caption.isEmpty else {
            return imageLine
        }
        return "\(imageLine)\nCaption:\n  \(caption)"
    }

    private func sanitizedImageFileStem(from value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)
        let cleaned = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "user-image" : cleaned
    }

    private func uniqueImageURL(in folderURL: URL, baseName: String, fileExtension: String) -> URL {
        var candidate = folderURL.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folderURL.appendingPathComponent("\(baseName)-\(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }

    func paragraphDisplayTitle(at index: Int) -> String {
        let paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index) else {
            return "Paragraph \(index + 1)"
        }
        if let label = markdownFootnoteLabel(from: paragraphs[index]) {
            return "Footnote#\(label)"
        }
        if isMarkdownBlockquote(paragraphs[index]) {
            return "Blockquote#\(index + 1)"
        }
        if ocrSourcePageIsKnown(for: index) {
            return "Paragraph \(index + 1) (Page \(sourcePageForParagraph(at: index)))"
        }
        return "Paragraph \(index + 1)"
    }

    func isFootnoteParagraph(at index: Int) -> Bool {
        let paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index) else { return false }
        return markdownFootnoteLabel(from: paragraphs[index]) != nil
    }

    func isBlockquoteParagraph(at index: Int) -> Bool {
        let paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index) else { return false }
        return isMarkdownBlockquote(paragraphs[index])
    }

    private func isMarkdownBlockquote(_ paragraph: String) -> Bool {
        let lines = paragraph.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { $0.hasPrefix(">") }
    }

    private func markdownFootnoteLabel(from paragraph: String) -> String? {
        guard let firstLine = paragraph.components(separatedBy: .newlines).first else { return nil }
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[^"),
              let closeIndex = trimmed.firstIndex(of: "]") else {
            return nil
        }
        let afterClose = trimmed[trimmed.index(after: closeIndex)...]
        guard afterClose.hasPrefix(":") else { return nil }
        let labelStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let label = String(trimmed[labelStart..<closeIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    private func markdownImageDescription(from paragraph: String) -> String {
        var foundDescription = false
        return paragraph.components(separatedBy: .newlines).dropFirst().compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = line.lowercased()
            if lowercased.hasPrefix("caption:") {
                foundDescription = true
                return String(line.dropFirst("caption:".count)).trimmingCharacters(in: .whitespaces)
            }
            if lowercased.hasPrefix("description:") {
                foundDescription = true
                return String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
            }
            if foundDescription && (rawLine.hasPrefix("  ") || rawLine.hasPrefix("    ") || rawLine.hasPrefix("\t")) {
                return line
            }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func markdownFootnoteReferenceLabels(in paragraph: String) -> [String] {
        let pattern = #"\[\^([A-Za-z0-9_-]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(paragraph.startIndex..<paragraph.endIndex, in: paragraph)
        return regex.matches(in: paragraph, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let labelRange = Range(match.range(at: 1), in: paragraph) else {
                return nil
            }
            return String(paragraph[labelRange])
        }
    }

    func moveParagraphUp(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard index > 0, paragraphs.indices.contains(index) else { return }
        var sourcePages = currentOCRParagraphSourcePages(for: paragraphs.count)
        var sourcePageFlags = currentOCRSourcePageFlags(for: paragraphs.count)
        paragraphs.swapAt(index, index - 1)
        sourcePages.swapAt(index, index - 1)
        sourcePageFlags.swapAt(index, index - 1)
        setOCRParagraphs(paragraphs, sourcePages: sourcePages, ocrSourcePageFlags: sourcePageFlags)
        finishParagraphAction(focusIndex: index - 1)
    }

    func moveParagraphDown(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index), index + 1 < paragraphs.count else { return }
        var sourcePages = currentOCRParagraphSourcePages(for: paragraphs.count)
        var sourcePageFlags = currentOCRSourcePageFlags(for: paragraphs.count)
        paragraphs.swapAt(index, index + 1)
        sourcePages.swapAt(index, index + 1)
        sourcePageFlags.swapAt(index, index + 1)
        setOCRParagraphs(paragraphs, sourcePages: sourcePages, ocrSourcePageFlags: sourcePageFlags)
        finishParagraphAction(focusIndex: index + 1)
    }

    private func finishParagraphAction(focusIndex: Int) {
        let paragraphs = ocrParagraphs
        let clampedIndex = max(0, min(focusIndex, max(0, paragraphs.count - 1)))
        ocrSearchText = ""
        paragraphScrollTargetIndex = clampedIndex
        paragraphScrollRequestID += 1
    }

    func replaceAllOCRSearchMatches(with replacement: String) -> Int {
        let query = ocrSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }

        let originalText = ocrText
        let originalSourcePages = currentOCRParagraphSourcePages(for: ocrParagraphs.count)
        let originalSourcePageFlags = currentOCRSourcePageFlags(for: ocrParagraphs.count)
        var updatedText = ""
        var searchStart = originalText.startIndex
        var replacementCount = 0

        while let range = originalText.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchStart..<originalText.endIndex
        ) {
            updatedText += originalText[searchStart..<range.lowerBound]
            updatedText += replacement
            replacementCount += 1
            searchStart = range.upperBound
        }

        guard replacementCount > 0 else { return 0 }
        updatedText += originalText[searchStart..<originalText.endIndex]
        let updatedParagraphCount = splitParagraphs(updatedText).count
        ocrParagraphSourcePages = normalizedSourcePages(originalSourcePages, paragraphCount: updatedParagraphCount)
        ocrParagraphHasOCRSourcePage = normalizedOCRSourcePageFlags(originalSourcePageFlags, paragraphCount: updatedParagraphCount)
        ocrText = updatedText
        ocrStatus = "Replaced \(replacementCount) occurrences in editor. Click Save to update Markdown."
        return replacementCount
    }

    private func splitParagraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var currentLines: [String] = []
        var blankLineCount = 0

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !currentLines.isEmpty {
                    paragraphs.append(currentLines.joined(separator: "\n"))
                    currentLines = []
                    blankLineCount = 1
                } else {
                    blankLineCount += 1
                }
            } else {
                if blankLineCount > 0 {
                    paragraphs.append(contentsOf: Array(repeating: "", count: blankLineCount / 2))
                    blankLineCount = 0
                }
                currentLines.append(line)
            }
        }

        if !currentLines.isEmpty {
            paragraphs.append(currentLines.joined(separator: "\n"))
        } else if blankLineCount > 0 {
            paragraphs.append(contentsOf: Array(repeating: "", count: blankLineCount / 2))
        }

        if paragraphs.isEmpty && !text.isEmpty {
            return [text]
        }
        return paragraphs
    }

    func focusOCRParagraphSourcePage(_ index: Int) {
        previewOCRParagraphSourcePage(index)
    }

    func previewOCRParagraphSourcePage(_ index: Int) {
        let paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index) else { return }
        let page = sourcePageForParagraph(at: index)
        ocrPDFPreviewPageRequestIndex = max(page - 1, 0)
        ocrPDFPreviewPageRequestID += 1
    }

    func ocrPDFPreviewZoomPercent(for path: String) -> Double {
        let stored = ocrPDFPreviewZoomPercents[path] ?? ocrPDFPreviewLastZoomPercent
        return min(max(stored, 50), 220)
    }

    func setOCRPDFPreviewZoomPercent(_ value: Double, for path: String) {
        let clampedValue = min(max(value, 50), 220)
        ocrPDFPreviewLastZoomPercent = clampedValue
        if !path.isEmpty {
            ocrPDFPreviewZoomPercents[path] = clampedValue
        }
        save()
        defaults.synchronize()
    }

    private func setOCRParagraphs(_ paragraphs: [String], sourcePages: [Int]? = nil, ocrSourcePageFlags: [Bool]? = nil) {
        let pages = sourcePages ?? currentOCRParagraphSourcePages(for: ocrParagraphs.count)
        let flags = ocrSourcePageFlags ?? currentOCRSourcePageFlags(for: ocrParagraphs.count)
        ocrParagraphSourcePages = normalizedSourcePages(pages, paragraphCount: paragraphs.count)
        ocrParagraphHasOCRSourcePage = normalizedOCRSourcePageFlags(flags, paragraphCount: paragraphs.count)
        // Trim trailing newlines before joining so that a Return keypress at the
        // end of a paragraph (which appends "\n") does not produce three consecutive
        // newlines ("\n" + "\n\n" separator) that splitParagraphs would interpret as
        // an extra empty paragraph.
        ocrText = paragraphs.map { $0.trimmingCharacters(in: .newlines) }.joined(separator: "\n\n")
    }

    private func sourcePageForParagraph(at index: Int) -> Int {
        let pages = currentOCRParagraphSourcePages(for: ocrParagraphs.count)
        guard pages.indices.contains(index) else { return pages.last ?? 1 }
        return pages[index]
    }

    func ocrSourcePageIsKnown(for index: Int) -> Bool {
        let flags = currentOCRSourcePageFlags(for: ocrParagraphs.count)
        guard flags.indices.contains(index) else { return false }
        return flags[index]
    }

    private func sourcePagesByInserting(at insertIndex: Int, page: Int) -> [Int] {
        var pages = currentOCRParagraphSourcePages(for: ocrParagraphs.count)
        let clampedIndex = max(0, min(insertIndex, pages.count))
        pages.insert(max(page, 1), at: clampedIndex)
        return pages
    }

    private func ocrSourcePageFlagsByInsertingManualParagraph(at insertIndex: Int) -> [Bool] {
        var flags = currentOCRSourcePageFlags(for: ocrParagraphs.count)
        let clampedIndex = max(0, min(insertIndex, flags.count))
        flags.insert(false, at: clampedIndex)
        return flags
    }

    private func currentOCRParagraphSourcePages(for count: Int) -> [Int] {
        normalizedSourcePages(ocrParagraphSourcePages, paragraphCount: count)
    }

    private func currentOCRSourcePageFlags(for count: Int) -> [Bool] {
        normalizedOCRSourcePageFlags(ocrParagraphHasOCRSourcePage, paragraphCount: count)
    }

    private func normalizedSourcePages(_ pages: [Int]?, paragraphCount: Int) -> [Int] {
        guard paragraphCount > 0 else { return [] }
        let cleanPages = (pages ?? []).map { max($0, 1) }
        var result: [Int] = []
        for index in 0..<paragraphCount {
            if cleanPages.indices.contains(index) {
                result.append(cleanPages[index])
            } else {
                result.append(result.last ?? cleanPages.last ?? 1)
            }
        }
        return result
    }

    private func normalizedOCRSourcePageFlags(_ flags: [Bool]?, paragraphCount: Int) -> [Bool] {
        guard paragraphCount > 0 else { return [] }
        let cleanFlags = flags ?? []
        var result: [Bool] = []
        for index in 0..<paragraphCount {
            result.append(cleanFlags.indices.contains(index) ? cleanFlags[index] : false)
        }
        return result
    }

    func markdownImageURL(from paragraph: String) -> URL? {
        guard let firstLine = paragraph.components(separatedBy: .newlines).first else { return nil }
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!["),
              let openParen = trimmed.firstIndex(of: "("),
              let closeParen = trimmed.lastIndex(of: ")"),
              openParen < closeParen else {
            return nil
        }

        let pathText = String(trimmed[trimmed.index(after: openParen)..<closeParen])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pathText.isEmpty,
              !pathText.lowercased().hasPrefix("http://"),
              !pathText.lowercased().hasPrefix("https://") else {
            return nil
        }

        if pathText.hasPrefix("/") {
            return URL(fileURLWithPath: pathText)
        }

        guard let folderURL = localAppleVisionOutputFolderURL else {
            return nil
        }
        return folderURL.appendingPathComponent(pathText)
    }

    private func countOccurrences(of query: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex

        while let range = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchRange
        ) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }

        return count
    }

    private func mergeParagraphText(_ first: String, _ second: String) -> String {
        let previous = first.trimmingTrailingCharacters(in: .whitespacesAndNewlines)
        let current = second.trimmingLeadingCharacters(in: .whitespacesAndNewlines)

        if previous.isEmpty { return current }
        if current.isEmpty { return previous }
        return previous + current
    }

    func sendSelectedPDFToOCREngine() {
        guard !selectedItemIsManualSection else {
            ocrStatus = "Manual section has no PDF to OCR."
            logOutput = "Add text in the editor, then save Markdown."
            return
        }

        guard !selectedPDFPath.isEmpty else {
            ocrStatus = "No PDF selected."
            return
        }

        sendSelectedPDFToAppleVision()
    }

    func processOCRAllSections() {
        let sectionItems = pdfFiles.filter {
            !($0.isManualSection)
                && !epubReadySectionIDs.contains($0.id)
                && FileManager.default.fileExists(atPath: $0.url.path)
        }
        guard !sectionItems.isEmpty else {
            ocrStatus = "No section PDF files to OCR."
            logOutput = "Manual sections and Ready for EPUB checked sections are skipped."
            return
        }
        guard !isOCRRunning else { return }

        isOCRRunning = true
        isOCRCancelling = false
        ocrProgressPercent = 0
        ocrStatus = "Processing OCR for \(sectionItems.count) sections..."
        logOutput = ""
        bulkOCRProgressTitle = "Process OCR All"
        bulkOCRProgressMessage = "Preparing OCR..."
        bulkOCRCurrentFile = ""
        bulkOCRCompletedCount = 0
        bulkOCRTotalCount = sectionItems.count
        isBulkOCRFinished = false
        isBulkOCRProgressPresented = true

        let filterTopLinesValue = filterTopLines
        let filterBottomLinesValue = filterBottomLines
        let filteredTextValue = filteredText
        DispatchQueue.global(qos: .userInitiated).async {
            var completed = 0
            var logs: [String] = []

            do {
                for (index, item) in sectionItems.enumerated() {
                    if self.isOCRCancelling {
                        throw NSError(domain: "NewOCR", code: 3, userInfo: [NSLocalizedDescriptionKey: "AppleVision OCR cancelled."])
                    }

                    let pdfPath = item.url.path
                    try self.removeAppleVisionResources(for: item.url)

                    DispatchQueue.main.async {
                        let percent = (Double(index) / Double(sectionItems.count)) * 100
                        self.ocrProgressPercent = percent
                        self.ocrStatus = "Processing OCR \(index + 1)/\(sectionItems.count): \(item.url.lastPathComponent)"
                        self.bulkOCRProgressMessage = "Processing \(index + 1) of \(sectionItems.count)"
                        self.bulkOCRCurrentFile = item.url.lastPathComponent
                        self.bulkOCRCompletedCount = index
                    }

                    let result = try self.runAppleVisionOCR(
                        pdfPath: pdfPath,
                        filterTopLines: filterTopLinesValue,
                        filterBottomLines: filterBottomLinesValue,
                        filteredText: filteredTextValue,
                        documentTitle: ""
                    )
                    completed += 1
                    logs.append("\(item.url.lastPathComponent): \(result.pages) pages, \(result.characters) characters")
                }

                DispatchQueue.main.async {
                    self.isOCRRunning = false
                    self.isOCRCancelling = false
                    self.ocrProgressPercent = 100
                    self.ocrStatus = "Processed OCR for \(completed) sections."
                    self.logOutput = logs.joined(separator: "\n")
                    self.bulkOCRProgressTitle = "Finished Successfully"
                    self.bulkOCRProgressMessage = "Finished OCR for \(completed) sections."
                    self.bulkOCRCurrentFile = ""
                    self.bulkOCRCompletedCount = completed
                    self.isBulkOCRFinished = true
                    self.loadPDFFiles()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isOCRRunning = false
                    self.isOCRCancelling = false
                    self.ocrProgressPercent = nil
                    self.ocrStatus = "Bulk OCR failed."
                    self.logOutput = error.localizedDescription
                    self.bulkOCRProgressTitle = "OCR Failed"
                    self.bulkOCRProgressMessage = error.localizedDescription
                    self.bulkOCRCurrentFile = ""
                    self.isBulkOCRFinished = true
                    self.loadPDFFiles()
                }
            }
        }
    }

    private func sendSelectedPDFToAppleVision() {
        isOCRRunning = true
        isOCRCancelling = false
        ocrProgressPercent = 0
        ocrStatus = "Running AppleVision OCR..."
        logOutput = ""

        let pdfPath = selectedPDFPath
        let filterTopLinesValue = filterTopLines
        let filterBottomLinesValue = filterBottomLines
        let filteredTextValue = filteredText

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.runAppleVisionOCR(
                    pdfPath: pdfPath,
                    filterTopLines: filterTopLinesValue,
                    filterBottomLines: filterBottomLinesValue,
                    filteredText: filteredTextValue,
                    documentTitle: ""
                )

                DispatchQueue.main.async {
                    self.isOCRRunning = false
                    self.isOCRCancelling = false
                    self.ocrProgressPercent = 100
                    self.ocrStatus = "AppleVision OCR completed and Markdown files saved."
                    self.logOutput = """
                    AppleVision used Apple's Vision framework only.

                    Markdown folder:
                    \(result.mdFolder)

                    Pages: \(result.pages)
                    Characters: \(result.characters)
                    Header/footer lines removed: \(result.removedLines)
                    """
                    if let text = self.loadAppleVisionMarkdownText() {
                        self.ocrText = text
                        self.updateSelectedPDFTitleFromOCRText(text)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isOCRRunning = false
                    self.isOCRCancelling = false
                    self.ocrProgressPercent = nil
                    self.ocrStatus = "AppleVision OCR failed."
                    self.logOutput = error.localizedDescription
                }
            }
        }
    }

    private func runAppleVisionOCR(
        pdfPath: String,
        filterTopLines: String,
        filterBottomLines: String,
        filteredText: String,
        documentTitle: String
    ) throws -> (mdFolder: String, pages: Int, characters: Int, removedLines: Int) {
        let pdfURL = URL(fileURLWithPath: pdfPath)
        guard let document = PDFDocument(url: pdfURL) else {
            throw NSError(domain: "NewOCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open PDF: \(pdfPath)"])
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw NSError(domain: "NewOCR", code: 2, userInfo: [NSLocalizedDescriptionKey: "PDF has no pages: \(pdfPath)"])
        }

        let mdFolder = appleVisionOutputFolderURL(for: pdfURL)
            .appendingPathComponent(pdfURL.deletingPathExtension().lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: mdFolder, withIntermediateDirectories: true)

        let topCount = parseLineCount(filterTopLines, defaultValue: 1)
        let bottomCount = parseLineCount(filterBottomLines, defaultValue: 1)
        let cleanDocumentTitle = documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleMatchTopLineCount = cleanDocumentTitle.isEmpty ? 0 : ocrTitleMatchTopLineCount
        let filterValues = parseFilterValues(filteredText)
        let layoutRules = loadOCRLayoutAreaRules(for: pdfURL)

        DispatchQueue.main.async { self.ocrStatus = "Calibrating paragraph indent…" }
        let calibratedIndentFraction = (try? resolvedIndentFraction(for: pdfURL, document: document)) ?? 0.04

        var rawPages: [[OCRLine]] = []
        var pageImages: [CGImage] = []
        var allPageLines: [OCRLine] = []
        var allPageImageRegions: [OCRImageRegion] = []

        for pageIndex in 0..<pageCount {
            if isOCRCancelling {
                throw NSError(domain: "NewOCR", code: 3, userInfo: [NSLocalizedDescriptionKey: "AppleVision OCR cancelled."])
            }

            guard let page = document.page(at: pageIndex) else {
                continue
            }

            let image = try renderPDFPageToCGImage(page, scale: ocrRenderScale)
            let rawLines = try recognizeTextWithAppleVision(in: image)
            rawPages.append(rawLines)
            pageImages.append(image)

            DispatchQueue.main.async {
                let percent = (Double(pageIndex + 1) / Double(pageCount)) * 50
                self.ocrProgressPercent = percent
                self.ocrStatus = "AppleVision recognized page \(pageIndex + 1): \(pageIndex + 1)/\(pageCount)"
            }
        }

        try updateAppleVisionLineCache(pdfURL: pdfURL, rawPages: rawPages)
        let repeatedHeaderFooterKeys = repeatedHeaderFooterKeys(for: pdfURL)
        var removedLines = 0
        var pageMarkdownItems: [OCRPageMarkdown] = []

        for (pageIndex, rawLines) in rawPages.enumerated() {
            let pageNumber = pageIndex + 1
            let pageLayoutRules = matchingLayoutAreaRules(layoutRules, pdfURL: pdfURL, pageNumber: pageNumber)
            let pageImage = pageImages.indices.contains(pageIndex) ? pageImages[pageIndex] : nil
            var imageRegions = try imageRegionsFromLayoutRules(
                layoutAreaRules(pageLayoutRules, type: "image"),
                in: pageImage,
                pageNumber: pageNumber,
                outputFolder: mdFolder
            )
            let imageDescRules = layoutAreaRules(pageLayoutRules, type: "image_desc")
            let filteredLines = removeTopBottomLines(
                rawLines,
                topCount: topCount,
                bottomCount: bottomCount,
                filterValues: filterValues,
                documentTitle: cleanDocumentTitle,
                titleMatchTopLineCount: pageIndex == 0 ? titleMatchTopLineCount : 0,
                repeatedHeaderFooterKeys: repeatedHeaderFooterKeys
            )
            let headingRules = layoutAreaRules(pageLayoutRules, type: "header")
                + layoutAreaRules(pageLayoutRules, type: "h2")
                + layoutAreaRules(pageLayoutRules, type: "header3")
            let filteredTextLines = filteredLines.filter { line in
                !layoutAreaRules(pageLayoutRules, type: "ignore").contains { rule in
                    lineOverlapsLayoutArea(line, rule.rect, threshold: 0.30)
                }
                && (headingRules.contains { lineOverlapsLayoutArea(line, $0.rect, threshold: 0.45) }
                    || !imageRegions.contains { imageRegion in
                        normalizedOverlapArea(line, imageRegion) >= 0.18
                    })
                && !imageDescRules.contains { rule in
                    lineOverlapsLayoutArea(line, rule.rect, threshold: 0.30)
                }
            }
            // Assign descriptions extracted from image_desc areas to their matching image regions.
            if !imageDescRules.isEmpty {
                let descriptions = imageDescriptionsFromLayoutRules(imageDescRules, ocrLines: filteredLines)
                for i in imageRegions.indices {
                    if let desc = descriptions[imageRegions[i].label] {
                        imageRegions[i].description = desc
                    }
                }
            }
            removedLines += rawLines.count - filteredTextLines.count
            let noSuperscriptLines = removeSuperscriptLines(filteredTextLines)
            removedLines += filteredTextLines.count - noSuperscriptLines.count

            // Apply underscore-artifact cleanup.
            var cleanedLines: [OCRLine] = []
            for line in noSuperscriptLines {
                let cleaned = cleanOCRLineText(line.text)
                if cleaned != line.text {
                    cleanedLines.append(OCRLine(
                        text: cleaned,
                        left: line.left, right: line.right,
                        bottom: line.bottom, top: line.top,
                        confidence: line.confidence
                    ))
                } else {
                    cleanedLines.append(line)
                }
            }
            let builtPageText = buildMarkdownPage(from: cleanedLines, imageRegions: imageRegions, layoutRules: pageLayoutRules, indentFraction: calibratedIndentFraction)
            let hasHeaderRule = !layoutAreaRules(pageLayoutRules, type: "header").isEmpty
            let pageText = (pageIndex == 0 && !hasHeaderRule)
                ? applyMarkdownTitle(cleanDocumentTitle, to: builtPageText, replaceExistingHeading: true)
                : builtPageText

            // Exclude footnote-area lines when computing page-boundary continuation flags.
            // Footnote lines sit at the bottom of the page and are narrower than body text,
            // so without this filter the right-edge check on the "last" line incorrectly
            // prevents body text from being merged across the page boundary.
            let pageFootnoteRules = layoutAreaRules(pageLayoutRules, type: "footnote")
            let bodyLines = pageFootnoteRules.isEmpty ? cleanedLines : cleanedLines.filter { line in
                !pageFootnoteRules.contains { lineOverlapsLayoutArea(line, $0.rect, threshold: 0.45) }
            }
            pageMarkdownItems.append(
                OCRPageMarkdown(
                    pageNumber: pageNumber,
                    text: pageText,
                    firstTextLineContinuesPreviousPage: firstTextLineContinuesPreviousPage(bodyLines, indentFraction: calibratedIndentFraction),
                    lastTextLineCanContinueNextPage: lastTextLineCanContinueNextPage(bodyLines)
                )
            )
            allPageLines.append(contentsOf: cleanedLines)
            allPageImageRegions.append(contentsOf: imageRegions)

            DispatchQueue.main.async {
                let percent = 50 + (Double(pageNumber) / Double(pageCount)) * 50
                self.ocrProgressPercent = percent
                self.ocrStatus = "AppleVision preparing page \(pageNumber): \(pageNumber)/\(pageCount) (\(Int(percent))%)"
            }
        }

        mergePageBoundaryContinuations(in: &pageMarkdownItems)
        try savePureOCRSnapshot(pageMarkdownItems, in: mdFolder)

        for pageMarkdown in pageMarkdownItems {
            let pageURL = mdFolder.appendingPathComponent("page\(pageMarkdown.pageNumber).md")
            try pageMarkdown.text.write(to: pageURL, atomically: true, encoding: .utf8)
        }

        let fullText = applyMarkdownTitle(cleanDocumentTitle, to: buildMarkdownPage(from: allPageLines, imageRegions: allPageImageRegions, indentFraction: calibratedIndentFraction), replaceExistingHeading: true)

        return (mdFolder.path, pageCount, fullText.count, removedLines)
    }

    private func renderPDFPageToCGImage(_ page: PDFPage, scale: CGFloat = 2.0) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "NewOCR", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF render context."])
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw NSError(domain: "NewOCR", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not render PDF page image."])
        }
        return image
    }

    private func recognizeTextWithAppleVision(in image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["th-TH", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? []).sorted { first, second in
            let yDifference = abs(first.boundingBox.minY - second.boundingBox.minY)
            if yDifference > 0.01 {
                return first.boundingBox.minY > second.boundingBox.minY
            }
            return first.boundingBox.minX < second.boundingBox.minX
        }

        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRLine(
                text: text,
                left: observation.boundingBox.minX,
                right: observation.boundingBox.maxX,
                bottom: observation.boundingBox.minY,
                top: observation.boundingBox.maxY,
                confidence: candidate.confidence
            )
        }
    }

    // Unicode superscript digits and common superscript letters that Vision embeds
    // inside a text observation instead of emitting a separate small line.
    // These are unambiguous — they never appear as normal body characters.
    private static let superscriptCharacters: Set<Character> = [
        "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹",  // superscript digits
        "ⁱ", "ⁿ",                                                // common superscript letters
        "ᵃ", "ᵇ", "ᶜ", "ᵈ", "ᵉ", "ᶠ", "ᵍ", "ʰ", "ʲ", "ᵏ",
        "ˡ", "ᵐ", "ᵒ", "ᵖ", "ʳ", "ˢ", "ᵗ", "ᵘ", "ᵛ", "ʷ", "ˣ", "ʸ", "ᶻ",
    ]

    private func cleanOCRLineText(_ text: String) -> String {
        // 1. Strip inline Unicode superscript characters (digits ⁰–⁹ and superscript
        //    letters). These are unambiguous — Vision embeds them when a footnote
        //    reference number is part of the same text observation as body text.
        let noSuperChars = text.filter { !Self.superscriptCharacters.contains($0) }

        // 2. Remove underscore OCR artifacts produced when Vision reads italic-styled text.
        // Rule: drop `_` that sits at a word boundary (preceded/followed by space or
        // at the very start/end of the line). Underscores inside words (e.g.
        // variable_name) are preserved.
        let chars = Array(noSuperChars)
        var result: [Character] = []
        for i in chars.indices {
            let ch = chars[i]
            guard ch == "_" else { result.append(ch); continue }
            let prev = i > 0 ? chars[i - 1] : nil
            let next = i < chars.count - 1 ? chars[i + 1] : nil
            let atWordStart = prev == nil || prev == " "
            let atWordEnd   = next == nil || next == " "
            if !atWordStart && !atWordEnd { result.append(ch) }
            // else: boundary underscore — skip (OCR italic artifact)
        }
        return String(result)
    }

    // Remove OCR lines that are geometrically superscript: significantly shorter than body
    // text, contain only 1–4 alphanumeric or footnote-symbol characters, and are vertically
    // elevated so their lower edge sits at or above the midpoint of a neighbouring body line.
    // This runs before layout rules are applied so footnote reference numbers in body text
    // do not interfere with header/blockquote/footnote rule matching.
    // Runs Apple Vision OCR on a rendered page image and returns all superscript
    // candidates found in the body text area (above the footnote zone).
    // Results use the same Y-up coordinate system as OCRLayoutAreaRect.
    private func removeSuperscriptLines(_ lines: [OCRLine]) -> [OCRLine] {
        guard lines.count > 1 else { return lines }

        // Derive body-text height from the page median.
        let sortedHeights = lines.map(\.height).sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]
        guard medianHeight > 0.003 else { return lines }

        // Lines shorter than 55 % of the median are superscript candidates.
        let heightThreshold = medianHeight * 0.55

        // Allowed character set: digits, ASCII letters, and common footnote symbols.
        let superscriptPattern = try? NSRegularExpression(pattern: "^[0-9a-zA-Z*†‡§¶°+\\-]{1,4}$")

        return lines.filter { line in
            // Keep any line at or above normal body height.
            guard line.height < heightThreshold else { return true }

            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }

            // Keep lines that don't match the superscript character pattern.
            guard let regex = superscriptPattern,
                  regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
            else { return true }

            // Geometric check: the tiny line's lower edge must sit at or above the
            // vertical midpoint of a body-text neighbour that overlaps horizontally.
            // Coordinates are normalised with Y increasing upward (top > bottom).
            let isElevated = lines.contains { neighbor in
                guard neighbor.height >= heightThreshold else { return false }
                let hOverlap = min(line.right, neighbor.right) - max(line.left, neighbor.left)
                guard hOverlap > 0 else { return false }
                let neighborMid = (neighbor.top + neighbor.bottom) / 2
                return line.bottom >= neighborMid
            }

            // Remove only if confirmed elevated — keep everything else.
            return !isElevated
        }
    }

    private func imageRegionsFromLayoutRules(
        _ imageRules: [OCRLayoutAreaRule],
        in image: CGImage?,
        pageNumber: Int,
        outputFolder: URL
    ) throws -> [OCRImageRegion] {
        guard !imageRules.isEmpty,
              let image,
              image.width > 0,
              image.height > 0 else {
            return []
        }

        let imagesFolder = outputFolder.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

        return try imageRules
            .sorted {
                if abs($0.rect.top - $1.rect.top) > 0.01 {
                    return $0.rect.top > $1.rect.top
                }
                return $0.rect.left < $1.rect.left
            }
            .enumerated()
            .compactMap { index, rule in
                let cropRect = pixelCropRect(for: rule.rect, imageWidth: image.width, imageHeight: image.height)
                guard cropRect.width > 1, cropRect.height > 1,
                      let croppedImage = image.cropping(to: cropRect) else {
                    return nil
                }

                let rawLabel = rule.markers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let label = rawLabel.isEmpty ? "Image \(index + 1)" : rawLabel
                let safeName = label
                    .components(separatedBy: CharacterSet(charactersIn: "/:*?\"<>|\\"))
                    .joined(separator: "-")
                let fileName = "page\(pageNumber)-\(safeName).png"
                let imageURL = imagesFolder.appendingPathComponent(fileName)
                try writePNG(croppedImage, to: imageURL)

                let left = cropRect.minX / CGFloat(image.width)
                let right = cropRect.maxX / CGFloat(image.width)
                let top = 1 - (cropRect.minY / CGFloat(image.height))
                let bottom = 1 - (cropRect.maxY / CGFloat(image.height))
                return OCRImageRegion(
                    label: label,
                    markdown: "![\(label)](Images/\(fileName))",
                    description: nil,
                    imageURL: imageURL,
                    left: left,
                    right: right,
                    bottom: bottom,
                    top: top
                )
            }
    }

    // Extracts OCR text from each image_desc rule area and keys it by the matching image label.
    private func imageDescriptionsFromLayoutRules(
        _ descRules: [OCRLayoutAreaRule],
        ocrLines: [OCRLine]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for rule in descRules {
            let label = rule.markers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !label.isEmpty else { continue }
            // Use Codex-saved caption text when available; fall back to Vision line matching.
            if let codexText = rule.codexText, !codexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[label] = codexText.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            let matchingLines = ocrLines
                .filter { lineOverlapsLayoutArea($0, rule.rect, threshold: 0.18) }
                .sorted { $0.top > $1.top }
            let text = matchingLines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !text.isEmpty {
                result[label] = text
            }
        }
        return result
    }

    private func pixelCropRect(for rect: OCRLayoutAreaRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let width = CGFloat(imageWidth)
        let height = CGFloat(imageHeight)
        let left = min(max(rect.left, 0), 1)
        let right = min(max(rect.right, left), 1)
        let top = min(max(rect.top, 0), 1)
        let bottom = min(max(rect.bottom, 0), top)
        let x = floor(left * width)
        let y = floor((1 - top) * height)
        let maxX = ceil(right * width)
        let maxY = ceil((1 - bottom) * height)
        return CGRect(
            x: max(0, x),
            y: max(0, y),
            width: min(width, maxX) - max(0, x),
            height: min(height, maxY) - max(0, y)
        )
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "NewOCR", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not encode image: \(url.path)"])
        }
        try data.write(to: url, options: .atomic)
    }

    private func parseLineCount(_ value: String, defaultValue: Int) -> Int {
        guard let count = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return defaultValue
        }
        return max(0, count)
    }

    private func parseFilterValues(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func removeTopBottomLines(
        _ lines: [OCRLine],
        topCount: Int,
        bottomCount: Int,
        filterValues: [String],
        documentTitle: String,
        titleMatchTopLineCount: Int,
        repeatedHeaderFooterKeys: Set<String>
    ) -> [OCRLine] {
        var removeIndexes = Set<Int>()

        for (index, line) in lines.enumerated() where isPageBoundaryLine(index, in: lines) && shouldAutoRemoveHeaderFooterLine(line, repeatedHeaderFooterKeys: repeatedHeaderFooterKeys) {
            removeIndexes.insert(index)
        }

        let titleTopCount = min(max(0, titleMatchTopLineCount), lines.count)
        if titleTopCount > 0 {
            for index in titleLineIndexesToRemove(in: lines, topCount: titleTopCount, documentTitle: documentTitle) {
                removeIndexes.insert(index)
            }
        }

        if !filterValues.isEmpty {
            for index in 0..<min(topCount, lines.count) where filterValues.contains(where: { lines[index].text.contains($0) }) {
                removeIndexes.insert(index)
            }

            if bottomCount > 0 {
                let bottomStart = max(0, lines.count - bottomCount)
                for index in bottomStart..<lines.count where filterValues.contains(where: { lines[index].text.contains($0) }) {
                    removeIndexes.insert(index)
                }
            }
        }

        return lines
            .enumerated()
            .filter { !removeIndexes.contains($0.offset) }
            .map { $0.element }
    }

    private func titleLineIndexesToRemove(in lines: [OCRLine], topCount: Int, documentTitle: String) -> Set<Int> {
        guard topCount > 0 else { return [] }
        let topIndexes = Array(0..<min(topCount, lines.count))
        var indexesToRemove = Set<Int>()

        for index in topIndexes where shouldRemoveTitleText(lines[index].text, documentTitle: documentTitle) {
            indexesToRemove.insert(index)
        }

        for start in topIndexes {
            var combinedParts: [String] = []
            for end in start..<min(topCount, lines.count) {
                combinedParts.append(lines[end].text)
                let combinedText = combinedParts.joined(separator: " ")
                if shouldRemoveTitleText(combinedText, documentTitle: documentTitle) {
                    for index in start...end {
                        indexesToRemove.insert(index)
                    }
                    break
                }
            }
        }

        return indexesToRemove
    }

    private func shouldRemoveTitleText(_ text: String, documentTitle: String) -> Bool {
        guard let titleKey = normalizedHeaderFooterKey(documentTitle),
              let lineKey = normalizedHeaderFooterKey(text) else {
            return false
        }

        let compactTitleKey = compactTitleMatchKey(titleKey)
        let compactLineKey = compactTitleMatchKey(lineKey)
        let compactExtraLimit = max(2, compactTitleKey.count / 4)
        if compactTitleKey.count >= 2
            && compactLineKey.contains(compactTitleKey)
            && compactLineKey.count <= compactTitleKey.count + compactExtraLimit {
            return true
        }

        let tokenExtraLimit = max(6, titleKey.count / 3)
        return lineKey.count <= titleKey.count + tokenExtraLimit
            && headerFooterKeyTokensMatchInOrder(lineKey, pattern: titleKey)
    }

    private func compactTitleMatchKey(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }

    private func shouldAutoRemoveHeaderFooterLine(_ line: OCRLine, repeatedHeaderFooterKeys: Set<String>) -> Bool {
        if isBottomPageNumberLine(line) {
            return true
        }
        guard isPlausibleHeaderFooterText(line.text) else {
            return false
        }
        guard let key = normalizedHeaderFooterKey(line.text),
              repeatedHeaderFooterKeys.contains(where: { headerFooterKeysMatch(key, $0) }) else {
            return false
        }
        return true
    }

    private func isPageBoundaryLine(_ index: Int, in lines: [OCRLine]) -> Bool {
        index == 0 || index == lines.count - 1
    }

    private func isPageNumberLine(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { thaiDigitValue($0).map(String.init) ?? String($0) }
            .joined()
        let digits = normalized.filter { $0.isNumber }
        let letters = normalized.filter { $0.isLetter }
        return !digits.isEmpty && letters.isEmpty && normalized.count <= 6
    }

    private func isBottomPageNumberLine(_ line: OCRLine) -> Bool {
        isPageNumberLine(line.text) && line.bottom < 0.50
    }

    private func normalizedHeaderFooterKey(_ text: String) -> String? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { character -> String in
                if thaiDigitValue(character) != nil || character.isNumber || character.isWhitespace || isHeaderFooterSeparator(character) {
                    return " "
                }
                return String(character)
            }
            .joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard normalized.count >= 2, normalized.contains(where: { $0.isLetter }) else {
            return nil
        }
        return normalized
    }

    private func isPlausibleHeaderFooterText(_ text: String) -> Bool {
        guard let key = normalizedHeaderFooterKey(text) else {
            return false
        }
        if key.count >= 8 {
            return true
        }

        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDigit = raw.contains { $0.isNumber || thaiDigitValue($0) != nil }
        let hasHeaderSeparator = raw.contains { character in
            character == "•" || character == ":" || character == "/" || character == "-" || character == "–" || character == "—"
        }
        return key.count >= 4 && hasDigit && hasHeaderSeparator
    }

    private func isHeaderFooterSeparator(_ character: Character) -> Bool {
        if character == "/" {
            return false
        }
        return character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }
    }

    private func thaiDigitValue(_ character: Character) -> Int? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return nil
        }
        let value = scalar.value
        if value >= 0x0E50 && value <= 0x0E59 {
            return Int(value - 0x0E50)
        }
        return nil
    }

    private func updateAppleVisionLineCache(pdfURL: URL, rawPages: [[OCRLine]]) throws {
        let cacheURL = appleVisionLineCacheURL(for: pdfURL)
        var pages = loadAppleVisionLineCache(for: pdfURL)
        let pdfName = pdfURL.lastPathComponent
        pages.removeAll { $0.pdfName == pdfName }

        for (index, lines) in rawPages.enumerated() {
            pages.append(
                OCRLineCachePage(
                    key: "\(pdfName)#\(index + 1)",
                    pdfName: pdfName,
                    pageNumber: index + 1,
                    lines: headerFooterScanLines(from: lines)
                )
            )
        }

        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pages.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending })
        try data.write(to: cacheURL, options: .atomic)
    }

    private func removeAppleVisionResources(for pdfURL: URL) throws {
        let mdFolder = appleVisionOutputFolderURL(for: pdfURL)
            .appendingPathComponent(pdfURL.deletingPathExtension().lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: mdFolder.path) {
            try FileManager.default.removeItem(at: mdFolder)
        }

        let cacheURL = appleVisionLineCacheURL(for: pdfURL)
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let data = try? Data(contentsOf: cacheURL),
           var pages = try? JSONDecoder().decode([OCRLineCachePage].self, from: data) {
            pages.removeAll { $0.pdfName == pdfURL.lastPathComponent }
            if pages.isEmpty {
                try FileManager.default.removeItem(at: cacheURL)
            } else {
                let encoded = try JSONEncoder().encode(pages.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending })
                try encoded.write(to: cacheURL, options: .atomic)
            }
        }
    }

    private func scanHeaderFooterSample(pdfURL: URL, progress: ((Int, Int) -> Void)? = nil) throws -> String? {
        guard let document = PDFDocument(url: pdfURL) else {
            throw NSError(domain: "NewOCR", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not open PDF: \(pdfURL.path)"])
        }

        var rawPages: [[OCRLine]] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                continue
            }
            let image = try renderPDFPageToCGImage(page, scale: ocrRenderScale)
            rawPages.append(try recognizeTextWithAppleVision(in: image))
            progress?(pageIndex, document.pageCount)
        }
        try updateAppleVisionLineCache(pdfURL: pdfURL, rawPages: rawPages)
        return rawPages.first.flatMap { detectedFirstPageTitle(from: $0) }
    }

    private func headerFooterScanLines(from lines: [OCRLine]) -> [OCRLine] {
        guard let first = lines.first else {
            return []
        }
        guard let bodyHeight = typicalBodyLineHeight(from: lines) else {
            guard let last = lines.last, lines.count > 1 else {
                return [first]
            }
            return [first, last]
        }

        var candidates: [OCRLine] = []
        if isLikelySmallHeaderFooterLine(first, bodyHeight: bodyHeight) {
            candidates.append(first)
        }
        if let last = lines.last,
           lines.count > 1,
           isLikelySmallHeaderFooterLine(last, bodyHeight: bodyHeight) {
            candidates.append(last)
        }
        return candidates
    }

    private func typicalBodyLineHeight(from lines: [OCRLine]) -> CGFloat? {
        let contentLines = lines
            .filter { !isPageNumberLine($0.text) && $0.text.count >= 4 }
            .map(\.height)
            .sorted()
        guard !contentLines.isEmpty else {
            return nil
        }
        return contentLines[contentLines.count / 2]
    }

    private func isLikelySmallHeaderFooterLine(_ line: OCRLine, bodyHeight: CGFloat) -> Bool {
        if isBottomPageNumberLine(line) {
            return true
        }
        return line.height <= bodyHeight * 0.82
    }

    private func writeHeaderFooterReview(for pdfURL: URL) throws -> URL {
        let pages = loadAppleVisionLineCache(for: pdfURL)
        let repeatedGroups = repeatedHeaderFooterGroups(for: pdfURL)
        let reviewURL = headerFooterReviewURL(for: pdfURL)

        var lines: [String] = []
        lines.append("Header/Footer Review")
        lines.append("====================")
        lines.append("")
        lines.append("Scanned pages: \(pages.count)")
        lines.append("Repeated candidates: \(repeatedGroups.count)")
        lines.append("")

        if repeatedGroups.isEmpty {
            lines.append("No repeated first/last row text detected yet. Select more representative PDFs and scan again.")
        } else {
            for group in repeatedGroups.sorted(by: { $0.displayKey.localizedStandardCompare($1.displayKey) == .orderedAscending }) {
                lines.append("REMOVE: \(group.displayKey)")
            }
        }

        try FileManager.default.createDirectory(at: reviewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: reviewURL, atomically: true, encoding: .utf8)
        return reviewURL
    }

    private func detectedFirstPageTitle(from lines: [OCRLine]) -> String? {
        guard !lines.isEmpty else { return nil }

        let normalLeft = lines.map(\.left).min() ?? 0
        let normalRight = lines.map(\.right).max() ?? 1
        let normalWidth = normalRight - normalLeft
        let blockCenter = (normalLeft + normalRight) / 2
        let averageHeight = lines.map(\.height).reduce(0, +) / CGFloat(max(1, lines.count))

        for (index, line) in lines.prefix(5).enumerated() {
            if isHeadingLine(
                line,
                index: index,
                lines: lines,
                normalWidth: normalWidth,
                blockCenter: blockCenter,
                averageHeight: averageHeight
            ) {
                return line.text
            }

            if isChapterNumberHeadingLine(
                line,
                index: index,
                lines: lines,
                normalWidth: normalWidth,
                blockCenter: blockCenter,
                averageHeight: averageHeight
            ) {
                return line.text
            }
        }

        return nil
    }

    private func repeatedHeaderFooterKeys(for pdfURL: URL) -> Set<String> {
        let reviewURL = headerFooterReviewURL(for: pdfURL)
        if FileManager.default.fileExists(atPath: reviewURL.path),
           let reviewText = try? String(contentsOf: reviewURL, encoding: .utf8) {
            return Set(parseHeaderFooterReviewRemoveItems(from: reviewText).compactMap { normalizedHeaderFooterKey($0) })
        }
        return []
    }

    private func parseHeaderFooterReviewRemoveItems(from text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("REMOVE:") else {
                return nil
            }
            let value = line.dropFirst("REMOVE:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private func repeatedHeaderFooterGroups(for pdfURL: URL) -> [HeaderFooterGroup] {
        let pages = loadAppleVisionLineCache(for: pdfURL)
        var clusters: [HeaderFooterGroup] = []

        for page in pages {
            for (lineIndex, line) in page.lines.enumerated() where isPageBoundaryLine(lineIndex, in: page.lines) {
                guard !isPageNumberLine(line.text),
                      isPlausibleHeaderFooterText(line.text),
                      let key = normalizedHeaderFooterKey(line.text) else {
                    continue
                }

                if let index = clusters.firstIndex(where: { cluster in
                    cluster.keys.contains(where: { headerFooterKeysMatch(key, $0) })
                }) {
                    clusters[index].keys.insert(key)
                    clusters[index].pageKeys.insert(page.key)
                    clusters[index].countsByKey[key, default: 0] += 1
                } else {
                    clusters.append(HeaderFooterGroup(keys: [key], pageKeys: [page.key], countsByKey: [key: 1]))
                }
            }
        }

        return clusters
            .filter { $0.pageKeys.count >= minimumHeaderFooterRepeatCount(for: pages.count) }
            .map { group in
                var group = group
                group.displayKey = preferredHeaderFooterDisplayKey(for: group)
                return group
            }
    }

    private func minimumHeaderFooterRepeatCount(for pageCount: Int) -> Int {
        min(max(3, Int(ceil(Double(pageCount) * 0.08))), 8)
    }

    private func headerFooterKeysMatch(_ first: String, _ second: String) -> Bool {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)
        guard first.count >= 2, second.count >= 2 else {
            return first == second
        }

        if first.contains(second) || second.contains(first) {
            return true
        }

        if headerFooterKeyTokensMatchInOrder(first, pattern: second)
            || headerFooterKeyTokensMatchInOrder(second, pattern: first) {
            return true
        }

        return characterBigramSimilarity(first, second) >= 0.82
    }

    private func headerFooterKeyTokensMatchInOrder(_ value: String, pattern: String) -> Bool {
        let valueTokens = headerFooterKeyTokens(value)
        let patternTokens = headerFooterKeyTokens(pattern)
        guard patternTokens.count >= 2, valueTokens.count >= patternTokens.count else {
            return false
        }

        var searchStart = valueTokens.startIndex
        for patternToken in patternTokens {
            guard let matchIndex = valueTokens[searchStart...].firstIndex(where: { valueToken in
                valueToken == patternToken || valueToken.contains(patternToken) || patternToken.contains(valueToken)
            }) else {
                return false
            }
            searchStart = valueTokens.index(after: matchIndex)
        }
        return true
    }

    private func headerFooterKeyTokens(_ value: String) -> [String] {
        value
            .split(separator: " ")
            .map(String.init)
            .filter { $0.contains(where: { $0.isLetter }) }
    }

    private func preferredHeaderFooterDisplayKey(for group: HeaderFooterGroup) -> String {
        group.keys.max { first, second in
            let firstCount = group.countsByKey[first, default: 0]
            let secondCount = group.countsByKey[second, default: 0]
            if firstCount != secondCount {
                return firstCount < secondCount
            }
            if first.count != second.count {
                return first.count < second.count
            }
            return first.localizedStandardCompare(second) == .orderedDescending
        } ?? ""
    }

    private func characterBigramSimilarity(_ first: String, _ second: String) -> Double {
        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        guard firstCharacters.count >= 2, secondCharacters.count >= 2 else {
            return first == second ? 1 : 0
        }

        let firstBigrams = countedBigrams(firstCharacters)
        let secondBigrams = countedBigrams(secondCharacters)
        let shared = firstBigrams.reduce(0) { total, item in
            total + min(item.value, secondBigrams[item.key, default: 0])
        }
        let firstCount = firstBigrams.values.reduce(0, +)
        let secondCount = secondBigrams.values.reduce(0, +)

        return Double(shared * 2) / Double(firstCount + secondCount)
    }

    private func countedBigrams(_ characters: [Character]) -> [String: Int] {
        var counts: [String: Int] = [:]
        guard characters.count >= 2 else {
            return counts
        }

        for index in 0..<(characters.count - 1) {
            let bigram = "\(characters[index])\(characters[index + 1])"
            counts[bigram, default: 0] += 1
        }
        return counts
    }

    private func loadAppleVisionLineCache(for pdfURL: URL) -> [OCRLineCachePage] {
        let cacheURL = appleVisionLineCacheURL(for: pdfURL)
        guard let data = try? Data(contentsOf: cacheURL),
              let pages = try? JSONDecoder().decode([OCRLineCachePage].self, from: data) else {
            return []
        }
        return pages
    }

    private func appleVisionLineCacheURL(for pdfURL: URL) -> URL {
        pdfURL
            .deletingLastPathComponent()
            .appendingPathComponent("AppleVision", isDirectory: true)
            .appendingPathComponent("LineCache", isDirectory: true)
            .appendingPathComponent("header-footer-lines.json")
    }

    // MARK: - Indent Calibration

    private func indentCalibrationURL(for pdfURL: URL) -> URL {
        pdfURL
            .deletingLastPathComponent()
            .appendingPathComponent("AppleVision", isDirectory: true)
            .appendingPathComponent("indent-calibration.json")
    }

    private func loadCachedIndentFraction(for pdfURL: URL) -> CGFloat? {
        let url = indentCalibrationURL(for: pdfURL)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: CGFloat].self, from: data),
              let value = dict[pdfURL.lastPathComponent],
              value > 0 else { return nil }
        return value
    }

    private func saveCachedIndentFraction(_ fraction: CGFloat, for pdfURL: URL) {
        let url = indentCalibrationURL(for: pdfURL)
        var dict: [String: CGFloat] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode([String: CGFloat].self, from: data) {
            dict = existing
        }
        dict[pdfURL.lastPathComponent] = fraction
        if let data = try? JSONEncoder().encode(dict) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func indentFractionFromOffsets(_ offsets: [CGFloat]) -> CGFloat {
        guard offsets.count >= 2 else { return 0.04 }
        let binSize: CGFloat = 0.005
        var bins: [Int: Int] = [:]
        for offset in offsets {
            bins[Int(offset / binSize), default: 0] += 1
        }
        let minCount = max(2, offsets.count / 15)
        let significantBins = bins
            .filter { $0.value >= minCount }
            .map(\.key)
            .sorted()
        guard let firstBin = significantBins.first else { return 0.04 }
        // Center of first significant bin is the detected indent.
        // Threshold is set at 65% of that so indented lines are reliably caught.
        let indentFraction = (CGFloat(firstBin) + 0.5) * binSize
        return min(max(indentFraction * 0.65, 0.010), 0.060)
    }

    private func calibrateIndentFraction(for pdfURL: URL, document: PDFDocument) throws -> CGFloat {
        let pageCount = document.pageCount
        guard pageCount >= 2 else { return 0.04 }
        // Sample up to 5 body pages, skipping page 0 (often a title page).
        let sampleRange = 1..<min(1 + 5, pageCount)
        var allOffsets: [CGFloat] = []
        for pageIndex in sampleRange {
            guard let page = document.page(at: pageIndex) else { continue }
            let image = try renderPDFPageToCGImage(page, scale: 2.0)
            let lines = try recognizeTextWithAppleVision(in: image)
            guard lines.count >= 4 else { continue }
            let normalLeft = lines.map(\.left).min() ?? 0
            let normalRight = lines.map(\.right).max() ?? 1
            let normalWidth = normalRight - normalLeft
            guard normalWidth > 0.1 else { continue }
            for line in lines {
                let fraction = (line.left - normalLeft) / normalWidth
                // Collect only small positive offsets — the indent range.
                if fraction >= 0.005 && fraction <= 0.20 {
                    allOffsets.append(fraction)
                }
            }
        }
        return indentFractionFromOffsets(allOffsets)
    }

    private func resolvedIndentFraction(for pdfURL: URL, document: PDFDocument) throws -> CGFloat {
        if let cached = loadCachedIndentFraction(for: pdfURL) {
            return cached
        }
        let fraction = try calibrateIndentFraction(for: pdfURL, document: document)
        saveCachedIndentFraction(fraction, for: pdfURL)
        return fraction
    }

    private func headerFooterReviewURL(for pdfURL: URL) -> URL {
        appleVisionLineCacheURL(for: pdfURL)
            .deletingLastPathComponent()
            .appendingPathComponent("header-footer-review.txt")
    }

    private func resetOCRFilterStateForFolderChange() {
        filteredText = ""
        configText = ""
        if configEditorTitle == "Header/Footer Review" {
            activeConfigFileURL = nil
            isConfigEditorPresented = false
        }

        guard !selectedFolderPath.isEmpty else { return }
        let reviewURL = URL(fileURLWithPath: selectedFolderPath)
            .appendingPathComponent("AppleVision", isDirectory: true)
            .appendingPathComponent("LineCache", isDirectory: true)
            .appendingPathComponent("header-footer-review.txt")
        if FileManager.default.fileExists(atPath: reviewURL.path) {
            try? FileManager.default.removeItem(at: reviewURL)
        }
    }

    private enum OCRMarkdownBlock {
        case text(OCRLine)
        case header(OCRLine)
        case h2(OCRLine)
        case header3(OCRLine)
        case blockquote(OCRLine)
        case footnote(OCRLine, [String])  // ordered marker labels from rule (e.g. ["1","2","3"])
        case refmark(OCRLine, [(marker: String, anchorWord: String?, fractionLeft: CGFloat, fractionRight: CGFloat)])  // insertion data: marker + optional anchor word + fractions
        case image(OCRImageRegion)

        var top: CGFloat {
            switch self {
            case .text(let line): return line.top
            case .header(let line): return line.top
            case .h2(let line): return line.top
            case .header3(let line): return line.top
            case .blockquote(let line): return line.top
            case .footnote(let line, _): return line.top
            case .refmark(let line, _): return line.top
            case .image(let r): return r.top
            }
        }

        var left: CGFloat {
            switch self {
            case .text(let line): return line.left
            case .header(let line): return line.left
            case .h2(let line): return line.left
            case .header3(let line): return line.left
            case .blockquote(let line): return line.left
            case .footnote(let line, _): return line.left
            case .refmark(let line, _): return line.left
            case .image(let r): return r.left
            }
        }
    }

    private func buildMarkdownPage(from lines: [OCRLine], imageRegions: [OCRImageRegion], layoutRules: [OCRLayoutAreaRule] = [], indentFraction: CGFloat = 0.04) -> String {
        let headerRules = layoutAreaRules(layoutRules, type: "header")
        let h2Rules = layoutAreaRules(layoutRules, type: "h2")
        let header3Rules = layoutAreaRules(layoutRules, type: "header3")
        let blockquoteRules = layoutAreaRules(layoutRules, type: "blockquote")
        let footnoteRules = layoutAreaRules(layoutRules, type: "footnote")
        let refmarkRules = layoutAreaRules(layoutRules, type: "refmark")
        let hasForcedLayout = !headerRules.isEmpty || !h2Rules.isEmpty || !header3Rules.isEmpty || !blockquoteRules.isEmpty || !footnoteRules.isEmpty || !refmarkRules.isEmpty

        if hasForcedLayout {
            return buildMarkdownPageWithForcedLayout(from: lines, imageRegions: imageRegions, headerRules: headerRules, h2Rules: h2Rules, header3Rules: header3Rules, blockquoteRules: blockquoteRules, footnoteRules: footnoteRules, refmarkRules: refmarkRules, indentFraction: indentFraction)
        }

        if imageRegions.isEmpty {
            return buildContinuousParagraphs(from: lines, indentFraction: indentFraction)
        }

        var blocks: [OCRMarkdownBlock] = lines.map { .text($0) } + imageRegions.map { .image($0) }
        blocks.sort {
            if abs($0.top - $1.top) > 0.01 {
                return $0.top > $1.top
            }
            return $0.left < $1.left
        }

        var rendered: [String] = []
        var pendingTextLines: [OCRLine] = []

        func flushText() {
            let text = buildContinuousParagraphs(from: pendingTextLines, indentFraction: indentFraction)
            if !text.isEmpty {
                rendered.append(text)
            }
            pendingTextLines.removeAll()
        }

        for block in blocks {
            switch block {
            case .text(let line):
                pendingTextLines.append(line)
            case .header(let line):
                flushText()
                rendered.append("## \(line.text.trimmingCharacters(in: .whitespacesAndNewlines))")
            case .h2(let line):
                flushText()
                rendered.append("## \(line.text.trimmingCharacters(in: .whitespacesAndNewlines))")
            case .header3(let line):
                flushText()
                rendered.append("### \(line.text.trimmingCharacters(in: .whitespacesAndNewlines))")
            case .blockquote(let line):
                flushText()
                rendered.append("> \(line.text.trimmingCharacters(in: .whitespacesAndNewlines))")
            case .footnote(let line, _):
                flushText()
                rendered.append(footnoteMarkdownLine(from: line.text, fallbackLabel: "note1", forcedLabel: nil))
            case .refmark(let line, let refData):
                flushText()
                rendered.append(applyRefmarkInsertions(line.text.trimmingCharacters(in: .whitespacesAndNewlines), refmarks: refData))
            case .image(let imageRegion):
                flushText()
                var imageBlock = imageRegion.markdown
                if let desc = imageRegion.description, !desc.isEmpty {
                    imageBlock += "\n\n*\(desc)*"
                }
                rendered.append(imageBlock)
                rendered.append("<br/>")
            }
        }
        flushText()

        return rendered.joined(separator: "\n\n")
    }

    private func buildMarkdownPageWithForcedLayout(
        from lines: [OCRLine],
        imageRegions: [OCRImageRegion],
        headerRules: [OCRLayoutAreaRule],
        h2Rules: [OCRLayoutAreaRule] = [],
        header3Rules: [OCRLayoutAreaRule] = [],
        blockquoteRules: [OCRLayoutAreaRule],
        footnoteRules: [OCRLayoutAreaRule],
        refmarkRules: [OCRLayoutAreaRule] = [],
        indentFraction: CGFloat = 0.04
    ) -> String {
        // Pre-process: rules with codexText replace Vision-recognized lines with saved Codex text.
        // Remove OCR lines overlapping those rules and inject synthetic lines carrying the Codex text.
        // Injected lines fall inside the rule rects, so the block-classifier below picks them up normally.
        let codexTextRules = (headerRules + h2Rules + header3Rules + blockquoteRules + footnoteRules)
            .filter { !($0.codexText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var effectiveLines: [OCRLine]
        if codexTextRules.isEmpty {
            effectiveLines = lines
        } else {
            var filtered = lines
            var injected: [OCRLine] = []
            for rule in codexTextRules {
                filtered = filtered.filter { !lineOverlapsLayoutArea($0, rule.rect, threshold: 0.45) }
                let rawTextLines = (rule.codexText ?? "")
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let rectHeight = max(0.001, rule.rect.top - rule.rect.bottom)
                let lineStep = rawTextLines.count > 1 ? rectHeight / CGFloat(rawTextLines.count) : rectHeight
                for (idx, txt) in rawTextLines.enumerated() {
                    let top = rule.rect.top - CGFloat(idx) * lineStep
                    let bottom = max(rule.rect.bottom, top - lineStep)
                    injected.append(OCRLine(text: txt, left: rule.rect.left, right: rule.rect.right, bottom: bottom, top: top))
                }
            }
            effectiveLines = filtered + injected
        }

        var blocks: [OCRMarkdownBlock] = effectiveLines.map { line in
            if headerRules.contains(where: { lineOverlapsLayoutArea(line, $0.rect, threshold: 0.45) }) {
                return .header(line)
            }
            if h2Rules.contains(where: { lineOverlapsLayoutArea(line, $0.rect, threshold: 0.45) }) {
                return .h2(line)
            }
            if header3Rules.contains(where: { lineOverlapsLayoutArea(line, $0.rect, threshold: 0.45) }) {
                return .header3(line)
            }
            if blockquoteRules.contains(where: { lineOverlapsLayoutArea(line, $0.rect, threshold: 0.45) }) {
                return .blockquote(line)
            }
            if let rule = footnoteRules.first(where: { lineOverlapsLayoutArea(line, $0.rect, threshold: 0.45) }) {
                return .footnote(line, ruleMarkersToList(rule.markers))
            }
            // RefMark uses a low threshold (0.10) because the drawn rectangle is intentionally
            // small — covering just one word/superscript in an otherwise full-width OCR line.
            // Collect ALL matching refmark rules for this line, sorted left-to-right.
            // Store the insertion fraction so the marker is spliced into the text at the
            // horizontal position of the refmark rectangle's right edge, not appended at the end.
            let lineWidth = max(0.0001, line.right - line.left)
            let matchingRefmarks = refmarkRules
                .filter { lineOverlapsLayoutArea(line, $0.rect, threshold: 0.10) }
                .sorted { $0.rect.left < $1.rect.left }
            let refData: [(marker: String, anchorWord: String?, fractionLeft: CGFloat, fractionRight: CGFloat)] = matchingRefmarks.compactMap { rule in
                guard let m = rule.markers?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { return nil }
                let fl = min(max((rule.rect.left  - line.left) / lineWidth, 0), 1)
                let fr = min(max((rule.rect.right - line.left) / lineWidth, 0), 1)
                let aw = rule.anchorWord.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                return (marker: m, anchorWord: aw, fractionLeft: fl, fractionRight: fr)
            }
            if !refData.isEmpty {
                return .refmark(line, refData)
            }
            return .text(line)
        } + imageRegions.map { .image($0) }

        blocks.sort {
            if abs($0.top - $1.top) > 0.01 {
                return $0.top > $1.top
            }
            return $0.left < $1.left
        }

        // Remove body text lines whose content duplicates a detected header line.
        // Codex's header rect may not be pixel-perfect, so the same heading text can
        // appear once as .header and again as a .text line right below it.
        let headerTexts = Set(blocks.compactMap { block -> String? in
            if case .header(let l) = block { return l.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return nil
        })
        if !headerTexts.isEmpty {
            blocks = blocks.filter { block in
                if case .text(let l) = block {
                    return !headerTexts.contains(l.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
                return true
            }
        }

        var rendered: [String] = []
        var pendingTextLines: [OCRLine] = []
        var pendingHeaderLines: [OCRLine] = []
        var pendingH2Lines: [OCRLine] = []
        var pendingHeader3Lines: [OCRLine] = []
        var pendingQuoteLines: [OCRLine] = []
        // footnote: (line, markers list from the matching rule)
        var pendingFootnoteLines: [(OCRLine, [String])] = []
        // refmark: (line, insertion entries sorted left-to-right)
        var pendingRefmarkLines: [(OCRLine, [(marker: String, anchorWord: String?, fractionLeft: CGFloat, fractionRight: CGFloat)])] = []
        var hadFootnotes = false

        func flushText() {
            let text = buildContinuousParagraphs(from: pendingTextLines, indentFraction: indentFraction)
            if !text.isEmpty { rendered.append(text) }
            pendingTextLines.removeAll()
        }

        func flushHeader() {
            if !pendingHeaderLines.isEmpty {
                let headerLines = pendingHeaderLines
                    .map { "## \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
                    .joined(separator: "\n")
                rendered.append(headerLines)
                pendingHeaderLines.removeAll()
            }
        }

        func flushH2() {
            if !pendingH2Lines.isEmpty {
                let h2Lines = pendingH2Lines
                    .map { "## \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
                    .joined(separator: "\n")
                rendered.append(h2Lines)
                pendingH2Lines.removeAll()
            }
        }

        func flushHeader3() {
            if !pendingHeader3Lines.isEmpty {
                let header3Lines = pendingHeader3Lines
                    .map { "### \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
                    .joined(separator: "\n")
                rendered.append(header3Lines)
                pendingHeader3Lines.removeAll()
            }
        }

        func flushQuote() {
            if !pendingQuoteLines.isEmpty {
                rendered.append(buildBlockquoteMarkdown(from: pendingQuoteLines))
                rendered.append("<br/>")
                pendingQuoteLines.removeAll()
            }
        }

        func flushFootnote() {
            guard !pendingFootnoteLines.isEmpty else { return }
            hadFootnotes = true

            // Group consecutive lines that share the same markers into one footnote entry.
            // A single-marker rule covering multiple OCR lines means the footnote text wraps —
            // join those lines rather than emitting one [^label]: per line.
            var groups: [(markers: [String], lines: [OCRLine])] = []
            for (line, markers) in pendingFootnoteLines {
                if let last = groups.indices.last, groups[last].markers == markers {
                    groups[groups.count - 1].lines.append(line)
                } else {
                    groups.append((markers, [line]))
                }
            }

            var outputLines: [String] = []
            for (groupIndex, group) in groups.enumerated() {
                if group.markers.count == 1 {
                    // Single marker: join all wrapped lines into one footnote.
                    let label = group.markers[0]
                    let joinedText = group.lines
                        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    outputLines.append(footnoteMarkdownLine(from: joinedText, fallbackLabel: "note\(groupIndex + 1)", forcedLabel: label))
                } else if group.markers.count > 1 {
                    // Multi-marker: one marker per line within the group.
                    for (lineIndex, line) in group.lines.enumerated() {
                        let forcedLabel = lineIndex < group.markers.count ? group.markers[lineIndex] : nil
                        outputLines.append(footnoteMarkdownLine(from: line.text, fallbackLabel: "note\(groupIndex + 1)", forcedLabel: forcedLabel))
                    }
                } else {
                    // No markers: auto-detect from each line.
                    for line in group.lines {
                        outputLines.append(footnoteMarkdownLine(from: line.text, fallbackLabel: "note\(groupIndex + 1)", forcedLabel: nil))
                    }
                }
            }

            rendered.append(outputLines.joined(separator: "\n"))
            pendingFootnoteLines.removeAll()
        }

        func flushRefmark() {
            if !pendingRefmarkLines.isEmpty {
                let parts = pendingRefmarkLines.map { line, refData -> String in
                    let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return applyRefmarkInsertions(text, refmarks: refData)
                }.filter { !$0.isEmpty }
                if !parts.isEmpty { rendered.append(parts.joined(separator: "\n\n")) }
                pendingRefmarkLines.removeAll()
            }
        }

        for block in blocks {
            switch block {
            case .text(let line):
                flushHeader(); flushH2(); flushHeader3(); flushQuote(); flushFootnote(); flushRefmark()
                pendingTextLines.append(line)
            case .header(let line):
                flushText(); flushH2(); flushHeader3(); flushQuote(); flushFootnote(); flushRefmark()
                pendingHeaderLines.append(line)
            case .h2(let line):
                flushText(); flushHeader(); flushHeader3(); flushQuote(); flushFootnote(); flushRefmark()
                pendingH2Lines.append(line)
            case .header3(let line):
                flushText(); flushHeader(); flushH2(); flushQuote(); flushFootnote(); flushRefmark()
                pendingHeader3Lines.append(line)
            case .blockquote(let line):
                flushHeader(); flushH2(); flushHeader3(); flushText(); flushFootnote(); flushRefmark()
                pendingQuoteLines.append(line)
            case .footnote(let line, let markers):
                flushHeader(); flushH2(); flushHeader3(); flushText(); flushQuote(); flushRefmark()
                pendingFootnoteLines.append((line, markers))
            case .refmark(let line, let refData):
                // Apply refmark insertions now and feed the result into pendingTextLines so
                // buildContinuousParagraphs treats this line like a normal body line. This
                // lets short wrap-over text that follows (e.g. "แบ่งปัน...") join naturally
                // instead of being split into a separate paragraph.
                flushHeader(); flushH2(); flushHeader3(); flushQuote(); flushFootnote(); flushRefmark()
                let processedText = applyRefmarkInsertions(
                    line.text.trimmingCharacters(in: .whitespacesAndNewlines), refmarks: refData)
                if !processedText.isEmpty {
                    pendingTextLines.append(OCRLine(
                        text: processedText, left: line.left, right: line.right,
                        bottom: line.bottom, top: line.top, confidence: line.confidence))
                }
            case .image(let imageRegion):
                flushHeader(); flushH2(); flushHeader3(); flushText(); flushQuote(); flushFootnote(); flushRefmark()
                var imageBlock = imageRegion.markdown
                if let desc = imageRegion.description, !desc.isEmpty {
                    imageBlock += "\n\n*\(desc)*"
                }
                rendered.append(imageBlock)
                rendered.append("<br/>")
            }
        }
        flushHeader()
        flushH2()
        flushHeader3()
        flushText()
        flushQuote()
        flushFootnote()
        flushRefmark()

        var result = rendered.joined(separator: "\n\n")
        if hadFootnotes {
            result += "\n\n<!-- page-break-after -->"
        }
        return result
    }

    // Splits a rule's markers string ("1,2,3" or "*, †") into an ordered list.
    private func ruleMarkersToList(_ markers: String?) -> [String] {
        guard let m = markers, !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return m.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // OCR characters that represent superscript numbers the recogniser couldn't classify.
    private static let superscriptArtefacts: Set<Unicode.Scalar> = ["'", "\u{2019}", "`", "′", "ʹ", "´", "ʼ", "\u{02BC}"]

    // Inserts [^marker] into text for each refmark entry (sorted left-to-right).
    //
    // When a refmark has an anchorWord:
    //   1. Try exact unicode-scalar match of the anchor word in the line text.
    //   2. If not found, retry after stripping Thai above-base diacritic marks from
    //      both the anchor word and the line (tolerates OCR dropping ็ ่ ้ etc.).
    //   3. On a match, insert [^marker] immediately after the word AND remove the
    //      nearest superscript artefact within 20 chars (OCR residue from the original
    //      printed superscript number/symbol).
    //   4. If still not found, fall through to the legacy artefact-detection strategy.
    //
    // When a refmark has no anchorWord (legacy rules):
    //   Use the original superscript-artefact strategy:
    //   1. Estimate character-index centre from the rectangle's horizontal fraction.
    //   2. Search a ±15 % window for an artefact; pick the nearest.
    //   3. If none in the window, scan the full line for the nearest unused artefact.
    //   4. If still none, insert at the right-edge estimate.
    //
    // All mutations are collected then applied right-to-left so earlier indices stay valid.
    private func applyRefmarkInsertions(_ text: String, refmarks: [(marker: String, anchorWord: String?, fractionLeft: CGFloat, fractionRight: CGFloat)]) -> String {
        guard !refmarks.isEmpty, !text.isEmpty else { return text }
        var scalars = Array(text.unicodeScalars)
        let total = scalars.count

        enum OpKind {
            case replaceArtifact(at: Int, marker: String) // remove artifact, insert [^marker]
            case insertOnly(at: Int, marker: String)       // just insert [^marker]
            case removeOnly(at: Int)                       // just remove artifact residue
        }
        var ops: [OpKind] = []
        func sortKey(_ op: OpKind) -> Int {
            switch op {
            case .replaceArtifact(let i, _): return i
            case .insertOnly(let i, _):      return i
            case .removeOnly(let i):         return i
            }
        }

        // Pre-collect artefact positions (used by both paths).
        var availableArtefacts: Set<Int> = []
        for i in scalars.indices where Self.superscriptArtefacts.contains(scalars[i]) {
            availableArtefacts.insert(i)
        }

        for refmark in refmarks {
            // — Anchor-word path —
            if let anchor = refmark.anchorWord, !anchor.isEmpty {
                let insertIdx = indexAfterAnchor(in: scalars, anchor: anchor)

                if let idx = insertIdx {
                    let clampedIdx = min(idx, total)
                    ops.append(.insertOnly(at: clampedIdx, marker: refmark.marker))
                    // Remove the nearest superscript artifact within 20 chars (OCR residue).
                    let nearby = availableArtefacts.filter { abs($0 - clampedIdx) <= 20 }
                    if let nearest = nearby.min(by: { abs($0 - clampedIdx) < abs($1 - clampedIdx) }) {
                        availableArtefacts.remove(nearest)
                        ops.append(.removeOnly(at: nearest))
                    }
                    continue
                }
                // Anchor word specified but not found in this line — this line is not the
                // refmark host (the rectangle overlapped an adjacent line). Skip it.
                continue
            }

            // — Legacy artefact-detection path (no anchorWord, or anchor not found) —
            let centre = Int((CGFloat(total) * (refmark.fractionLeft + refmark.fractionRight) / 2).rounded())
            let buffer = max(Int((CGFloat(total) * 0.15).rounded()), 4)
            let lo = max(0, centre - buffer)
            let hi = min(total, centre + buffer)

            var bestIdx: Int? = nil
            var bestDist = Int.max
            for i in lo..<hi {
                guard availableArtefacts.contains(i) else { continue }
                let d = abs(i - centre)
                if d < bestDist { bestDist = d; bestIdx = i }
            }
            if bestIdx == nil {
                for i in availableArtefacts {
                    let d = abs(i - centre)
                    if d < bestDist { bestDist = d; bestIdx = i }
                }
            }
            if let ai = bestIdx {
                availableArtefacts.remove(ai)
                ops.append(.replaceArtifact(at: ai, marker: refmark.marker))
            } else {
                ops.append(.insertOnly(at: min(hi, total), marker: refmark.marker))
            }
        }

        // Apply right-to-left so earlier indices remain valid.
        // Tiebreaker: when two ops share the same index, removeOnly runs before insertOnly so
        // the artifact is gone before [^marker] is spliced in at the same position.
        ops.sort {
            let k0 = sortKey($0), k1 = sortKey($1)
            if k0 != k1 { return k0 > k1 }
            if case .removeOnly = $0 { return true }
            return false
        }
        for op in ops {
            switch op {
            case .replaceArtifact(let i, let marker):
                let tag = Array("[^\(marker)]".unicodeScalars)
                scalars.remove(at: i)
                scalars.insert(contentsOf: tag, at: i)
            case .insertOnly(let i, let marker):
                let tag = Array("[^\(marker)]".unicodeScalars)
                scalars.insert(contentsOf: tag, at: i)
            case .removeOnly(let i):
                if i < scalars.count { scalars.remove(at: i) }
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    // Thai above-base diacritic marks that OCR may drop, used for fuzzy anchor matching.
    private static let thaiAboveBaseMarks: Set<UInt32> = [
        0x0E47, // ็ mai tai khu
        0x0E48, // ่ mai ek
        0x0E49, // ้ mai tho
        0x0E4A, // ๊ mai tri
        0x0E4B, // ๋ mai jattawa
        0x0E4C, // ์ thanthakat
        0x0E4D, // ํ nikhahit
        0x0E4E, // ๎ yamakkan
    ]

    // Returns the scalar index immediately after the first occurrence of `anchor` in `scalars`.
    // Tries exact match first; falls back to Thai-diacritic-normalized match.
    private func indexAfterAnchor(in scalars: [Unicode.Scalar], anchor: String) -> Int? {
        // Exact match
        if let pos = indexAfterSubsequence(in: scalars, target: anchor) { return pos }
        // Normalized match: strip Thai above-base marks from both sides and search,
        // then map the end position back to the original scalar array.
        let anchorNorm = Array(anchor.unicodeScalars.filter { !Self.thaiAboveBaseMarks.contains($0.value) })
        guard !anchorNorm.isEmpty else { return nil }
        var normScalars: [Unicode.Scalar] = []
        var normToOrigNextIdx: [Int] = [] // normToOrigNextIdx[k] = original index AFTER the k-th normalized scalar
        for (origIdx, s) in scalars.enumerated() {
            if !Self.thaiAboveBaseMarks.contains(s.value) {
                normScalars.append(s)
                normToOrigNextIdx.append(origIdx + 1)
            }
        }
        guard normScalars.count >= anchorNorm.count else { return nil }
        for i in 0...(normScalars.count - anchorNorm.count) {
            if normScalars[i..<(i + anchorNorm.count)].elementsEqual(anchorNorm) {
                let normEndIdx = i + anchorNorm.count - 1
                return normEndIdx < normToOrigNextIdx.count ? normToOrigNextIdx[normEndIdx] : nil
            }
        }
        return nil
    }

    // Returns the scalar index immediately after the first occurrence of `target` in `scalars`,
    // or nil if not found.
    private func indexAfterSubsequence(in scalars: [Unicode.Scalar], target: String) -> Int? {
        let needle = Array(target.unicodeScalars)
        guard !needle.isEmpty, scalars.count >= needle.count else { return nil }
        for i in 0...(scalars.count - needle.count) {
            if scalars[i..<(i + needle.count)].elementsEqual(needle) {
                return i + needle.count
            }
        }
        return nil
    }

    private func normalizedOverlapArea(_ line: OCRLine, _ imageRegion: OCRImageRegion) -> CGFloat {
        let left = max(line.left, imageRegion.left)
        let right = min(line.right, imageRegion.right)
        let bottom = max(line.bottom, imageRegion.bottom)
        let top = min(line.top, imageRegion.top)
        guard right > left, top > bottom else { return 0 }
        let overlap = (right - left) * (top - bottom)
        let lineArea = max(0.0001, line.width * line.height)
        return overlap / lineArea
    }

    private func loadOCRLayoutAreaRules(for pdfURL: URL) -> [OCRLayoutAreaRule] {
        // Load global (all_sections) rules + rules specific to this section's file.
        var rules: [OCRLayoutAreaRule] = []
        if let url = layoutAreasFileURL(),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(OCRLayoutAreasFile.self, from: data) {
            rules += decoded.rules
        }
        let stem = pdfURL.deletingPathExtension().lastPathComponent
        if let url = layoutAreasSectionFileURL(forStem: stem),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(OCRLayoutAreasFile.self, from: data) {
            rules += decoded.rules
        }
        let validTypes: Set<String> = ["header", "h2", "header3", "blockquote", "image", "image_desc", "footnote", "ignore", "refmark"]
        return rules.filter { rule in
            let type = rule.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard validTypes.contains(type) else { return false }
            return rule.rect.left < rule.rect.right && rule.rect.bottom < rule.rect.top
        }
    }

    private func matchingLayoutAreaRules(_ rules: [OCRLayoutAreaRule], pdfURL: URL, pageNumber: Int) -> [OCRLayoutAreaRule] {
        let fileName = pdfURL.lastPathComponent
        let stem = pdfURL.deletingPathExtension().lastPathComponent
        return rules.filter { rule in
            let ruleType = rule.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if (ruleType == "header" || ruleType == "h2" || ruleType == "header3") && pageNumber != 1 {
                return false
            }
            if let page = rule.page, page != pageNumber {
                return false
            }
            if let section = rule.section?.trimmingCharacters(in: .whitespacesAndNewlines), !section.isEmpty {
                return section == fileName || section == stem
            }
            let scope = rule.scope?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "all_sections"
            return scope == "all_sections" || scope == "all" || scope == "project"
        }
    }

    private func layoutAreaRules(_ rules: [OCRLayoutAreaRule], type: String) -> [OCRLayoutAreaRule] {
        rules.filter { $0.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == type }
    }

    private func lineOverlapsLayoutArea(_ line: OCRLine, _ rect: OCRLayoutAreaRect, threshold: CGFloat) -> Bool {
        let left = max(line.left, rect.left)
        let right = min(line.right, rect.right)
        let bottom = max(line.bottom, rect.bottom)
        let top = min(line.top, rect.top)
        if right > left, top > bottom {
            let overlap = (right - left) * (top - bottom)
            let lineArea = max(0.0001, line.width * line.height)
            if overlap / lineArea >= threshold {
                return true
            }
        }
        return line.centerX >= rect.left
            && line.centerX <= rect.right
            && ((line.bottom + line.top) / 2) >= rect.bottom
            && ((line.bottom + line.top) / 2) <= rect.top
    }

    private func firstTextLineContinuesPreviousPage(_ lines: [OCRLine], indentFraction: CGFloat = 0.04) -> Bool {
        guard let firstLine = lines.first else { return false }
        let normalLeft = lines.map(\.left).min() ?? firstLine.left
        let normalRight = lines.map(\.right).max() ?? firstLine.right
        let normalWidth = max(0.0001, normalRight - normalLeft)
        let blockCenter = (normalLeft + normalRight) / 2
        let averageHeight = lines.map(\.height).reduce(0, +) / CGFloat(max(1, lines.count))
        let indentThreshold = max(0.015, normalWidth * indentFraction)

        if isHeadingLine(firstLine, index: 0, lines: lines, normalWidth: normalWidth, blockCenter: blockCenter, averageHeight: averageHeight)
            || isChapterNumberHeadingLine(firstLine, index: 0, lines: lines, normalWidth: normalWidth, blockCenter: blockCenter, averageHeight: averageHeight) {
            return false
        }

        return (firstLine.left - normalLeft) < indentThreshold
    }

    private func lastTextLineCanContinueNextPage(_ lines: [OCRLine]) -> Bool {
        guard let lastLine = lines.last else { return false }
        let normalLeft = lines.map(\.left).min() ?? lastLine.left
        let normalRight = lines.map(\.right).max() ?? lastLine.right
        let normalWidth = max(0.0001, normalRight - normalLeft)
        let blockCenter = (normalLeft + normalRight) / 2
        let averageHeight = lines.map(\.height).reduce(0, +) / CGFloat(max(1, lines.count))
        let rightEdgeThreshold = max(0.025, normalWidth * 0.08)

        if isHeadingLine(lastLine, index: max(0, lines.count - 1), lines: lines, normalWidth: normalWidth, blockCenter: blockCenter, averageHeight: averageHeight)
            || isChapterNumberHeadingLine(lastLine, index: max(0, lines.count - 1), lines: lines, normalWidth: normalWidth, blockCenter: blockCenter, averageHeight: averageHeight) {
            return false
        }

        return (normalRight - lastLine.right) <= rightEdgeThreshold
    }

    private func mergePageBoundaryContinuations(in pages: inout [OCRPageMarkdown]) {
        guard pages.count > 1 else { return }

        for index in 1..<pages.count {
            guard pages[index - 1].lastTextLineCanContinueNextPage,
                  pages[index].firstTextLineContinuesPreviousPage else {
                continue
            }
            // Skip page-break comments and footnote definitions when looking for
            // the last body-text paragraph that can continue across the page boundary.
            let previousLastItem = lastMergeableMarkdownParagraphWithRange(in: pages[index - 1].text)
            let currentFirst = firstMarkdownParagraph(in: pages[index].text)
            guard let previousLastItem,
                  let currentFirst,
                  canMergePageBoundaryParagraph(previousLastItem.text, currentFirst) else {
                continue
            }

            // Replace only that specific paragraph in-place — footnotes and
            // <!-- page-break-after --> markers that follow it are left untouched.
            pages[index - 1].text = replacingMarkdownParagraphAtRange(
                previousLastItem.range,
                in: pages[index - 1].text,
                with: joinContinuousLine(previousLastItem.text, currentFirst)
            )
            pages[index].text = removingFirstMarkdownParagraph(from: pages[index].text)
        }
    }

    // Last paragraph suitable for cross-page merging: skips page-break comments
    // and footnote definitions that may trail the real body text.
    private func lastMergeableMarkdownParagraphWithRange(in text: String) -> (text: String, range: Range<String.Index>)? {
        markdownParagraphsWithRanges(in: text).last { item in
            let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.hasPrefix("<!--") && !t.hasPrefix("[^")
        }
    }

    private func replacingMarkdownParagraphAtRange(_ range: Range<String.Index>, in text: String, with replacement: String) -> String {
        var updated = text
        // The stored range includes the trailing \n of the paragraph's last line.
        // Appending \n to the replacement restores the blank-line separator so the
        // following content (footnotes, page-break) stays in its own paragraph.
        updated.replaceSubrange(range, with: replacement + "\n")
        return updated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canMergePageBoundaryParagraph(_ previous: String, _ current: String) -> Bool {
        let previous = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty, !current.isEmpty else { return false }
        guard !previous.hasPrefix("#"), !previous.hasPrefix("!["),
              !previous.hasPrefix(">"), !previous.hasPrefix("<!--"),
              !current.hasPrefix("#"), !current.hasPrefix("!["),
              !current.hasPrefix(">"), !current.hasPrefix("<!--") else {
            return false
        }
        return true
    }

    private func markdownParagraphsWithRanges(in text: String) -> [(text: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let nextIndex = lineEnd == text.endIndex ? text.endIndex : text.index(after: lineEnd)
            let line = String(text[index..<lineEnd])

            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let paragraphStart = start {
                    result.append((String(text[paragraphStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines), paragraphStart..<index))
                    start = nil
                }
            } else if start == nil {
                start = index
            }

            index = nextIndex
        }

        if let paragraphStart = start {
            result.append((String(text[paragraphStart..<text.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines), paragraphStart..<text.endIndex))
        }

        return result
    }

    private func firstMarkdownParagraph(in text: String) -> String? {
        markdownParagraphsWithRanges(in: text).first?.text
    }

    private func lastMarkdownParagraph(in text: String) -> String? {
        markdownParagraphsWithRanges(in: text).last?.text
    }

    private func replacingLastMarkdownParagraph(in text: String, with replacement: String) -> String {
        guard let last = markdownParagraphsWithRanges(in: text).last else { return text }
        var updated = text
        updated.replaceSubrange(last.range, with: replacement)
        return updated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removingFirstMarkdownParagraph(from text: String) -> String {
        guard let first = markdownParagraphsWithRanges(in: text).first else { return text }
        var updated = text
        updated.removeSubrange(first.range)
        return updated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildContinuousParagraphs(from lines: [OCRLine], indentFraction: CGFloat = 0.04) -> String {
        guard !lines.isEmpty else { return "" }

        let normalLeft = lines.map(\.left).min() ?? 0
        let normalRight = lines.map(\.right).max() ?? 1
        let normalWidth = normalRight - normalLeft
        let blockCenter = (normalLeft + normalRight) / 2
        let averageHeight = lines.map(\.height).reduce(0, +) / CGFloat(max(1, lines.count))
        let indentThreshold = max(0.015, (normalRight - normalLeft) * indentFraction)
        let rightEdgeThreshold = max(0.025, (normalRight - normalLeft) * 0.08)
        var paragraphs: [String] = []
        var current = ""
        var previousLine: OCRLine?
        var centeredBodyMode = false

        for (index, line) in lines.enumerated() {
            if isHeadingLine(
                line,
                index: index,
                lines: lines,
                normalWidth: normalWidth,
                blockCenter: blockCenter,
                averageHeight: averageHeight
            ) {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
                paragraphs.append("# \(line.text)")
                previousLine = nil
                centeredBodyMode = isCenteredBodyPage(
                    lines: Array(lines.dropFirst(index + 1)),
                    normalLeft: normalLeft,
                    normalWidth: normalWidth,
                    blockCenter: blockCenter,
                    indentThreshold: indentThreshold
                )
                continue
            }

            if isChapterNumberHeadingLine(
                line,
                index: index,
                lines: lines,
                normalWidth: normalWidth,
                blockCenter: blockCenter,
                averageHeight: averageHeight
            ) {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
                paragraphs.append("## \(line.text)")
                previousLine = nil
                centeredBodyMode = isCenteredBodyPage(
                    lines: Array(lines.dropFirst(index + 1)),
                    normalLeft: normalLeft,
                    normalWidth: normalWidth,
                    blockCenter: blockCenter,
                    indentThreshold: indentThreshold
                )
                continue
            }

            let isIndented = (line.left - normalLeft) >= indentThreshold
            let previousIsFullLine = previousLine.map { (normalRight - $0.right) <= rightEdgeThreshold } ?? false
            // A short line after a full line is a clear word-wrap carry-over (e.g. "ไหม""
            // at the end of a Thai dialogue speech). Join it even when it appears indented —
            // in dialogue text the wrapped word sits at the same indent level as the rest of
            // the speech, so the plain isIndented check incorrectly fires and creates a
            // spurious new paragraph.
            let currentLineIsShort = (line.right - line.left) <= normalWidth * 0.40
            let isWrappedCarryOver = currentLineIsShort && previousIsFullLine
            let hasBlankLineGap = previousLine.map { hasDetectedBlankLineGap(between: $0, and: line, averageHeight: averageHeight) } ?? false
            let shouldContinue = !hasBlankLineGap && !current.isEmpty &&
                (isWrappedCarryOver || (!isIndented && (centeredBodyMode || previousIsFullLine || currentLineIsShort)))

            if shouldContinue {
                current = joinContinuousLine(current, line.text)
            } else {
                if !current.isEmpty {
                    paragraphs.append(current)
                    if hasBlankLineGap {
                        paragraphs.append("<br/>")
                    }
                }
                current = line.text
            }
            previousLine = line
        }

        if !current.isEmpty {
            paragraphs.append(current)
        }

        return paragraphs.joined(separator: "\n\n")
    }

    private func buildBlockquoteMarkdown(from lines: [OCRLine]) -> String {
        lines.map {
            "> \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        .joined(separator: "\n")
    }

    private func buildFootnoteMarkdown(from lines: [OCRLine]) -> String {
        lines.enumerated().map { index, line in
            footnoteMarkdownLine(from: line.text, fallbackLabel: "note\(index + 1)", forcedLabel: nil)
        }
        .joined(separator: "\n")
    }

    // Maps Unicode superscript digits/letters to their ASCII equivalent for footnote labels.
    private static let superscriptLabelMap: [Character: String] = [
        "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5",
        "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "⁰": "0",
        "ⁱ": "i", "ⁿ": "n",
        "ᵃ": "a", "ᵇ": "b", "ᶜ": "c", "ᵈ": "d", "ᵉ": "e",
        "ᶠ": "f", "ᵍ": "g", "ʰ": "h", "ʲ": "j", "ᵏ": "k",
        "ˡ": "l", "ᵐ": "m", "ᵒ": "o", "ᵖ": "p", "ʳ": "r",
        "ˢ": "s", "ᵗ": "t", "ᵘ": "u", "ᵛ": "v", "ʷ": "w",
        "ˣ": "x", "ʸ": "y", "ᶻ": "z"
    ]

    private func footnoteMarkdownLine(from text: String, fallbackLabel: String, forcedLabel: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "[^\(forcedLabel ?? fallbackLabel)]:"
        }

        // When the user specified a marker via the layout rule, use it as the label and
        // treat the full OCR text as the definition body (stripping any leading marker chars).
        if let label = forcedLabel, !label.isEmpty {
            // Strip a leading superscript or ASCII-digit prefix that OCR may have captured.
            let body = strippingLeadingMarker(from: trimmed)
            return "[^\(label)]: \(body.isEmpty ? trimmed : body)"
        }

        // Auto-detect: match superscript prefix characters (¹²³…) at the start of the line.
        var superLabel = ""
        var bodyStart = trimmed.startIndex
        for idx in trimmed.indices {
            let ch = trimmed[idx]
            if let mapped = Self.superscriptLabelMap[ch] {
                superLabel += mapped
                bodyStart = trimmed.index(after: idx)
            } else {
                break
            }
        }
        if !superLabel.isEmpty {
            let body = String(trimmed[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return "[^\(superLabel)]: \(body.isEmpty ? trimmed : body)"
        }

        // Fallback: match ASCII digit/symbol prefix (e.g. "1.", "1)", "*", "†").
        let pattern = #"^([0-9๐-๙]+|[*†‡])[\.)\]\s]*(.*)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
           match.numberOfRanges >= 3,
           let labelRange = Range(match.range(at: 1), in: trimmed),
           let bodyRange = Range(match.range(at: 2), in: trimmed) {
            let label = String(trimmed[labelRange])
            let body = String(trimmed[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return "[^\(label)]: \(body.isEmpty ? trimmed : body)"
        }

        return "[^\(fallbackLabel)]: \(trimmed)"
    }

    // Strips a leading superscript-digit or ASCII-digit prefix from text so it is not
    // duplicated in the footnote body when a forcedLabel is already provided.
    private func strippingLeadingMarker(from text: String) -> String {
        var idx = text.startIndex
        // Skip superscript chars
        while idx < text.endIndex, Self.superscriptLabelMap[text[idx]] != nil {
            idx = text.index(after: idx)
        }
        if idx > text.startIndex {
            return String(text[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Skip ASCII digit + optional separator
        let pattern = #"^[0-9๐-๙]+[\.)\]\s]*"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let range = Range(match.range, in: text) {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func hasDetectedBlankLineGap(between previousLine: OCRLine, and currentLine: OCRLine, averageHeight: CGFloat) -> Bool {
        let verticalGap = previousLine.bottom - currentLine.top
        guard verticalGap > 0 else { return false }
        return verticalGap >= max(averageHeight * 1.35, 0.026)
    }

    private func applyMarkdownTitle(_ title: String, to markdown: String, replaceExistingHeading: Bool) -> String {
        let cleanTitle = normalizedMarkdownTitle(title)
        guard !cleanTitle.isEmpty else {
            return markdown
        }

        let heading = "## \(cleanTitle)"
        let trimmedMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMarkdown.isEmpty else {
            return heading
        }

        var lines = trimmedMarkdown.components(separatedBy: .newlines)
        let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if replaceExistingHeading,
           firstLine.hasPrefix("#"),
           isNumericMarkdownTitle(cleanTitle) {
            return trimmedMarkdown
        }

        if replaceExistingHeading, firstLine.hasPrefix("#") {
            lines[0] = heading
            return lines.joined(separator: "\n")
        }

        if firstLine == heading {
            return trimmedMarkdown
        }

        return "\(heading)\n\n\(trimmedMarkdown)"
    }

    private func normalizedMarkdownTitle(_ title: String) -> String {
        var cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleanTitle.first == "#" {
            cleanTitle.removeFirst()
        }
        return cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isNumericMarkdownTitle(_ title: String) -> Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { thaiDigitValue($0).map(String.init) ?? String($0) }
            .joined()
        return !normalized.isEmpty && normalized.allSatisfy { $0.isNumber }
    }

    private func isCenteredBodyPage(
        lines: [OCRLine],
        normalLeft: CGFloat,
        normalWidth: CGFloat,
        blockCenter: CGFloat,
        indentThreshold: CGFloat
    ) -> Bool {
        guard lines.count >= 3, normalWidth > 0 else {
            return false
        }

        let centerThreshold = max(0.04, normalWidth * 0.12)
        let indentedCount = lines.filter { ($0.left - normalLeft) >= indentThreshold }.count
        let centeredCount = lines.filter { abs($0.centerX - blockCenter) <= centerThreshold }.count
        let shortCount = lines.filter { $0.width <= normalWidth * 0.92 }.count

        return indentedCount == 0
            && Double(centeredCount) / Double(lines.count) >= 0.70
            && Double(shortCount) / Double(lines.count) >= 0.70
    }

    private func isHeadingLine(
        _ line: OCRLine,
        index: Int,
        lines: [OCRLine],
        normalWidth: CGFloat,
        blockCenter: CGFloat,
        averageHeight: CGFloat
    ) -> Bool {
        guard index <= 1, normalWidth > 0 else {
            return false
        }

        // Dialogue lines start with a quote and are never chapter headings.
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoteStarts: [Character] = ["\"", "'", "\u{201C}", "\u{2018}", "\u{201E}", "\u{00AB}", "\u{300C}"]
        guard !quoteStarts.contains(where: { text.hasPrefix(String($0)) }) else { return false }

        let isNearTop = line.centerX.isFinite && line.bottom >= 0.42
        let headingWidthLimit = index == 0 ? normalWidth * 0.74 : normalWidth * 0.65
        let isShort = line.width <= headingWidthLimit
        let isCentered = abs(line.centerX - blockCenter) <= max(0.04, normalWidth * 0.12)
        let nextLine = lines.indices.contains(index + 1) ? lines[index + 1] : nil
        let previousLine = lines.indices.contains(index - 1) ? lines[index - 1] : nil
        let followsChapterNumber = previousLine.map {
            isChapterNumberHeadingLine(
                $0,
                index: index - 1,
                lines: lines,
                normalWidth: normalWidth,
                blockCenter: blockCenter,
                averageHeight: averageHeight
            )
        } ?? false
        let followsCenteredTitleLine = previousLine.map {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !isPageNumberLine($0.text)
                && $0.width <= normalWidth * 0.65
                && abs($0.centerX - blockCenter) <= max(0.04, normalWidth * 0.12)
                && $0.bottom >= 0.42
        } ?? false
        // A real chapter heading has a gap below it. Requiring hasLargeGapBelow even for
        // index 0 prevents a short dialogue line at the top of a page from being misread
        // as a heading (dialogue is immediately followed by more text, no gap).
        let hasLargeGapBelow = nextLine.map { (line.bottom - $0.top) >= max(averageHeight * 1.8, 0.035) } ?? true

        return isNearTop && isShort && isCentered && (hasLargeGapBelow || followsChapterNumber || followsCenteredTitleLine)
    }

    private func isChapterNumberHeadingLine(
        _ line: OCRLine,
        index: Int,
        lines: [OCRLine],
        normalWidth: CGFloat,
        blockCenter: CGFloat,
        averageHeight: CGFloat
    ) -> Bool {
        guard index <= 4, normalWidth > 0 else {
            return false
        }

        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDigits = text
            .map { thaiDigitValue($0).map(String.init) ?? String($0) }
            .joined()
        guard !normalizedDigits.isEmpty,
              normalizedDigits.allSatisfy({ $0.isNumber }),
              normalizedDigits.count <= 3 else {
            return false
        }

        let isContentZone = line.top < 0.94 && line.bottom > 0.18
        let isShort = line.width <= max(normalWidth * 0.22, 0.08)
        let isCentered = abs(line.centerX - blockCenter) <= max(0.04, normalWidth * 0.12)
        let nextLine = lines.indices.contains(index + 1) ? lines[index + 1] : nil
        let hasGapBelow = nextLine.map { (line.bottom - $0.top) >= max(averageHeight * 1.5, 0.025) } ?? true

        return isContentZone && isShort && isCentered && hasGapBelow
    }

    private func buildContinuousParagraphs(from text: String) -> String {
        var paragraphs: [String] = []
        var current = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
            } else if rawLine.first?.isWhitespace == true && !current.isEmpty {
                paragraphs.append(current)
                current = line
            } else {
                current = joinContinuousLine(current, line)
            }
        }

        if !current.isEmpty {
            paragraphs.append(current)
        }

        return paragraphs.joined(separator: "\n\n")
    }

    private func joinContinuousLine(_ previous: String, _ current: String) -> String {
        guard !previous.isEmpty else { return current }
        guard !current.isEmpty else { return previous }

        if shouldJoinWithoutSpace(previous, current) {
            return previous + current
        }
        return previous + " " + current
    }

    private func shouldJoinWithoutSpace(_ previous: String, _ current: String) -> Bool {
        guard let previousCharacter = previous.trimmingCharacters(in: .whitespacesAndNewlines).last,
              let currentCharacter = current.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return false
        }
        return isThaiCharacter(previousCharacter) && isThaiCharacter(currentCharacter)
    }

    private func isThaiCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x0E00 && scalar.value <= 0x0E7F
        }
    }

    private func restore() {
        isRestoring = true

        currentStep = defaults.integer(forKey: "currentStep")
        if currentStep < 1 {
            currentStep = 1
        }

        selectedFolderPath = defaults.string(forKey: "selectedFolderPath") ?? ""
        selectedPDFPath = defaults.string(forKey: "selectedPDFPath") ?? ""
        ocrText = ""
        ocrParagraphSourcePages = []
        ocrParagraphHasOCRSourcePage = []
        skipProcessOCREngine = defaults.bool(forKey: "skipProcessOCREngine")
        filterTopLines = defaults.string(forKey: "filterTopLines") ?? "1"
        filterBottomLines = defaults.string(forKey: "filterBottomLines") ?? "1"
        filteredText = defaults.string(forKey: "filteredText") ?? ""
        ocrStatus = defaults.string(forKey: "ocrStatus") ?? "No OCR job has been sent yet."
        logOutput = ""
        pdfTitles = defaults.dictionary(forKey: "pdfTitles") as? [String: String] ?? [:]
        ocrPDFPreviewZoomPercents = loadDoubleDictionary(forKey: "ocrPDFPreviewZoomPercents")
        ocrPDFPreviewLastZoomPercent = min(max(defaults.double(forKey: "ocrPDFPreviewLastZoomPercent"), 50), 220)
        frontCoverImagePath = defaults.string(forKey: "frontCoverImagePath") ?? ""
        backCoverImagePath = defaults.string(forKey: "backCoverImagePath") ?? ""
        epubStatus = ""

        isRestoring = false
        loadAppConfigValues()
        loadPDFFiles()
        refreshCoverImagePathsForSelectedFolder()
    }

    private func save() {
        defaults.set(currentStep, forKey: "currentStep")
        defaults.set(selectedFolderPath, forKey: "selectedFolderPath")
        defaults.set(selectedPDFPath, forKey: "selectedPDFPath")
        defaults.removeObject(forKey: "ocrText")
        defaults.set(skipProcessOCREngine, forKey: "skipProcessOCREngine")
        defaults.set(filterTopLines, forKey: "filterTopLines")
        defaults.set(filterBottomLines, forKey: "filterBottomLines")
        defaults.set(filteredText, forKey: "filteredText")
        defaults.set(ocrStatus, forKey: "ocrStatus")
        defaults.removeObject(forKey: "cloudVisionOutput")
        defaults.set(pdfTitles, forKey: "pdfTitles")
        defaults.set(ocrPDFPreviewZoomPercents, forKey: "ocrPDFPreviewZoomPercents")
        defaults.set(ocrPDFPreviewLastZoomPercent, forKey: "ocrPDFPreviewLastZoomPercent")
        defaults.set(frontCoverImagePath, forKey: "frontCoverImagePath")
        defaults.set(backCoverImagePath, forKey: "backCoverImagePath")
    }

    private func loadDoubleDictionary(forKey key: String) -> [String: Double] {
        guard let stored = defaults.dictionary(forKey: key) else {
            return [:]
        }
        return stored.reduce(into: [String: Double]()) { result, item in
            if let value = item.value as? Double {
                result[item.key] = value
            } else if let value = item.value as? NSNumber {
                result[item.key] = value.doubleValue
            } else if let value = item.value as? String,
                      let doubleValue = Double(value) {
                result[item.key] = doubleValue
            }
        }
    }

    private func loadPDFFiles() {
        guard !selectedFolderPath.isEmpty else {
            pdfFiles = []
            frontCoverImagePath = ""
            backCoverImagePath = ""
            return
        }

        let folderURL = URL(fileURLWithPath: selectedFolderPath)
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        let physicalItems = urls
            .filter(isSectionPDFURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { PDFFileItem(id: $0.path, url: $0) }

        let physicalByPath = Dictionary(uniqueKeysWithValues: physicalItems.map { ($0.url.path, $0) })
        let entries = loadBookSections()
        var orderedItems: [PDFFileItem] = []
        var usedPaths = Set<String>()
        var readyIDs = Set<String>()

        for entry in entries {
            if entry.type == "manual" {
                let url = manualSectionURL(id: entry.id)
                let item = PDFFileItem(id: url.path, url: url)
                orderedItems.append(item)
                usedPaths.insert(item.url.path)
                if let title = entry.title, !title.isEmpty {
                    pdfTitles[item.id] = title
                }
                if entry.readyForEPUB == true {
                    readyIDs.insert(item.id)
                }
            } else if let path = entry.path,
                      let item = physicalByPath[path] {
                orderedItems.append(item)
                usedPaths.insert(path)
                if let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    pdfTitles[item.id] = title
                }
                if entry.readyForEPUB == true {
                    readyIDs.insert(item.id)
                }
            }
        }

        for item in physicalItems where !usedPaths.contains(item.url.path) {
            orderedItems.append(item)
        }

        pdfFiles = orderedItems
        epubReadySectionIDs = readyIDs
    }

    private func appleVisionOutputFolderURL(for pdfURL: URL) -> URL {
        pdfURL
            .deletingLastPathComponent()
            .appendingPathComponent("AppleVision", isDirectory: true)
            .appendingPathComponent("MD", isDirectory: true)
    }

    private func bookSectionsURL() -> URL? {
        guard !selectedFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: selectedFolderPath).appendingPathComponent("book-sections.json")
    }

    private func bookSectionsURL(for projectFolderURL: URL) -> URL {
        projectFolderURL.appendingPathComponent("book-sections.json")
    }

    private func manualSectionURL(id: String) -> URL {
        URL(fileURLWithPath: selectedFolderPath)
            .appendingPathComponent("ManualSections", isDirectory: true)
            .appendingPathComponent(id)
            .appendingPathExtension("manual")
    }

    private func loadBookSections() -> [BookSectionEntry] {
        guard let url = bookSectionsURL(),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([BookSectionEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func loadBookSections(from projectFolderURL: URL) -> [BookSectionEntry] {
        let url = bookSectionsURL(for: projectFolderURL)
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([BookSectionEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func saveBookSections() {
        guard let url = bookSectionsURL() else { return }
        let entries = pdfFiles.map { item -> BookSectionEntry in
            let title = pdfTitles[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isManualSection {
                return BookSectionEntry(
                    id: item.url.deletingPathExtension().lastPathComponent,
                    type: "manual",
                    path: nil,
                    title: title,
                    readyForEPUB: epubReadySectionIDs.contains(item.id)
                )
            }
            return BookSectionEntry(
                id: item.url.deletingPathExtension().lastPathComponent,
                type: "pdf",
                path: item.url.path,
                title: title,
                readyForEPUB: epubReadySectionIDs.contains(item.id)
            )
        }

        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            logOutput = "Could not save book sections: \(error.localizedDescription)"
        }
    }

    private func saveDetectedSplitTitles(_ savedTitles: [(URL, String)], projectFolderURL: URL) {
        let titleByFile = savedTitles.reduce(into: [String: String]()) { result, item in
            let title = item.1.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            result[item.0.lastPathComponent] = title
        }
        guard !titleByFile.isEmpty else { return }

        let existingEntries = loadBookSections(from: projectFolderURL)
        let existingByPath = Dictionary(uniqueKeysWithValues: existingEntries.compactMap { entry -> (String, BookSectionEntry)? in
            guard let path = entry.path else { return nil }
            return (path, entry)
        })
        let existingByID = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.id, $0) })

        let sectionEntries = sectionPDFURLs(in: projectFolderURL).map { url -> BookSectionEntry in
            let id = url.deletingPathExtension().lastPathComponent
            let existing = existingByPath[url.path] ?? existingByID[id]
            let title = titleByFile[url.lastPathComponent] ?? existing?.title
            return BookSectionEntry(
                id: id,
                type: "pdf",
                path: url.path,
                title: title,
                readyForEPUB: existing?.readyForEPUB ?? false
            )
        }

        let existingPDFIDs = Set(sectionEntries.map(\.id))
        let manualEntries = existingEntries.filter { entry in
            entry.type == "manual" || (entry.type == "pdf" && !existingPDFIDs.contains(entry.id) && entry.path == nil)
        }
        let entries = sectionEntries + manualEntries

        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: bookSectionsURL(for: projectFolderURL), options: .atomic)
        } catch {
            logOutput = "Could not save detected split titles: \(error.localizedDescription)"
        }
    }

    private func projectFolderMatchesSelected(_ projectFolderURL: URL) -> Bool {
        guard !selectedFolderPath.isEmpty else { return false }
        let selectedURL = URL(fileURLWithPath: selectedFolderPath, isDirectory: true)
        return selectedURL.standardizedFileURL.path == projectFolderURL.standardizedFileURL.path
            || selectedURL.resolvingSymlinksInPath().path == projectFolderURL.resolvingSymlinksInPath().path
    }

    private func removeSplitPlanEntry(forFile fileName: String) {
        guard !selectedFolderPath.isEmpty else { return }
        let projectFolderURL = URL(fileURLWithPath: selectedFolderPath, isDirectory: true)
        let planURL = splitPlanURL(for: projectFolderURL)
        guard let data = try? Data(contentsOf: planURL),
              var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ranges = payload["splitRanges"] as? [[String: Any]] else {
            return
        }

        payload["splitRanges"] = ranges.filter { item in
            (item["file"] as? String) != fileName
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: planURL, options: .atomic)
        } catch {
            logOutput = "Could not update split plan: \(error.localizedDescription)"
        }
    }

    private func loadAppConfigValues() {
        let values = readKeyValueConfig(from: configFileURL)
        newProjectsFolderPath = expandedPath(values["NEW_PROJECTS_FOLDER"] ?? "~/Downloads")
        pdfListMinHeight = CGFloat(parseDouble(values["PDF_LIST_MIN_HEIGHT"], defaultValue: 420, minimum: 200))
        layoutPreviewZoomDefault = CGFloat(parseDouble(values["LAYOUT_PREVIEW_ZOOM"], defaultValue: 75, minimum: 25)) / 100.0
        shouldOpenMainWindowFullScreen = (values["MAIN_WINDOW_WIDTH"] ?? "FULL").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "FULL"
        if !shouldOpenMainWindowFullScreen {
            mainWindowWidth = CGFloat(parseDouble(values["MAIN_WINDOW_WIDTH"], defaultValue: 780, minimum: 640))
            mainWindowHeight = CGFloat(parseDouble(values["MAIN_WINDOW_HEIGHT"], defaultValue: 520, minimum: 480))
        }
        ocrRenderScale = CGFloat(min(parseDouble(values["OCR_RENDER_SCALE"], defaultValue: 4.0, minimum: 1.0), 8.0))
        ocrParagraphTextAreaMinHeight = CGFloat(parseDouble(values["OCR_PARAGRAPH_TEXTAREA_MIN_HEIGHT"], defaultValue: 58, minimum: 40))
        ocrTitleMatchTopLineCount = Int(parseDouble(values["OCR_TITLE_MATCH_TOP_LINES"], defaultValue: 3, minimum: 0))
        previewTextScalePercent = min(parseDouble(values["PREVIEW_TEXT_SCALE_PERCENT"], defaultValue: 170, minimum: 80), 220)
        footnotePopupFontPercent = min(parseDouble(values["FOOTNOTE_POPUP_FONT_PERCENT"], defaultValue: 120, minimum: 60), 300)
        shouldOpenOCRWindowFullScreen = (values["OCR_WINDOW_WIDTH"] ?? "FULL").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "FULL"
        if !shouldOpenOCRWindowFullScreen {
            ocrWindowWidth = CGFloat(parseDouble(values["OCR_WINDOW_WIDTH"], defaultValue: 820, minimum: 640))
            ocrWindowHeight = CGFloat(parseDouble(values["OCR_WINDOW_HEIGHT"], defaultValue: 620, minimum: 480))
        }
        let cropPDFWindowWidthValue = values["CROP_PDF_WINDOW_WIDTH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? "FULL"
        shouldOpenCropPDFWindowFullScreen = cropPDFWindowWidthValue == "FULL"
        if !shouldOpenCropPDFWindowFullScreen {
            cropPDFWindowWidth = CGFloat(parseDouble(values["CROP_PDF_WINDOW_WIDTH"], defaultValue: 920, minimum: 760))
            cropPDFWindowHeight = CGFloat(parseDouble(values["CROP_PDF_WINDOW_HEIGHT"], defaultValue: 720, minimum: 560))
        }
        let addSplitWindowWidthValue = values["ADD_SPLIT_WINDOW_WIDTH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? "FULL"
        shouldOpenAddSplitWindowFullScreen = addSplitWindowWidthValue == "FULL"
        if !shouldOpenAddSplitWindowFullScreen {
            addSplitWindowWidth = CGFloat(parseDouble(values["ADD_SPLIT_WINDOW_WIDTH"], defaultValue: 920, minimum: 760))
            addSplitWindowHeight = CGFloat(parseDouble(values["ADD_SPLIT_WINDOW_HEIGHT"], defaultValue: 720, minimum: 560))
        }
        codexFinalizePromptFile = values["CODEX_FINALIZE_PROMPT_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "codex-finalize-prompt.txt"
        codexFinalizeMaxSections = max(1, Int(parseDouble(values["CODEX_FINALIZE_MAX_SECTIONS"], defaultValue: 5, minimum: 1)))
        codexExecutablePath = values["CODEX_EXECUTABLE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "/Applications/Codex.app/Contents/Resources/codex"
        codexFinalizeModel = values["CODEX_FINALIZE_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? defaultCodexFinalizeModel
    }

    private func readKeyValueConfig(from url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || !line.contains("=") {
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)] =
                String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values
    }

    private func parseDouble(_ value: String?, defaultValue: Double, minimum: Double) -> Double {
        guard let value, let parsed = Double(value), parsed >= minimum else {
            return defaultValue
        }
        return parsed
    }

}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            StepOneLoadPDFView()
        }
        .frame(
            minWidth: appState.shouldOpenMainWindowFullScreen ? 1180 : max(1180, appState.mainWindowWidth),
            minHeight: appState.shouldOpenMainWindowFullScreen ? 520 : appState.mainWindowHeight
        )
        .background(NewOCRMainPalette.windowBackground)
        .buttonStyle(NewOCRButtonStyle())
        .onAppear {
            DispatchQueue.main.async {
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first,
                      let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
                    return
                }
                if appState.shouldOpenMainWindowFullScreen {
                    window.setFrame(visibleFrame, display: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }
}

private struct ClearInitialFirstResponderView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !context.coordinator.didClear else { return }
        context.coordinator.didClear = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            nsView.window?.makeFirstResponder(nil)
        }
    }

    final class Coordinator {
        var didClear = false
    }
}

struct NewOCRButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NewOCRButtonStyleBody(configuration: configuration)
    }
}

struct SectionActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SectionActionButtonStyleBody(configuration: configuration)
    }
}

private enum NewOCRMainPalette {
    static let windowBackground = Color(nsColor: NSColor(calibratedWhite: 0.22, alpha: 1))
    static let panelBackground = Color(nsColor: NSColor(calibratedWhite: 0.27, alpha: 1))
    static let headerBackground = Color(nsColor: NSColor(calibratedWhite: 0.24, alpha: 1))
    static let rowBackground = Color(nsColor: NSColor(calibratedWhite: 0.33, alpha: 1))
    static let alternateRowBackground = Color(nsColor: NSColor(calibratedWhite: 0.29, alpha: 1))
    static let fieldBackground = Color(nsColor: NSColor(calibratedWhite: 0.20, alpha: 1))
    static let stroke = Color.white.opacity(0.16)
    static let primaryText = Color.white.opacity(0.92)
    static let headingText = Color.white.opacity(0.98)
    static let secondaryText = Color.white.opacity(0.74)
    static let tertiaryText = Color.white.opacity(0.58)
}

private enum OCRTypography {
    static let editorFontSize: CGFloat = 18
    static let editorInset = NSSize(width: 10, height: 9)
}

private enum MainTypography {
    static let headingSize: CGFloat = 22
    static let bodySize: CGFloat = 14
    static let buttonSize: CGFloat = 17
    static let smallSize: CGFloat = 15
    static let badgeSize: CGFloat = 16
    static let iconSize: CGFloat = 21
}

private struct SectionActionButtonStyleBody: View {
    let configuration: SectionActionButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var foregroundColor: Color {
        isEnabled ? .black : Color.black.opacity(0.34)
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return Color.white.opacity(0.42)
        }
        if configuration.isPressed {
            return Color.white.opacity(0.76)
        }
        if isHovered {
            return Color.white
        }
        return Color.white.opacity(0.92)
    }

    private var borderColor: Color {
        if !isEnabled {
            return Color.black.opacity(0.10)
        }
        return Color.black.opacity(isHovered || configuration.isPressed ? 0.34 : 0.18)
    }

    var body: some View {
        configuration.label
            .font(.system(size: MainTypography.smallSize, weight: .semibold))
            .labelStyle(.iconOnly)
            .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .frame(width: 46, height: 36)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(isEnabled ? (isHovered ? 0.12 : 0.07) : 0),
                radius: isHovered ? 5 : 3,
                x: 0,
                y: isHovered ? 2 : 1
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
            .modifier(PointingHandCursorModifier(isEnabled: isEnabled))
    }
}

private struct SectionIconButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    var backgroundColor: Color = Color.white.opacity(0.92)
    var foregroundColor: Color = Color.black
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: MainTypography.smallSize, weight: .semibold))
                .foregroundStyle(isDisabled ? foregroundColor.opacity(0.34) : foregroundColor)
                .frame(width: 46, height: 36)
                .background(isDisabled ? backgroundColor.opacity(0.42) : backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.black.opacity(isDisabled ? 0.10 : 0.18), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .frame(width: 46, height: 36)
        .background(FloatingTooltip(title: title, isEnabled: !isDisabled))
        .accessibilityLabel(title)
        .onHover { isHovering in
            guard !isDisabled else { return }
            if isHovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            if !isDisabled {
                NSCursor.arrow.set()
            }
        }
    }
}

private struct NewOCRLargeCheckboxButton: View {
    let title: String
    @Binding var isChecked: Bool
    var checkedColor: Color = Color(red: 53/255, green: 200/255, blue: 90/255)
    @State private var isHovered = false

    var body: some View {
        Button {
            isChecked.toggle()
        } label: {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(isChecked ? checkedColor : Color.white.opacity(0.88))
                .frame(width: 46, height: 36)
                .background(isHovered ? Color.white.opacity(0.16) : Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isChecked ? checkedColor.opacity(0.72) : NewOCRMainPalette.stroke, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(isHovered ? 0.13 : 0.06), radius: isHovered ? 6 : 3, x: 0, y: isHovered ? 2 : 1)
        }
        .buttonStyle(.plain)
        .frame(width: 46, height: 36)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
        .help(title)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            if isHovered {
                NSCursor.arrow.set()
                isHovered = false
            }
        }
    }
}

private let detectSplitSelectionBlue = Color(red: 72/255, green: 168/255, blue: 255/255)

private struct SectionReadyCheckboxButton: View {
    @Binding var isReady: Bool

    var body: some View {
        NewOCRLargeCheckboxButton(
            title: isReady ? "Ready for EPUB" : "Not ready for EPUB",
            isChecked: $isReady
        )
    }
}

private struct SectionUtilityCircleButton: View {
    let title: String
    let systemImage: String
    let backgroundColor: Color
    var foregroundColor: Color = Color.black
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: MainTypography.smallSize, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 46, height: 36)
                .background(isHovered ? backgroundColor.opacity(0.86) : backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.black.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(isHovered ? 0.13 : 0.06), radius: isHovered ? 6 : 3, x: 0, y: isHovered ? 2 : 1)
        }
        .buttonStyle(.plain)
        .frame(width: 46, height: 36)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
        .help(title)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            if isHovered {
                NSCursor.arrow.set()
                isHovered = false
            }
        }
    }
}

private struct SectionFileNameButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: MainTypography.bodySize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(NewOCRMainPalette.primaryText)
        .contentShape(Rectangle())
        .accessibilityLabel("Open PDF")
        .help("Open PDF")
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            if isHovered {
                NSCursor.arrow.set()
                isHovered = false
            }
        }
    }
}

private struct NewOCRButtonStyleBody: View {
    let configuration: NewOCRButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var isDestructive: Bool {
        configuration.role == .destructive
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return Color(nsColor: .disabledControlTextColor)
        }
        if isDestructive {
            return .red
        }
        return NewOCRMainPalette.primaryText
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return Color(nsColor: .controlBackgroundColor).opacity(0.45)
        }
        if configuration.isPressed {
            return isDestructive ? Color.red.opacity(0.16) : Color.accentColor.opacity(0.18)
        }
        if isHovered {
            return isDestructive ? Color.red.opacity(0.10) : Color.accentColor.opacity(0.10)
        }
        return NewOCRMainPalette.panelBackground
    }

    private var borderColor: Color {
        if !isEnabled {
            return Color(nsColor: .separatorColor).opacity(0.7)
        }
        if isDestructive {
            return Color.red.opacity(isHovered || configuration.isPressed ? 0.48 : 0.28)
        }
        return Color.accentColor.opacity(isHovered || configuration.isPressed ? 0.82 : 0.52)
    }

    var body: some View {
        configuration.label
            .font(.system(size: MainTypography.buttonSize, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .minFrame(width: 34, height: 30)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(isEnabled && isHovered ? 0.08 : 0),
                radius: 5,
                x: 0,
                y: 2
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
            .modifier(PointingHandCursorModifier(isEnabled: isEnabled))
    }
}

// NSView subclass that uses NSTrackingArea for reliable hover detection.
// SwiftUI's .onHover is unreliable when combined with .popover() because
// the popover lives in a separate NSPanel, breaking SwiftUI's hover tracking.
private class HoverTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let new = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(new)
        trackingArea = new
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

private struct HoverArea: NSViewRepresentable {
    var onEnter: () -> Void
    var onExit: () -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        HoverTrackingView()
    }

    func updateNSView(_ nsView: HoverTrackingView, context: Context) {
        // Always update closures so they capture the freshest state bindings.
        nsView.onEnter = onEnter
        nsView.onExit = onExit
    }
}

private class TooltipHostView: NSView {
    var title: String = ""
    var isEnabled: Bool = true {
        didSet {
            if !isEnabled {
                closePopover()
            }
        }
    }
    private var trackingArea: NSTrackingArea?
    private var popover: NSPopover?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let new = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(new)
        trackingArea = new
    }

    override func mouseEntered(with event: NSEvent) {
        showPopover()
    }

    override func mouseExited(with event: NSEvent) {
        closePopover()
    }

    private func showPopover() {
        guard isEnabled, !title.isEmpty, popover?.isShown != true else { return }
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let contentWidth = ceil(min(max(72, textWidth + 24), 360))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white)
        )
        popover.contentSize = NSSize(width: contentWidth, height: 32)
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    private func closePopover() {
        popover?.close()
        popover = nil
    }
}

private struct FloatingTooltip: NSViewRepresentable {
    let title: String
    let isEnabled: Bool

    func makeNSView(context: Context) -> TooltipHostView {
        TooltipHostView()
    }

    func updateNSView(_ nsView: TooltipHostView, context: Context) {
        nsView.title = title
        nsView.isEnabled = isEnabled
    }
}

// Reference-type controller so DispatchWorkItem can be cancelled without
// reading any SwiftUI state inside an async closure.
private final class MenuHoverController {
    private var closeItem: DispatchWorkItem?

    func cancelClose() {
        closeItem?.cancel()
        closeItem = nil
    }

    func scheduleClose(after delay: Double = 0.08, action: @escaping () -> Void) {
        cancelClose()
        let item = DispatchWorkItem(block: action)
        closeItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

private struct TopBarDropdownMenu<Content: View>: View {
    let id: String
    let title: String
    let systemImage: String
    @Binding var activeMenuID: String?
    @ViewBuilder let content: (_ close: @escaping () -> Void) -> Content
    // @State keeps the same controller instance across re-renders.
    @State private var ctrl = MenuHoverController()

    private var isPresentedBinding: Binding<Bool> {
        Binding {
            activeMenuID == id
        } set: { newValue in
            if !newValue, activeMenuID == id { activeMenuID = nil }
        }
    }

    var body: some View {
        Button {
            activeMenuID = activeMenuID == id ? nil : id
        } label: {
            Label(title, systemImage: systemImage)
        }
        .controlSize(.large)
        .background(
            HoverArea {
                ctrl.cancelClose()
                activeMenuID = id
            } onExit: {
                ctrl.scheduleClose {
                    if activeMenuID == id { activeMenuID = nil }
                }
            }
        )
        .popover(isPresented: isPresentedBinding, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                content {
                    if activeMenuID == id { activeMenuID = nil }
                }
            }
            .padding(8)
            .frame(minWidth: 230, alignment: .leading)
            .background(NewOCRMainPalette.panelBackground)
            .background(
                HoverArea {
                    ctrl.cancelClose()
                } onExit: {
                    ctrl.scheduleClose {
                        if activeMenuID == id { activeMenuID = nil }
                    }
                }
            )
        }
    }
}

private struct TopBarDropdownRow: View {
    let title: String
    let systemImage: String
    var isDisabled: Bool = false
    var isDestructive: Bool = false
    let close: () -> Void
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    private var foregroundColor: Color {
        if isDisabled {
            return NewOCRMainPalette.tertiaryText
        }
        if isDestructive && (isHovered || isPressed) {
            return Color.white
        }
        if isDestructive {
            return Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.56, blue: 0.56, alpha: 1))
        }
        return NewOCRMainPalette.primaryText
    }

    private var highlightColor: Color {
        if isDisabled {
            return Color.clear
        }
        if isPressed {
            return isDestructive ? Color(nsColor: NSColor(calibratedRed: 0.92, green: 0.36, blue: 0.36, alpha: 1)) : Color.white.opacity(0.30)
        }
        if isHovered {
            return isDestructive ? Color(nsColor: NSColor(calibratedRed: 0.98, green: 0.48, blue: 0.48, alpha: 1)) : Color.white.opacity(0.22)
        }
        return Color.clear
    }

    var body: some View {
        Button {
            guard !isDisabled else { return }
            action()
            close()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: MainTypography.bodySize, weight: .semibold))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: MainTypography.bodySize, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlightColor)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !isDisabled else { return }
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
                isPressed = false
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isDisabled {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    isPressed = false
                }
        )
    }
}

private struct TopBarDropdownDivider: View {
    var body: some View {
        Rectangle()
            .fill(NewOCRMainPalette.stroke)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

private extension View {
    func minFrame(width: CGFloat, height: CGFloat) -> some View {
        frame(minWidth: width, minHeight: height)
    }

    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier(isEnabled: true))
    }
}

struct StepOneLoadPDFView: View {
    @EnvironmentObject private var appState: AppState
    @State private var activeTopBarMenuID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.94))
                                .frame(width: 58, height: 58)
                                .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                            Image(systemName: "doc.text.viewfinder")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(Color.black)
                        }
                        ProjectPathView(path: appState.selectedFolderPath)
                            .frame(maxWidth: 320, alignment: .leading)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 10) {
                        TopBarDropdownMenu(
                            id: "project",
                            title: "Project",
                            systemImage: "folder",
                            activeMenuID: $activeTopBarMenuID
                        ) { close in
                            TopBarDropdownRow(title: "New", systemImage: "plus", close: close) {
                                appState.newSplitPlan()
                            }

                            TopBarDropdownRow(title: "Open", systemImage: "folder", close: close) {
                                appState.chooseFolder()
                            }

                            TopBarDropdownDivider()

                            if appState.canOpenSplitPlannerForSelectedFolder {
                                TopBarDropdownRow(
                                    title: "Revert Original",
                                    systemImage: "arrow.uturn.backward",
                                    isDestructive: true,
                                    close: close
                                ) {
                                    appState.confirmAndRevertSelectedFolderToOriginalPDF()
                                }
                            }

                            TopBarDropdownRow(title: "Open Config", systemImage: "gearshape", close: close) {
                                appState.openConfigEditor()
                            }

                            if appState.bookEPUBFilePathIfExists != nil {
                                TopBarDropdownDivider()

                                TopBarDropdownRow(title: "View EPUB", systemImage: "eye", close: close) {
                                    appState.openBuiltEPUBFile()
                                }
                            }
                        }

                        TopBarDropdownMenu(
                            id: "edit-pdf",
                            title: "Edit PDF",
                            systemImage: "slider.horizontal.3",
                            activeMenuID: $activeTopBarMenuID
                        ) { close in
                            if appState.canOpenSplitPlannerForSelectedFolder {
                                TopBarDropdownRow(title: "Crop", systemImage: "crop", close: close) {
                                    appState.openSelectedFolderCropPDF()
                                }

                                TopBarDropdownRow(
                                    title: "Add Split",
                                    systemImage: "rectangle.split.2x1",
                                    isDisabled: !appState.canAddSplitForSelectedFolder,
                                    close: close
                                ) {
                                    appState.openSelectedFolderAddSplit()
                                }
                            }

                            TopBarDropdownRow(
                                title: "Define Layout",
                                systemImage: "rectangle.dashed",
                                isDisabled: !appState.canDefineLayoutForSelectedFolder,
                                close: close
                            ) {
                                appState.openLayoutAreasEditor()
                            }

                            TopBarDropdownRow(
                                title: "Apply CSS",
                                systemImage: "paintbrush",
                                isDisabled: appState.selectedFolderPath.isEmpty,
                                close: close
                            ) {
                                appState.applyStylesheet()
                            }

                            TopBarDropdownDivider()

                            TopBarDropdownRow(
                                title: "Clear Scan Report",
                                systemImage: "trash",
                                isDisabled: appState.selectedFolderPath.isEmpty || appState.isHeaderFooterScanRunning,
                                isDestructive: true,
                                close: close
                            ) {
                                appState.clearAllHeaderFooterScans()
                            }
                        }

                        Button {
                            appState.buildBookEPUB()
                        } label: {
                            Label(appState.isOCRRunning ? "Building EPUB..." : "Build EPUB", systemImage: "book")
                        }
                        .controlSize(.large)
                        .disabled(appState.isOCRRunning || appState.markdownChapterCount == 0)

                        OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white) {
                            NSApp.terminate(nil)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("EPUB Covers")
                            .font(.system(size: MainTypography.bodySize, weight: .semibold))
                            .foregroundStyle(NewOCRMainPalette.headingText)

                        CoverSidebarView()
                            .environmentObject(appState)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Sections")
                                .font(.system(size: MainTypography.headingSize, weight: .semibold))
                                .foregroundStyle(NewOCRMainPalette.headingText)
                            Text("\(appState.pdfFiles.count)")
                                .font(.system(size: MainTypography.badgeSize, weight: .semibold))
                                .foregroundStyle(NewOCRMainPalette.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.12))
                                .clipShape(Capsule())
                            SectionIconButton(
                                title: "Process OCR All",
                                systemImage: "square.stack.3d.up.fill",
                                isDisabled: !appState.canProcessOCRAllSections
                            ) {
                                appState.processOCRAllSections()
                            }
                            SectionIconButton(
                                title: "Scan Header All",
                                systemImage: "text.viewfinder",
                                isDisabled: !appState.canScanHeaderAllSections,
                                backgroundColor: Color.brown.opacity(0.92),
                                foregroundColor: Color.white
                            ) {
                                appState.scanHeaderFooterAllSections()
                            }
                            SectionIconButton(
                                title: "Clear All OCR",
                                systemImage: "trash.fill",
                                isDisabled: !appState.canClearAllOCR,
                                backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255),
                                foregroundColor: Color.white
                            ) {
                                appState.clearAllOCR()
                            }
                            Spacer()
                        }

                        if appState.isHeaderFooterScanRunning {
                            HStack(spacing: 10) {
                                ProgressView(value: appState.headerFooterScanProgressPercent ?? 0, total: 100)
                                    .frame(maxWidth: .infinity)
                                Text("\(Int(appState.headerFooterScanProgressPercent ?? 0))%")
                                    .font(.system(size: MainTypography.smallSize, weight: .medium, design: .monospaced))
                                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                                    .frame(width: 42, alignment: .trailing)
                            }
                            Text(appState.headerFooterScanStatus)
                                .font(.system(size: MainTypography.smallSize, weight: .medium))
                                .foregroundStyle(NewOCRMainPalette.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        PDFListView()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(22)
        .sheet(isPresented: $appState.isConfigEditorPresented) {
            ConfigEditorView()
                .environmentObject(appState)
        }
        .alert(appState.cssApplyAlertTitle, isPresented: $appState.isCSSAppliedAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.cssApplyAlertMessage)
        }
        .sheet(isPresented: $appState.isBulkOCRProgressPresented) {
            BulkOCRProgressView()
                .environmentObject(appState)
        }
        .overlay {
            if appState.isPreparingLayoutThumbnails {
                Color.black.opacity(0.50)
                    .ignoresSafeArea()
                VStack(spacing: 22) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.94))
                            .frame(width: 58, height: 58)
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Color.black)
                    }
                    Text("Preparing Layout Thumbnails")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    Text(appState.layoutThumbnailProgress)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if appState.layoutThumbnailProgressTotal > 0 {
                        VStack(spacing: 6) {
                            ProgressView(value: Double(appState.layoutThumbnailProgressCurrent),
                                         total: Double(appState.layoutThumbnailProgressTotal))
                                .progressViewStyle(.linear)
                                .frame(width: 280)
                                .tint(Color(red: 30/255, green: 139/255, blue: 238/255))
                            Text("\(appState.layoutThumbnailProgressCurrent) / \(appState.layoutThumbnailProgressTotal) pages")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(NewOCRMainPalette.secondaryText)
                        }
                    }
                }
                .padding(32)
                .background(NewOCRMainPalette.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.30), radius: 24, x: 0, y: 8)
                .frame(maxWidth: 380)
            }
        }
        .overlay {
            if appState.isEPUBBuiltAlertPresented || appState.isLayoutRefreshConfirmationPresented || appState.isCropResetConfirmationPresented || appState.isClearOCRConfirmationPresented || appState.isClearAllOCRConfirmationPresented {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()
            }

            if appState.isEPUBBuiltAlertPresented {
                VStack(spacing: 18) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.94))
                                .frame(width: 44, height: 44)
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Color(red: 53/255, green: 200/255, blue: 90/255))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("EPUB was created successfully")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(NewOCRMainPalette.headingText)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            appState.openBuiltEPUBInBooks()
                        } label: {
                            Label("Open", systemImage: "book")
                        }

                        Button("Close") {
                            appState.isEPUBBuiltAlertPresented = false
                        }
                    }
                    .buttonStyle(NewOCRButtonStyle())
                }
                .padding(22)
                .frame(minWidth: 430, maxWidth: 560)
                .background(NewOCRMainPalette.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
            }

            if appState.isLayoutRefreshConfirmationPresented {
                LayoutRefreshConfirmationView()
                    .environmentObject(appState)
            }

            if appState.isCropResetConfirmationPresented {
                CropResetConfirmationView()
                    .environmentObject(appState)
            }

            if appState.isClearOCRConfirmationPresented {
                ClearOCRConfirmationView()
                    .environmentObject(appState)
            }

            if appState.isClearAllOCRConfirmationPresented {
                ClearAllOCRConfirmationView()
                    .environmentObject(appState)
            }
        }
        .background(NewOCRMainPalette.windowBackground)
    }
}

private struct CropResetConfirmationView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "crop")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Prepare PDF for Cropping?")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    Text("Cropping changes the page layout used by existing split sections.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("This project already contains section PDF files.", systemImage: "doc.richtext")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("OK removes all section files and generated OCR resources so the project can be cropped cleanly.", systemImage: "trash")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("Close leaves the project unchanged.", systemImage: "xmark.circle")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
            }
            .font(.system(size: 15, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NewOCRMainPalette.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )

            HStack(spacing: 12) {
                Spacer()

                OCRIconButton(
                    title: "OK",
                    systemImage: "checkmark",
                    backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255),
                    foregroundColor: .black,
                    size: 42
                ) {
                    appState.confirmCropResetAndOpenCrop()
                }
                .keyboardShortcut(.defaultAction)

                OCRIconButton(
                    title: "Close",
                    systemImage: "xmark",
                    backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255),
                    foregroundColor: .white,
                    size: 42
                ) {
                    appState.closeCropResetConfirmation()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
        .buttonStyle(NewOCRButtonStyle())
    }
}

private struct LayoutRefreshConfirmationView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color(red: 255/255, green: 169/255, blue: 48/255))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Refresh Existing OCR Data?")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    Text("Defining layout areas changes how OCR output is generated.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("This project already contains OCR output or PDF sections marked Ready for EPUB.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("OK removes existing PDF-section OCR Markdown, images, OCR snapshots, and line-cache data.", systemImage: "arrow.clockwise")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("Ready for EPUB flags are reset so the sections can be processed again.", systemImage: "checkmark.square")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
            }
            .font(.system(size: 15, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NewOCRMainPalette.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )

            HStack(spacing: 12) {
                Spacer()

                OCRIconButton(
                    title: "OK",
                    systemImage: "checkmark",
                    backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255),
                    foregroundColor: .black,
                    size: 42
                ) {
                    appState.confirmLayoutRefreshAndOpenEditor()
                }
                .keyboardShortcut(.defaultAction)

                OCRIconButton(
                    title: "Close",
                    systemImage: "xmark",
                    backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255),
                    foregroundColor: .white,
                    size: 42
                ) {
                    appState.closeLayoutRefreshConfirmation()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
        .buttonStyle(NewOCRButtonStyle())
    }
}

private struct ClearAllOCRConfirmationView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "trash.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color(red: 255/255, green: 71/255, blue: 71/255))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Clear All OCR?")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    Text("OCR Markdown files and resources will be removed for all sections.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Removes `AppleVision/MD/<section>/` for every section.", systemImage: "trash")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("Removes all pure OCR snapshots from `OriginalOCR/` folders.", systemImage: "doc.text")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("Removes all line-cache entries for all sections.", systemImage: "line.3.horizontal")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("Resets the Ready for EPUB flag for all sections.", systemImage: "checkmark.square")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("Preserves header/footer review file for future processing.", systemImage: "checkmark.circle")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
            }
            .font(.system(size: 15, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NewOCRMainPalette.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )

            HStack(spacing: 12) {
                Spacer()

                OCRIconButton(
                    title: "Clear All",
                    systemImage: "checkmark",
                    backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255),
                    foregroundColor: .black,
                    size: 42
                ) {
                    appState.confirmClearAllOCRAndProceed()
                }
                .keyboardShortcut(.defaultAction)

                OCRIconButton(
                    title: "Close",
                    systemImage: "xmark",
                    backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255),
                    foregroundColor: .white,
                    size: 42
                ) {
                    appState.closeClearAllOCRConfirmation()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
        .buttonStyle(NewOCRButtonStyle())
    }
}

private struct ClearOCRConfirmationView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color(red: 255/255, green: 71/255, blue: 71/255))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Clear OCR for \(appState.pendingClearOCRItem.map { appState.sectionRemovalTitle(for: $0) } ?? "Section")?")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    Text("OCR Markdown files and resources will be removed.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Removes `AppleVision/MD/<section>/` directory with all Markdown files and images.", systemImage: "trash")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("Removes the pure OCR snapshot from `OriginalOCR/` folder.", systemImage: "doc.text")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("Removes line-cache entries for this section.", systemImage: "line.3.horizontal")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("Resets the Ready for EPUB flag to unchecked.", systemImage: "checkmark.square")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Label("Preserves header/footer review file for future processing.", systemImage: "checkmark.circle")
                    .foregroundStyle(NewOCRMainPalette.primaryText)
            }
            .font(.system(size: 15, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NewOCRMainPalette.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )

            HStack(spacing: 12) {
                Spacer()

                OCRIconButton(
                    title: "Clear",
                    systemImage: "checkmark",
                    backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255),
                    foregroundColor: .black,
                    size: 42
                ) {
                    appState.confirmClearOCRAndProceed()
                }
                .keyboardShortcut(.defaultAction)

                OCRIconButton(
                    title: "Close",
                    systemImage: "xmark",
                    backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255),
                    foregroundColor: .white,
                    size: 42
                ) {
                    appState.closeClearOCRConfirmation()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
        .buttonStyle(NewOCRButtonStyle())
    }
}

private struct LayoutAreasReportView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var isPresented: Bool
    var state: LayoutAreaEditorState? = nil
    var sectionFileName: String? = nil
    var onView: ((OCRLayoutAreaRule) -> Void)? = nil
    var isAutoOnly: Bool = false
    @State private var rules: [OCRLayoutAreaRule] = []
    @State private var isLoading = true
    @State private var pendingDeleteRule: OCRLayoutAreaRule?
    @State private var isDeleteConfirmationPresented = false

    private var typeColors: [String: Color] {
        [
            "header": Color(red: 30/255, green: 139/255, blue: 238/255),
            "h2": Color(red: 50/255, green: 160/255, blue: 240/255),
            "header3": Color(red: 100/255, green: 180/255, blue: 255/255),
            "blockquote": Color(red: 255/255, green: 182/255, blue: 216/255),
            "image": Color(red: 255/255, green: 152/255, blue: 0/255),
            "image_desc": Color(red: 255/255, green: 200/255, blue: 80/255),
            "footnote": Color(red: 120/255, green: 220/255, blue: 100/255),
            "refmark": Color(red: 160/255, green: 100/255, blue: 240/255),
            "ignore": Color.red.opacity(0.8)
        ]
    }

    private var typeIcons: [String: String] {
        [
            "header": "book.closed",
            "h2": "textformat.size",
            "header3": "textformat.size.smaller",
            "blockquote": "quote.bubble",
            "image": "photo",
            "image_desc": "captions.bubble.fill",
            "footnote": "text.badge.plus",
            "refmark": "textformat.superscript",
            "ignore": "eye.slash"
        ]
    }

    private var typeLabels: [String: String] {
        [
            "header": "Section Title",
            "h2": "H2",
            "header3": "H3",
            "blockquote": "Quote",
            "image": "Image",
            "image_desc": "Image Description",
            "footnote": "Footnote",
            "refmark": "Ref Mark",
            "ignore": "Ignore"
        ]
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.94))
                            .frame(width: 58, height: 58)
                            .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Color.black)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Layout Area Rules")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(NewOCRMainPalette.headingText)
                        if let sectionFileName {
                            Text(sectionFileName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(NewOCRMainPalette.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(sortedRules.count) rule\(sortedRules.count == 1 ? "" : "s") for this section")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(NewOCRMainPalette.secondaryText)
                        } else {
                            Text("\(sortedRules.count) rule\(sortedRules.count == 1 ? "" : "s") saved")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(NewOCRMainPalette.secondaryText)
                        }
                    }

                    Spacer()

                    OCRIconButton(
                        title: "Close",
                        systemImage: "xmark",
                        backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255),
                        foregroundColor: .white,
                        size: 42
                    ) {
                        isPresented = false
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(22)
                .border(width: 1, edges: [.bottom], color: NewOCRMainPalette.stroke)

                if isLoading {
                    VStack {
                        ProgressView()
                            .foregroundStyle(NewOCRMainPalette.primaryText)
                        Text("Loading rules...")
                            .foregroundStyle(NewOCRMainPalette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(22)
                } else if rules.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 40))
                            .foregroundStyle(NewOCRMainPalette.tertiaryText)
                        Text("No Layout Area Rules")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NewOCRMainPalette.primaryText)
                        Text(sectionFileName != nil ? "No rules apply to this section" : "Define and save layout areas to see them here")

                            .font(.system(size: 13))
                            .foregroundStyle(NewOCRMainPalette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(22)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(sortedRules.enumerated()), id: \.offset) { index, rule in
                                LayoutAreaRuleRow(
                                    rule: rule,
                                    typeColor: typeColors[rule.type] ?? .gray,
                                    typeIcon: typeIcons[rule.type] ?? "rectangle.dashed",
                                    typeLabel: typeLabels[rule.type] ?? rule.type,
                                    showLoadButton: state != nil && onView == nil,
                                    onView: onView != nil ? { onView?(rule) } : nil,
                                    onLoad: {
                                        state?.loadRule(rule)
                                        isPresented = false
                                    },
                                    onDelete: {
                                        pendingDeleteRule = rule
                                        isDeleteConfirmationPresented = true
                                    }
                                )
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(index.isMultiple(of: 2) ? NewOCRMainPalette.rowBackground : NewOCRMainPalette.alternateRowBackground)

                                if index < sortedRules.count - 1 {
                                    Divider()
                                        .overlay(NewOCRMainPalette.stroke)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NewOCRMainPalette.rowBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                        )
                        .padding(8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NewOCRMainPalette.panelBackground)
                }
            }
            .padding(22)
            .frame(minWidth: 500, minHeight: 400)
            .background(NewOCRMainPalette.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)

            if isDeleteConfirmationPresented {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.94))
                                .frame(width: 58, height: 58)
                                .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                            Image(systemName: "trash.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(Color.red)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Delete Layout Area Rule?")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(NewOCRMainPalette.headingText)
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(red: 255/255, green: 169/255, blue: 48/255))
                                Text("This action cannot be undone.")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color(red: 255/255, green: 169/255, blue: 48/255))
                            }
                        }

                        Spacer(minLength: 0)
                    }

                    if let rule = pendingDeleteRule {
                        DeleteRuleDetailView(rule: rule, typeIcon: typeIcons[rule.type] ?? "rectangle.dashed", typeLabel: typeLabels[rule.type] ?? rule.type)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NewOCRMainPalette.fieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                        )
                    }

                    HStack(spacing: 12) {
                        Spacer()

                        OCRIconButton(
                            title: "Cancel",
                            systemImage: "xmark",
                            backgroundColor: Color(red: 100/255, green: 100/255, blue: 105/255),
                            foregroundColor: .white,
                            size: 42
                        ) {
                            isDeleteConfirmationPresented = false
                            pendingDeleteRule = nil
                        }
                        .keyboardShortcut(.cancelAction)

                        OCRIconButton(
                            title: "Delete",
                            systemImage: "trash",
                            backgroundColor: Color.red,
                            foregroundColor: .white,
                            size: 42
                        ) {
                            if let rule = pendingDeleteRule {
                                deleteRule(for: rule)
                                isDeleteConfirmationPresented = false
                                pendingDeleteRule = nil
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(22)
                .frame(width: 560)
                .background(NewOCRMainPalette.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
                .buttonStyle(NewOCRButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NewOCRMainPalette.windowBackground)
        .onAppear {
            loadRules()
        }
    }

    private var filteredRules: [OCRLayoutAreaRule] {
        let base: [OCRLayoutAreaRule]
        if let sectionFileName {
            base = rules.filter { rule in
                rule.scope == "all_sections" || rule.section == sectionFileName
            }
        } else if let state {
            // When opened from Define Layout, state.pdfItems contains only non-completed
            // sections, so mirror that filter here.
            let visibleFiles = Set(state.pdfItems.map { $0.url.lastPathComponent })
            base = rules.filter { rule in
                rule.section == nil || visibleFiles.contains(rule.section ?? "")
            }
        } else {
            base = rules
        }
        return isAutoOnly ? base.filter { $0.isAuto == true } : base
    }

    private var sortedRules: [OCRLayoutAreaRule] {
        filteredRules.sorted { rule1, rule2 in
            let section1 = rule1.section ?? ""
            let section2 = rule2.section ?? ""

            if section1 != section2 {
                return section1.localizedStandardCompare(section2) == .orderedAscending
            }

            let page1 = rule1.page ?? 0
            let page2 = rule2.page ?? 0
            return page1 < page2
        }
    }

    private func loadRules() {
        isLoading = true
        DispatchQueue.global().async {
            let loaded = appState.loadAllLayoutAreaRules()
            DispatchQueue.main.async {
                rules = loaded
                isLoading = false
            }
        }
    }

    private func deleteRule(for rule: OCRLayoutAreaRule) {
        rules.removeAll { $0 == rule }
        try? appState.deleteLayoutAreaRule(rule)
    }
}

private struct LayoutAreaRuleRow: View {
    let rule: OCRLayoutAreaRule
    let typeColor: Color
    let typeIcon: String
    let typeLabel: String
    var showLoadButton: Bool = true
    var onView: (() -> Void)? = nil
    let onLoad: () -> Void
    let onDelete: () -> Void
    @State private var isDeleteHovered = false
    @State private var isLoadHovered = false
    @State private var isViewHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: typeIcon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(typeColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(typeLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.primaryText)

                HStack(spacing: 8) {
                    if rule.scope == "all_sections" {
                        Text("All Sections")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NewOCRMainPalette.secondaryText)
                    } else if let section = rule.section {
                        Text(section)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NewOCRMainPalette.secondaryText)

                        if let page = rule.page {
                            Text("Page \(page)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(NewOCRMainPalette.secondaryText)
                        }
                    }
                }

                if rule.type == "refmark" {
                    HStack(spacing: 6) {
                        if let m = rule.markers, !m.isEmpty {
                            Text("[^\(m)]")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color(red: 160/255, green: 100/255, blue: 240/255))
                        }
                        if let aw = rule.anchorWord, !aw.isEmpty {
                            Text("after \"\(aw)\"")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(NewOCRMainPalette.secondaryText)
                        }
                    }
                }

                if let codexText = rule.codexText, !codexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 100/255, green: 180/255, blue: 255/255))
                            .padding(.top, 1)
                        Text(codexText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(NewOCRMainPalette.primaryText)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .italic()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 40/255, green: 55/255, blue: 75/255))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(red: 60/255, green: 110/255, blue: 175/255).opacity(0.7), lineWidth: 1)
                    )
                    .padding(.top, 2)
                }
            }

            Spacer()

            if showLoadButton {
                Button(action: onLoad) {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .background(Color.blue.opacity(isLoadHovered ? 0.9 : 0.8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .help("Edit rule")
                .onHover { hovering in isLoadHovered = hovering }
            } else if let onView {
                Button(action: onView) {
                    Image(systemName: "eye")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .background(Color(red: 30/255, green: 160/255, blue: 160/255).opacity(isViewHovered ? 0.95 : 0.8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .help("Preview rule on page")
                .onHover { hovering in isViewHovered = hovering }
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .background(Color.red.opacity(isDeleteHovered ? 0.9 : 0.8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .help("Delete rule")
            .onHover { hovering in
                isDeleteHovered = hovering
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Border extension for splitting header and content
extension View {
    func border(width: CGFloat, edges: [Edge], color: Color) -> some View {
        overlay(alignment: .bottom) {
            if edges.contains(.bottom) {
                VStack {
                    Spacer()
                    color.frame(height: width)
                }
            }
        }
    }
}

private struct DeleteRuleDetailView: View {
    let rule: OCRLayoutAreaRule
    let typeIcon: String
    let typeLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: typeIcon)
                Text(typeLabel)
            }
            .foregroundStyle(NewOCRMainPalette.primaryText)

            if rule.scope == "all_sections" {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                    Text("All Sections")
                }
                .foregroundStyle(NewOCRMainPalette.primaryText)
            }
            if let section = rule.section {
                HStack(spacing: 8) {
                    Image(systemName: "doc.richtext")
                    Text(section)
                }
                .foregroundStyle(NewOCRMainPalette.primaryText)
            }
            if let pageNum = rule.page {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                    Text("Page " + String(pageNum))
                }
                .foregroundStyle(NewOCRMainPalette.primaryText)
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NewOCRMainPalette.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }
}

private struct DuplicateRuleWarningView: View {
    let duplicateRule: OCRLayoutAreaRule
    let onCancel: () -> Void
    let onContinue: () -> Void

    private let typeLabels: [String: String] = [
        "header": "Section Title",
        "h2": "H2",
        "header3": "H3",
        "blockquote": "Quote",
        "image": "Image",
        "image_desc": "Image Description",
        "footnote": "Footnote",
        "refmark": "Ref Mark",
        "ignore": "Ignore"
    ]

    private let typeIcons: [String: String] = [
        "header": "book.closed",
        "h2": "textformat.size",
        "header3": "textformat.size.smaller",
        "blockquote": "quote.bubble",
        "image": "photo",
        "image_desc": "captions.bubble.fill",
        "footnote": "text.badge.plus",
        "refmark": "textformat.superscript",
        "ignore": "eye.slash"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 1.0, green: 0.84, blue: 0.0).opacity(0.92))
                        .frame(width: 52, height: 52)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Duplicate Rule Found")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.primaryText)
                    Text("A similar rule with the same settings already exists")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Existing Rule:")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.secondaryText)

                HStack(spacing: 12) {
                    Image(systemName: typeIcons[duplicateRule.type] ?? "rectangle.dashed")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(red: 30/255, green: 139/255, blue: 238/255))
                        .frame(width: 40)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(typeLabels[duplicateRule.type] ?? duplicateRule.type)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NewOCRMainPalette.primaryText)

                        HStack(spacing: 6) {
                            if duplicateRule.scope != nil {
                                Text("All Sections")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                            } else if let section = duplicateRule.section {
                                Text(section)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(NewOCRMainPalette.secondaryText)

                                if let page = duplicateRule.page {
                                    Text("Page \(page)")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                                }
                            }
                        }
                    }

                    Spacer()
                }
                .padding(12)
                .background(NewOCRMainPalette.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
            }
            .padding(12)
            .background(NewOCRMainPalette.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )

            HStack(spacing: 12) {
                Spacer()

                OCRIconButton(
                    title: "Close",
                    systemImage: "xmark",
                    backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255),
                    foregroundColor: .white,
                    size: 42
                ) {
                    onCancel()
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
        .buttonStyle(NewOCRButtonStyle())
    }
}

struct BulkOCRProgressView: View {
    @EnvironmentObject private var appState: AppState

    private var progressValue: Double {
        guard appState.bulkOCRTotalCount > 0 else { return 0 }
        return Double(appState.bulkOCRCompletedCount) / Double(appState.bulkOCRTotalCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: appState.isBulkOCRFinished ? "checkmark.circle.fill" : "text.viewfinder")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(appState.isBulkOCRFinished ? .green : Color.accentColor)
                Text(appState.bulkOCRProgressTitle)
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            Text(appState.bulkOCRProgressMessage)
                .foregroundStyle(.secondary)

            if !appState.bulkOCRCurrentFile.isEmpty {
                HStack(spacing: 8) {
                    Text("File")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(appState.bulkOCRCurrentFile)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            ProgressView(value: progressValue)
                .progressViewStyle(.linear)

            HStack {
                Text("\(appState.bulkOCRCompletedCount) / \(appState.bulkOCRTotalCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if appState.isBulkOCRFinished {
                    Button("OK") {
                        appState.isBulkOCRProgressPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .buttonStyle(NewOCRButtonStyle())
    }
}

struct ConfigEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var closeAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: appState.isHeaderFooterReviewOpen ? "text.viewfinder" : "gearshape")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.configEditorTitle)
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    if !appState.isCodexFinalizeInstructionOpen {
                        Text(appState.configEditorPath)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(NewOCRMainPalette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                if !appState.isHeaderFooterReviewOpen {
                    OCRIconButton(title: "Save", systemImage: "square.and.arrow.down", backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255), foregroundColor: .black) {
                        appState.saveConfigFile()
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                }

                OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white) {
                    if let closeAction {
                        closeAction()
                    } else {
                        dismiss()
                    }
                }
            }

            if appState.isHeaderFooterReviewOpen {
                HeaderFooterReviewView()
                    .environmentObject(appState)
                    .frame(minWidth: 640, minHeight: 360)
            } else {
                TextEditor(text: $appState.configText)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                    .scrollContentBackground(.hidden)
                    .background(NewOCRMainPalette.fieldBackground)
                    .frame(minWidth: 640, minHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                    )
            }

            HStack {
                Text(appState.configStatus)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
        }
        .padding(22)
        .background(NewOCRMainPalette.windowBackground)
        .buttonStyle(NewOCRButtonStyle())
    }
}

struct FinalizeAIWindowView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var state: FinalizeAISelectionState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "sparkles")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex Review")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    Text("Select up to \(max(1, appState.codexFinalizeMaxSections)) sections")
                        .font(.system(size: MainTypography.smallSize, weight: .medium))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                }

                Spacer()

                OCRIconButton(title: "Codex Instruction", systemImage: "quote.bubble", backgroundColor: Color(red: 255/255, green: 182/255, blue: 216/255), foregroundColor: .black) {
                    appState.openCodexFinalizeInstruction()
                }
                .disabled(state.isRunning)

                OCRIconButton(
                    title: "Codex Log",
                    systemImage: "info.circle",
                    backgroundColor: Color(red: 60/255, green: 60/255, blue: 72/255),
                    foregroundColor: .white
                ) {
                    appState.openCodexFinalizeLogWindow(state: state)
                }

                OCRIconButton(
                    title: "Run Codex",
                    systemImage: "paperplane.fill",
                    backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255),
                    foregroundColor: .black
                ) {
                    appState.runCodexFinalize(for: state.selectedItems, state: state)
                }
                .disabled(state.selectedItems.isEmpty || state.isRunning)

                OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white) {
                    NSApp.keyWindow?.close()
                }
            }

            HStack(spacing: 10) {
                Text("\(state.selectedSectionCount) sections selected")
                    .font(.system(size: MainTypography.bodySize, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Text("Max \(max(1, appState.codexFinalizeMaxSections))")
                    .font(.system(size: MainTypography.smallSize, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
                Text(state.status)
                    .font(.system(size: MainTypography.smallSize, weight: .medium))
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(12)
            .background(NewOCRMainPalette.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(state.sectionTitles, id: \.self) { sectionTitle in
                        FinalizeAISectionGroup(
                            sectionTitle: sectionTitle,
                            items: state.items(in: sectionTitle),
                            state: state
                        )
                        .environmentObject(appState)
                    }
                }
                .padding(10)
            }
            .background(NewOCRMainPalette.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )
        }
        .padding(22)
        .frame(minWidth: 980, minHeight: 620)
        .background(NewOCRMainPalette.windowBackground)
        .buttonStyle(NewOCRButtonStyle())
    }
}

struct CodexFinalizeInstructionWindowView: View {
    @EnvironmentObject private var appState: AppState
    let promptURL: URL
    @State private var promptText = ""
    @State private var status = "AI instruction is ready."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                Text("Codex Finalize Instruction")
                    .font(.system(size: 31, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.headingText)

                Spacer()

                OCRIconButton(title: "Save", systemImage: "square.and.arrow.down", backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255), foregroundColor: .black) {
                    savePrompt()
                }
                .keyboardShortcut("s", modifiers: [.command])

                OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white) {
                    NSApp.keyWindow?.close()
                }
            }

            TextEditor(text: $promptText)
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(NewOCRMainPalette.primaryText)
                .scrollContentBackground(.hidden)
                .background(NewOCRMainPalette.fieldBackground)
                .frame(minWidth: 640, minHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )

            Text(status)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(NewOCRMainPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(22)
        .background(NewOCRMainPalette.windowBackground)
        .buttonStyle(NewOCRButtonStyle())
        .onAppear {
            promptText = (try? String(contentsOf: promptURL, encoding: .utf8)) ?? defaultCodexFinalizePrompt
            status = "Editing Codex instruction."
        }
    }

    private func savePrompt() {
        do {
            try promptText.write(to: promptURL, atomically: true, encoding: .utf8)
            status = "Saved Codex instruction."
            appState.configStatus = "Saved \(promptURL.lastPathComponent)."
        } catch {
            status = "Could not save Codex instruction: \(error.localizedDescription)"
        }
    }
}

struct CodexFinalizeLogWindowView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var state: FinalizeAISelectionState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "terminal")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Log")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    Text(state.isRunning ? "Running..." : state.status)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 10)

                OCRIconButton(
                    title: "Download Log",
                    systemImage: "arrow.down.doc",
                    backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255),
                    foregroundColor: .white
                ) {
                    if let url = state.savedLogURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(state.savedLogURL == nil)

                OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white) {
                    appState.closeCodexFinalizeLogWindow()
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if state.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(state.isRunning ? "Codex is running..." : (state.codexLog.isEmpty ? "No output yet. Run Codex to see progress here." : state.status))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(state.isRunning ? NewOCRMainPalette.secondaryText : NewOCRMainPalette.primaryText)
                        .lineLimit(2)
                    Spacer()
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(state.codexLog.isEmpty ? " " : state.codexLog)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(NewOCRMainPalette.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .id("logBottom")
                    }
                    .background(NewOCRMainPalette.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                    )
                    .onChange(of: state.codexLog) {
                        withAnimation {
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(NewOCRMainPalette.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 420)
        .background(NewOCRMainPalette.windowBackground)
        .buttonStyle(NewOCRButtonStyle())
    }
}

private struct FinalizeAISectionGroup: View {
    @EnvironmentObject private var appState: AppState
    let sectionTitle: String
    let items: [FinalizeAIFileItem]
    @ObservedObject var state: FinalizeAISelectionState

    private var isSelected: Bool {
        state.selectedSectionTitles.contains(sectionTitle)
    }

    private var sectionPDFItem: FinalizeAIFileItem? {
        items.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                NewOCRLargeCheckboxButton(
                    title: isSelected ? "Selected section for AI finalize" : "Not selected section for AI finalize",
                    isChecked: Binding(
                        get: { isSelected },
                        set: { _ in appState.toggleFinalizeAISection(sectionTitle, in: state) }
                    ),
                    checkedColor: Color(red: 30/255, green: 139/255, blue: 238/255)
                )
                .disabled(!isSelected && !appState.canSelectFinalizeAISection(sectionTitle, in: state))

                Image(systemName: "doc.richtext")
                    .font(.system(size: MainTypography.iconSize, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text(sectionTitle)
                    .font(.system(size: MainTypography.bodySize, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(items.count) pages")
                    .font(.system(size: MainTypography.smallSize, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                Text(isSelected ? "Selected" : "Not selected")
                    .font(.system(size: MainTypography.smallSize, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                SectionIconButton(
                    title: "Open PDF",
                    systemImage: "doc.richtext",
                    isDisabled: sectionPDFItem == nil,
                    backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255),
                    foregroundColor: .white
                ) {
                    if let sectionPDFItem {
                        appState.openFinalizeAIPDF(for: sectionPDFItem)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(NewOCRMainPalette.rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                ForEach(items) { item in
                    FinalizeAIFileRow(item: item, state: state)
                }
            }
        }
        .padding(10)
        .background(isSelected ? NewOCRMainPalette.fieldBackground.opacity(0.72) : NewOCRMainPalette.fieldBackground.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color(red: 30/255, green: 139/255, blue: 238/255) : NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }
}

private struct FinalizeAIFileRow: View {
    @EnvironmentObject private var appState: AppState
    let item: FinalizeAIFileItem
    @ObservedObject var state: FinalizeAISelectionState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: MainTypography.iconSize, weight: .semibold))
                .foregroundStyle(NewOCRMainPalette.secondaryText)
                .frame(width: 46, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.system(size: MainTypography.bodySize, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.folderPath)
                    .font(.system(size: MainTypography.smallSize, weight: .medium))
                    .foregroundStyle(NewOCRMainPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            SectionIconButton(
                title: "Preview",
                systemImage: "eye",
                isDisabled: false,
                backgroundColor: Color.orange.opacity(0.92),
                foregroundColor: .black
            ) {
                appState.previewFinalizeAIFile(item)
            }

            SectionIconButton(
                title: "Show Files",
                systemImage: "folder",
                isDisabled: false,
                backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255),
                foregroundColor: .white
            ) {
                appState.openFinalizeAIFolder(for: item)
            }
        }
        .padding(12)
        .background(NewOCRMainPalette.fieldBackground.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }
}

struct HeaderFooterReviewView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Approved Remove Items")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.headingText)

                if appState.headerFooterReviewRemoveItems.isEmpty {
                    Text("No remove items.")
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                } else {
                    ForEach(appState.headerFooterReviewRemoveItems, id: \.self) { item in
                        HStack(spacing: 10) {
                            Text(item)
                                .font(.system(size: 16, design: .monospaced))
                                .foregroundStyle(NewOCRMainPalette.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            OCRIconButton(title: "Remove", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white) {
                                appState.removeHeaderFooterReviewItem(item)
                            }
                        }
                        .padding(11)
                        .background(NewOCRMainPalette.fieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                        )
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }
}

struct ProjectPathView: View {
    let path: String

    private var isEmpty: Bool {
        path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var folderName: String {
        guard !isEmpty else { return "No project folder selected" }
        return URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isEmpty ? "folder.badge.questionmark" : "folder.fill")
                .font(.system(size: MainTypography.iconSize, weight: .semibold))
                .foregroundStyle(isEmpty ? NewOCRMainPalette.tertiaryText : Color.white.opacity(0.92))
                .frame(width: 22)

            Text(folderName)
                .font(.system(size: MainTypography.bodySize, weight: .semibold))
                .foregroundStyle(isEmpty ? NewOCRMainPalette.secondaryText : NewOCRMainPalette.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture {
            guard !isEmpty else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        }
        .modifier(PointingHandCursorModifier(isEnabled: !isEmpty))
        .help(isEmpty ? "No project folder selected" : "Open project folder")
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                guard isEnabled else { return }
                if isHovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .onDisappear {
                if isEnabled {
                    NSCursor.arrow.set()
                }
            }
        }
}

struct PDFListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var autoScrolledFolderPath = ""
    @State private var autoScrolledTargetID: String?
    private let sectionTableWidth: CGFloat = 1118

    private var sectionIDsSignature: String {
        appState.pdfFiles.map(\.id).joined(separator: "\n")
    }

    private var readySectionIDsSignature: String {
        appState.epubReadySectionIDs.sorted().joined(separator: "\n")
    }

    private func scrollToFirstNotReadySection(with proxy: ScrollViewProxy, force: Bool = false) {
        guard let targetID = appState.firstNotReadySectionID else { return }
        guard force || autoScrolledFolderPath != appState.selectedFolderPath || autoScrolledTargetID != targetID else { return }
        autoScrolledFolderPath = appState.selectedFolderPath
        autoScrolledTargetID = targetID
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(targetID, anchor: .top)
            }
        }
    }

    var body: some View {
        Group {
            if appState.selectedFolderPath.isEmpty {
                EmptyStateView(title: "Choose a folder to load PDF files.")
            } else if appState.pdfFiles.isEmpty {
                VStack(spacing: 12) {
                    EmptyStateView(title: "No sections found in this folder.")
                        .frame(minHeight: 180)
                    Button {
                        appState.addManualSectionAtEnd()
                    } label: {
                        Label("Add Section", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .controlSize(.large)
                    .padding(.bottom, 16)
                }
            } else {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(appState.pdfFiles.enumerated()), id: \.element.id) { index, item in
                                    SectionListRowView(item: item, index: index, totalCount: appState.pdfFiles.count)
                                }
                            }
                            .frame(width: sectionTableWidth)
                            .background(NewOCRMainPalette.rowBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                            )
                            .padding(8)
                        }
                        .onAppear {
                            scrollToFirstNotReadySection(with: proxy)
                        }
                        .onChange(of: appState.selectedFolderPath) { _, _ in
                            autoScrolledFolderPath = ""
                            autoScrolledTargetID = nil
                            scrollToFirstNotReadySection(with: proxy, force: true)
                        }
                        .onChange(of: sectionIDsSignature) { _, _ in
                            scrollToFirstNotReadySection(with: proxy)
                        }
                        .onChange(of: readySectionIDsSignature) { _, _ in
                            scrollToFirstNotReadySection(with: proxy)
                        }
                    }
                }
                .frame(width: sectionTableWidth)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: appState.pdfListMinHeight, maxHeight: .infinity)
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(0.05),
            radius: 8,
            x: 0,
            y: 3
        )
    }
}

struct CoverSidebarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverRowView(
                title: "Front",
                systemImage: "photo",
                path: appState.frontCoverImagePath
            ) {
                appState.chooseFrontCoverImage()
            }

            CoverRowView(
                title: "Back",
                systemImage: "photo.on.rectangle",
                path: appState.backCoverImagePath
            ) {
                appState.chooseBackCoverImage()
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 145)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }
}

struct CoverRowView: View {
    let title: String
    let systemImage: String
    let path: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .font(.system(size: MainTypography.smallSize, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .pointingHandCursor()

            CoverThumbnailView(path: path)
        }
    }
}

struct CoverThumbnailView: View {
    let path: String

    var body: some View {
        Group {
            if !path.isEmpty, let image = NSImage(contentsOfFile: path) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 68, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Open cover image")
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(NewOCRMainPalette.tertiaryText)
                    .frame(width: 68, height: 88)
                    .background(NewOCRMainPalette.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                    )
            }
        }
    }
}

struct EmptyStateView: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 34))
                .foregroundStyle(NewOCRMainPalette.tertiaryText)
            Text(title)
                .foregroundStyle(NewOCRMainPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SplitViewAutosaver: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            var candidate: NSView? = view.superview
            while let v = candidate {
                if let split = v as? NSSplitView, split.autosaveName != name {
                    split.autosaveName = name
                    return
                }
                candidate = v.superview
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct StepTwoOCRView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isFilesPopoverPresented = false
    @State private var isMarkdownInfoPopoverPresented = false
    @State private var isSearchInfoPopoverPresented = false
    @State private var isReplacePopoverPresented = false
    @State private var isSaveAlertPresented = false
    @State private var windowToCloseAfterSave: NSWindow?
    @State private var replacementText = ""
    @State private var isViewRulesPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 48, height: 48)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                Text("OCR")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.headingText)

                Rectangle()
                    .fill(NewOCRMainPalette.stroke)
                    .frame(width: 1, height: 32)
                    .padding(.horizontal, 4)

                // OCR action buttons
                OCRIconButton(title: "Files", systemImage: "folder", backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255), foregroundColor: .white) {
                    isFilesPopoverPresented.toggle()
                }
                .popover(isPresented: $isFilesPopoverPresented) {
                    FilesPopoverView().environmentObject(appState)
                }

                OCRIconButton(title: "View Rules", systemImage: "list.bullet.rectangle", backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255), foregroundColor: .white) {
                    isViewRulesPresented = true
                }
                .disabled(appState.selectedPDFPath.isEmpty)
                .sheet(isPresented: $isViewRulesPresented) {
                    LayoutAreasReportView(
                        isPresented: $isViewRulesPresented,
                        sectionFileName: appState.selectedPDFFileItem?.url.lastPathComponent
                    )
                    .environmentObject(appState)
                }

                OCRIconButton(title: "Run OCR", systemImage: appState.isOCRRunning ? "hourglass" : "text.viewfinder", backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255)) {
                    appState.sendSelectedPDFToOCREngine()
                }
                .disabled(appState.isOCRRunning || appState.selectedPDFPath.isEmpty || appState.selectedItemIsManualSection)

                OCRIconButton(title: "Log", systemImage: "terminal", backgroundColor: Color.white.opacity(0.92)) {
                    appState.openOCRLogWindow()
                }

                if appState.isOCRRunning {
                    OCRIconButton(title: appState.isOCRCancelling ? "Cancelling" : "Cancel OCR", systemImage: "stop.fill", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255)) {
                        appState.cancelOCR()
                    }
                    .disabled(appState.isOCRCancelling)
                }

                Rectangle()
                    .fill(NewOCRMainPalette.stroke)
                    .frame(width: 1, height: 32)
                    .padding(.horizontal, 4)

                // File chip
                Button {
                    if !appState.selectedPDFPath.isEmpty && !appState.selectedItemIsManualSection {
                        NSWorkspace.shared.open(URL(fileURLWithPath: appState.selectedPDFPath))
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: appState.selectedItemIsManualSection ? "doc.text" : "doc.richtext")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(appState.selectedItemIsManualSection ? "Manual Section" : "Ready for OCR")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(NewOCRMainPalette.secondaryText)
                            Text(appState.selectedPDFName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(NewOCRMainPalette.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(NewOCRMainPalette.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(NewOCRMainPalette.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Open PDF")
                .disabled(appState.selectedPDFPath.isEmpty || appState.selectedItemIsManualSection)
                .frame(maxWidth: .infinity)

                // Inline progress
                if appState.isOCRRunning {
                    HStack(spacing: 6) {
                        ProgressView(value: appState.ocrProgressPercent ?? 0, total: 100)
                            .frame(width: 90)
                        Text("\(Int(appState.ocrProgressPercent ?? 0))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(NewOCRMainPalette.secondaryText)
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                Rectangle()
                    .fill(NewOCRMainPalette.stroke)
                    .frame(width: 1, height: 32)
                    .padding(.horizontal, 4)

                // Window action buttons
                OCRIconButton(title: "Markdown syntax", systemImage: "info.circle", backgroundColor: Color(red: 255/255, green: 182/255, blue: 216/255)) {
                    isMarkdownInfoPopoverPresented.toggle()
                }
                .popover(isPresented: $isMarkdownInfoPopoverPresented) {
                    MarkdownSyntaxPopoverView()
                }

                OCRIconButton(title: "Preview", systemImage: "eye", backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255), foregroundColor: .white) {
                    appState.openOCRMarkdownPreviewWindow()
                }
                .disabled(appState.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.localAppleVisionOutputFolderPathIfExists == nil)

                OCRIconButton(title: "Compare", systemImage: "doc.text.magnifyingglass", backgroundColor: Color(red: 255/255, green: 182/255, blue: 216/255)) {
                    if let item = appState.selectedPDFFileItem {
                        appState.openOCRCompareReport(for: item)
                    }
                }
                .disabled(
                    appState.selectedPDFFileItem.map { item in
                        item.isManualSection || !appState.pureOCRSnapshotExists(for: item)
                    } ?? true
                )

                OCRIconButton(title: "Save", systemImage: "square.and.arrow.down", backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255)) {
                    windowToCloseAfterSave = NSApp.keyWindow
                    if appState.saveOCRTextFile() {
                        isSaveAlertPresented = true
                    } else {
                        windowToCloseAfterSave = nil
                    }
                }
                .disabled(appState.isOCRRunning || appState.selectedPDFPath.isEmpty || appState.localAppleVisionOutputFolderPathIfExists == nil)

                OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white) {
                    appState.closeOCRWindowsAndPreview(NSApp.keyWindow)
                }
            }

            HSplitView {
                markdownPane
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    .background(SplitViewAutosaver(name: "NewOCR.ocrEditorSplit"))

                sidePane
                    .frame(minWidth: 260, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(22)
        .overlay {
            if isSaveAlertPresented {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.94))
                                .frame(width: 44, height: 44)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Color(red: 53/255, green: 200/255, blue: 90/255))
                        }

                        Text(appState.ocrSaveAlertMessage)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(NewOCRMainPalette.headingText)
                    }

                    HStack(spacing: 10) {
                        OCRIconButton(
                            title: "Mark Completed",
                            systemImage: "checkmark.square.fill",
                            backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255),
                            size: 38
                        ) {
                            appState.markSelectedSectionReadyForEPUB()
                            isSaveAlertPresented = false
                            appState.closeOCRWindowsAndPreview(windowToCloseAfterSave)
                            windowToCloseAfterSave = nil
                        }
                        .disabled(!appState.selectedSectionCanBeMarkedReady)

                        Button("OK") {
                            isSaveAlertPresented = false
                            windowToCloseAfterSave = nil
                        }

                        Button("Close") {
                            isSaveAlertPresented = false
                            appState.closeOCRWindowsAndPreview(windowToCloseAfterSave)
                            windowToCloseAfterSave = nil
                        }
                    }
                    .buttonStyle(NewOCRButtonStyle())
                }
                .padding(22)
                .frame(minWidth: 340)
                .background(NewOCRMainPalette.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
            }
        }
        .buttonStyle(NewOCRButtonStyle())
        .background(NewOCRMainPalette.windowBackground)
    }

    private var markdownPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if appState.localAppleVisionOutputFolderPathIfExists != nil {
                HStack(spacing: 8) {
                    Text(appState.shouldUsePlainOCRTextEditor ? "\(appState.ocrText.count) characters" : "\(appState.ocrParagraphs.count) paragraphs")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                    OCRMarkdownPresenceBadge(label: "Image", systemImage: "photo", exists: appState.hasOCRMarkdownImages) {
                        appState.focusFirstOCRMarkdownImage()
                    }
                    OCRMarkdownPresenceBadge(label: "Footnote", systemImage: "text.badge.plus", exists: appState.hasOCRMarkdownFootnotes) {
                        appState.focusFirstOCRMarkdownFootnote()
                    }
                    OCRMarkdownPresenceBadge(label: "Blockquote", systemImage: "quote.bubble", exists: appState.hasOCRMarkdownBlockquotes) {
                        appState.focusFirstOCRMarkdownBlockquote()
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.66))
                        TextField("Search Text", text: $appState.ocrSearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .tint(Color.yellow)
                            .disabled(appState.ocrText.isEmpty)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.black.opacity(0.18), lineWidth: 1)
                    )

                    OCRIconButton(title: "Replace", systemImage: "arrow.triangle.2.circlepath", backgroundColor: Color(red: 255/255, green: 182/255, blue: 216/255), size: 34) {
                        replacementText = ""
                        isReplacePopoverPresented = true
                    }
                    .disabled(appState.ocrText.isEmpty || appState.ocrSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .popover(isPresented: $isReplacePopoverPresented) {
                        replacePopover
                    }

                    OCRIconButton(title: "Remove Search", systemImage: "xmark.circle", backgroundColor: Color.white.opacity(0.92), size: 34) {
                        appState.ocrSearchText = ""
                    }
                    .disabled(appState.ocrSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    OCRIconButton(title: "Information", systemImage: "questionmark.circle", backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255), foregroundColor: .white, size: 34) {
                        isSearchInfoPopoverPresented.toggle()
                    }
                    .popover(isPresented: $isSearchInfoPopoverPresented) {
                        OCRSearchGuidelinePopoverView()
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(NewOCRMainPalette.panelBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )

                Text(appState.ocrSearchResultText.isEmpty ? " " : appState.ocrSearchResultText)
                    .font(.caption)
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if appState.shouldUsePlainOCRTextEditor {
                    PlainOCRTextEditorView()
                        .environmentObject(appState)
                        .frame(minHeight: 360, maxHeight: .infinity)
                } else {
                    ParagraphEditorView()
                        .environmentObject(appState)
                        .frame(minHeight: 360, maxHeight: .infinity)
                }
            } else {
                EmptyStateView(title: "Markdown will appear after OCR creates it.")
                    .frame(minHeight: 360, maxHeight: .infinity)
                    .background(NewOCRMainPalette.panelBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                    )
            }
        }
        .padding(10)
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }


    private var sidePane: some View {
        OCRPDFPreviewPanel()
            .environmentObject(appState)
            .padding(.leading, 14)
    }

    private var replacePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace All")
                .font(.headline)

            HStack(spacing: 8) {
                Text("Replace To:")
                    .font(.subheadline.weight(.semibold))
                TextField("Replacement text", text: $replacementText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isReplacePopoverPresented = false
                }
                Button("Replace") {
                    _ = appState.replaceAllOCRSearchMatches(with: replacementText)
                    isReplacePopoverPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

struct OCRPDFPreviewPanel: View {
    @EnvironmentObject private var appState: AppState
    @State private var pageIndex = 0

    private var pdfURL: URL? {
        guard !appState.selectedPDFPath.isEmpty,
              !appState.selectedItemIsManualSection,
              FileManager.default.fileExists(atPath: appState.selectedPDFPath) else {
            return nil
        }
        return URL(fileURLWithPath: appState.selectedPDFPath)
    }

    private var pageCount: Int {
        guard let pdfURL,
              let document = PDFDocument(url: pdfURL) else {
            return 0
        }
        return document.pageCount
    }

    private var safePageIndex: Int {
        min(max(pageIndex, 0), max(pageCount - 1, 0))
    }

    private var zoomPercent: Double {
        appState.ocrPDFPreviewZoomPercent(for: appState.selectedPDFPath)
    }

    private func setZoomPercent(_ value: Double) {
        appState.setOCRPDFPreviewZoomPercent(value, for: appState.selectedPDFPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OCRIconButton(title: "Previous Page", systemImage: "chevron.up", backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255), foregroundColor: .white, size: 34) {
                    pageIndex = max(safePageIndex - 1, 0)
                }
                .disabled(pageCount <= 1 || safePageIndex <= 0)

                Text(pageCount > 0 ? "Page \(safePageIndex + 1) / \(pageCount)" : "Page 0 / 0")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                    .frame(minWidth: 96)

                OCRIconButton(title: "Next Page", systemImage: "chevron.down", backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255), foregroundColor: .white, size: 34) {
                    pageIndex = min(safePageIndex + 1, max(pageCount - 1, 0))
                }
                .disabled(pageCount <= 1 || safePageIndex >= pageCount - 1)

                Spacer(minLength: 0)

                if appState.isOCRRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                OCRIconButton(title: "Zoom Out", systemImage: "minus.magnifyingglass", backgroundColor: Color.white.opacity(0.92), size: 34) {
                    setZoomPercent(zoomPercent - 15)
                }
                .disabled(pdfURL == nil || zoomPercent <= 50)

                Text("\(Int(zoomPercent))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                    .frame(width: 44, alignment: .trailing)

                OCRIconButton(title: "Zoom In", systemImage: "plus.magnifyingglass", backgroundColor: Color.white.opacity(0.92), size: 34) {
                    setZoomPercent(zoomPercent + 15)
                }
                .disabled(pdfURL == nil || zoomPercent >= 220)
            }
            .onReceive(appState.$ocrPDFPreviewPageRequestID) { requestID in
                guard requestID > 0, pageCount > 0 else { return }
                pageIndex = min(max(appState.ocrPDFPreviewPageRequestIndex, 0), pageCount - 1)
            }

            if let pdfURL, pageCount > 0 {
                OCRPDFPreviewView(
                    url: pdfURL,
                    pageIndex: $pageIndex,
                    zoomScale: zoomPercent / 100
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
                .onChange(of: appState.selectedPDFPath) { _, _ in
                    pageIndex = 0
                }
            } else {
                EmptyStateView(title: appState.selectedItemIsManualSection ? "Manual section has no PDF preview." : "No PDF preview available.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NewOCRMainPalette.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                    )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }
}

struct OCRPDFPreviewView: NSViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    let zoomScale: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = DraggablePDFView()
        context.coordinator.pdfView = pdfView
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayBox = .cropBox
        pdfView.autoScales = false
        pdfView.backgroundColor = NSColor(calibratedWhite: 0.20, alpha: 1)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pdfViewPageChanged(_:)),
            name: Notification.Name.PDFViewPageChanged,
            object: pdfView
        )
        return pdfView
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: Notification.Name.PDFViewPageChanged, object: pdfView)
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.pageIndex = $pageIndex
        let draggablePDFView = pdfView as? DraggablePDFView
        if context.coordinator.url != url {
            context.coordinator.url = url
            context.coordinator.document = PDFDocument(url: url)
            draggablePDFView?.resetRememberedHorizontalOrigin()
            pdfView.document = context.coordinator.document
        }

        guard let document = context.coordinator.document,
              document.pageCount > 0 else {
            pdfView.document = nil
            return
        }

        let clampedIndex = min(max(pageIndex, 0), document.pageCount - 1)
        draggablePDFView?.rememberCurrentHorizontalOriginIfNeeded()

        if let page = document.page(at: clampedIndex), pdfView.currentPage !== page {
            context.coordinator.isProgrammaticPageChange = true
            pdfView.go(to: page)
            context.coordinator.isProgrammaticPageChange = false
        }

        DispatchQueue.main.async {
            let fitScale = max(pdfView.scaleFactorForSizeToFit, 0.1)
            let targetScale = min(max(fitScale * zoomScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
            if abs(pdfView.scaleFactor - targetScale) > 0.01 {
                pdfView.scaleFactor = targetScale
            }
            draggablePDFView?.restoreRememberedHorizontalOrigin()
        }
    }

    final class Coordinator {
        var url: URL?
        var document: PDFDocument?
        weak var pdfView: PDFView?
        var pageIndex: Binding<Int>?
        var isProgrammaticPageChange = false

        @objc func pdfViewPageChanged(_ notification: Notification) {
            guard !isProgrammaticPageChange,
                  let pdfView,
                  let document = pdfView.document,
                  let currentPage = pdfView.currentPage else {
                return
            }
            let index = document.index(for: currentPage)
            guard index != NSNotFound else { return }
            DispatchQueue.main.async {
                if self.pageIndex?.wrappedValue != index {
                    self.pageIndex?.wrappedValue = index
                }
            }
        }
    }
}

private final class DraggablePDFView: PDFView {
    private var rememberedHorizontalOrigin: CGFloat?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        DispatchQueue.main.async { [weak self] in
            self?.rememberCurrentHorizontalOrigin()
        }
    }

    func resetRememberedHorizontalOrigin() {
        rememberedHorizontalOrigin = nil
    }

    func rememberCurrentHorizontalOriginIfNeeded() {
        guard rememberedHorizontalOrigin == nil else { return }
        rememberCurrentHorizontalOrigin()
    }

    func restoreRememberedHorizontalOrigin() {
        guard let rememberedHorizontalOrigin,
              let clipView = enclosingScrollView?.contentView,
              let documentView = enclosingScrollView?.documentView else { return }
        let maxX = max(documentView.bounds.width - clipView.bounds.width, 0)
        let restoredX = min(max(rememberedHorizontalOrigin, 0), maxX)
        let currentOrigin = clipView.bounds.origin
        guard abs(currentOrigin.x - restoredX) > 0.5 else { return }
        clipView.scroll(to: NSPoint(x: restoredX, y: currentOrigin.y))
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    private func rememberCurrentHorizontalOrigin() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        rememberedHorizontalOrigin = clipView.bounds.origin.x
    }
}

private struct SectionListRowView: View {
    @EnvironmentObject private var appState: AppState
    let item: PDFFileItem
    let index: Int
    let totalCount: Int
    @State private var showDropdown = false

    private let actionColumnWidth: CGFloat = 156
    private let nameColumnWidth: CGFloat = 365
    private let tableWidth: CGFloat = 1118

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Left action buttons
                HStack(spacing: 6) {
                    SectionReadyCheckboxButton(isReady: appState.epubReadyBinding(for: item))

                    SectionUtilityCircleButton(
                        title: "Remove section",
                        systemImage: "xmark",
                        backgroundColor: Color.red.opacity(0.92),
                        foregroundColor: Color.white
                    ) {
                        appState.removeSectionItem(item)
                    }

                    SectionUtilityCircleButton(
                        title: "Add manual section below",
                        systemImage: "plus",
                        backgroundColor: Color.green.opacity(0.92)
                    ) {
                        appState.addManualSection(after: item)
                    }
                }
                .frame(width: actionColumnWidth)

                // Section name column
                HStack(spacing: 8) {
                    Image(systemName: item.isManualSection ? "text.badge.plus" : "doc.richtext")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(item.isManualSection ? Color.blue : Color.orange)
                        .frame(width: 46, height: 36)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                        )

                    if appState.appleVisionMarkdownExists(for: item) {
                        Text("MD")
                            .font(.system(size: MainTypography.smallSize, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .frame(width: 46, height: 32)
                            .background(Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.84, alpha: 1)))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.black.opacity(0.18), lineWidth: 1)
                            )
                    }

                    if item.isManualSection {
                        Text(appState.sectionListDisplayName(for: item))
                            .font(.system(size: MainTypography.bodySize, weight: .medium))
                            .foregroundStyle(NewOCRMainPalette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        SectionFileNameButton(title: appState.sectionListDisplayName(for: item)) {
                            NSWorkspace.shared.open(item.url)
                        }
                    }
                }
                .frame(width: nameColumnWidth, alignment: .leading)

                // Title field (flex, fills remaining space)
                TextField("Title", text: appState.titleBinding(for: item))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.black)
                    .font(.system(size: MainTypography.bodySize, weight: .medium))
                    .tint(Color.yellow)
                    .accentColor(Color.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.black.opacity(0.18), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity)

                // Preview standalone button
                SectionIconButton(
                    title: "Preview",
                    systemImage: "eye",
                    isDisabled: !appState.appleVisionMarkdownExists(for: item) || appState.isScanningHeaderFooter(for: item),
                    backgroundColor: Color.orange.opacity(0.92),
                    foregroundColor: Color.black
                ) {
                    appState.previewMarkdown(for: item)
                }

                // More actions dropdown button
                SectionIconButton(
                    title: "More Actions",
                    systemImage: "ellipsis.circle",
                    isDisabled: false,
                    backgroundColor: Color(white: 0.28),
                    foregroundColor: Color.white
                ) {
                    showDropdown = true
                }
                .popover(isPresented: $showDropdown, arrowEdge: .trailing) {
                    SectionRowDropdownView(item: item, close: { showDropdown = false })
                        .environmentObject(appState)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: tableWidth, alignment: .leading)
            .background(index.isMultiple(of: 2) ? NewOCRMainPalette.rowBackground : NewOCRMainPalette.alternateRowBackground)

            if index < totalCount - 1 {
                Divider()
                    .overlay(NewOCRMainPalette.stroke)
                    .frame(width: tableWidth)
            }
        }
    }
}

private struct SectionRowDropdownView: View {
    @EnvironmentObject private var appState: AppState
    let item: PDFFileItem
    let close: () -> Void

    private var hasOCR: Bool { appState.appleVisionMarkdownExists(for: item) }
    private var isScanning: Bool { appState.isScanningHeaderFooter(for: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !item.isManualSection {
                SectionDropdownRow(
                    title: "Scan Header",
                    systemImage: "text.viewfinder",
                    isDisabled: isScanning,
                    close: close
                ) {
                    appState.scanHeaderFooterSample(for: item)
                }
            }

            SectionDropdownRow(
                title: "Process",
                systemImage: "play.fill",
                isDisabled: (!item.isManualSection && !appState.headerFooterScanned(for: item) && appState.titleBinding(for: item).wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || isScanning,
                close: close
            ) {
                appState.beginOCR(for: item)
            }

            if !item.isManualSection && appState.pureOCRSnapshotExists(for: item) {
                SectionDropdownRow(
                    title: "Compare",
                    systemImage: "doc.text.magnifyingglass",
                    isDisabled: isScanning,
                    close: close
                ) {
                    appState.openOCRCompareReport(for: item)
                }
            }

            if hasOCR {
                SectionDropdownRow(
                    title: "Clear OCR",
                    systemImage: "xmark.circle.fill",
                    isDisabled: isScanning,
                    isDestructive: true,
                    close: close
                ) {
                    appState.clearOCRForSection(item)
                }
            }
        }
        .padding(8)
        .frame(minWidth: 262, alignment: .leading)
        .background(NewOCRMainPalette.panelBackground)
    }
}

private struct SectionDropdownRow: View {
    let title: String
    let systemImage: String
    var isDisabled: Bool = false
    var isDestructive: Bool = false
    let close: () -> Void
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    private var foregroundColor: Color {
        if isDisabled { return NewOCRMainPalette.tertiaryText }
        if isDestructive && (isHovered || isPressed) { return Color.white }
        if isDestructive { return Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.56, blue: 0.56, alpha: 1)) }
        return NewOCRMainPalette.primaryText
    }

    private var highlightColor: Color {
        if isDisabled { return Color.clear }
        if isPressed { return isDestructive ? Color(nsColor: NSColor(calibratedRed: 0.92, green: 0.36, blue: 0.36, alpha: 1)) : Color.white.opacity(0.30) }
        if isHovered { return isDestructive ? Color(nsColor: NSColor(calibratedRed: 0.98, green: 0.48, blue: 0.48, alpha: 1)) : Color.white.opacity(0.22) }
        return Color.clear
    }

    var body: some View {
        Button {
            guard !isDisabled else { return }
            action()
            close()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: MainTypography.bodySize, weight: .semibold))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: MainTypography.bodySize, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlightColor)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !isDisabled else { return }
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set(); isPressed = false }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isDisabled { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
    }
}

private struct OCRIconButton: View {
    let title: String
    let systemImage: String
    let backgroundColor: Color
    var foregroundColor: Color = Color(red: 17/255, green: 17/255, blue: 17/255)
    var size: CGFloat = 38
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var iconSize: CGFloat {
        min(max(size * 0.46, 16), 28)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(isEnabled ? foregroundColor : foregroundColor.opacity(0.34))
                .frame(width: size, height: size)
                .background(isEnabled ? (isHovered ? backgroundColor.opacity(0.86) : backgroundColor) : backgroundColor.opacity(0.32))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.black.opacity(isEnabled ? 0.18 : 0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(isEnabled && isHovered ? 0.13 : 0.06), radius: isHovered ? 6 : 3, x: 0, y: isHovered ? 2 : 1)
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .background(FloatingTooltip(title: title, isEnabled: isEnabled))
        .accessibilityLabel(title)
        .onHover { hovering in
            isHovered = hovering
            if hovering && isEnabled {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            if isHovered {
                NSCursor.arrow.set()
                isHovered = false
            }
        }
    }
}

struct MarkdownSyntaxPopoverView: View {
    private let examples: [(syntax: String, result: String)] = [
        ("# Chapter title", "Heading 1"),
        ("## Section title", "Heading 2"),
        ("### Subsection title", "Heading 3"),
        ("A blank line", "Starts a new paragraph"),
        ("Line one<br/>Line two", "Line break"),
        ("> Quoted text", "Blockquote"),
        ("**bold text**", "Bold text"),
        ("*italic text*", "Italic text"),
        ("![Alt text](Images/example.png)", "Image"),
        ("Caption:\\n  Image description", "Image description"),
        ("Text with a note.[^1]", "Footnote marker"),
        ("[^1]: Footnote text", "Footnote at bottom"),
        ("<p class=\"left\">Text</p>", "Left aligned paragraph"),
        ("<p class=\"center\">Text</p>", "Center aligned paragraph"),
        ("<p class=\"right\">Text</p>", "Right aligned paragraph")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.accentColor)
                Text("Markdown (.md) Syntax")
                    .font(.headline)
            }

            Text("The OCR editor saves Markdown text. EPUB export currently supports these common forms:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Highlight commands")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Select text, then choose LEFT, CENTER, or RIGHT. NewOCR writes the selected paragraph as <p class=\"left\">Text</p>, <p class=\"center\">Text</p>, or <p class=\"right\">Text</p>. Apply CSS adds these classes for Preview and EPUB.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Type")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Meaning")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(examples, id: \.syntax) { example in
                        GridRow {
                            Text(example.syntax)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                            Text(example.result)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)

            Text("Image paths are relative to the Markdown folder. Put Caption: or Description: directly below an image; following lines stay in the same caption until a blank line. Use > for blockquotes. Footnotes use matching labels, such as [^1] or [^a]. Alignment classes are supported only on paragraph tags with class left, center, or right.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 540, alignment: .leading)
    }
}

struct OCRSearchGuidelinePopoverView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.accentColor)
                Text("Search")
                    .font(.headline)
            }

            Text("Type normal text to show only paragraphs containing that text. Matching text stays highlighted.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Type exactly Image to show image paragraphs.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Type exactly Footnote to show paragraphs with footnote markers and footnote items.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Type exactly Blockquote to show quote blocks.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Paragraph numbers and merge actions still use the real document position.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

struct OCRMarkdownPreviewWindowView: View {
    let previewURL: URL
    let readAccessURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "eye")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Preview")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    Text(previewURL.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 10)

                OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white) {
                    NSApp.keyWindow?.close()
                }
            }

            WebPreviewView(url: previewURL, readAccessURL: readAccessURL)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 520)
        .background(NewOCRMainPalette.windowBackground)
        .buttonStyle(NewOCRButtonStyle())
    }
}

struct OCRLogWindowView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "terminal")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("OCR Log")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    Text(appState.selectedPDFName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 10)

                OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white) {
                    appState.closeOCRLogWindow()
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if appState.isOCRRunning {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(appState.ocrStatus)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(appState.isOCRRunning ? NewOCRMainPalette.secondaryText : NewOCRMainPalette.primaryText)
                        .lineLimit(2)
                    Spacer()
                }

                TextEditor(text: $appState.logOutput)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                    .scrollContentBackground(.hidden)
                    .background(NewOCRMainPalette.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                    )
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(NewOCRMainPalette.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 420)
        .background(NewOCRMainPalette.windowBackground)
        .buttonStyle(NewOCRButtonStyle())
    }
}

private struct OCRCompareReportWindowView: View {
    let sectionTitle: String
    let differences: [OCRCompareDifference]

    private var groupedDifferences: [(page: Int, differences: [OCRCompareDifference])] {
        Dictionary(grouping: differences, by: \.page)
            .map { (page: $0.key, differences: $0.value) }
            .sorted { $0.page < $1.page }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Compare")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    Text(sectionTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 10)

                Text("\(differences.count) differences")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())

                OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white) {
                    NSApp.keyWindow?.close()
                }
            }

            if differences.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(Color(red: 53/255, green: 200/255, blue: 90/255))
                    Text("No differences found")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.headingText)
                    Text("The edited MD text currently matches the saved pure Apple Vision OCR snapshot for this section.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(22)
                .background(NewOCRMainPalette.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groupedDifferences, id: \.page) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Text("Page \(group.page)")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(NewOCRMainPalette.headingText)
                                    Text("\(group.differences.count)")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color.black)
                                        .frame(minWidth: 28, minHeight: 24)
                                        .background(Color.white.opacity(0.90))
                                        .clipShape(Capsule())
                                    Spacer()
                                }

                                ForEach(group.differences) { difference in
                                    OCRCompareDifferenceRow(difference: difference)
                                }
                            }
                            .padding(14)
                            .background(NewOCRMainPalette.panelBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                            )
                        }
                    }
                    .padding(2)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 840, minHeight: 620)
        .background(NewOCRMainPalette.windowBackground)
        .buttonStyle(NewOCRButtonStyle())
    }
}

private struct OCRCompareDifferenceRow: View {
    let difference: OCRCompareDifference

    private var accentColor: Color {
        switch difference.kind {
        case .missingFromEdited:
            return Color(red: 255/255, green: 117/255, blue: 117/255)
        case .addedInEdited:
            return Color(red: 53/255, green: 200/255, blue: 90/255)
        case .changed:
            return Color(red: 255/255, green: 182/255, blue: 216/255)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: difference.kind.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(difference.kind.title)
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            HStack(alignment: .top, spacing: 10) {
                compareTextPanel(title: "Pure OCR", text: difference.pureText, isEmpty: difference.pureText.isEmpty)
                compareTextPanel(title: "Edited MD", text: difference.editedText, isEmpty: difference.editedText.isEmpty)
            }
        }
        .padding(12)
        .background(NewOCRMainPalette.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }

    private func compareTextPanel(title: String, text: String, isEmpty: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NewOCRMainPalette.secondaryText)
            Text(isEmpty ? "-" : text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isEmpty ? NewOCRMainPalette.tertiaryText : NewOCRMainPalette.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct WebPreviewView: NSViewRepresentable {
    let url: URL
    let readAccessURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        webView.layer?.backgroundColor = NSColor.white.cgColor
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.layer?.backgroundColor = NSColor.white.cgColor
        webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }
}

struct PathRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct FilesPopoverView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files")
                .font(.title3.weight(.semibold))

            PathRow(label: "PDF", value: appState.selectedPDFPath.isEmpty ? "No PDF selected" : appState.selectedPDFPath)

            if let epubPath = appState.bookEPUBFilePathIfExists {
                PathRow(label: "EPUB", value: epubPath)
            }

            if let appleVisionFolderPath = appState.localAppleVisionOutputFolderPathIfExists {
                PathRow(label: "AppleVision MD", value: appleVisionFolderPath)
            }
        }
        .padding(16)
        .frame(width: 620)
    }
}

private struct ParagraphScrollPositionItem: Equatable {
    let index: Int
    let minY: CGFloat
}

private struct ParagraphScrollPositionKey: PreferenceKey {
    static var defaultValue: [ParagraphScrollPositionItem] = []
    static func reduce(value: inout [ParagraphScrollPositionItem], nextValue: () -> [ParagraphScrollPositionItem]) {
        value.append(contentsOf: nextValue())
    }
}

struct ParagraphEditorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var handledOpenFocusRequestID = 0
    @State private var scrollSyncTask: Task<Void, Never>?

    var body: some View {
        let visibleIndexes = appState.visibleOCRParagraphIndexes

        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleIndexes, id: \.self) { index in
                        ParagraphItemView(
                            index: index,
                            text: appState.paragraphBinding(at: index)
                        )
                        .environmentObject(appState)
                        .id(index)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ParagraphScrollPositionKey.self,
                                    value: [ParagraphScrollPositionItem(
                                        index: index,
                                        minY: geo.frame(in: .named("ocrParagraphScroll")).minY
                                    )]
                                )
                            }
                        )
                    }

                    if visibleIndexes.isEmpty {
                        EmptyStateView(title: "No matching paragraphs found.")
                            .frame(minHeight: 220)
                    }
                }
                .padding(8)
            }
            .coordinateSpace(name: "ocrParagraphScroll")
            .onAppear {
                focusFirstParagraph(with: proxy)
            }
            .onReceive(appState.$ocrWindowOpenFocusRequestID) { requestID in
                guard requestID > 0, requestID != handledOpenFocusRequestID else { return }
                focusFirstParagraph(with: proxy)
            }
            .onReceive(appState.$paragraphScrollRequestID) { requestID in
                guard requestID > 0 else { return }
                DispatchQueue.main.async {
                    withAnimation {
                        proxy.scrollTo(appState.paragraphScrollTargetIndex, anchor: .center)
                    }
                }
            }
            .onPreferenceChange(ParagraphScrollPositionKey.self) { items in
                guard appState.ocrSearchText.isEmpty else { return }
                // Find the paragraph nearest the top of the scroll view (minY closest to 0 from above)
                let nearTop = items.filter { $0.minY >= -40 }
                guard let topmost = nearTop.min(by: { abs($0.minY) < abs($1.minY) }) else { return }
                let idx = topmost.index
                scrollSyncTask?.cancel()
                scrollSyncTask = Task {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard appState.ocrSearchText.isEmpty else { return }
                        appState.previewOCRParagraphSourcePage(idx)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .onDisappear {
            scrollSyncTask?.cancel()
        }
    }

    private func focusFirstParagraph(with proxy: ScrollViewProxy) {
        let requestID = appState.ocrWindowOpenFocusRequestID
        guard handledOpenFocusRequestID != requestID else { return }
        handledOpenFocusRequestID = requestID
        guard appState.ocrParagraphs.indices.contains(0) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(0, anchor: .top)
            appState.previewOCRParagraphSourcePage(0)
        }
    }
}

struct PlainOCRTextEditorView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HighlightingTextEditor(
            text: $appState.ocrText,
            searchText: appState.ocrSearchText
        )
            .frame(minHeight: 360)
            .background(Color(nsColor: .textBackgroundColor))
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}

struct OCRMarkdownPresenceBadge: View {
    let label: String
    let systemImage: String
    let exists: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            guard exists else { return }
            action()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                    .frame(width: 40, height: 34)
                    .background(exists ? Color.white.opacity(isHovered ? 0.18 : 0.13) : Color.white.opacity(0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(exists ? Color.green.opacity(0.48) : Color(red: 255/255, green: 102/255, blue: 102/255).opacity(0.48), lineWidth: 1)
                    )

                Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(exists ? Color.green : Color(red: 255/255, green: 102/255, blue: 102/255))
                    .background(Color.black.opacity(0.32))
                    .clipShape(Circle())
                    .offset(x: 4, y: 4)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 38)
        .background(FloatingTooltip(title: "\(label) \(exists ? "found" : "not found")", isEnabled: true))
        .accessibilityLabel("\(label) \(exists ? "exists" : "not found")")
        .onHover { hovering in
            isHovered = hovering
            if hovering && exists {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            if isHovered {
                NSCursor.arrow.set()
                isHovered = false
            }
        }
    }
}

struct HighlightingTextEditor: NSViewRepresentable {
    @Binding var text: String
    let searchText: String
    var onFocus: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = .systemFont(ofSize: OCRTypography.editorFontSize)
        textView.textContainerInset = OCRTypography.editorInset
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.parent = self
        let textChanged = textView.string != text
        if textChanged {
            textView.string = text
        }

        let coord = context.coordinator
        let currentLength = (textView.string as NSString).length
        if textChanged || coord.lastHighlightedSearchText != searchText || coord.lastHighlightedTextLength != currentLength {
            coord.applyHighlights(searchText: searchText)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightingTextEditor
        weak var textView: NSTextView?
        private var markdownPopover: NSPopover?
        private var isApplyingMarkdownStyle = false
        var lastHighlightedSearchText: String? = nil
        var lastHighlightedTextLength: Int = -1

        init(_ parent: HighlightingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.onFocus?()
            parent.text = textView.string
            applyHighlights(searchText: parent.searchText)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocus?()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingMarkdownStyle else { return }
            showMarkdownStylePopoverIfNeeded()
        }

        private func showMarkdownStylePopoverIfNeeded() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            guard selection.length > 0 else {
                markdownPopover?.close()
                return
            }

            if markdownPopover?.isShown == true {
                return
            }

            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 690, height: 42)
            popover.contentViewController = NSHostingController(
                rootView: MarkdownStylePopoverView(
                    applyBold: { [weak self] in self?.applyMarkdownWrapper("**") },
                    applyItalic: { [weak self] in self?.applyMarkdownWrapper("*") },
                    applyBlockquote: { [weak self] in self?.applyBlockquote() },
                    applyHeading1: { [weak self] in self?.applyHeading(level: 1) },
                    applyHeading2: { [weak self] in self?.applyHeading(level: 2) },
                    applyHeading3: { [weak self] in self?.applyHeading(level: 3) },
                    applyLeft: { [weak self] in self?.applyAlignment("left") },
                    applyCenter: { [weak self] in self?.applyAlignment("center") },
                    applyRight: { [weak self] in self?.applyAlignment("right") }
                )
            )
            markdownPopover = popover

            let rect = textView.firstRect(forCharacterRange: selection, actualRange: nil)
            let localRect = textView.convert(rect, from: nil)
            let anchorRect = localRect == .zero ? textView.visibleRect : localRect
            popover.show(relativeTo: anchorRect, of: textView, preferredEdge: .maxY)
        }

        private func applyMarkdownWrapper(_ marker: String) {
            guard let textView else { return }
            let selection = textView.selectedRange()
            guard selection.length > 0 else { return }

            let source = textView.string as NSString
            let selectedText = source.substring(with: selection)
            let replacement = "\(marker)\(selectedText)\(marker)"

            isApplyingMarkdownStyle = true
            textView.shouldChangeText(in: selection, replacementString: replacement)
            textView.replaceCharacters(in: selection, with: replacement)
            textView.didChangeText()
            let newSelection = NSRange(location: selection.location + marker.count, length: selection.length)
            textView.setSelectedRange(newSelection)
            isApplyingMarkdownStyle = false

            parent.text = textView.string
            applyHighlights(searchText: parent.searchText)
            markdownPopover?.close()
        }

        private func applyBlockquote() {
            applyMarkdownTransform { selectedText in
                selectedText
                    .components(separatedBy: .newlines)
                    .map { line in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        return trimmed.hasPrefix(">") ? line : "> \(line)"
                    }
                    .joined(separator: "\n")
            }
        }

        private func applyHeading(level: Int) {
            let marker = String(repeating: "#", count: max(1, min(level, 6)))
            applyMarkdownTransform { selectedText in
                selectedText
                    .components(separatedBy: .newlines)
                    .map { line in
                        let cleanLine = line
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
                            .replacingOccurrences(of: #"\s*#{1,6}$"#, with: "", options: .regularExpression)
                        return cleanLine.isEmpty ? "" : "\(marker) \(cleanLine) \(marker)"
                    }
                    .joined(separator: "\n")
            }
        }

        private func applyAlignment(_ alignment: String) {
            let cleanAlignment = ["left", "right", "center"].contains(alignment) ? alignment : "left"
            applyMarkdownTransform { selectedText in
                selectedText
                    .components(separatedBy: "\n\n")
                    .map { block in
                        let cleanBlock = block
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(
                                of: #"(?is)^<p\s+class\s*=\s*["'](?:left|right|center)["']\s*>(.*?)</p>$"#,
                                with: "$1",
                                options: .regularExpression
                            )
                            .replacingOccurrences(of: "\n", with: "<br/>")
                        return cleanBlock.isEmpty ? "" : "<p class=\"\(cleanAlignment)\">\(cleanBlock)</p>"
                    }
                    .joined(separator: "\n\n")
            }
        }

        private func applyMarkdownTransform(_ transform: (String) -> String) {
            guard let textView else { return }
            let selection = textView.selectedRange()
            guard selection.length > 0 else { return }

            let source = textView.string as NSString
            let selectedText = source.substring(with: selection)
            let replacement = transform(selectedText)

            isApplyingMarkdownStyle = true
            textView.shouldChangeText(in: selection, replacementString: replacement)
            textView.replaceCharacters(in: selection, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: selection.location, length: replacement.count))
            isApplyingMarkdownStyle = false

            parent.text = textView.string
            applyHighlights(searchText: parent.searchText)
            markdownPopover?.close()
        }

        func applyHighlights(searchText: String) {
            guard let textView, let layoutManager = textView.layoutManager else { return }

            let nsString = textView.string as NSString
            lastHighlightedSearchText = searchText
            lastHighlightedTextLength = nsString.length

            let fullRange = NSRange(location: 0, length: nsString.length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }

            var searchRange = fullRange
            while searchRange.location < nsString.length {
                let foundRange = nsString.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )

                if foundRange.location == NSNotFound {
                    break
                }

                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.45),
                    forCharacterRange: foundRange
                )

                let nextLocation = foundRange.location + max(foundRange.length, 1)
                searchRange = NSRange(location: nextLocation, length: nsString.length - nextLocation)
            }
        }
    }
}

struct MarkdownStylePopoverView: View {
    let applyBold: () -> Void
    let applyItalic: () -> Void
    let applyBlockquote: () -> Void
    let applyHeading1: () -> Void
    let applyHeading2: () -> Void
    let applyHeading3: () -> Void
    let applyLeft: () -> Void
    let applyCenter: () -> Void
    let applyRight: () -> Void
    private let commandButtonHeight: CGFloat = 30
    private let compactCommandButtonWidth: CGFloat = 38

    var body: some View {
        HStack(spacing: 8) {
            Button {
                applyBold()
            } label: {
                Text("B")
                    .font(.body.weight(.bold))
                    .frame(width: compactCommandButtonWidth, height: commandButtonHeight)
            }
            .help("Bold")

            Button {
                applyItalic()
            } label: {
                Text("I")
                    .font(.body.italic())
                    .frame(width: compactCommandButtonWidth, height: commandButtonHeight)
            }
            .help("Italic")

            Button {
                applyBlockquote()
            } label: {
                Text("Quote")
                    .frame(height: commandButtonHeight)
            }
            .help("BlockQuote")

            Button {
                applyHeading1()
            } label: {
                Text("H1")
                    .frame(height: commandButtonHeight)
            }
            .help("Heading 1")

            Button {
                applyHeading2()
            } label: {
                Text("H2")
                    .frame(height: commandButtonHeight)
            }
            .help("Heading 2")

            Button {
                applyHeading3()
            } label: {
                Text("H3")
                    .frame(height: commandButtonHeight)
            }
            .help("Heading 3")

            Divider()
                .frame(height: 24)

            alignmentButton(title: "Left", systemImage: "text.alignleft", action: applyLeft)
                .help("Align left")

            alignmentButton(title: "Center", systemImage: "text.aligncenter", action: applyCenter)
                .help("Align center")

            alignmentButton(title: "Right", systemImage: "text.alignright", action: applyRight)
                .help("Align right")
        }
        .padding(8)
    }

    private func alignmentButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: compactCommandButtonWidth, height: commandButtonHeight)
        }
        .accessibilityLabel(title)
    }
}

struct ParagraphItemView: View {
    @EnvironmentObject private var appState: AppState
    let index: Int
    @Binding var text: String
    @State private var editorHeight: CGFloat? = nil
    @State private var resizeStartHeight: CGFloat? = nil
    @State private var editorWidth: CGFloat = 640

    var body: some View {
        let displayTitle = appState.paragraphDisplayTitle(at: index)
        let isFootnote = appState.isFootnoteParagraph(at: index)
        let isBlockquote = appState.isBlockquoteParagraph(at: index)
        let isImage = appState.markdownImageURL(from: text) != nil
        let canAddImageDescription = isImage && !appState.imageParagraphHasDescription(at: index)
        let canRemove = appState.ocrParagraphs.count > 1 || isFootnote || isBlockquote
        let itemKind = isFootnote ? "footnote" : (isBlockquote ? "blockquote" : "paragraph")
        let itemKindTitle = isFootnote ? "Footnote" : (isBlockquote ? "Blockquote" : "Paragraph")

        HStack(alignment: .top, spacing: 8) {
            Button {
                appState.removeParagraph(index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove \(itemKind)")
            .accessibilityLabel("Remove \(displayTitle)")
            .disabled(!canRemove)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if appState.ocrSourcePageIsKnown(for: index) {
                        Button {
                            appState.previewOCRParagraphSourcePage(index)
                        } label: {
                            Image(systemName: "doc.viewfinder")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Jump PDF preview to this paragraph's page")
                    }

                    Menu("Actions") {
                        if isImage {
                            Button("Add Image Description") {
                                appState.addImageDescription(at: index)
                            }
                            .disabled(!canAddImageDescription)

                            Divider()
                        }

                        Button("Add Paragraph Before") {
                            appState.addParagraphBefore(index)
                        }

                        Button("Add Paragraph After") {
                            appState.addParagraphAfter(index)
                        }

                        Button("Add Image Before") {
                            appState.addUserImage(before: index)
                        }

                        Button("Add Image After") {
                            appState.addUserImage(after: index)
                        }

                        Button("Line Break Before") {
                            appState.addLineBreakBefore(index)
                        }

                        Button("Line Break After") {
                            appState.addLineBreakAfter(index)
                        }

                        Button("Page Break Before") {
                            appState.addPageBreakBefore(index)
                        }

                        Button("Page Break After") {
                            appState.addPageBreakAfter(index)
                        }

                        Divider()

                        Button("Merge With Paragraph Above") {
                            appState.mergeParagraphBefore(index)
                        }
                        .disabled(index == 0)

                        Button("Merge With Paragraph Below") {
                            appState.mergeParagraphAfter(index)
                        }
                        .disabled(index + 1 >= appState.ocrParagraphs.count)

                        Divider()

                        Button("Remove \(itemKindTitle)", role: .destructive) {
                            appState.removeParagraph(index)
                        }
                        .disabled(!canRemove)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if let imageURL = appState.markdownImageURL(from: text) {
                    OCRMarkdownImagePreview(imageURL: imageURL)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Image Markdown")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HighlightingTextEditor(
                            text: $text,
                            searchText: appState.ocrSearchText
                        )
                            .frame(height: max(appState.ocrParagraphTextAreaMinHeight, 86))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            )
                    }
                } else {
                    VStack(spacing: 0) {
                        HighlightingTextEditor(
                            text: $text,
                            searchText: appState.ocrSearchText
                        )
                            .frame(height: currentEditorHeight)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(key: ParagraphEditorWidthPreferenceKey.self, value: proxy.size.width)
                                }
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            )

                        ResizeHandleView()
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        if resizeStartHeight == nil {
                                            resizeStartHeight = currentEditorHeight
                                        }
                                        let baseHeight = resizeStartHeight ?? currentEditorHeight
                                        editorHeight = max(appState.ocrParagraphTextAreaMinHeight, baseHeight + value.translation.height)
                                    }
                                    .onEnded { _ in
                                        resizeStartHeight = nil
                                    }
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index.isMultiple(of: 2) ? Color(nsColor: .textBackgroundColor) : Color(nsColor: NSColor(calibratedWhite: 0.91, alpha: 1)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.46), lineWidth: 1)
        )
        .onPreferenceChange(ParagraphEditorWidthPreferenceKey.self) { width in
            guard width > 0 else { return }
            editorWidth = width
        }
    }

    private var currentEditorHeight: CGFloat {
        max(appState.ocrParagraphTextAreaMinHeight, automaticEditorHeight, editorHeight ?? automaticEditorHeight)
    }

    private var automaticEditorHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: OCRTypography.editorFontSize)
        let lineHeight = max(font.ascender - font.descender + font.leading, 22)
        let usableWidth = max(editorWidth - 28, 180)
        let alphabetWidth = ("abcdefghijklmnopqrstuvwxyz" as NSString).size(withAttributes: [.font: font]).width
        let averageCharacterWidth = max(alphabetWidth / 26, 7)
        let charactersPerLine = max(Int(usableWidth / averageCharacterWidth), 18)

        var estimatedLineCount = 0
        for line in text.components(separatedBy: .newlines) {
            let count = max(line.count, 1)
            let wrappedLineCount = Int(ceil(Double(count) / Double(charactersPerLine)))
            estimatedLineCount += max(1, wrappedLineCount)
        }

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let measuredRect = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [
                .font: font,
                .paragraphStyle: style,
            ]
        )
            .boundingRect(
                with: NSSize(width: usableWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )

        let measuredHeight = max(measuredRect.height, CGFloat(max(estimatedLineCount, 1)) * lineHeight)
        return ceil(max(appState.ocrParagraphTextAreaMinHeight, measuredHeight + 36))
    }
}

private struct ParagraphEditorWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 640

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

struct ResizeHandleView: View {
    var body: some View {
        HStack {
            Spacer()
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 44, height: 4)
            Spacer()
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .help("Drag to resize text area")
    }
}

struct OCRMarkdownImagePreview: View {
    let imageURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    Text("Image file not found")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }

        }
    }
}

struct SplitPlanRange: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var pageFrom: String
    var pageTo: String
    var file: String? = nil
}

final class DetectSplitSelectionState: ObservableObject {
    @Published var ranges: [SplitPlanRange]
    @Published var selectedIDs: Set<UUID>

    init(ranges: [SplitPlanRange]) {
        self.ranges = ranges
        self.selectedIDs = Set(ranges.map(\.id))
    }
}

private struct PDFBookmarkSplitPoint {
    let title: String
    let pageNumber: Int
}

final class SplitPlannerState: ObservableObject {
    @Published var pdfURL: URL
    @Published var projectFolderURL: URL
    @Published var pageCount: Int = 0
    @Published var ranges: [SplitPlanRange] = []
    @Published var projectPDFs: [PDFFileItem] = []
    @Published var status: String = "Loading PDF..."
    @Published var isLoadingPDF: Bool = true
    @Published var hasPDFBookmarks: Bool = false
    @Published var isUsingFallbackRange: Bool = false

    private var bookmarkData: Data
    private var isAccessingSecurityScopedResource = false
    private var pdfDocument: PDFDocument?
    private var cropWindows: [NSWindow] = []
    private var addSplitWindows: [NSWindow] = []
    private var detectSplitWindows: [NSWindow] = []
    private var retainedWindowDelegates: [ObjectIdentifier: WindowCleanupDelegate] = [:]
    private let cropWindowWidth: CGFloat
    private let cropWindowHeight: CGFloat
    private let shouldOpenCropWindowFullScreen: Bool
    private let addSplitWindowWidth: CGFloat
    private let addSplitWindowHeight: CGFloat
    private let shouldOpenAddSplitWindowFullScreen: Bool
    private var shouldOpenCropWindowAfterLoad: Bool
    private var shouldOpenAddSplitWindowAfterLoad: Bool
    private var hasSavedCropInCurrentCropWindow: Bool = false
    private var shouldWarnAddSplitCloseWithoutSplits: Bool = false
    private let onSectionsSaved: ([(URL, String)]) -> Void

    init(
        bookmarkData: Data,
        fallbackURL: URL,
        projectFolderURL: URL,
        cropWindowWidth: CGFloat = 920,
        cropWindowHeight: CGFloat = 720,
        shouldOpenCropWindowFullScreen: Bool = true,
        addSplitWindowWidth: CGFloat = 920,
        addSplitWindowHeight: CGFloat = 720,
        shouldOpenAddSplitWindowFullScreen: Bool = true,
        shouldOpenCropWindowAfterLoad: Bool = false,
        shouldOpenAddSplitWindowAfterLoad: Bool = false,
        onSectionsSaved: @escaping ([(URL, String)]) -> Void = { _ in }
    ) {
        self.bookmarkData = bookmarkData
        self.pdfURL = fallbackURL
        self.projectFolderURL = projectFolderURL
        self.cropWindowWidth = cropWindowWidth
        self.cropWindowHeight = cropWindowHeight
        self.shouldOpenCropWindowFullScreen = shouldOpenCropWindowFullScreen
        self.addSplitWindowWidth = addSplitWindowWidth
        self.addSplitWindowHeight = addSplitWindowHeight
        self.shouldOpenAddSplitWindowFullScreen = shouldOpenAddSplitWindowFullScreen
        self.shouldOpenCropWindowAfterLoad = shouldOpenCropWindowAfterLoad
        self.shouldOpenAddSplitWindowAfterLoad = shouldOpenAddSplitWindowAfterLoad
        self.onSectionsSaved = onSectionsSaved
        loadProjectPDFs()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.loadPDF()
        }
    }

    deinit {
        if isAccessingSecurityScopedResource {
            pdfURL.stopAccessingSecurityScopedResource()
        }
    }

    var pdfName: String {
        pdfURL.lastPathComponent
    }

    var hasCompletedCropStep: Bool {
        FileManager.default.fileExists(atPath: backupPDFURL(for: pdfURL).path)
    }

    var hasExistingSplitFiles: Bool {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: projectFolderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .nameKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.contains { sectionPDFIndex($0) != nil }
    }

    func confirmCropSaveIfNeeded() -> Bool {
        guard hasExistingSplitFiles else { return true }
        let alert = NSAlert()
        alert.messageText = "Save Crop and Remove Existing Split Files?"
        alert.informativeText = "Saving this crop will remove all existing split PDF files because they were created from the previous page layout. You will need to split the cropped PDF again. Are you sure you want to continue?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save Crop")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func openPDF() {
        NSWorkspace.shared.open(pdfURL)
    }

    func openProjectPDF(_ item: PDFFileItem) {
        NSWorkspace.shared.open(item.url)
    }

    func openCropWindow() {
        guard pdfDocument?.page(at: 0) != nil else {
            status = "PDF is not loaded yet."
            return
        }
        hasSavedCropInCurrentCropWindow = false

        let initialRect: NSRect
        if shouldOpenCropWindowFullScreen, let visibleFrame = NSScreen.main?.visibleFrame {
            initialRect = visibleFrame
        } else {
            initialRect = NSRect(x: 0, y: 0, width: cropWindowWidth, height: cropWindowHeight)
        }

        let window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Crop PDF - \(pdfName)"
        if shouldOpenCropWindowFullScreen {
            window.setFrame(initialRect, display: true)
        } else {
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: CropPDFWindowView()
                .environmentObject(self)
        )
        cropWindows.append(window)
        trackCropWindow(window)
        window.makeKeyAndOrderFront(nil)
    }

    func openAddSplitWindow() {
        guard pdfDocument?.page(at: 0) != nil else {
            status = "PDF is not loaded yet."
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: addSplitWindowWidth, height: addSplitWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add Split - \(pdfName)"
        window.contentMinSize = NSSize(width: 1100, height: 620)
        window.isReleasedWhenClosed = false

        let hostingView = NSHostingView(rootView: AddSplitWindowView().environmentObject(self))
        hostingView.sizingOptions = []
        window.contentView = hostingView

        if shouldOpenAddSplitWindowFullScreen, let visibleFrame = NSScreen.main?.visibleFrame {
            window.setFrame(visibleFrame, display: true)
        } else {
            window.center()
        }
        addSplitWindows.append(window)
        trackAddSplitWindow(window)
        window.makeKeyAndOrderFront(nil)
    }

    func closeAddSplitWindows() {
        for window in addSplitWindows {
            forceCloseWindowAndAttachedSheets(window)
        }
        addSplitWindows.removeAll()
    }

    func closeAllWindows() {
        for window in cropWindows {
            forceCloseWindowAndAttachedSheets(window)
        }
        cropWindows.removeAll()
        for window in detectSplitWindows {
            forceCloseWindowAndAttachedSheets(window)
        }
        detectSplitWindows.removeAll()
        closeAddSplitWindows()
    }

    private func trackCropWindow(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        let delegate = WindowCleanupDelegate(
            onShouldClose: { [weak self] _ in
                self?.confirmCropWindowCloseIfNeeded() ?? true
            },
            onClose: { [weak self] closedWindow in
                guard let self else { return }
                closedWindow.contentView = nil
                self.cropWindows.removeAll { $0 === closedWindow }
                self.retainedWindowDelegates.removeValue(forKey: ObjectIdentifier(closedWindow))
            }
        )
        retainedWindowDelegates[key] = delegate
        window.delegate = delegate
    }

    private func confirmCropWindowCloseIfNeeded() -> Bool {
        guard shouldOpenAddSplitWindowAfterLoad && !hasSavedCropInCurrentCropWindow && !hasCompletedCropStep else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Crop Required Before Splitting"
        alert.informativeText = "This project must be cropped before you can continue to the split step. If you close Crop PDF now, Add Split will remain unavailable until you save a crop."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Cropping")
        alert.addButton(withTitle: "Close Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func trackAddSplitWindow(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        let delegate = WindowCleanupDelegate(
            onShouldClose: { [weak self] _ in
                self?.confirmAddSplitWindowCloseIfNeeded() ?? true
            },
            onClose: { [weak self] closedWindow in
                guard let self else { return }
                closedWindow.contentView = nil
                self.addSplitWindows.removeAll { $0 === closedWindow }
                self.retainedWindowDelegates.removeValue(forKey: ObjectIdentifier(closedWindow))
            }
        )
        retainedWindowDelegates[key] = delegate
        window.delegate = delegate
    }

    private func confirmAddSplitWindowCloseIfNeeded() -> Bool {
        guard shouldWarnAddSplitCloseWithoutSplits && !hasExistingSplitFiles else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Exit Without Creating a Split?"
        alert.informativeText = "No split PDF files have been created yet. If you close Add Split now, the project will not be ready for Define Layout or OCR until you create at least one split. Are you sure you want to exit?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Splitting")
        alert.addButton(withTitle: "Exit")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func openDetectSplitWindow() {
        let ranges = detectedBookmarkSplitRanges()
        let state = DetectSplitSelectionState(ranges: ranges)
        var window: NSWindow?
        let detectWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window = detectWindow
        detectWindow.title = "Detect Split - \(pdfName)"
        detectWindow.contentMinSize = NSSize(width: 1100, height: 620)
        detectWindow.isReleasedWhenClosed = false
        detectWindow.contentView = NSHostingView(
            rootView: DetectSplitWindowView(
                state: state,
                thumbnail: { [weak self] range in
                    guard let self, let from = Int(range.pageFrom) else { return nil }
                    return self.cropPreviewImage(pageIndex: from - 1, size: CGSize(width: 520, height: 680))
                },
                splitAction: { [weak self] in
                    guard let self else { return }
                    let selectedRanges = state.ranges.filter { state.selectedIDs.contains($0.id) }
                    self.addDetectedSplits(selectedRanges) { saved in
                        if saved {
                            window?.close()
                        }
                    }
                },
                closeAction: {
                    window?.close()
                }
            )
            .environmentObject(self)
        )
        detectWindow.center()
        detectSplitWindows.append(detectWindow)
        trackRetainedWindow(detectWindow, removeFrom: \.detectSplitWindows)
        detectWindow.makeKeyAndOrderFront(nil)
    }

    private func trackRetainedWindow(_ window: NSWindow, removeFrom keyPath: ReferenceWritableKeyPath<SplitPlannerState, [NSWindow]>) {
        let key = ObjectIdentifier(window)
        let delegate = WindowCleanupDelegate { [weak self] closedWindow in
            guard let self else { return }
            closedWindow.contentView = nil
            self[keyPath: keyPath].removeAll { $0 === closedWindow }
            self.retainedWindowDelegates.removeValue(forKey: ObjectIdentifier(closedWindow))
        }
        retainedWindowDelegates[key] = delegate
        window.delegate = delegate
    }

    func nextAddSplitFromPage() -> Int {
        let sectionURLs = existingSectionPDFURLs()
        guard !sectionURLs.isEmpty else {
            return 1
        }

        if let lastURL = sectionURLs.last,
           let lastRange = ranges.first(where: { $0.file == lastURL.lastPathComponent }),
           let lastTo = Int(lastRange.pageTo) {
            return max(lastTo + 1, 1)
        }

        let createdPageCount = sectionURLs.reduce(0) { total, url in
            total + ((PDFDocument(url: url)?.pageCount) ?? 0)
        }
        return max(createdPageCount + 1, 1)
    }

    var canAddMoreSplits: Bool {
        pageCount > 0 && nextAddSplitFromPage() <= pageCount
    }

    func addSplit(title: String, pageFrom: String, pageTo: String, completion: @escaping (Bool, Int) -> Void) {
        guard pdfDocument != nil, pageCount > 0 else {
            status = "PDF is not loaded yet."
            completion(false, nextAddSplitFromPage())
            return
        }
        guard canAddMoreSplits else {
            status = "All pages have already been split."
            showLastPageAlreadyAlert()
            completion(false, nextAddSplitFromPage())
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            status = "Title is required."
            completion(false, nextAddSplitFromPage())
            return
        }
        guard let from = Int(pageFrom),
              let to = Int(pageTo),
              from >= 1,
              to >= from,
              to <= pageCount else {
            status = "Enter a valid page range from 1-\(pageCount)."
            completion(false, nextAddSplitFromPage())
            return
        }

        isLoadingPDF = true
        status = "Creating split PDF..."
        let sourceURL = pdfURL
        let outputIndex = nextSectionPDFIndex()
        let outputFileName = String(format: "section-%03d.pdf", outputIndex)
        let range = SplitPlanRange(title: trimmedTitle, pageFrom: "\(from)", pageTo: "\(to)", file: outputFileName)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let freshDocument = PDFDocument(url: sourceURL), freshDocument.pageCount > 0 else {
                    throw NSError(domain: "NewOCR", code: 41, userInfo: [NSLocalizedDescriptionKey: "Could not reload source PDF."])
                }
                let sectionDocument = try self.documentForRange(range, from: freshDocument)
                let outputURL = self.projectFolderURL.appendingPathComponent(outputFileName)
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }
                guard sectionDocument.write(to: outputURL) else {
                    throw NSError(domain: "NewOCR", code: 42, userInfo: [NSLocalizedDescriptionKey: "Could not write \(outputURL.lastPathComponent)."])
                }

                DispatchQueue.main.async {
                    if self.isUsingFallbackRange {
                        self.ranges = [range]
                        self.isUsingFallbackRange = false
                    } else {
                        self.ranges.append(range)
                    }
                    try? self.saveCurrentSplitPlan()
                    self.loadProjectPDFs()
                    self.onSectionsSaved([(outputURL, trimmedTitle)])
                    self.status = "Created \(outputURL.lastPathComponent)."
                    self.isLoadingPDF = false
                    completion(true, to + 1)
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "Could not add split: \(error.localizedDescription)"
                    self.isLoadingPDF = false
                    completion(false, self.nextAddSplitFromPage())
                }
            }
        }
    }

    func detectedBookmarkSplitRanges() -> [SplitPlanRange] {
        let candidateURLs = [
            pdfURL,
            backupPDFURL(for: pdfURL),
            originalPDFURL(for: pdfURL),
        ]

        for candidateURL in candidateURLs {
            guard let document = PDFDocument(url: candidateURL) else { continue }
            let ranges = splitRangesFromBookmarks(in: document)
            if !ranges.isEmpty {
                status = "Detected \(ranges.count) bookmark ranges from \(candidateURL.lastPathComponent)."
                return ranges
            }
        }

        if let pdfDocument {
            let ranges = splitRangesFromBookmarks(in: pdfDocument)
            status = ranges.isEmpty ? "No PDF bookmarks found." : "Detected \(ranges.count) bookmark ranges."
            return ranges
        }

        status = "No PDF bookmarks found."
        return []
    }

    func addDetectedSplits(_ detectedRanges: [SplitPlanRange], completion: @escaping (Bool) -> Void) {
        let selectedRanges = detectedRanges.filter { range in
            !range.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !selectedRanges.isEmpty else {
            status = "No bookmark splits selected."
            completion(false)
            return
        }
        guard pdfDocument != nil, pageCount > 0 else {
            status = "PDF is not loaded yet."
            completion(false)
            return
        }

        isLoadingPDF = true
        status = "Creating \(selectedRanges.count) detected splits..."
        let sourceURL = pdfURL
        let projectFolderURL = projectFolderURL
        let firstOutputIndex = nextSectionPDFIndex()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let freshDocument = PDFDocument(url: sourceURL), freshDocument.pageCount > 0 else {
                    throw NSError(domain: "NewOCR", code: 46, userInfo: [NSLocalizedDescriptionKey: "Could not reload source PDF."])
                }

                var createdRanges: [SplitPlanRange] = []
                var savedTitles: [(URL, String)] = []

                for (offset, detectedRange) in selectedRanges.enumerated() {
                    let title = detectedRange.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let from = Int(detectedRange.pageFrom),
                          let to = Int(detectedRange.pageTo),
                          from >= 1,
                          to >= from,
                          to <= freshDocument.pageCount else {
                        throw NSError(domain: "NewOCR", code: 47, userInfo: [NSLocalizedDescriptionKey: "Invalid detected range \(detectedRange.pageFrom)-\(detectedRange.pageTo)."])
                    }

                    let outputFileName = String(format: "section-%03d.pdf", firstOutputIndex + offset)
                    let outputURL = projectFolderURL.appendingPathComponent(outputFileName)
                    let outputRange = SplitPlanRange(title: title, pageFrom: "\(from)", pageTo: "\(to)", file: outputFileName)
                    let sectionDocument = try self.documentForRange(outputRange, from: freshDocument)
                    if FileManager.default.fileExists(atPath: outputURL.path) {
                        try FileManager.default.removeItem(at: outputURL)
                    }
                    guard sectionDocument.write(to: outputURL) else {
                        throw NSError(domain: "NewOCR", code: 48, userInfo: [NSLocalizedDescriptionKey: "Could not write \(outputURL.lastPathComponent)."])
                    }
                    createdRanges.append(outputRange)
                    savedTitles.append((outputURL, title))
                }

                DispatchQueue.main.async {
                    if self.isUsingFallbackRange {
                        self.ranges = []
                        self.isUsingFallbackRange = false
                    }
                    self.ranges.append(contentsOf: createdRanges)
                    try? self.saveCurrentSplitPlan()
                    self.loadProjectPDFs()
                    self.onSectionsSaved(savedTitles)
                    self.status = "Created \(createdRanges.count) detected split files."
                    self.isLoadingPDF = false
                    self.closeAddSplitWindows()
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "Could not detect split: \(error.localizedDescription)"
                    self.isLoadingPDF = false
                    completion(false)
                }
            }
        }
    }

    func cropPreviewImage(pageIndex: Int, size: CGSize = CGSize(width: 900, height: 1100)) -> NSImage? {
        guard let page = pdfDocument?.page(at: min(max(pageIndex, 0), max(pageCount - 1, 0))) else { return nil }
        return page.thumbnail(of: size, for: .cropBox)
    }

    func titleFromPage(pageIndex: Int, completion: @escaping (String?) -> Void) {
        guard pageCount > 0 else {
            status = "PDF is not loaded yet."
            completion(nil)
            return
        }

        let clampedIndex = min(max(pageIndex, 0), max(pageCount - 1, 0))
        let sourceURL = pdfURL
        isLoadingPDF = true
        status = "Reading title from page \(clampedIndex + 1)..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let document = PDFDocument(url: sourceURL),
                      let page = document.page(at: clampedIndex) else {
                    throw NSError(domain: "NewOCR", code: 43, userInfo: [NSLocalizedDescriptionKey: "Could not read page \(clampedIndex + 1)."])
                }

                let image = try self.renderPageForTitleOCR(page)
                let title = try self.firstOCRRow(in: image)

                DispatchQueue.main.async {
                    self.isLoadingPDF = false
                    if let title, !title.isEmpty {
                        self.status = "Set title from page \(clampedIndex + 1)."
                        completion(title)
                    } else {
                        self.status = "No title text found on page \(clampedIndex + 1)."
                        completion(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoadingPDF = false
                    self.status = "Could not read title: \(error.localizedDescription)"
                    completion(nil)
                }
            }
        }
    }

    func saveCrop(normalizedRect: CGRect, openAddSplitAfterSave: Bool = false, completion: @escaping (Bool) -> Void) {
        let cropRect = normalizedRect.standardized
        guard cropRect.width >= 0.03, cropRect.height >= 0.03 else {
            status = "Crop area is too small."
            completion(false)
            return
        }

        isLoadingPDF = true
        status = "Saving cropped PDF..."
        let sourceURL = pdfURL

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let document = PDFDocument(url: sourceURL), document.pageCount > 0 else {
                    throw NSError(domain: "NewOCR", code: 31, userInfo: [NSLocalizedDescriptionKey: "Could not reload source PDF for cropping."])
                }

                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    let bounds = page.bounds(for: .cropBox)
                    let newBounds = CGRect(
                        x: bounds.minX + cropRect.minX * bounds.width,
                        y: bounds.minY + (1 - cropRect.maxY) * bounds.height,
                        width: cropRect.width * bounds.width,
                        height: cropRect.height * bounds.height
                    )
                    page.setBounds(newBounds, for: .cropBox)
                }
                if let outlineRoot = self.clonedOutlineRoot(from: document) {
                    document.outlineRoot = outlineRoot
                }

                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("pdf")
                guard document.write(to: temporaryURL) else {
                    throw NSError(domain: "NewOCR", code: 32, userInfo: [NSLocalizedDescriptionKey: "Could not write cropped PDF."])
                }

                let backupURL = self.backupPDFURL(for: sourceURL)
                try self.replaceSourcePDF(at: sourceURL, with: temporaryURL, backupURL: backupURL)
                try self.removeSplitFilesAfterCrop()
                let newBookmarkData = try sourceURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )

                DispatchQueue.main.async {
                    self.pdfURL = sourceURL
                    self.bookmarkData = newBookmarkData
                    try? self.saveCurrentSplitPlan()
                    self.loadProjectPDFs()
                    self.hasSavedCropInCurrentCropWindow = true
                    self.status = "Saved cropped PDF. Backup: \(backupURL.lastPathComponent)"
                    self.shouldOpenAddSplitWindowAfterLoad = openAddSplitAfterSave || self.shouldOpenAddSplitWindowAfterLoad
                    completion(true)
                    self.onSectionsSaved([])
                    self.loadPDF()
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "Could not crop PDF: \(error.localizedDescription)"
                    self.isLoadingPDF = false
                    completion(false)
                }
            }
        }
    }

    private func removeSplitFilesAfterCrop() throws {
        loadProjectPDFs()
        let sectionURLs = existingSectionPDFURLs()
        for url in sectionURLs where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        ranges = []
        isUsingFallbackRange = false
    }

    private func loadPDF() {
        isLoadingPDF = true
        status = "Loading PDF and reading bookmarks..."
        do {
            let resolvedURL: URL
            let loadedFromPath = FileManager.default.fileExists(atPath: pdfURL.path)
            var isStale = false
            if loadedFromPath {
                resolvedURL = pdfURL
            } else {
                resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isAccessingSecurityScopedResource {
                    pdfURL.stopAccessingSecurityScopedResource()
                }
                isAccessingSecurityScopedResource = resolvedURL.startAccessingSecurityScopedResource()
                pdfURL = resolvedURL
            }

            guard let document = PDFDocument(url: resolvedURL), document.pageCount > 0 else {
                status = "Could not read PDF from bookmark."
                isLoadingPDF = false
                return
            }

            pdfDocument = document
            pageCount = document.pageCount
            try? ensureOriginalPDFCopyExists(for: resolvedURL)
            let bookmarkRanges = splitRangesFromBookmarks(in: document)
            let savedRanges = loadSavedSplitRanges()
            hasPDFBookmarks = !bookmarkRanges.isEmpty
            isUsingFallbackRange = savedRanges.isEmpty && bookmarkRanges.isEmpty
            ranges = !savedRanges.isEmpty ? savedRanges : (!bookmarkRanges.isEmpty ? bookmarkRanges : [
                SplitPlanRange(
                    title: resolvedURL.deletingPathExtension().lastPathComponent,
                    pageFrom: "1",
                    pageTo: "\(document.pageCount)"
                )
            ])
            if !savedRanges.isEmpty {
                status = "\(savedRanges.count) split files"
            } else {
                status = bookmarkRanges.isEmpty ? "No PDF bookmarks found." : "Created \(bookmarkRanges.count) split files from PDF bookmarks."
            }
            isLoadingPDF = false
            if shouldOpenCropWindowAfterLoad {
                shouldOpenCropWindowAfterLoad = false
                openCropWindow()
                return
            }
            if shouldOpenAddSplitWindowAfterLoad {
                shouldOpenAddSplitWindowAfterLoad = false
                if canAddMoreSplits {
                    shouldWarnAddSplitCloseWithoutSplits = true
                    openAddSplitWindow()
                } else {
                    status = "All pages have already been split."
                    showLastPageAlreadyAlert()
                }
            }
        } catch {
            status = "Could not open PDF bookmark: \(error.localizedDescription)"
            isLoadingPDF = false
        }
    }

    private func splitRangesFromBookmarks(in document: PDFDocument) -> [SplitPlanRange] {
        let points = bookmarkSplitPoints(in: document)
        guard !points.isEmpty else { return [] }

        var uniquePoints: [PDFBookmarkSplitPoint] = []
        var seenPages: Set<Int> = []
        for point in points.sorted(by: { $0.pageNumber < $1.pageNumber }) {
            guard !seenPages.contains(point.pageNumber) else { continue }
            seenPages.insert(point.pageNumber)
            uniquePoints.append(point)
        }

        return uniquePoints.enumerated().map { index, point in
            let nextPage = uniquePoints.indices.contains(index + 1) ? uniquePoints[index + 1].pageNumber : document.pageCount + 1
            let pageTo = max(point.pageNumber, min(document.pageCount, nextPage - 1))
            return SplitPlanRange(
                title: point.title,
                pageFrom: "\(point.pageNumber)",
                pageTo: "\(pageTo)"
            )
        }
    }

    private func bookmarkSplitPoints(in document: PDFDocument) -> [PDFBookmarkSplitPoint] {
        guard let outlineRoot = document.outlineRoot else { return [] }
        var points: [PDFBookmarkSplitPoint] = []
        collectBookmarkSplitPoints(from: outlineRoot, document: document, points: &points)
        return points
    }

    private func clonedOutlineRoot(from document: PDFDocument) -> PDFOutline? {
        guard let outlineRoot = document.outlineRoot, outlineRoot.numberOfChildren > 0 else {
            return nil
        }

        let clonedRoot = PDFOutline()
        for index in 0..<outlineRoot.numberOfChildren {
            guard let child = outlineRoot.child(at: index),
                  let clonedChild = clonedOutline(child, document: document) else {
                continue
            }
            clonedRoot.insertChild(clonedChild, at: clonedRoot.numberOfChildren)
        }
        return clonedRoot.numberOfChildren > 0 ? clonedRoot : nil
    }

    private func clonedOutline(_ outline: PDFOutline, document: PDFDocument) -> PDFOutline? {
        let cloned = PDFOutline()
        cloned.label = outline.label
        if let destination = outline.destination,
           let page = destination.page {
            let pageIndex = document.index(for: page)
            if pageIndex != NSNotFound,
               let destinationPage = document.page(at: pageIndex) {
                cloned.destination = PDFDestination(page: destinationPage, at: destination.point)
            }
        } else if let action = outline.action {
            cloned.action = action
        }

        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index),
                  let clonedChild = clonedOutline(child, document: document) else {
                continue
            }
            cloned.insertChild(clonedChild, at: cloned.numberOfChildren)
        }

        return cloned.label != nil || cloned.destination != nil || cloned.action != nil || cloned.numberOfChildren > 0 ? cloned : nil
    }

    private func collectBookmarkSplitPoints(from outline: PDFOutline, document: PDFDocument, points: inout [PDFBookmarkSplitPoint]) {
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            if let destination = child.destination,
               let page = destination.page {
                let pageNumber = document.index(for: page) + 1
                if pageNumber >= 1 && pageNumber <= document.pageCount {
                    let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                    points.append(
                        PDFBookmarkSplitPoint(
                            title: title?.isEmpty == false ? title! : "Part \(points.count + 1)",
                            pageNumber: pageNumber
                        )
                    )
                }
            }
            collectBookmarkSplitPoints(from: child, document: document, points: &points)
        }
    }

    private func loadProjectPDFs() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: projectFolderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        projectPDFs = urls
            .filter(isSectionPDFURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { PDFFileItem(id: $0.path, url: $0) }
    }

    private func existingSectionPDFURLs() -> [URL] {
        projectPDFs
            .map(\.url)
            .filter { sectionPDFIndex($0) != nil }
            .sorted { left, right in
                let leftIndex = sectionPDFIndex(left) ?? 0
                let rightIndex = sectionPDFIndex(right) ?? 0
                if leftIndex != rightIndex {
                    return leftIndex < rightIndex
                }
                return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
            }
    }

    private func nextSectionPDFIndex() -> Int {
        let lastIndex = existingSectionPDFURLs()
            .compactMap(sectionPDFIndex)
            .max() ?? 0
        return lastIndex + 1
    }

    private func showLastPageAlreadyAlert() {
        let alert = NSAlert()
        alert.messageText = "All pages have already been split."
        alert.informativeText = "All pages in the original PDF are already covered by the created section files."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func backupPDFURL(for sourceURL: URL) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + "_bkp")
            .appendingPathExtension("pdf")
    }

    private func originalPDFURL(for sourceURL: URL) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + "_original")
            .appendingPathExtension("pdf")
    }

    private func ensureOriginalPDFCopyExists(for sourceURL: URL) throws {
        let originalURL = originalPDFURL(for: sourceURL)
        guard !FileManager.default.fileExists(atPath: originalURL.path),
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }
        try FileManager.default.copyItem(at: sourceURL, to: originalURL)
    }

    private func replaceSourcePDF(at sourceURL: URL, with temporaryURL: URL, backupURL: URL) throws {
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            try FileManager.default.moveItem(at: sourceURL, to: backupURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: sourceURL)
    }

    private func saveCurrentSplitPlan() throws {
        let payload: [String: Any] = [
            "sourcePDFName": pdfURL.lastPathComponent,
            "sourcePDFPath": pdfURL.path,
            "sourcePDFBookmark": bookmarkData.base64EncodedString(),
            "splitRanges": ranges
                .filter { range in
                    guard let file = range.file,
                          Int(range.pageFrom) != nil,
                          Int(range.pageTo) != nil else {
                        return false
                    }
                    return FileManager.default.fileExists(atPath: projectFolderURL.appendingPathComponent(file).path)
                }
                .map { range in
                    [
                        "file": range.file ?? "",
                        "title": range.title,
                        "pageFrom": range.pageFrom,
                        "pageTo": range.pageTo,
                    ]
                },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: projectFolderURL.appendingPathComponent("split-plan.json"), options: .atomic)
    }

    private func loadSavedSplitRanges() -> [SplitPlanRange] {
        let planURL = projectFolderURL.appendingPathComponent("split-plan.json")
        guard let data = try? Data(contentsOf: planURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRanges = payload["splitRanges"] as? [[String: Any]] else {
            return []
        }

        return rawRanges.compactMap { item in
            let title = item["title"] as? String ?? ""
            let pageFrom = item["pageFrom"] as? String ?? ""
            let pageTo = item["pageTo"] as? String ?? ""
            let file = item["file"] as? String
            guard let file,
                  !file.isEmpty,
                  Int(pageFrom) != nil,
                  Int(pageTo) != nil,
                  FileManager.default.fileExists(atPath: projectFolderURL.appendingPathComponent(file).path) else {
                return nil
            }
            return SplitPlanRange(title: title, pageFrom: pageFrom, pageTo: pageTo, file: file)
        }
    }

    private func documentForRange(_ range: SplitPlanRange, from document: PDFDocument) throws -> PDFDocument {
        guard let from = Int(range.pageFrom),
              let to = Int(range.pageTo),
              from >= 1,
              to >= from,
              to <= document.pageCount else {
            throw NSError(domain: "NewOCR", code: 39, userInfo: [NSLocalizedDescriptionKey: "Invalid range \(range.pageFrom)-\(range.pageTo)."])
        }

        let outputDocument = PDFDocument()
        for pageNumber in from...to {
            guard let page = document.page(at: pageNumber - 1) else { continue }
            outputDocument.insert(page, at: outputDocument.pageCount)
        }

        guard outputDocument.pageCount > 0 else {
            throw NSError(domain: "NewOCR", code: 40, userInfo: [NSLocalizedDescriptionKey: "No pages found in range \(range.pageFrom)-\(range.pageTo)."])
        }

        return outputDocument
    }

    private func pageIndex(from value: String) -> Int? {
        guard pageCount > 0, let pageNumber = Int(value) else { return nil }
        let clampedPageNumber = min(max(pageNumber, 1), pageCount)
        return clampedPageNumber - 1
    }

    private func renderPageForTitleOCR(_ page: PDFPage, scale: CGFloat = 2.0) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "NewOCR", code: 44, userInfo: [NSLocalizedDescriptionKey: "Could not render PDF page."])
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw NSError(domain: "NewOCR", code: 45, userInfo: [NSLocalizedDescriptionKey: "Could not create page image."])
        }
        return image
    }

    private func firstOCRRow(in image: CGImage) throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["th-TH", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? [])
            .sorted { first, second in
                let yDifference = abs(first.boundingBox.minY - second.boundingBox.minY)
                if yDifference > 0.01 {
                    return first.boundingBox.minY > second.boundingBox.minY
                }
                return first.boundingBox.minX < second.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

struct LayoutAreaEditorWindowView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var state: LayoutAreaEditorState
    @State private var isSelectedSectionsPopoverPresented = false
    @State private var isLayoutAreasReportPresented = false
    @State private var pendingDuplicateRule: OCRLayoutAreaRule?
    @State private var layoutZoomScale: CGFloat = 1.0  // kept for legacy; preview now always fits page
    @State private var previewImage: NSImage? = nil
    @State private var isPreviewLoading: Bool = false
    @State private var previewImageKey: String = ""
    @State private var displayedImageKey: String = ""
    @State private var isProgrammaticScroll = false
    @State private var isUserScrollDriven = false

    private let areaTypes: [(id: String, label: String, icon: String)] = [
        ("header", "Section Title", "book.closed"),
        ("h2", "H2", "textformat.size"),
        ("header3", "H3", "textformat.size.smaller"),
        ("blockquote", "Quote", "quote.bubble"),
        ("image", "Image", "photo"),
        ("image_desc", "Image Description", "captions.bubble.fill"),
        ("footnote", "Footnote", "text.badge.plus"),
        ("refmark", "Ref Mark", "textformat.superscript"),
        ("ignore", "Ignore", "eye.slash")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 16) {
                sectionList

                VStack(alignment: .leading, spacing: 16) {
                    controls
                    HStack(alignment: .top, spacing: 12) {
                        statusBar
                        preview
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 22)
        .padding(.horizontal, 36)
        .padding(.bottom, 22)
        .frame(minWidth: 0, minHeight: 720)
        .background(NewOCRMainPalette.windowBackground)
        .buttonStyle(NewOCRButtonStyle())
        .onChange(of: state.selectedPage) { _, newValue in
            state.selectedPage = min(max(newValue, 1), max(state.pageCount, 1))
        }
        .onChange(of: state.selectedPDFPath) { _, _ in
            loadPreviewImageAsync()
        }
        .onChange(of: state.selectedPage) { _, _ in
            loadPreviewImageAsync()
        }
        .onAppear {
            loadPreviewImageAsync()
        }
        .sheet(isPresented: $isLayoutAreasReportPresented) {
            LayoutAreasReportView(isPresented: $isLayoutAreasReportPresented, state: state, sectionFileName: state.selectedScope == "all_sections" ? nil : state.primarySelectedLayoutSectionName)
                .environmentObject(appState)
                .onDisappear {
                    appState.reloadAllSavedRules(into: state)
                }
        }
        .sheet(item: $pendingDuplicateRule) { duplicate in
            DuplicateRuleWarningView(
                duplicateRule: duplicate,
                onCancel: {
                    pendingDuplicateRule = nil
                },
                onContinue: {
                    pendingDuplicateRule = nil
                    performSave()
                }
            )
        }
    }

    private func performSave() {
        guard let url = state.selectedPDFURL else { return }
        let markersValue = markersApply(to: state.selectedType) ? state.markers : nil
        let anchorWordValue = state.selectedType == "refmark"
            ? (state.anchorWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : state.anchorWord.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        let codexTextValue = codexTextApplies(to: state.selectedType)
            ? (state.codexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : state.codexText.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        do {
            let count: Int
            if let loadedRule = state.loadedRule {
                count = try appState.updateLayoutAreaRule(
                    loadedRule,
                    with: state.selectedType,
                    newScope: state.selectedScope,
                    newCurrentSectionURL: url,
                    newSelectedSectionURLs: state.selectedLayoutSectionItems.map(\.url),
                    newPageNumber: state.selectedPage,
                    newRect: state.normalizedOCRRect,
                    newMarkers: markersValue,
                    newAnchorWord: anchorWordValue,
                    newCodexText: codexTextValue
                )
                state.loadedRule = nil
                state.status = "Updated \(displayName(for: state.selectedType)) area."
            } else {
                count = try appState.saveLayoutAreaRules(
                    type: state.selectedType,
                    scope: state.selectedScope,
                    currentSectionURL: url,
                    selectedSectionURLs: state.selectedLayoutSectionItems.map(\.url),
                    pageNumber: state.selectedPage,
                    rect: state.normalizedOCRRect,
                    markers: markersValue,
                    anchorWord: anchorWordValue,
                    codexText: codexTextValue
                )
                state.status = savedStatusMessage(for: state.selectedType)
            }
            state.savedRuleCount = count
            appState.reloadAllSavedRules(into: state)
        } catch {
            state.status = "Could not save: \(error.localizedDescription)"
        }
    }

    private func markersApply(to type: String) -> Bool {
        type == "footnote" || type == "refmark" || type == "image" || type == "image_desc"
    }

    private func codexTextApplies(to type: String) -> Bool {
        type == "header" || type == "h2" || type == "header3" || type == "blockquote" || type == "footnote" || type == "image_desc"
    }

    private func loadPreviewImageAsync() {
        guard let url = state.selectedPDFURL else {
            previewImage = nil
            isPreviewLoading = false
            return
        }
        let page = state.selectedPage
        let key = "\(url.path):\(page)"
        guard key != previewImageKey else { return }
        previewImageKey = key
        // Don't clear previewImage — keep old image visible to avoid layout jump
        isPreviewLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let image = appState.layoutAreaPreviewImage(pdfURL: url, pageNumber: page)
            DispatchQueue.main.async {
                guard self.previewImageKey == key else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    self.previewImage = image
                    self.displayedImageKey = key
                    self.isPreviewLoading = false
                }
            }
        }
    }

    private func toggleSectionCheck(_ item: PDFFileItem) {
        let path = item.url.path
        state.selectPDFPath(path)
        state.selectedPage = 1  // always start from page 1 on a manual section switch

        if state.sectionSelectionMode == "single" {
            // Single mode: always select exactly the tapped section.
            state.selectedLayoutSectionPaths = [path]
            if state.selectedScope == "selected_sections" || state.selectedScope == "all_sections" {
                state.selectedScope = "section"
            }
            return
        }

        // Multiple mode: original toggle behaviour.
        if state.selectedScope == "all_sections" {
            state.selectedLayoutSectionPaths = [path]
            state.selectedScope = "section"
            return
        }

        if state.selectedLayoutSectionPaths.contains(path) {
            guard state.selectedLayoutSectionPaths.count > 1 else { return }
            state.selectedLayoutSectionPaths.remove(path)
            if state.selectedLayoutSectionPaths.count == 1,
               state.selectedScope == "selected_sections" {
                state.selectedScope = "section"
            }
            if state.selectedPDFPath == path,
               let next = state.selectedLayoutSectionPaths.first {
                state.selectPDFPath(next)
            }
        } else {
            state.selectedLayoutSectionPaths.insert(path)
            if state.selectedLayoutSectionPaths.count > 1 {
                state.selectedScope = "selected_sections"
            } else if state.selectedScope != "page" {
                state.selectedScope = "section"
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.94))
                    .frame(width: 58, height: 58)
                    .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.black)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Define Layout")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                if !state.status.isEmpty {
                    Text(state.status)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Text("\(state.visibleSavedRuleCount) saved")
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(NewOCRMainPalette.primaryText)
                .lineLimit(1)
                .frame(minWidth: 96, alignment: .trailing)

            OCRIconButton(
                title: "View Rules",
                systemImage: "list.bullet.rectangle",
                backgroundColor: state.loadedRule != nil ? Color(red: 30/255, green: 139/255, blue: 238/255).opacity(0.5) : Color(red: 30/255, green: 139/255, blue: 238/255),
                foregroundColor: .white,
                size: 44
            ) {
                isLayoutAreasReportPresented = true
            }
            .disabled(state.loadedRule != nil)

            OCRIconButton(
                title: "Clear Rules",
                systemImage: "trash",
                backgroundColor: state.loadedRule != nil ? Color(red: 255/255, green: 71/255, blue: 71/255).opacity(0.5) : Color(red: 255/255, green: 71/255, blue: 71/255),
                foregroundColor: .white,
                size: 44
            ) {
                clearRules()
            }
            .disabled(state.loadedRule != nil)

            if state.loadedRule != nil {
                OCRIconButton(
                    title: "Cancel",
                    systemImage: "arrow.uturn.left",
                    backgroundColor: Color(red: 100/255, green: 110/255, blue: 130/255),
                    foregroundColor: .white,
                    size: 44
                ) {
                    state.clearLoadedRule()
                    isLayoutAreasReportPresented = true
                }
                .help("Cancel editing and return to View Rules")
            }

            OCRIconButton(
                title: state.loadedRule != nil ? "Update Rule" : "Save Area",
                systemImage: state.loadedRule != nil ? "pencil.and.list.clipboard" : "square.and.arrow.down",
                backgroundColor: state.loadedRule != nil ? Color(red: 255/255, green: 159/255, blue: 64/255) : Color(red: 53/255, green: 200/255, blue: 90/255),
                foregroundColor: .black,
                size: 44
            ) {
                saveCurrentArea()
            }

            OCRIconButton(
                title: "Close",
                systemImage: "xmark",
                backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255),
                foregroundColor: .white,
                size: 44
            ) {
                NSApp.keyWindow?.close()
            }
        }
    }

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Sections")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Spacer()
                Text("\(state.pdfItems.count)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
            }

            // Single / Multiple selection mode picker
            HStack(spacing: 0) {
                ForEach(["Single", "Multiple"], id: \.self) { mode in
                    let isActive = state.sectionSelectionMode == mode.lowercased()
                    Button(mode) {
                        guard state.sectionSelectionMode != mode.lowercased() else { return }
                        state.sectionSelectionMode = mode.lowercased()
                        if mode.lowercased() == "single", state.selectedLayoutSectionPaths.count > 1 {
                            state.selectedLayoutSectionPaths = [state.selectedPDFPath]
                            if state.selectedScope == "selected_sections" {
                                state.selectedScope = "section"
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isActive ? Color.black : NewOCRMainPalette.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(isActive ? Color.white.opacity(0.88) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .animation(.easeInOut(duration: 0.12), value: isActive)
                }
            }
            .padding(2)
            .frame(maxWidth: .infinity)
            .background(NewOCRMainPalette.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("\(state.selectedLayoutSectionPaths.count) of \(state.pdfItems.count) selected")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(NewOCRMainPalette.primaryText)

                        Spacer()

                        let isSelectAllDisabled = state.sectionSelectionMode == "single"
                            || state.pdfItems.isEmpty
                            || state.selectedLayoutSectionPaths.count == state.pdfItems.count
                        Button("Select All") {
                            state.setAllLayoutSectionsSelected(true)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelectAllDisabled ? NewOCRMainPalette.tertiaryText : Color.white)
                        .disabled(isSelectAllDisabled)

                        Rectangle()
                            .fill(NewOCRMainPalette.stroke)
                            .frame(width: 1, height: 14)

                        Button("Unselect All") {
                            state.setAllLayoutSectionsSelected(false)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.selectedLayoutSectionPaths.isEmpty ? NewOCRMainPalette.tertiaryText : Color.white)
                        .disabled(state.selectedLayoutSectionPaths.isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(NewOCRMainPalette.panelBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                    )

                    ForEach(state.pdfItems) { item in
                        LayoutAreaSectionRow(
                            item: item,
                            isChecked: state.selectedLayoutSectionPaths.contains(item.url.path),
                            isCurrentPreview: state.selectedLayoutSectionPaths.contains(item.url.path) && item.url.path == state.selectedPDFPath && state.selectedScope != "all_sections",
                            pageCount: state.pageCount(for: item)
                        ) {
                            toggleSectionCheck(item)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NewOCRMainPalette.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )
        }
        .padding(12)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusBar: some View {
        if let pdfURL = state.selectedPDFURL {
            let totalPages = max(state.pageCount, 1)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 10) {
                        ForEach(1...totalPages, id: \.self) { page in
                            let isSelected = state.selectedPage == page
                            let thumb = appState.layoutAreaPreviewImage(pdfURL: pdfURL, pageNumber: page)
                            VStack(spacing: 6) {
                                Group {
                                    if let thumb {
                                        Image(nsImage: thumb)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxWidth: .infinity)
                                    } else {
                                        NewOCRMainPalette.fieldBackground
                                            .frame(maxWidth: .infinity, minHeight: 100)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isSelected ? Color.accentColor : NewOCRMainPalette.stroke,
                                                lineWidth: isSelected ? 2.5 : 1)
                                )
                                .shadow(color: Color.black.opacity(isSelected ? 0.25 : 0.08), radius: isSelected ? 6 : 2)

                                Text("Page \(page)")
                                    .font(.system(size: 11, weight: isSelected ? .bold : .regular).monospacedDigit())
                                    .foregroundStyle(isSelected ? Color.accentColor : NewOCRMainPalette.secondaryText)
                            }
                            .padding(8)
                            .background(isSelected ? Color.accentColor.opacity(0.08) : NewOCRMainPalette.panelBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .id(page)
                            .onTapGesture { state.selectedPage = page }
                            .pointingHandCursor()
                        }
                    }
                    .padding(8)
                }
                .onChange(of: state.selectedPage) { _, page in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(page, anchor: .center)
                    }
                }
                .onChange(of: state.selectedPDFPath) { _, _ in
                    proxy.scrollTo(state.selectedPage, anchor: .center)
                }
                .onAppear {
                    proxy.scrollTo(state.selectedPage, anchor: .center)
                }
            }
            .frame(width: 140)
            .frame(maxHeight: .infinity)
            .background(NewOCRMainPalette.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )
        }
    }

    private var controls: some View {
        let showCodexRow = state.loadedRule != nil && !state.codexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    if markersApply(to: state.selectedType) {
                        markersField
                            .frame(width: 300)
                    }
                    Spacer(minLength: 4)
                    typeButtons
                    Spacer(minLength: 12)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        if markersApply(to: state.selectedType) {
                            markersField
                                .frame(width: 300)
                        }
                    }
                    typeButtons
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showCodexRow {
                Divider().overlay(NewOCRMainPalette.stroke)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 100/255, green: 180/255, blue: 255/255))
                        .padding(.top, 3)

                    ZStack(alignment: .topLeading) {
                        if state.codexText.isEmpty {
                            Text("Codex text override…")
                                .font(.system(size: 13))
                                .foregroundStyle(NewOCRMainPalette.tertiaryText)
                                .italic()
                                .allowsHitTesting(false)
                                .padding(.leading, 4)
                                .padding(.top, 2)
                        }
                        TextEditor(text: $state.codexText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(NewOCRMainPalette.primaryText)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .frame(minHeight: 52, maxHeight: 96)
                    }

                    Button {
                        state.codexText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NewOCRMainPalette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Clear Codex text override")
                    .padding(.top, 2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(NewOCRMainPalette.fieldBackground)
            }
        }
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(showCodexRow ? Color(red: 100/255, green: 180/255, blue: 255/255).opacity(0.45) : NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }

    private var typeButtons: some View {
        HStack(spacing: 8) {
            ForEach(areaTypes, id: \.id) { type in
                LayoutAreaTypeButton(
                    title: type.label,
                    systemImage: type.icon,
                    isSelected: state.selectedType == type.id
                ) {
                    state.selectedType = type.id
                    if !markersApply(to: type.id) {
                        state.markers = ""
                    }
                    if type.id != "refmark" {
                        state.anchorWord = ""
                    }
                    if !codexTextApplies(to: type.id) {
                        state.codexText = ""
                    }
                    let pageOnlyTypes: Set<String> = ["image", "image_desc", "blockquote", "footnote", "refmark"]
                    if pageOnlyTypes.contains(type.id) {
                        if state.selectedScope == "all_sections" {
                            state.selectedLayoutSectionPaths = Set([state.selectedPDFPath].filter { !$0.isEmpty })
                        }
                        state.selectedScope = "page"
                    }
                }
            }
        }
    }

    private var markersField: some View {
        let isRefmark   = state.selectedType == "refmark"
        let isImage     = state.selectedType == "image"
        let isImageDesc = state.selectedType == "image_desc"

        if isRefmark {
            return AnyView(
                HStack(spacing: 6) {
                    // Ref label field
                    Image(systemName: "textformat.superscript")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                    TextField("Ref label (e.g. 1)", text: $state.markers)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.black)
                        .frame(width: 60)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.black.opacity(0.22), lineWidth: 1)
                        )
                        .help("Marker label — inserted as [^\u{200B}label] after the anchor word")

                    // Anchor word field
                    Image(systemName: "character.cursor.ibeam")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                        .padding(.leading, 4)
                    TextField("Word in area", text: $state.anchorWord)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.black)
                        .frame(width: 130)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.black.opacity(0.22), lineWidth: 1)
                        )
                        .help("Exact word from the selected area — [^\u{200B}label] is inserted right after this word during OCR")
                }
                .padding(.leading, 8)
            )
        }

        let placeholder: String
        let helpText: String
        let fieldIcon: String
        if isImage {
            placeholder = "Image label (e.g. Image#1)"
            helpText    = "Unique label for this image — OCR maps it to a matching Image Description area"
            fieldIcon   = "photo"
        } else if isImageDesc {
            placeholder = "Matching image label (e.g. Image#1)"
            helpText    = "Must match the label of an Image area — description is placed right after that image in the output"
            fieldIcon   = "captions.bubble"
        } else {
            placeholder = "Labels (e.g. 1,2,3)"
            helpText    = "Comma-separated labels assigned to footnote lines in order"
            fieldIcon   = "list.number"
        }

        return AnyView(
            HStack(spacing: 6) {
                Image(systemName: fieldIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                TextField(placeholder, text: $state.markers)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.black)
                    .frame(width: (isImage || isImageDesc) ? 200 : 160)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.black.opacity(0.22), lineWidth: 1)
                    )
                    .help(helpText)
            }
            .padding(.leading, 8)
        )
    }

    private var codexTextPanel: some View {
        let typeColorMap: [String: Color] = [
            "header": Color(red: 60/255, green: 120/255, blue: 220/255),
            "h2": Color(red: 60/255, green: 120/255, blue: 220/255),
            "header3": Color(red: 60/255, green: 120/255, blue: 220/255),
            "blockquote": Color(red: 210/255, green: 130/255, blue: 60/255),
            "footnote": Color(red: 60/255, green: 180/255, blue: 100/255),
            "image_desc": Color(red: 210/255, green: 170/255, blue: 60/255)
        ]
        let accentColor = typeColorMap[state.selectedType] ?? Color(red: 100/255, green: 160/255, blue: 255/255)
        let hasText = !state.codexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            // Header strip
            HStack(spacing: 8) {
                Image(systemName: "text.quote")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text("Codex Text Override")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                Text("— replaces Vision OCR for this area during OCR runs")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                Spacer(minLength: 0)
                if hasText {
                    Button {
                        state.codexText = ""
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Clear")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 7)

            Divider().overlay(NewOCRMainPalette.stroke)

            // Text editor
            ZStack(alignment: .topLeading) {
                if state.codexText.isEmpty {
                    Text("Paste or type the Codex-detected text here. During OCR, this text replaces Vision recognition for the drawn rectangle.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(NewOCRMainPalette.tertiaryText)
                        .italic()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $state.codexText)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(minHeight: 64, maxHeight: 120)
            }
            .background(NewOCRMainPalette.fieldBackground)
        }
        .background(NewOCRMainPalette.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(hasText ? accentColor.opacity(0.55) : NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var preview: some View {
        if let pdfURL = state.selectedPDFURL {
            let totalPages = max(state.pageCount, 1)
            GeometryReader { container in
                let pageWidth = max(container.size.width - 48, 100) * state.previewZoom
                ScrollViewReader { scrollProxy in
                    ScrollView([.vertical, .horizontal], showsIndicators: true) {
                        LazyVStack(spacing: 20) {
                            ForEach(1...totalPages, id: \.self) { page in
                                LayoutAreaPageCard(
                                    page: page,
                                    pdfURL: pdfURL,
                                    pageWidth: pageWidth,
                                    isActive: state.loadedRule != nil
                                        ? page == (state.loadedRule?.page ?? 1)
                                        : state.selectedPage == page,
                                    isLoading: state.selectedPage == page && isPreviewLoading,
                                    selectionRect: $state.selectionRect,
                                    appState: appState
                                ) {
                                    if state.selectedPage != page { state.selectedPage = page }
                                }
                                .id(page)
                                .background(
                                    GeometryReader { geo in
                                        let minY = geo.frame(in: .named("mainScroll")).minY
                                        // Page whose top edge is nearest the visible top wins
                                        let isAtTop = minY > -60 && minY < 160
                                        Color.clear.preference(
                                            key: LayoutScrollPageKey.self,
                                            value: isAtTop ? page : nil
                                        )
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                    }
                    .coordinateSpace(name: "mainScroll")
                    .onPreferenceChange(LayoutScrollPageKey.self) { page in
                        guard let page, !isProgrammaticScroll, page != state.selectedPage else { return }
                        isUserScrollDriven = true
                        state.selectedPage = page
                        DispatchQueue.main.async { isUserScrollDriven = false }
                    }
                    .onChange(of: state.selectedPage) { _, newPage in
                        guard !isUserScrollDriven else { return }
                        isProgrammaticScroll = true
                        withAnimation(.easeInOut(duration: 0.25)) {
                            scrollProxy.scrollTo(newPage, anchor: .top)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            isProgrammaticScroll = false
                        }
                    }
                    .onChange(of: state.selectedPDFPath) { _, _ in
                        isProgrammaticScroll = true
                        DispatchQueue.main.async {
                            scrollProxy.scrollTo(state.selectedPage, anchor: .top)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            isProgrammaticScroll = false
                        }
                    }
                    .onAppear {
                        isProgrammaticScroll = true
                        DispatchQueue.main.async {
                            scrollProxy.scrollTo(state.selectedPage, anchor: .top)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            isProgrammaticScroll = false
                        }
                    }
                }
            }
            .frame(minWidth: 0, minHeight: 460)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NewOCRMainPalette.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(NewOCRMainPalette.stroke, lineWidth: 1))
            .overlay(alignment: .bottom) { previewZoomBar }
        } else {
            ContentUnavailableView("No PDF Preview", systemImage: "doc.richtext")
                .foregroundStyle(NewOCRMainPalette.primaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NewOCRMainPalette.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var previewZoomBar: some View {
        HStack(spacing: 4) {
            Button {
                state.previewZoom = max(0.25, state.previewZoom - 0.25)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.previewZoom <= 0.25)
            .opacity(state.previewZoom <= 0.25 ? 0.4 : 1)

            Button {
                state.previewZoom = 1.0
            } label: {
                Text("\(Int((state.previewZoom * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 42)
            }
            .buttonStyle(.plain)
            .help("Click to reset to 100%")

            Button {
                state.previewZoom = min(4.0, state.previewZoom + 0.25)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.previewZoom >= 4.0)
            .opacity(state.previewZoom >= 4.0 ? 0.4 : 1)
        }
        .foregroundStyle(NewOCRMainPalette.primaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(NewOCRMainPalette.panelBackground.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(NewOCRMainPalette.stroke, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.14), radius: 4, x: 0, y: 2)
        .padding(.bottom, 10)
        .pointingHandCursor()
    }

    private func saveCurrentArea() {
        guard let url = state.selectedPDFURL else { return }
        let normalizedRect = state.normalizedOCRRect
        let cleanScope = state.selectedScope

        var duplicateFound: OCRLayoutAreaRule? = nil

        switch cleanScope {
        case "all_sections":
            duplicateFound = appState.findDuplicateRule(
                type: state.selectedType,
                scope: "all_sections",
                section: nil,
                page: nil,
                rect: normalizedRect,
                excludingRule: state.loadedRule
            )
        case "selected_sections":
            for sectionURL in state.selectedLayoutSectionItems.map(\.url) {
                if let dup = appState.findDuplicateRule(
                    type: state.selectedType,
                    scope: nil,
                    section: sectionURL.lastPathComponent,
                    page: nil,
                    rect: normalizedRect,
                    excludingRule: state.loadedRule
                ) {
                    duplicateFound = dup
                    break
                }
            }
        case "page":
            duplicateFound = appState.findDuplicateRule(
                type: state.selectedType,
                scope: nil,
                section: url.lastPathComponent,
                page: state.selectedPage,
                rect: normalizedRect,
                excludingRule: state.loadedRule
            )
        default: // "section"
            duplicateFound = appState.findDuplicateRule(
                type: state.selectedType,
                scope: nil,
                section: url.lastPathComponent,
                page: nil,
                rect: normalizedRect,
                excludingRule: state.loadedRule
            )
        }

        if let duplicate = duplicateFound {
            pendingDuplicateRule = duplicate
            return
        }

        let markersValue = markersApply(to: state.selectedType) ? state.markers : nil
        let anchorWordValue = state.selectedType == "refmark"
            ? (state.anchorWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : state.anchorWord.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        let codexTextValue = codexTextApplies(to: state.selectedType)
            ? (state.codexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : state.codexText.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        do {
            let count: Int
            if let loadedRule = state.loadedRule {
                count = try appState.updateLayoutAreaRule(
                    loadedRule,
                    with: state.selectedType,
                    newScope: state.selectedScope,
                    newCurrentSectionURL: url,
                    newSelectedSectionURLs: state.selectedLayoutSectionItems.map(\.url),
                    newPageNumber: state.selectedPage,
                    newRect: state.normalizedOCRRect,
                    newMarkers: markersValue,
                    newAnchorWord: anchorWordValue,
                    newCodexText: codexTextValue
                )
                state.loadedRule = nil
                state.status = "Updated \(displayName(for: state.selectedType)) area."
            } else {
                count = try appState.saveLayoutAreaRules(
                    type: state.selectedType,
                    scope: state.selectedScope,
                    currentSectionURL: url,
                    selectedSectionURLs: state.selectedLayoutSectionItems.map(\.url),
                    pageNumber: state.selectedPage,
                    rect: state.normalizedOCRRect,
                    markers: markersValue,
                    anchorWord: anchorWordValue,
                    codexText: codexTextValue
                )
                state.status = savedStatusMessage(for: state.selectedType)
            }
            state.savedRuleCount = count
            appState.reloadAllSavedRules(into: state)
        } catch {
            state.status = "Could not save: \(error.localizedDescription)"
        }
    }

    private func savedStatusMessage(for type: String) -> String {
        let areaName = displayName(for: type)
        return "Saved \(areaName) area for current section page \(state.selectedPage)."
    }

    private func clearRules() {
        let alert = NSAlert()
        alert.messageText = "Clear Layout Rules?"
        alert.informativeText = "This removes all saved header, quote, image, image description, footnote, ref mark, and ignore layout areas for the current project."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try appState.clearLayoutAreaRules()
            state.savedRuleCount = 0
            state.allSavedRules = []
            state.status = "Cleared layout rules."
        } catch {
            state.status = "Could not clear rules: \(error.localizedDescription)"
        }
    }

    private func displayName(for type: String) -> String {
        switch type {
        case "header":     return "section title"
        case "h2":         return "H2 heading"
        case "header3":    return "H3 subheading"
        case "blockquote": return "quote"
        case "image":      return "image"
        case "image_desc": return "image description"
        case "footnote":   return "footnote"
        case "refmark":    return "ref mark"
        case "ignore":     return "ignore"
        default:           return "layout"
        }
    }
}

private struct LayoutScrollPageKey: PreferenceKey {
    static let defaultValue: Int? = nil
    static func reduce(value: inout Int?, nextValue: () -> Int?) {
        if value == nil { value = nextValue() }
    }
}

private struct LayoutAreaPageCard: View {
    let page: Int
    let pdfURL: URL
    let pageWidth: CGFloat
    let isActive: Bool
    let isLoading: Bool
    @Binding var selectionRect: CGRect
    let appState: AppState
    let onActivate: () -> Void

    var body: some View {
        let thumb = appState.layoutAreaPreviewImage(pdfURL: pdfURL, pageNumber: page)
        let aspectRatio = thumb.map { $0.size.height / max($0.size.width, 1) } ?? 1.41
        let pageHeight = pageWidth * aspectRatio
        let imageFrame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        ZStack(alignment: .topLeading) {
            if let img = thumb {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: pageWidth, height: pageHeight)
            } else {
                NewOCRMainPalette.panelBackground
                    .frame(width: pageWidth, height: pageHeight)
            }

            if isActive {
                LayoutAreaOverlayView(selectionRect: $selectionRect, imageFrame: imageFrame)
            }

            Text("p\(page)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isActive ? Color.accentColor : Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(8)

            if isLoading {
                ProgressView().controlSize(.small)
                    .padding(8)
                    .background(NewOCRMainPalette.panelBackground.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
            }
        }
        .frame(width: pageWidth, height: pageHeight)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(isActive ? Color.accentColor : NewOCRMainPalette.stroke.opacity(0.5),
                        lineWidth: isActive ? 2.5 : 1)
        )
        .shadow(
            color: Color.black.opacity(isActive ? 0.22 : 0.10),
            radius: isActive ? 8 : 3, x: 0, y: 2
        )
        .onTapGesture(perform: onActivate)
        .pointingHandCursor()
    }
}

private struct NewOCRPageSlider: View {
    @Binding var page: Int
    let pageCount: Int
    var dragSensitivity: CGFloat = 1.18

    private var totalPages: Int {
        max(pageCount, 1)
    }

    private var sliderPageCount: Int {
        max(totalPages, 2)
    }

    private var isEnabled: Bool {
        totalPages > 1
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = CGFloat(max(min(page, totalPages), 1) - 1) / CGFloat(sliderPageCount - 1)
            let knobSize: CGFloat = 22
            let trackHeight: CGFloat = 10
            let knobX = min(max(progress * width, knobSize / 2), width - knobSize / 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(isEnabled ? 0.22 : 0.12))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color(red: 30/255, green: 139/255, blue: 238/255).opacity(isEnabled ? 1 : 0.45))
                    .frame(width: max(knobX, knobSize / 2), height: trackHeight)

                Circle()
                    .fill(isEnabled ? Color.white : Color.white.opacity(0.60))
                    .frame(width: knobSize, height: knobSize)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.20), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(isEnabled ? 0.22 : 0.10), radius: 4, x: 0, y: 2)
                    .offset(x: knobX - knobSize / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        let acceleratedX = value.location.x + value.translation.width * (dragSensitivity - 1)
                        let clampedX = min(max(acceleratedX, 0), width)
                        let nextPage = Int((clampedX / width * CGFloat(sliderPageCount - 1)).rounded()) + 1
                        page = min(max(nextPage, 1), totalPages)
                    }
            )
        }
        .frame(height: 34)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel("Page")
        .accessibilityValue("\(page) of \(totalPages)")
    }
}

private struct LayoutPageScrollbar: View {
    @Binding var page: Int
    let totalPages: Int
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let trackH = geo.size.height
            let thumbH = max(24, trackH / max(1, CGFloat(totalPages)))
            let travel = max(0, trackH - thumbH)
            let fraction = totalPages > 1 ? CGFloat(page - 1) / CGFloat(totalPages - 1) : 0
            let thumbY = fraction * travel

            ZStack(alignment: .top) {
                // Track
                RoundedRectangle(cornerRadius: 3)
                    .fill(NewOCRMainPalette.fieldBackground)
                    .frame(width: 8)
                    .frame(maxHeight: .infinity)

                // Thumb
                RoundedRectangle(cornerRadius: 3)
                    .fill(isDragging ? Color.white.opacity(0.7) : Color.white.opacity(0.45))
                    .frame(width: 8, height: thumbH)
                    .offset(y: thumbY)
                    .animation(.easeOut(duration: 0.1), value: thumbY)
            }
            .frame(width: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let f = max(0, min(1, value.location.y / trackH))
                        let newPage = Int((f * CGFloat(totalPages - 1)).rounded()) + 1
                        page = max(1, min(totalPages, newPage))
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(width: 14)
        .padding(.vertical, 6)
    }
}

private struct LayoutAreaTypeButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : NewOCRMainPalette.primaryText)
            .frame(width: 62, height: 48)
            .background(isSelected ? Color(red: 30/255, green: 139/255, blue: 238/255) : NewOCRMainPalette.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.18) : (isHovered ? NewOCRMainPalette.primaryText.opacity(0.30) : NewOCRMainPalette.stroke), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isHovered ? 0.13 : 0.06), radius: isHovered ? 6 : 3, x: 0, y: isHovered ? 2 : 1)
        }
        .buttonStyle(.plain)
        .frame(width: 62, height: 48)
        .contentShape(Rectangle())
        .background(FloatingTooltip(title: title, isEnabled: true))
        .accessibilityLabel(title)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            if isHovered {
                NSCursor.arrow.set()
                isHovered = false
            }
        }
    }
}

private struct LayoutAreaSelectedSectionsModal: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var state: LayoutAreaEditorState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 52, height: 52)
                    Image(systemName: "checklist")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Selected Sections")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.primaryText)
                    Text("\(state.selectedLayoutSectionItems.count) of \(state.pdfItems.count) selected")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                }

                Spacer()

                OCRIconButton(
                    title: "Select All",
                    systemImage: "checkmark.square",
                    backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255),
                    foregroundColor: .black,
                    size: 34
                ) {
                    state.setAllLayoutSectionsSelected(true)
                }

                OCRIconButton(
                    title: "Unselect All",
                    systemImage: "square",
                    backgroundColor: Color.white.opacity(0.92),
                    foregroundColor: .black,
                    size: 34
                ) {
                    state.setAllLayoutSectionsSelected(false)
                }

                OCRIconButton(
                    title: "OK",
                    systemImage: "checkmark",
                    backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255),
                    foregroundColor: .black,
                    size: 34
                ) {
                    close()
                }

                OCRIconButton(
                    title: "Close",
                    systemImage: "xmark",
                    backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255),
                    foregroundColor: .white,
                    size: 34
                ) {
                    close()
                }
            }

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(state.pdfItems) { item in
                        LayoutAreaSelectedSectionRow(
                            item: item,
                            isSelected: state.isLayoutSectionSelected(item),
                            previewImage: appState.layoutAreaPreviewImage(pdfURL: item.url, pageNumber: 1)
                        ) {
                            state.setLayoutSection(item, selected: !state.isLayoutSectionSelected(item))
                        }
                    }
                }
                .padding(8)
            }
            .frame(width: 520, height: 420)
            .background(NewOCRMainPalette.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )
        }
        .padding(18)
        .frame(width: 590, height: 540)
        .background(NewOCRMainPalette.panelBackground)
    }
}

private struct LayoutAreaSelectedSectionRow: View {
    let item: PDFFileItem
    let isSelected: Bool
    let previewImage: NSImage?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(red: 53/255, green: 200/255, blue: 90/255) : NewOCRMainPalette.secondaryText)
                    .frame(width: 32)

                Group {
                    if let previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        NewOCRMainPalette.fieldBackground
                    }
                }
                .frame(width: 58, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(8)
            .background(isSelected ? Color(red: 30/255, green: 139/255, blue: 238/255).opacity(0.26) : (isHovered ? NewOCRMainPalette.rowBackground.opacity(0.78) : NewOCRMainPalette.rowBackground.opacity(0.55)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color(red: 30/255, green: 139/255, blue: 238/255) : NewOCRMainPalette.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            if isHovered {
                NSCursor.arrow.set()
                isHovered = false
            }
        }
    }
}

private struct LayoutAreaSectionRow: View {
    let item: PDFFileItem
    let isChecked: Bool
    let isCurrentPreview: Bool
    let pageCount: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isChecked ? Color(red: 30/255, green: 139/255, blue: 238/255) : NewOCRMainPalette.tertiaryText)
                    .frame(width: 24)

                Image(systemName: "doc.richtext")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(pageCount > 0 ? "\(pageCount) pages" : item.fileName)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(NewOCRMainPalette.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isCurrentPreview ? Color(red: 30/255, green: 139/255, blue: 238/255) :
                        isChecked ? Color(red: 30/255, green: 139/255, blue: 238/255).opacity(0.45) :
                        NewOCRMainPalette.stroke,
                        lineWidth: isCurrentPreview ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    private var rowBackground: Color {
        if isCurrentPreview { return Color(red: 30/255, green: 139/255, blue: 238/255).opacity(0.28) }
        if isChecked { return Color(red: 30/255, green: 139/255, blue: 238/255).opacity(0.10) }
        if isHovered { return NewOCRMainPalette.rowBackground }
        return NewOCRMainPalette.panelBackground
    }
}

private struct LayoutAreaOverlayView: View {
    @Binding var selectionRect: CGRect
    let imageFrame: CGRect
    @State private var dragStartRect: CGRect? = nil
    @State private var drawStartPoint: CGPoint? = nil
    private let handleSize: CGFloat = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .gesture(drawGesture)

            outsideShade

            Rectangle()
                .fill(Color.accentColor.opacity(0.10))
                .border(Color.accentColor, width: 2)
                .frame(width: selectionFrame.width, height: selectionFrame.height)
                .position(x: selectionFrame.midX, y: selectionFrame.midY)
                .gesture(moveGesture)

            cropHandle(.topLeft)
            cropHandle(.topRight)
            cropHandle(.bottomLeft)
            cropHandle(.bottomRight)
        }
        .frame(width: imageFrame.maxX, height: imageFrame.maxY, alignment: .topLeading)
    }

    private var normalizedRect: CGRect {
        LayoutAreaEditorState.clampedSelection(selectionRect)
    }

    private var selectionFrame: CGRect {
        let rect = normalizedRect
        return CGRect(
            x: imageFrame.minX + rect.minX * imageFrame.width,
            y: imageFrame.minY + rect.minY * imageFrame.height,
            width: rect.width * imageFrame.width,
            height: rect.height * imageFrame.height
        )
    }

    private var outsideShade: some View {
        Path { path in
            path.addRect(imageFrame)
            path.addRect(selectionFrame)
        }
        .fill(Color.black.opacity(0.12), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let currentPoint = clampedPoint(value.location)
                if drawStartPoint == nil {
                    drawStartPoint = clampedPoint(value.startLocation)
                }
                let startPoint = drawStartPoint ?? currentPoint
                selectionRect = normalizedRect(from: startPoint, to: currentPoint)
            }
            .onEnded { _ in
                drawStartPoint = nil
                selectionRect = LayoutAreaEditorState.clampedSelection(selectionRect)
            }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartRect == nil {
                    dragStartRect = normalizedRect
                }
                let start = dragStartRect ?? normalizedRect
                let dx = value.translation.width / max(imageFrame.width, 1)
                let dy = value.translation.height / max(imageFrame.height, 1)
                selectionRect = LayoutAreaEditorState.clampedSelection(
                    CGRect(x: start.minX + dx, y: start.minY + dy, width: start.width, height: start.height)
                )
            }
            .onEnded { _ in
                dragStartRect = nil
            }
    }

    private func cropHandle(_ corner: CropCorner) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: handleSize, height: handleSize)
            .position(handlePosition(for: corner))
            .gesture(handleGesture(corner))
    }

    private func handlePosition(for corner: CropCorner) -> CGPoint {
        switch corner {
        case .topLeft:
            return CGPoint(x: selectionFrame.minX, y: selectionFrame.minY)
        case .topRight:
            return CGPoint(x: selectionFrame.maxX, y: selectionFrame.minY)
        case .bottomLeft:
            return CGPoint(x: selectionFrame.minX, y: selectionFrame.maxY)
        case .bottomRight:
            return CGPoint(x: selectionFrame.maxX, y: selectionFrame.maxY)
        }
    }

    private func handleGesture(_ corner: CropCorner) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartRect == nil {
                    dragStartRect = normalizedRect
                }

                let start = dragStartRect ?? normalizedRect
                let dx = value.translation.width / max(imageFrame.width, 1)
                let dy = value.translation.height / max(imageFrame.height, 1)
                var minX = start.minX
                var maxX = start.maxX
                var minY = start.minY
                var maxY = start.maxY

                switch corner {
                case .topLeft:
                    minX += dx
                    minY += dy
                case .topRight:
                    maxX += dx
                    minY += dy
                case .bottomLeft:
                    minX += dx
                    maxY += dy
                case .bottomRight:
                    maxX += dx
                    maxY += dy
                }

                selectionRect = clampedFromEdges(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
            }
            .onEnded { _ in
                dragStartRect = nil
            }
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, imageFrame.minX), imageFrame.maxX),
            y: min(max(point.y, imageFrame.minY), imageFrame.maxY)
        )
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let minX = (min(start.x, end.x) - imageFrame.minX) / max(imageFrame.width, 1)
        let maxX = (max(start.x, end.x) - imageFrame.minX) / max(imageFrame.width, 1)
        let minY = (min(start.y, end.y) - imageFrame.minY) / max(imageFrame.height, 1)
        let maxY = (max(start.y, end.y) - imageFrame.minY) / max(imageFrame.height, 1)
        return clampedFromEdges(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func clampedFromEdges(minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat) -> CGRect {
        let lowerX = min(max(minX, 0), 0.98)
        let lowerY = min(max(minY, 0), 0.98)
        let upperX = max(min(maxX, 1), lowerX + 0.02)
        let upperY = max(min(maxY, 1), lowerY + 0.02)
        return CGRect(x: lowerX, y: lowerY, width: upperX - lowerX, height: upperY - lowerY)
    }
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = pow(10.0, CGFloat(places))
        return (self * factor).rounded() / factor
    }
}

private func layoutAreaAspectFitRect(imageSize: NSSize, containerSize: CGSize, zoomScale: CGFloat = 1.0) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
        return CGRect(origin: .zero, size: containerSize)
    }

    let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height) * max(zoomScale, 0.1)
    let width = imageSize.width * scale
    let height = imageSize.height * scale
    return CGRect(
        x: (containerSize.width - width) / 2,
        y: (containerSize.height - height) / 2,
        width: width,
        height: height
    )
}

struct CropPDFWindowView: View {
    @EnvironmentObject private var planner: SplitPlannerState
    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var previewPageIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "crop")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                HStack(spacing: 9) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Crop PDF")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(NewOCRMainPalette.primaryText)
                        Text(planner.pdfName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NewOCRMainPalette.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(NewOCRMainPalette.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
                .frame(maxWidth: 420, alignment: .leading)

                Spacer()

                OCRIconButton(title: "Save Crop", systemImage: "square.and.arrow.down", backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255), size: 42) {
                    guard planner.confirmCropSaveIfNeeded() else { return }
                    let window = NSApp.keyWindow
                    planner.saveCrop(normalizedRect: cropRect, openAddSplitAfterSave: true) { saved in
                        if saved {
                            window?.close()
                        }
                    }
                }
                .disabled(planner.isLoadingPDF)

                OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white, size: 42) {
                    NSApp.keyWindow?.close()
                }
            }

            HStack(spacing: 14) {
                Text("Page \(min(previewPageIndex + 1, max(planner.pageCount, 1))) / \(max(planner.pageCount, 1))")
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(NewOCRMainPalette.primaryText)
                    .frame(width: 120, alignment: .leading)

                NewOCRPageSlider(
                    page: Binding(
                        get: { min(previewPageIndex + 1, max(planner.pageCount, 1)) },
                        set: { value in
                            previewPageIndex = min(max(value - 1, 0), max(planner.pageCount - 1, 0))
                        }
                    ),
                    pageCount: max(planner.pageCount, 1),
                    dragSensitivity: 1.24
                )
                .frame(minWidth: 380, maxWidth: .infinity)

                Spacer(minLength: 0)

            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(NewOCRMainPalette.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )

            if planner.isLoadingPDF {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(planner.status)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NewOCRMainPalette.tertiaryText)
                    Spacer()
                }
                .padding(10)
                .background(NewOCRMainPalette.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
            }

            if let image = planner.cropPreviewImage(pageIndex: previewPageIndex) {
                GeometryReader { proxy in
                    let imageFrame = aspectFitRect(imageSize: image.size, containerSize: proxy.size)

                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)

                        CropOverlayView(cropRect: $cropRect, imageFrame: imageFrame)
                    }
                }
                .frame(minWidth: 720, minHeight: 500)
                .background(NewOCRMainPalette.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
            } else {
                ContentUnavailableView("No PDF Preview", systemImage: "doc.richtext", description: Text("Load the source PDF before cropping."))
                    .frame(minWidth: 720, minHeight: 500)
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
            }
        }
        .padding(22)
        .frame(minWidth: 820, minHeight: 620)
        .background(NewOCRMainPalette.windowBackground)
        .buttonStyle(NewOCRButtonStyle())
        .onChange(of: planner.pageCount) { _, newValue in
            previewPageIndex = min(previewPageIndex, max(newValue - 1, 0))
        }
    }

    private func aspectFitRect(imageSize: NSSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
    }
}

private struct AddSplitActionButtonStyle: ButtonStyle {
    let backgroundColor: Color
    let foregroundColor: Color
    var fontSize: CGFloat = 16
    var paddingH: CGFloat = 11
    var paddingV: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        AddSplitActionButtonBody(configuration: configuration, backgroundColor: backgroundColor, foregroundColor: foregroundColor, fontSize: fontSize, paddingH: paddingH, paddingV: paddingV)
    }
}

private struct AddSplitActionButtonBody: View {
    let configuration: AddSplitActionButtonStyle.Configuration
    let backgroundColor: Color
    let foregroundColor: Color
    var fontSize: CGFloat = 16
    var paddingH: CGFloat = 11
    var paddingV: CGFloat = 9
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(isEnabled ? foregroundColor : foregroundColor.opacity(0.38))
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .background(isEnabled ? (configuration.isPressed ? backgroundColor.opacity(0.70) : (isHovered ? backgroundColor.opacity(0.86) : backgroundColor)) : backgroundColor.opacity(0.32))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
            .modifier(PointingHandCursorModifier(isEnabled: isEnabled))
    }
}

struct AddSplitWindowView: View {
    @EnvironmentObject private var planner: SplitPlannerState
    @State private var previewPageIndex = 0
    @State private var titleText = ""
    @State private var pageFrom = "1"
    @State private var pageTo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "scissors")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                HStack(spacing: 9) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(planner.pdfName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NewOCRMainPalette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(planner.ranges.count) split files")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NewOCRMainPalette.tertiaryText)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(NewOCRMainPalette.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
                .frame(maxWidth: 300, alignment: .leading)

                OCRIconButton(title: "Detect Split", systemImage: "list.bullet.rectangle", backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255), foregroundColor: .white, size: 58) {
                    showDetectSplit()
                }
                .disabled(planner.isLoadingPDF || planner.pageCount == 0)

                Spacer(minLength: 12)

                OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white) {
                    NSApp.keyWindow?.close()
                }
            }

            HStack(spacing: 8) {
                    Button {
                        setPreviewPageIndex(max(previewPageIndex - 1, 0))
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(AddSplitActionButtonStyle(
                        backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255),
                        foregroundColor: .white
                    ))
                    .disabled(previewPageIndex <= 0 || planner.pageCount == 0)

                    Text("\(min(previewPageIndex + 1, max(planner.pageCount, 1))) / \(max(planner.pageCount, 1))")
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .foregroundStyle(NewOCRMainPalette.primaryText)
                        .frame(minWidth: 68)

                    Button {
                        setPreviewPageIndex(min(previewPageIndex + 1, max(planner.pageCount - 1, 0)))
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(AddSplitActionButtonStyle(
                        backgroundColor: Color(red: 30/255, green: 139/255, blue: 238/255),
                        foregroundColor: .white
                    ))
                    .disabled(previewPageIndex >= planner.pageCount - 1 || planner.pageCount == 0)

                    Rectangle()
                        .fill(NewOCRMainPalette.stroke)
                        .frame(width: 1, height: 30)

                    Button {
                        pageFrom = "\(previewPageIndex + 1)"
                    } label: {
                        Label("From", systemImage: "arrow.right.to.line")
                    }
                    .buttonStyle(AddSplitActionButtonStyle(
                        backgroundColor: Color(red: 184/255, green: 135/255, blue: 98/255),
                        foregroundColor: .white
                    ))
                    .disabled(planner.pageCount == 0 || !planner.canAddMoreSplits)

                    Button {
                        pageTo = "\(previewPageIndex + 1)"
                    } label: {
                        Label("To", systemImage: "arrow.left.to.line")
                    }
                    .buttonStyle(AddSplitActionButtonStyle(
                        backgroundColor: Color(red: 184/255, green: 135/255, blue: 98/255),
                        foregroundColor: .white
                    ))
                    .disabled(planner.pageCount == 0)

                    Button {
                        setTitleFromCurrentPage()
                    } label: {
                        Label("Title", systemImage: "textformat")
                    }
                    .buttonStyle(AddSplitActionButtonStyle(
                        backgroundColor: Color(red: 255/255, green: 182/255, blue: 216/255),
                        foregroundColor: Color(red: 17/255, green: 17/255, blue: 17/255)
                    ))
                    .disabled(planner.isLoadingPDF || planner.pageCount == 0)

                    Rectangle()
                        .fill(NewOCRMainPalette.stroke)
                        .frame(width: 1, height: 30)

                    TextField("Section title", text: $titleText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.black)
                        .tint(Color.yellow)
                        .accentColor(Color.yellow)
                        .frame(minWidth: 170)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.94))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.black.opacity(0.18), lineWidth: 1)
                        )

                    TextField("From", text: $pageFrom)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17).monospacedDigit())
                        .foregroundStyle(NewOCRMainPalette.primaryText)
                        .frame(width: 64)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 9)
                        .background(NewOCRMainPalette.fieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                        )

                    TextField("To", text: $pageTo)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17).monospacedDigit())
                        .foregroundStyle(NewOCRMainPalette.primaryText)
                        .frame(width: 64)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 9)
                        .background(NewOCRMainPalette.fieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                        )

                    Button {
                        saveSplit()
                    } label: {
                        Image(systemName: "scissors")
                            .font(.system(size: 22, weight: .semibold))
                    }
                    .buttonStyle(AddSplitActionButtonStyle(
                        backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255),
                        foregroundColor: Color(red: 17/255, green: 17/255, blue: 17/255),
                        paddingH: 16,
                        paddingV: 11
                    ))
                    .keyboardShortcut(.defaultAction)
                    .disabled(planner.isLoadingPDF || !planner.canAddMoreSplits || planner.pageCount == 0)
            }
            .padding(10)
            .background(NewOCRMainPalette.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
            )

            if let image = planner.cropPreviewImage(pageIndex: previewPageIndex) {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .frame(maxWidth: .infinity, minHeight: 500)
                .background(NewOCRMainPalette.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
            } else {
                ContentUnavailableView("No PDF Preview", systemImage: "doc.richtext", description: Text("Load the source PDF before adding splits."))
                    .frame(maxWidth: .infinity, minHeight: 500)
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(22)
        .background(NewOCRMainPalette.windowBackground)
        .buttonStyle(NewOCRButtonStyle())
        .onAppear {
            resetRange()
        }
        .onChange(of: planner.pageCount) { _, _ in resetRange() }
    }

    private func showDetectSplit() {
        planner.openDetectSplitWindow()
    }

    private func saveSplit() {
        planner.addSplit(title: titleText, pageFrom: pageFrom, pageTo: pageTo) { saved, nextFrom in
            if saved {
                if nextFrom > planner.pageCount {
                    pageFrom = "\(nextFrom)"
                    pageTo = "\(planner.pageCount)"
                    previewPageIndex = max(planner.pageCount - 1, 0)
                } else {
                    pageTo = "\(planner.pageCount)"
                    setPreviewPageIndex(min(max(nextFrom - 1, 0), max(planner.pageCount - 1, 0)), updatePageFrom: true)
                    setTitleFromCurrentPage()
                }
            }
        }
    }

    private func resetRange() {
        let nextFrom = planner.nextAddSplitFromPage()
        pageFrom = "\(nextFrom)"
        pageTo = "\(max(planner.pageCount, nextFrom))"
        if nextFrom > planner.pageCount {
            pageTo = "\(planner.pageCount)"
            previewPageIndex = max(planner.pageCount - 1, 0)
        } else {
            setPreviewPageIndex(min(max(nextFrom - 1, 0), max(planner.pageCount - 1, 0)), updatePageFrom: true)
        }
    }

    private func setPreviewPageIndex(_ index: Int, updatePageFrom: Bool? = nil) {
        let clampedIndex = min(max(index, 0), max(planner.pageCount - 1, 0))
        previewPageIndex = clampedIndex
        let pageNumber = "\(clampedIndex + 1)"
        if let updatePageFrom {
            if updatePageFrom {
                pageFrom = pageNumber
            } else {
                pageTo = pageNumber
            }
        } else if titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pageFrom = pageNumber
        } else {
            pageTo = pageNumber
        }
    }

    private func setTitleFromCurrentPage() {
        planner.titleFromPage(pageIndex: previewPageIndex) { title in
            if let title {
                titleText = title
            }
        }
    }
}

struct DetectSplitWindowView: View {
    @EnvironmentObject private var planner: SplitPlannerState
    @ObservedObject var state: DetectSplitSelectionState
    let thumbnail: (SplitPlanRange) -> NSImage?
    let splitAction: () -> Void
    let closeAction: () -> Void

    private var selectedCount: Int {
        state.ranges.filter { state.selectedIDs.contains($0.id) }.count
    }

    private var hasUnselectedRanges: Bool {
        selectedCount < state.ranges.count
    }

    private var hasSelectedRanges: Bool {
        selectedCount > 0
    }

    private var statusFont: Font {
        .system(size: 15, weight: .semibold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.black)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Detect Split")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(NewOCRMainPalette.primaryText)
                    Text(state.ranges.isEmpty ? "No PDF bookmarks found" : "\(state.ranges.count) bookmark ranges found")
                        .font(statusFont)
                        .foregroundStyle(NewOCRMainPalette.tertiaryText)
                }

                Spacer()

                OCRIconButton(
                    title: "Select All",
                    systemImage: "checkmark.square.fill",
                    backgroundColor: detectSplitSelectionBlue,
                    foregroundColor: .white,
                    size: 38
                ) {
                    state.selectedIDs = Set(state.ranges.map(\.id))
                }
                .disabled(state.ranges.isEmpty || !hasUnselectedRanges)

                OCRIconButton(
                    title: "Unselect All",
                    systemImage: "square",
                    backgroundColor: detectSplitSelectionBlue,
                    foregroundColor: .white,
                    size: 38
                ) {
                    state.selectedIDs.removeAll()
                }
                .disabled(state.ranges.isEmpty || !hasSelectedRanges)

                OCRIconButton(title: "Split", systemImage: "scissors", backgroundColor: Color(red: 53/255, green: 200/255, blue: 90/255), size: 38) {
                    splitAction()
                }
                .disabled(planner.isLoadingPDF || selectedCount == 0)

                OCRIconButton(title: "Close", systemImage: "xmark", backgroundColor: Color(red: 255/255, green: 71/255, blue: 71/255), foregroundColor: .white, size: 38) {
                    closeAction()
                }
            }

            if state.ranges.isEmpty {
                ContentUnavailableView("No Bookmarks", systemImage: "bookmark.slash", description: Text("No bookmark ranges were found in the current working PDF."))
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .foregroundStyle(NewOCRMainPalette.secondaryText)
                    .background(NewOCRMainPalette.panelBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                    )
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.ranges) { range in
                            DetectSplitRangeRow(
                                range: Binding(
                                    get: { state.ranges.first(where: { $0.id == range.id }) ?? range },
                                    set: { updatedRange in
                                        guard let index = state.ranges.firstIndex(where: { $0.id == range.id }) else { return }
                                        state.ranges[index] = updatedRange
                                    }
                                ),
                                isSelected: Binding(
                                    get: { state.selectedIDs.contains(range.id) },
                                    set: { isSelected in
                                        if isSelected {
                                            state.selectedIDs.insert(range.id)
                                        } else {
                                            state.selectedIDs.remove(range.id)
                                        }
                                    }
                                ),
                                thumbnail: thumbnail(state.ranges.first(where: { $0.id == range.id }) ?? range)
                            )
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 360, maxHeight: 620)
                .background(NewOCRMainPalette.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                )
            }

            HStack {
                Text("\(selectedCount) selected")
                    .font(statusFont)
                    .foregroundStyle(NewOCRMainPalette.tertiaryText)
                Spacer()
            }
        }
        .padding(22)
        .frame(width: 1240)
        .frame(minHeight: 680)
        .background(NewOCRMainPalette.windowBackground)
        .background(ClearInitialFirstResponderView())
        .buttonStyle(NewOCRButtonStyle())
    }
}

private struct DetectSplitRangeRow: View {
    @Binding var range: SplitPlanRange
    @Binding var isSelected: Bool
    let thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            NewOCRLargeCheckboxButton(
                title: isSelected ? "Selected for split" : "Not selected for split",
                isChecked: $isSelected,
                checkedColor: detectSplitSelectionBlue
            )

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 300, height: 400)
                    .background(NewOCRMainPalette.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(NewOCRMainPalette.stroke, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(NewOCRMainPalette.fieldBackground)
                    .frame(width: 300, height: 400)
                    .overlay(
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(NewOCRMainPalette.tertiaryText)
                    )
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: $range.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .tint(Color.yellow)
                    .accentColor(Color.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.black.opacity(0.18), lineWidth: 1)
                    )

                HStack(spacing: 10) {
                    DetectSplitField(label: "From", value: $range.pageFrom)
                    DetectSplitField(label: "To", value: $range.pageTo)
                }
            }
            .frame(width: 360, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(NewOCRMainPalette.fieldBackground.opacity(isSelected ? 1 : 0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? detectSplitSelectionBlue : NewOCRMainPalette.stroke, lineWidth: 1)
        )
    }
}

private struct DetectSplitField: View {
    let label: String
    @Binding var value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NewOCRMainPalette.tertiaryText)
            TextField(label, text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.black)
                .tint(Color.yellow)
                .accentColor(Color.yellow)
                .frame(width: 72)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.black.opacity(0.18), lineWidth: 1)
        )
    }
}

struct CropOverlayView: View {
    @Binding var cropRect: CGRect
    let imageFrame: CGRect
    @State private var dragStartRect: CGRect? = nil
    private let handleSize: CGFloat = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            outsideShade

            Rectangle()
                .fill(Color.clear)
                .border(Color.accentColor, width: 2)
                .background(Color.accentColor.opacity(0.08))
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .gesture(moveGesture)

            cropHandle(.topLeft)
            cropHandle(.topRight)
            cropHandle(.bottomLeft)
            cropHandle(.bottomRight)
        }
        .frame(width: imageFrame.maxX, height: imageFrame.maxY, alignment: .topLeading)
    }

    private var cropFrame: CGRect {
        CGRect(
            x: imageFrame.minX + cropRect.minX * imageFrame.width,
            y: imageFrame.minY + cropRect.minY * imageFrame.height,
            width: cropRect.width * imageFrame.width,
            height: cropRect.height * imageFrame.height
        )
    }

    private var outsideShade: some View {
        Path { path in
            path.addRect(imageFrame)
            path.addRect(cropFrame)
        }
        .fill(Color.black.opacity(0.32), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartRect == nil {
                    dragStartRect = cropRect
                }
                let start = dragStartRect ?? cropRect
                let dx = value.translation.width / max(imageFrame.width, 1)
                let dy = value.translation.height / max(imageFrame.height, 1)
                cropRect = clamped(
                    CGRect(
                        x: start.minX + dx,
                        y: start.minY + dy,
                        width: start.width,
                        height: start.height
                    )
                )
            }
            .onEnded { _ in
                dragStartRect = nil
            }
    }

    private func cropHandle(_ corner: CropCorner) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: handleSize, height: handleSize)
            .position(handlePosition(for: corner))
            .gesture(handleGesture(corner))
    }

    private func handlePosition(for corner: CropCorner) -> CGPoint {
        switch corner {
        case .topLeft:
            return CGPoint(x: cropFrame.minX, y: cropFrame.minY)
        case .topRight:
            return CGPoint(x: cropFrame.maxX, y: cropFrame.minY)
        case .bottomLeft:
            return CGPoint(x: cropFrame.minX, y: cropFrame.maxY)
        case .bottomRight:
            return CGPoint(x: cropFrame.maxX, y: cropFrame.maxY)
        }
    }

    private func handleGesture(_ corner: CropCorner) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartRect == nil {
                    dragStartRect = cropRect
                }

                let start = dragStartRect ?? cropRect
                let dx = value.translation.width / max(imageFrame.width, 1)
                let dy = value.translation.height / max(imageFrame.height, 1)
                var minX = start.minX
                var maxX = start.maxX
                var minY = start.minY
                var maxY = start.maxY

                switch corner {
                case .topLeft:
                    minX += dx
                    minY += dy
                case .topRight:
                    maxX += dx
                    minY += dy
                case .bottomLeft:
                    minX += dx
                    maxY += dy
                case .bottomRight:
                    maxX += dx
                    maxY += dy
                }

                cropRect = clampedFromEdges(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
            }
            .onEnded { _ in
                dragStartRect = nil
            }
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, 0.03), 1)
        let height = min(max(rect.height, 0.03), 1)
        let x = min(max(rect.minX, 0), 1 - width)
        let y = min(max(rect.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func clampedFromEdges(minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat) -> CGRect {
        let lowerX = min(max(minX, 0), 0.97)
        let lowerY = min(max(minY, 0), 0.97)
        let upperX = max(min(maxX, 1), lowerX + 0.03)
        let upperY = max(min(maxY, 1), lowerY + 0.03)
        return CGRect(x: lowerX, y: lowerY, width: upperX - lowerX, height: upperY - lowerY)
    }
}

private enum CropCorner {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

struct FilteredTextControlsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Filtered text")
                .font(.headline)

            HStack(spacing: 10) {
                TextField("Text to remove, separated by comma", text: $appState.filteredText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)
                    .disabled(appState.isOCRRunning)

                FilterLineCountField(
                    title: "Top",
                    value: $appState.filterTopLines,
                    isDisabled: appState.isOCRRunning
                )

                FilterLineCountField(
                    title: "Bottom",
                    value: $appState.filterBottomLines,
                    isDisabled: appState.isOCRRunning
                )
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct FilterLineCountField: View {
    let title: String
    @Binding var value: String
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("1", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .disabled(isDisabled)
        }
    }
}

@main
struct NewOCRApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .windowStyle(.titleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        appState?.closeAllApplicationWindows()
        for window in sender.windows {
            forceCloseWindowAndAttachedSheets(window)
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
