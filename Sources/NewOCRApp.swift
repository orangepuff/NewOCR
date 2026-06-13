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
}

private func isSectionPDFURL(_ url: URL) -> Bool {
    guard url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame else {
        return false
    }
    let stem = url.deletingPathExtension().lastPathComponent
    return stem.range(of: #"^section-\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
}

private struct OCRLine: Codable {
    let text: String
    let left: CGFloat
    let right: CGFloat
    let bottom: CGFloat
    let top: CGFloat

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
    let markdown: String
    let imageURL: URL
    let left: CGFloat
    let right: CGFloat
    let bottom: CGFloat
    let top: CGFloat
}

private struct OCRPageMarkdown {
    let pageNumber: Int
    var text: String
    let firstTextLineContinuesPreviousPage: Bool
    let lastTextLineCanContinueNextPage: Bool
}

private extension String {
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
        didSet {}
    }

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

    @Published var pdfTitles: [String: String] = [:] {
        didSet {
            if !isRestoring {
                save()
            }
        }
    }

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

    @Published var pdfListMinHeight: CGFloat = 420
    @Published var mainWindowWidth: CGFloat = 780
    @Published var mainWindowHeight: CGFloat = 520
    @Published var shouldOpenMainWindowFullScreen: Bool = false
    @Published var ocrParagraphTextAreaMinHeight: CGFloat = 58
    @Published var ocrWindowWidth: CGFloat = 820
    @Published var ocrWindowHeight: CGFloat = 620
    @Published var shouldOpenOCRWindowFullScreen: Bool = false
    @Published var splitPDFWindowWidth: CGFloat = 980
    @Published var splitPDFWindowHeight: CGFloat = 680
    @Published var shouldOpenSplitPDFWindowFullScreen: Bool = true
    @Published var newProjectsFolderPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)
        .path

    @Published private(set) var pdfFiles: [PDFFileItem] = []

    private let defaults = UserDefaults.standard
    private var isRestoring = false
    private var ocrWindows: [NSWindow] = []
    private var splitPlannerWindows: [NSWindow] = []
    private var activeConfigFileURL: URL?

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

    var configFileURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("config.txt")
    }

    var ocrInstructionFileURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("OCRInstruction")
    }

    var configEditorPath: String {
        (activeConfigFileURL ?? configFileURL).path
    }

    var isHeaderFooterReviewOpen: Bool {
        configEditorTitle == "Header/Footer Review"
    }

    var headerFooterReviewRemoveItems: [String] {
        parseHeaderFooterReviewRemoveItems(from: configText)
    }

    var conversionHelperURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/apple_vision_convert.py")
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
            openSplitPlannerWindow(bookmarkData: bookmarkData, fallbackURL: project.sourcePDFURL, projectFolderURL: project.folderURL)
        } catch {
            configStatus = "Could not create new project: \(error.localizedDescription)"
        }
    }

    func openSelectedFolderSplitPlan() {
        guard !selectedFolderPath.isEmpty else {
            configStatus = "No working folder selected."
            showAlert(title: "No Working Folder", message: configStatus)
            return
        }

        let projectFolderURL = URL(fileURLWithPath: selectedFolderPath, isDirectory: true)
        do {
            let plan = try loadOrCreateSplitPlan(from: projectFolderURL)
            openSplitPlannerWindow(bookmarkData: plan.bookmarkData, fallbackURL: plan.sourcePDFURL, projectFolderURL: projectFolderURL)
        } catch {
            configStatus = "Could not open split plan: \(error.localizedDescription)"
            showAlert(title: "Could Not Open Split", message: error.localizedDescription)
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
        try fileManager.copyItem(at: temporaryPDFURL ?? pdfURL, to: copiedPDFURL)
        if let temporaryPDFURL {
            try? fileManager.removeItem(at: temporaryPDFURL)
        }
        return (projectFolderURL, copiedPDFURL)
    }

    private func saveSplitPlan(bookmarkData: Data, sourcePDFURL: URL, projectFolderURL: URL) throws {
        let payload: [String: Any] = [
            "sourcePDFName": sourcePDFURL.lastPathComponent,
            "sourcePDFPath": sourcePDFURL.path,
            "sourcePDFBookmark": bookmarkData.base64EncodedString(),
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
        let sourceURL = appFolderURL.appendingPathComponent(name, isDirectory: true)
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

    private func openSplitPlannerWindow(bookmarkData: Data, fallbackURL: URL, projectFolderURL: URL) {
        let plannerState = SplitPlannerState(bookmarkData: bookmarkData, fallbackURL: fallbackURL, projectFolderURL: projectFolderURL) { savedTitles in
            for (url, title) in savedTitles {
                self.pdfTitles[url.path] = title
            }
            if self.selectedFolderPath == projectFolderURL.path {
                self.loadPDFFiles()
                self.saveBookSections()
            }
        }

        let initialRect: NSRect
        if shouldOpenSplitPDFWindowFullScreen, let visibleFrame = NSScreen.main?.visibleFrame {
            initialRect = visibleFrame
        } else {
            initialRect = NSRect(x: 0, y: 0, width: splitPDFWindowWidth, height: splitPDFWindowHeight)
        }

        let window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "New Split Plan - \(fallbackURL.lastPathComponent)"
        if shouldOpenSplitPDFWindowFullScreen {
            window.setFrame(initialRect, display: true)
        } else {
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: SplitPlannerWindowView()
                .environmentObject(plannerState)
        )
        splitPlannerWindows.append(window)
        window.makeKeyAndOrderFront(nil)
    }

    func beginOCR(for item: PDFFileItem) {
        selectedPDFPath = item.url.path
        currentStep = 1
        isOCRRunning = false
        logOutput = ""

        if item.isManualSection {
            if let markdownText = loadAppleVisionMarkdownText() {
                ocrText = markdownText
                updateSelectedPDFTitleFromOCRText(markdownText)
                ocrStatus = "Loaded existing Markdown."
                logOutput = "Loaded Markdown:\n\(localAppleVisionOutputFolderURL?.path ?? "")"
            } else {
                ocrText = "\n"
                ocrStatus = "Ready. Add text, then save Markdown."
                logOutput = "Manual section has no PDF. Save will create Markdown."
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
            skipProcessOCREngine = false
            ocrStatus = "Ready. Click OCR to start."
        }
        openOCRWindow()
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
        window.makeKeyAndOrderFront(nil)
    }

    func openConfigEditor() {
        openTextConfig(title: "Config File", url: configFileURL)
    }

    func openOCRInstructionEditor() {
        openTextConfig(title: "OCRInstruction", url: ocrInstructionFileURL)
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

        let folderURL = URL(fileURLWithPath: selectedFolderPath)
            .appendingPathComponent("CoverImage", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let destinationURL = folderURL.appendingPathComponent("\(outputStem).\(fileExtension)")
        if sourceURL.standardizedFileURL.path == destinationURL.standardizedFileURL.path {
            return destinationURL
        }

        let existingCoverFiles = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        for fileURL in existingCoverFiles where fileURL.deletingPathExtension().lastPathComponent == outputStem {
            try? FileManager.default.removeItem(at: fileURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
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
        ensureConfigFilesExist()
        activeConfigFileURL = url
        configEditorTitle = title
        configText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        configStatus = "Editing \(url.path)"
        isConfigEditorPresented = true
    }

    func saveConfigFile() {
        ensureConfigFilesExist()
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
    }

    func saveOCRTextFile() {
        guard let markdownFolderURL = localAppleVisionOutputFolderURL else {
            ocrStatus = "No PDF selected."
            logOutput = ""
            return
        }

        do {
            try saveAppleVisionMarkdownText(ocrText, folderURL: markdownFolderURL)
            ocrStatus = "Saved Markdown."
            logOutput = """
            Saved Markdown:
            \(markdownFolderURL.path)
            """
            ocrSaveAlertMessage = "Saved Markdown:\n\(markdownFolderURL.path)"
            isOCRSaveAlertPresented = true
        } catch {
            ocrStatus = "Could not save Markdown."
            logOutput = error.localizedDescription
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
            let title = pdfTitles[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? displayName(for: item)
            return [
                "pdf": item.url.path,
                "title": title.isEmpty ? displayName(for: item) : title,
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
        let frontCoverPath = frontCoverImagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let backCoverPath = backCoverImagePath.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        self.isEPUBBuiltAlertPresented = false
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
            let updatedCSS = blockquoteResult.css
            let progressLines = [
                "Image CSS: \(imageResult.status)",
                "Footnote CSS: \(footnoteResult.status)",
                "Blockquote CSS: \(blockquoteResult.status)",
            ]
            if updatedCSS == existingCSS {
                epubStatus = "CSS already up to date."
                let message = """
                Stylesheet already matches NewOCR CSS:
                \(stylesheetURL.path)

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
        .footnote-ref {
          font-size: 0.75em;
          line-height: 0;
          vertical-align: super;
        }

        .footnote-ref a {
          color: inherit;
          text-decoration: none;
        }

        .footnotes {
          margin-top: 2rem;
          padding-top: 1rem;
          border-top: 1px solid #d0d0d0;
          font-size: 0.9em;
          line-height: 1.5;
        }

        .footnotes ol {
          margin: 0;
          padding-left: 1.5rem;
        }

        .footnotes li {
          margin-bottom: 0.5rem;
        }

        .footnote-back {
          margin-left: 0.25rem;
          text-decoration: none;
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

    func openOCRMarkdownPreviewWindow() {
        guard let markdownFolderURL = localAppleVisionOutputFolderURL else {
            ocrStatus = "No PDF selected."
            return
        }

        do {
            let previewURL = markdownFolderURL.appendingPathComponent("preview.html")
            try previewHTML(for: ocrText).write(to: previewURL, atomically: true, encoding: .utf8)

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
            window.makeKeyAndOrderFront(nil)
        } catch {
            ocrStatus = "Could not open preview."
            logOutput = error.localizedDescription
        }
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
        \(markdownToPreviewHTML(markdown))
        </body>
        </html>
        """
    }

    private func previewStylesHTML() -> String {
        guard !selectedPDFPath.isEmpty else {
            return fallbackPreviewStyleHTML()
        }

        let pdfFolderURL = URL(fileURLWithPath: selectedPDFPath).deletingLastPathComponent()
        let stylesheetURL = pdfFolderURL
            .appendingPathComponent("Styles", isDirectory: true)
            .appendingPathComponent("stylesheet.css")

        if FileManager.default.fileExists(atPath: stylesheetURL.path) {
            return """
            <link rel="stylesheet" type="text/css" href="../../../Styles/stylesheet.css">
        <style>
        img { max-width: 100%; height: auto; }
        figure { margin: 1em 0; }
        figcaption { margin-top: 0.5em; }
        blockquote, .blockquote { margin: 1em 1.5em; padding: 0.6em 1em; border-left: 3px solid #999; font-style: italic; }
        blockquote p, .blockquote p { margin: 0; text-indent: 0; }
        </style>
        """
        }

        return fallbackPreviewStyleHTML()
    }

    private func fallbackPreviewStyleHTML() -> String {
        """
        <style>
        body { font-family: serif; line-height: 1.55; padding: 24px; }
        p { margin: 0 0 1em 0; }
        img { max-width: 100%; height: auto; }
        figure { margin: 1em 0; }
        figcaption { margin-top: 0.5em; font-size: 0.9em; color: #555; }
        blockquote, .blockquote { margin: 1em 1.5em; padding: 0.6em 1em; border-left: 3px solid #999; font-style: italic; }
        blockquote p, .blockquote p { margin: 0; text-indent: 0; }
        .footnote-ref { font-size: 0.75em; line-height: 0; vertical-align: super; }
        .footnote-ref a { color: inherit; text-decoration: none; }
        .footnotes { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid #d0d0d0; font-size: 0.9em; }
        .footnotes ol { margin: 0; padding-left: 1.5rem; }
        .footnotes li { margin-bottom: 0.5rem; }
        .footnote-back { margin-left: 0.25rem; text-decoration: none; }
        </style>
        """
    }

    private func markdownToPreviewHTML(_ markdown: String) -> String {
        var parts: [String] = []
        let extracted = extractMarkdownFootnotes(from: markdown)
        var usedFootnotes: [String] = []
        let paragraphs = splitParagraphs(extracted.markdown)
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

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

            parts.append("<p>\(markdownInlinePreviewHTML(trimmed.replacingOccurrences(of: "\n", with: " "), usedFootnotes: &usedFootnotes))</p>")
        }
        if let footnotesHTML = footnotesPreviewHTML(definitions: extracted.footnotes, usedLabels: usedFootnotes) {
            parts.append(footnotesHTML)
        }
        return parts.joined(separator: "\n")
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
        guard trimmed.hasPrefix("#") else { return nil }
        let level = min(trimmed.prefix(while: { $0 == "#" }).count, 6)
        var title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasSuffix("#") {
            title = title.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func footnotesPreviewHTML(definitions: [String: String], usedLabels: [String]) -> String? {
        var items: [String] = []
        for (index, label) in usedLabels.enumerated() {
            guard let noteText = definitions[label] else { continue }
            let fragment = footnoteFragmentID(label, fallback: "note-\(index + 1)")
            items.append("<li id=\"fn-\(htmlEscaped(fragment))\">\(markdownInlinePreviewHTML(noteText)) <a href=\"#fnref-\(htmlEscaped(fragment))\" class=\"footnote-back\">&#8617;</a></li>")
        }
        guard !items.isEmpty else { return nil }
        return "<section class=\"footnotes\">\n<ol>\n\(items.joined(separator: "\n"))\n</ol>\n</section>"
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
                let replacement = "<sup id=\"fnref-\(htmlEscaped(fragment))\" class=\"footnote-ref\"><a href=\"#fn-\(htmlEscaped(fragment))\">\(htmlEscaped(label))</a></sup>"
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

    var markdownChapterCount: Int {
        pdfFiles.filter { appleVisionMarkdownExists(for: $0) }.count
    }

    private func markdownFolderURL(for item: PDFFileItem) -> URL {
        if item.isManualSection {
            return manualMarkdownFolderURL(for: item.url)
        }

        return appleVisionOutputFolderURL(for: item.url)
            .appendingPathComponent(item.url.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    private func manualMarkdownFolderURL(for url: URL) -> URL {
        let folderURL = URL(fileURLWithPath: selectedFolderPath)
        return folderURL
            .appendingPathComponent("AppleVision", isDirectory: true)
            .appendingPathComponent("MD", isDirectory: true)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    private func loadAppleVisionMarkdownText() -> String? {
        guard let folderURL = localAppleVisionOutputFolderURL else {
            return nil
        }

        let files = appleVisionMarkdownPageFiles(in: folderURL)
        guard !files.isEmpty else {
            return nil
        }

        let text = files.compactMap { try? String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private func saveAppleVisionMarkdownText(_ text: String, folderURL: URL) throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let existingFiles = appleVisionMarkdownPageFiles(in: folderURL)
        for fileURL in existingFiles where fileURL.lastPathComponent != "page1.md" {
            let backupURL = fileURL.deletingPathExtension().appendingPathExtension("md.bak")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
            } else {
                try FileManager.default.removeItem(at: fileURL)
            }
        }

        let page1URL = folderURL.appendingPathComponent("page1.md")
        try text.trimmingCharacters(in: .whitespacesAndNewlines).write(to: page1URL, atomically: true, encoding: .utf8)
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

    func addManualSection(after item: PDFFileItem) {
        guard !selectedFolderPath.isEmpty else { return }
        let id = "manual-\(UUID().uuidString)"
        let url = manualSectionURL(id: id)
        let newItem = PDFFileItem(id: url.path, url: url)
        let insertIndex = (pdfFiles.firstIndex(of: item) ?? (pdfFiles.count - 1)) + 1

        pdfFiles.insert(newItem, at: min(insertIndex, pdfFiles.count))
        pdfTitles[newItem.id] = "Section"
        saveBookSections()
        save()
    }

    func addManualSectionAtEnd() {
        guard !selectedFolderPath.isEmpty else { return }
        let id = "manual-\(UUID().uuidString)"
        let url = manualSectionURL(id: id)
        let newItem = PDFFileItem(id: url.path, url: url)
        pdfFiles.append(newItem)
        pdfTitles[newItem.id] = "Section"
        saveBookSections()
        save()
    }

    func deleteManualSection(_ item: PDFFileItem) {
        guard item.isManualSection else { return }
        pdfFiles.removeAll { $0 == item }
        pdfTitles.removeValue(forKey: item.id)
        saveBookSections()
        save()
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
            guard line.hasPrefix("#") else { continue }
            let title = line
                .drop(while: { $0 == "#" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }

    var ocrParagraphs: [String] {
        splitParagraphs(ocrText)
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
                self.setOCRParagraphs(paragraphs)
            }
        )
    }

    func addParagraphBefore(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index, paragraphs.count))
        paragraphs.insert("", at: insertIndex)
        setOCRParagraphs(paragraphs)
        finishParagraphAction(focusIndex: insertIndex)
    }

    func addParagraphAfter(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index + 1, paragraphs.count))
        paragraphs.insert("", at: insertIndex)
        setOCRParagraphs(paragraphs)
        finishParagraphAction(focusIndex: insertIndex)
    }

    func addLineBreakBefore(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index, paragraphs.count))
        paragraphs.insert("<br/>", at: insertIndex)
        setOCRParagraphs(paragraphs)
        finishParagraphAction(focusIndex: insertIndex)
    }

    func addLineBreakAfter(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index + 1, paragraphs.count))
        paragraphs.insert("<br/>", at: insertIndex)
        setOCRParagraphs(paragraphs)
        finishParagraphAction(focusIndex: insertIndex)
    }

    func addPageBreakBefore(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index, paragraphs.count))
        paragraphs.insert("<!-- page-break-before -->", at: insertIndex)
        setOCRParagraphs(paragraphs)
        finishParagraphAction(focusIndex: insertIndex)
    }

    func addPageBreakAfter(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index + 1, paragraphs.count))
        paragraphs.insert("<!-- page-break-after -->", at: insertIndex)
        setOCRParagraphs(paragraphs)
        finishParagraphAction(focusIndex: insertIndex)
    }

    func mergeParagraphBefore(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard index > 0, paragraphs.indices.contains(index) else { return }
        paragraphs[index - 1] = mergeParagraphText(paragraphs[index - 1], paragraphs[index])
        paragraphs.remove(at: index)
        setOCRParagraphs(paragraphs)
        finishParagraphAction(focusIndex: index - 1)
    }

    func mergeParagraphAfter(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index), index + 1 < paragraphs.count else { return }
        paragraphs[index] = mergeParagraphText(paragraphs[index], paragraphs[index + 1])
        paragraphs.remove(at: index + 1)
        setOCRParagraphs(paragraphs)
        finishParagraphAction(focusIndex: index)
    }

    func removeParagraph(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index) else { return }
        paragraphs.remove(at: index)
        setOCRParagraphs(paragraphs)
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
        paragraphs.swapAt(index, index - 1)
        setOCRParagraphs(paragraphs)
        finishParagraphAction(focusIndex: index - 1)
    }

    func moveParagraphDown(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index), index + 1 < paragraphs.count else { return }
        paragraphs.swapAt(index, index + 1)
        setOCRParagraphs(paragraphs)
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

    private func setOCRParagraphs(_ paragraphs: [String]) {
        ocrText = paragraphs.joined(separator: "\n\n")
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

        ensureConfigFilesExist()
        sendSelectedPDFToAppleVision()
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
        let documentTitle = selectedPDFTitle

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.runAppleVisionOCR(
                    pdfPath: pdfPath,
                    filterTopLines: filterTopLinesValue,
                    filterBottomLines: filterBottomLinesValue,
                    filteredText: filteredTextValue,
                    documentTitle: documentTitle
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
        let filterValues = parseFilterValues(filteredText)
        var rawPages: [[OCRLine]] = []
        var pageImageRegions: [[OCRImageRegion]] = []
        var allPageLines: [OCRLine] = []
        var allPageImageRegions: [OCRImageRegion] = []

        for pageIndex in 0..<pageCount {
            if isOCRCancelling {
                throw NSError(domain: "NewOCR", code: 3, userInfo: [NSLocalizedDescriptionKey: "AppleVision OCR cancelled."])
            }

            guard let page = document.page(at: pageIndex) else {
                continue
            }

            let image = try renderPDFPageToCGImage(page)
            let rawLines = try recognizeTextWithAppleVision(in: image)
            let imageRegions = try detectImageRegions(
                in: image,
                textLines: rawLines,
                pageNumber: pageIndex + 1,
                outputFolder: mdFolder
            )
            rawPages.append(rawLines)
            pageImageRegions.append(imageRegions)

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
            let filteredLines = removeTopBottomLines(
                rawLines,
                topCount: topCount,
                bottomCount: bottomCount,
                filterValues: filterValues,
                repeatedHeaderFooterKeys: repeatedHeaderFooterKeys
            )
            let imageRegions = pageImageRegions.indices.contains(pageIndex) ? pageImageRegions[pageIndex] : []
            let filteredTextLines = filteredLines.filter { line in
                !imageRegions.contains { imageRegion in
                    normalizedOverlapArea(line, imageRegion) >= 0.18
                }
            }
            removedLines += rawLines.count - filteredTextLines.count
            let builtPageText = buildMarkdownPage(from: filteredTextLines, imageRegions: imageRegions)
            let pageText = pageIndex == 0
                ? applyMarkdownTitle(documentTitle, to: builtPageText, replaceExistingHeading: true)
                : builtPageText

            let pageNumber = pageIndex + 1
            pageMarkdownItems.append(
                OCRPageMarkdown(
                    pageNumber: pageNumber,
                    text: pageText,
                    firstTextLineContinuesPreviousPage: firstTextLineContinuesPreviousPage(filteredTextLines),
                    lastTextLineCanContinueNextPage: lastTextLineCanContinueNextPage(filteredTextLines)
                )
            )
            allPageLines.append(contentsOf: filteredTextLines)
            allPageImageRegions.append(contentsOf: imageRegions)

            DispatchQueue.main.async {
                let percent = 50 + (Double(pageNumber) / Double(pageCount)) * 50
                self.ocrProgressPercent = percent
                self.ocrStatus = "AppleVision preparing page \(pageNumber): \(pageNumber)/\(pageCount) (\(Int(percent))%)"
            }
        }

        mergePageBoundaryContinuations(in: &pageMarkdownItems)

        for pageMarkdown in pageMarkdownItems {
            let pageURL = mdFolder.appendingPathComponent("page\(pageMarkdown.pageNumber).md")
            try pageMarkdown.text.write(to: pageURL, atomically: true, encoding: .utf8)
        }

        let fullText = applyMarkdownTitle(documentTitle, to: buildMarkdownPage(from: allPageLines, imageRegions: allPageImageRegions), replaceExistingHeading: true)

        return (mdFolder.path, pageCount, fullText.count, removedLines)
    }

    private func renderPDFPageToCGImage(_ page: PDFPage, scale: CGFloat = 2.0) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
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
        page.draw(with: .mediaBox, to: context)
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
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return nil
            }
            return OCRLine(
                text: text,
                left: observation.boundingBox.minX,
                right: observation.boundingBox.maxX,
                bottom: observation.boundingBox.minY,
                top: observation.boundingBox.maxY
            )
        }
    }

    private func detectImageRegions(
        in image: CGImage,
        textLines: [OCRLine],
        pageNumber: Int,
        outputFolder: URL
    ) throws -> [OCRImageRegion] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [] }

        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return []
        }

        let bytesPerRow = image.bytesPerRow
        let bitsPerPixel = image.bitsPerPixel
        let bytesPerPixel = max(1, bitsPerPixel / 8)
        guard bytesPerPixel >= 3 else { return [] }

        let cellSize = max(8, min(width, height) / 160)
        let gridWidth = max(1, Int(ceil(Double(width) / Double(cellSize))))
        let gridHeight = max(1, Int(ceil(Double(height) / Double(cellSize))))
        var active = Array(repeating: false, count: gridWidth * gridHeight)

        func isTextMasked(pixelX: Int, pixelY: Int) -> Bool {
            let normalizedX = CGFloat(pixelX) / CGFloat(width)
            let normalizedY = 1 - (CGFloat(pixelY) / CGFloat(height))
            return textLines.contains { line in
                let horizontalPadding = max(0.006, line.width * 0.10)
                let verticalPadding = max(0.006, line.height * 0.80)
                return normalizedX >= line.left - horizontalPadding
                    && normalizedX <= line.right + horizontalPadding
                    && normalizedY >= line.bottom - verticalPadding
                    && normalizedY <= line.top + verticalPadding
            }
        }

        for gridY in 0..<gridHeight {
            for gridX in 0..<gridWidth {
                let startX = gridX * cellSize
                let startY = gridY * cellSize
                let endX = min(width, startX + cellSize)
                let endY = min(height, startY + cellSize)
                var sampleCount = 0
                var visualCount = 0
                var darkLineCount = 0
                let stride = max(2, cellSize / 4)

                var y = startY
                while y < endY {
                    var x = startX
                    while x < endX {
                        sampleCount += 1
                        if !isTextMasked(pixelX: x, pixelY: y) {
                            let offset = y * bytesPerRow + x * bytesPerPixel
                            let red = Int(bytes[offset])
                            let green = Int(bytes[offset + 1])
                            let blue = Int(bytes[offset + 2])
                            let brightness = (red + green + blue) / 3
                            let channelSpread = max(red, green, blue) - min(red, green, blue)
                            if brightness < 238 || channelSpread > 22 {
                                visualCount += 1
                            }
                            if brightness < 180 {
                                darkLineCount += 1
                            }
                        }
                        x += stride
                    }
                    y += stride
                }

                if sampleCount > 0 {
                    let visualRatio = Double(visualCount) / Double(sampleCount)
                    let darkLineRatio = Double(darkLineCount) / Double(sampleCount)
                    if visualRatio >= 0.18 || darkLineRatio >= 0.08 {
                        active[gridY * gridWidth + gridX] = true
                    }
                }
            }
        }

        var visited = Array(repeating: false, count: active.count)
        var regions: [CGRect] = []

        for startIndex in active.indices where active[startIndex] && !visited[startIndex] {
            var queue = [startIndex]
            visited[startIndex] = true
            var minX = startIndex % gridWidth
            var maxX = minX
            var minY = startIndex / gridWidth
            var maxY = minY
            var activeCellCount = 0

            while let index = queue.popLast() {
                activeCellCount += 1
                let x = index % gridWidth
                let y = index / gridWidth
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                for (nextX, nextY) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nextX >= 0, nextX < gridWidth, nextY >= 0, nextY < gridHeight else { continue }
                    let nextIndex = nextY * gridWidth + nextX
                    if active[nextIndex] && !visited[nextIndex] {
                        visited[nextIndex] = true
                        queue.append(nextIndex)
                    }
                }
            }

            let pixelRect = CGRect(
                x: max(0, minX * cellSize - cellSize),
                y: max(0, minY * cellSize - cellSize),
                width: min(width, (maxX + 2) * cellSize) - max(0, minX * cellSize - cellSize),
                height: min(height, (maxY + 2) * cellSize) - max(0, minY * cellSize - cellSize)
            )
            let pageArea = CGFloat(width * height)
            let regionArea = pixelRect.width * pixelRect.height
            let isLargeEnough = pixelRect.width >= CGFloat(width) * 0.15
                && pixelRect.height >= CGFloat(height) * 0.08
                && regionArea >= pageArea * 0.018
                && activeCellCount >= 8
            if isLargeEnough {
                regions.append(pixelRect)
            }
        }

        let mergedRegions = mergeOverlappingPixelRegions(regions)
        guard !mergedRegions.isEmpty else { return [] }

        let imagesFolder = outputFolder.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

        return try mergedRegions.enumerated().compactMap { index, pixelRect in
            let cropRect = CGRect(
                x: max(0, floor(pixelRect.minX)),
                y: max(0, floor(pixelRect.minY)),
                width: min(CGFloat(width) - floor(pixelRect.minX), ceil(pixelRect.width)),
                height: min(CGFloat(height) - floor(pixelRect.minY), ceil(pixelRect.height))
            )
            guard cropRect.width > 1, cropRect.height > 1,
                  let croppedImage = image.cropping(to: cropRect) else {
                return nil
            }

            let fileName = "page\(pageNumber)-image\(index + 1).png"
            let imageURL = imagesFolder.appendingPathComponent(fileName)
            try writePNG(croppedImage, to: imageURL)

            let left = cropRect.minX / CGFloat(width)
            let right = cropRect.maxX / CGFloat(width)
            let top = 1 - (cropRect.minY / CGFloat(height))
            let bottom = 1 - (cropRect.maxY / CGFloat(height))
            return OCRImageRegion(
                markdown: "![Page \(pageNumber) image \(index + 1)](Images/\(fileName))",
                imageURL: imageURL,
                left: left,
                right: right,
                bottom: bottom,
                top: top
            )
        }
    }

    private func mergeOverlappingPixelRegions(_ regions: [CGRect]) -> [CGRect] {
        var merged: [CGRect] = []
        for region in regions.sorted(by: { $0.minY < $1.minY }) {
            if let index = merged.firstIndex(where: { $0.intersects(region) || $0.insetBy(dx: -16, dy: -16).intersects(region) }) {
                merged[index] = merged[index].union(region)
            } else {
                merged.append(region)
            }
        }
        return merged.sorted {
            if abs($0.minY - $1.minY) > 12 {
                return $0.minY < $1.minY
            }
            return $0.minX < $1.minX
        }
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
        repeatedHeaderFooterKeys: Set<String>
    ) -> [OCRLine] {
        var removeIndexes = Set<Int>()

        for (index, line) in lines.enumerated() where isPageBoundaryLine(index, in: lines) && shouldAutoRemoveHeaderFooterLine(line, repeatedHeaderFooterKeys: repeatedHeaderFooterKeys) {
            removeIndexes.insert(index)
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

    private func scanHeaderFooterSample(pdfURL: URL, progress: ((Int, Int) -> Void)? = nil) throws -> String? {
        guard let document = PDFDocument(url: pdfURL) else {
            throw NSError(domain: "NewOCR", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not open PDF: \(pdfURL.path)"])
        }

        var rawPages: [[OCRLine]] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                continue
            }
            let image = try renderPDFPageToCGImage(page)
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
        return Set(repeatedHeaderFooterGroups(for: pdfURL).flatMap(\.keys))
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

        return characterBigramSimilarity(first, second) >= 0.82
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

    private func headerFooterReviewURL(for pdfURL: URL) -> URL {
        appleVisionLineCacheURL(for: pdfURL)
            .deletingLastPathComponent()
            .appendingPathComponent("header-footer-review.txt")
    }

    private enum OCRMarkdownBlock {
        case text(OCRLine)
        case image(OCRImageRegion)

        var top: CGFloat {
            switch self {
            case .text(let line):
                return line.top
            case .image(let imageRegion):
                return imageRegion.top
            }
        }

        var left: CGFloat {
            switch self {
            case .text(let line):
                return line.left
            case .image(let imageRegion):
                return imageRegion.left
            }
        }
    }

    private func buildMarkdownPage(from lines: [OCRLine], imageRegions: [OCRImageRegion]) -> String {
        if imageRegions.isEmpty {
            return buildContinuousParagraphs(from: lines)
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
            let text = buildContinuousParagraphs(from: pendingTextLines)
            if !text.isEmpty {
                rendered.append(text)
            }
            pendingTextLines.removeAll()
        }

        for block in blocks {
            switch block {
            case .text(let line):
                pendingTextLines.append(line)
            case .image(let imageRegion):
                flushText()
                rendered.append(imageRegion.markdown)
            }
        }
        flushText()

        return rendered.joined(separator: "\n\n")
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

    private func firstTextLineContinuesPreviousPage(_ lines: [OCRLine]) -> Bool {
        guard let firstLine = lines.first else { return false }
        let normalLeft = lines.map(\.left).min() ?? firstLine.left
        let normalRight = lines.map(\.right).max() ?? firstLine.right
        let normalWidth = max(0.0001, normalRight - normalLeft)
        let blockCenter = (normalLeft + normalRight) / 2
        let averageHeight = lines.map(\.height).reduce(0, +) / CGFloat(max(1, lines.count))
        let indentThreshold = max(0.025, normalWidth * 0.08)

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
            let previousLast = lastMarkdownParagraph(in: pages[index - 1].text)
            let currentFirst = firstMarkdownParagraph(in: pages[index].text)
            guard let previousLast,
                  let currentFirst,
                  canMergePageBoundaryParagraph(previousLast, currentFirst) else {
                continue
            }

            pages[index - 1].text = replacingLastMarkdownParagraph(
                in: pages[index - 1].text,
                with: joinContinuousLine(previousLast, currentFirst)
            )
            pages[index].text = removingFirstMarkdownParagraph(from: pages[index].text)
        }
    }

    private func canMergePageBoundaryParagraph(_ previous: String, _ current: String) -> Bool {
        let previous = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty, !current.isEmpty else { return false }
        guard !previous.hasPrefix("#"), !previous.hasPrefix("!["),
              !current.hasPrefix("#"), !current.hasPrefix("![") else {
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

    private func buildContinuousParagraphs(from lines: [OCRLine]) -> String {
        guard !lines.isEmpty else { return "" }

        let normalLeft = lines.map(\.left).min() ?? 0
        let normalRight = lines.map(\.right).max() ?? 1
        let normalWidth = normalRight - normalLeft
        let blockCenter = (normalLeft + normalRight) / 2
        let averageHeight = lines.map(\.height).reduce(0, +) / CGFloat(max(1, lines.count))
        let indentThreshold = max(0.025, (normalRight - normalLeft) * 0.08)
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
            let shouldContinue = !current.isEmpty && !isIndented && (centeredBodyMode || previousIsFullLine)

            if shouldContinue {
                current = joinContinuousLine(current, line.text)
            } else {
                if !current.isEmpty {
                    paragraphs.append(current)
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

        let isNearTop = line.centerX.isFinite && line.bottom >= 0.42
        let isShort = line.width <= normalWidth * 0.65
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
        let hasLargeGapBelow = nextLine.map { (line.bottom - $0.top) >= max(averageHeight * 1.8, 0.035) } ?? true

        return isNearTop && isShort && isCentered && (index == 0 || hasLargeGapBelow || followsChapterNumber || followsCenteredTitleLine)
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
        skipProcessOCREngine = defaults.bool(forKey: "skipProcessOCREngine")
        filterTopLines = defaults.string(forKey: "filterTopLines") ?? "1"
        filterBottomLines = defaults.string(forKey: "filterBottomLines") ?? "1"
        filteredText = defaults.string(forKey: "filteredText") ?? ""
        ocrStatus = defaults.string(forKey: "ocrStatus") ?? "No OCR job has been sent yet."
        logOutput = ""
        pdfTitles = defaults.dictionary(forKey: "pdfTitles") as? [String: String] ?? [:]
        frontCoverImagePath = defaults.string(forKey: "frontCoverImagePath") ?? ""
        backCoverImagePath = defaults.string(forKey: "backCoverImagePath") ?? ""
        epubStatus = ""

        isRestoring = false
        ensureConfigFilesExist()
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
        defaults.set(frontCoverImagePath, forKey: "frontCoverImagePath")
        defaults.set(backCoverImagePath, forKey: "backCoverImagePath")
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

        for entry in entries {
            if entry.type == "manual" {
                let url = manualSectionURL(id: entry.id)
                let item = PDFFileItem(id: url.path, url: url)
                orderedItems.append(item)
                usedPaths.insert(item.url.path)
                if let title = entry.title, !title.isEmpty {
                    pdfTitles[item.id] = title
                }
            } else if let path = entry.path,
                      let item = physicalByPath[path] {
                orderedItems.append(item)
                usedPaths.insert(path)
                if let title = entry.title, !title.isEmpty {
                    pdfTitles[item.id] = title
                }
            }
        }

        for item in physicalItems where !usedPaths.contains(item.url.path) {
            orderedItems.append(item)
        }

        pdfFiles = orderedItems
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

    private func saveBookSections() {
        guard let url = bookSectionsURL() else { return }
        let entries = pdfFiles.map { item -> BookSectionEntry in
            let title = pdfTitles[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isManualSection {
                return BookSectionEntry(
                    id: item.url.deletingPathExtension().lastPathComponent,
                    type: "manual",
                    path: nil,
                    title: title
                )
            }
            return BookSectionEntry(
                id: item.url.deletingPathExtension().lastPathComponent,
                type: "pdf",
                path: item.url.path,
                title: title
            )
        }

        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            logOutput = "Could not save book sections: \(error.localizedDescription)"
        }
    }

    private func ensureConfigFilesExist() {
        let folderURL = configFileURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

            if !FileManager.default.fileExists(atPath: configFileURL.path) {
                try defaultConfigText().write(to: configFileURL, atomically: true, encoding: .utf8)
            } else {
                try ensureConfigKeyExists("NEW_PROJECTS_FOLDER", defaultValue: "~/Downloads", comment: "# New projects made from the New button are created here.")
                try ensureConfigKeyExists("SPLIT_PDF_WINDOW_WIDTH", defaultValue: "FULL", comment: "# Set SPLIT_PDF_WINDOW_WIDTH=FULL to open the Split PDF window at full screen size.")
                try ensureConfigKeyExists("SPLIT_PDF_WINDOW_HEIGHT", defaultValue: "680", comment: "# Used only when SPLIT_PDF_WINDOW_WIDTH is a number.")
            }

            if !FileManager.default.fileExists(atPath: ocrInstructionFileURL.path) {
                try defaultOCRInstructionText().write(to: ocrInstructionFileURL, atomically: true, encoding: .utf8)
            }

        } catch {
            configStatus = "Could not prepare config: \(error.localizedDescription)"
        }
    }

    private func ensureConfigKeyExists(_ key: String, defaultValue: String, comment: String) throws {
        var text = (try? String(contentsOf: configFileURL, encoding: .utf8)) ?? ""
        let hasKey = text.components(separatedBy: .newlines).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.hasPrefix("\(key)=")
        }
        guard !hasKey else { return }

        if !text.hasSuffix("\n") {
            text += "\n"
        }
        text += "\n\(comment)\n\(key)=\(defaultValue)\n"
        try text.write(to: configFileURL, atomically: true, encoding: .utf8)
    }

    private func loadAppConfigValues() {
        let values = readKeyValueConfig(from: configFileURL)
        newProjectsFolderPath = expandedPath(values["NEW_PROJECTS_FOLDER"] ?? "~/Downloads")
        pdfListMinHeight = CGFloat(parseDouble(values["PDF_LIST_MIN_HEIGHT"], defaultValue: 420, minimum: 200))
        shouldOpenMainWindowFullScreen = values["MAIN_WINDOW_WIDTH"]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "FULL"
        if !shouldOpenMainWindowFullScreen {
            mainWindowWidth = CGFloat(parseDouble(values["MAIN_WINDOW_WIDTH"], defaultValue: 780, minimum: 640))
            mainWindowHeight = CGFloat(parseDouble(values["MAIN_WINDOW_HEIGHT"], defaultValue: 520, minimum: 480))
        }
        ocrParagraphTextAreaMinHeight = CGFloat(parseDouble(values["OCR_PARAGRAPH_TEXTAREA_MIN_HEIGHT"], defaultValue: 58, minimum: 40))
        shouldOpenOCRWindowFullScreen = values["OCR_WINDOW_WIDTH"]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "FULL"
        if !shouldOpenOCRWindowFullScreen {
            ocrWindowWidth = CGFloat(parseDouble(values["OCR_WINDOW_WIDTH"], defaultValue: 820, minimum: 640))
            ocrWindowHeight = CGFloat(parseDouble(values["OCR_WINDOW_HEIGHT"], defaultValue: 620, minimum: 480))
        }
        let splitPDFWindowWidthValue = values["SPLIT_PDF_WINDOW_WIDTH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? "FULL"
        shouldOpenSplitPDFWindowFullScreen = splitPDFWindowWidthValue == "FULL"
        if !shouldOpenSplitPDFWindowFullScreen {
            splitPDFWindowWidth = CGFloat(parseDouble(values["SPLIT_PDF_WINDOW_WIDTH"], defaultValue: 980, minimum: 760))
            splitPDFWindowHeight = CGFloat(parseDouble(values["SPLIT_PDF_WINDOW_HEIGHT"], defaultValue: 680, minimum: 560))
        }
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

    private func defaultConfigText() -> String {
        """
        # New projects made from the New button are created here.
        NEW_PROJECTS_FOLDER=~/Downloads
        PDF_LIST_MIN_HEIGHT=420
        # Set MAIN_WINDOW_WIDTH=FULL to open the main window at full screen size.
        MAIN_WINDOW_WIDTH=780
        MAIN_WINDOW_HEIGHT=520
        # Set OCR_WINDOW_WIDTH=FULL to open the OCR window at full screen size.
        OCR_WINDOW_WIDTH=820
        OCR_WINDOW_HEIGHT=620
        # Set SPLIT_PDF_WINDOW_WIDTH=FULL to open the Split PDF window at full screen size.
        SPLIT_PDF_WINDOW_WIDTH=FULL
        # Used only when SPLIT_PDF_WINDOW_WIDTH is a number.
        SPLIT_PDF_WINDOW_HEIGHT=680
        OCR_PARAGRAPH_TEXTAREA_MIN_HEIGHT=58

        """
    }

    private func defaultOCRInstructionText() -> String {
        """
        AppleVision uses Apple's local Vision framework to detect text.
        It writes per-page Markdown files first, then can produce combined text or EPUB later.

        """
    }
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            StepOneLoadPDFView()
        }
        .frame(
            minWidth: appState.shouldOpenMainWindowFullScreen ? 780 : appState.mainWindowWidth,
            minHeight: appState.shouldOpenMainWindowFullScreen ? 520 : appState.mainWindowHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard appState.shouldOpenMainWindowFullScreen else { return }
            DispatchQueue.main.async {
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first,
                      let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
                    return
                }
                window.setFrame(visibleFrame, display: true)
            }
        }
    }
}

struct StepOneLoadPDFView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Load PDF/OCR")
                            .font(.largeTitle.weight(.semibold))
                        Text("Choose which PDF file and do OCR.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        Button("New") {
                            appState.newSplitPlan()
                        }
                        .controlSize(.large)
                        .keyboardShortcut("n", modifiers: [.command])

                        Button("Open") {
                            appState.chooseFolder()
                        }
                        .controlSize(.large)
                        .keyboardShortcut("o", modifiers: [.command])

                        Text(appState.selectedFolderPath.isEmpty ? "No folder selected yet" : appState.selectedFolderPath)
                            .foregroundStyle(appState.selectedFolderPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 220, maxWidth: 520, alignment: .leading)

                        if appState.canOpenSplitPlannerForSelectedFolder {
                            Button("Open Split") {
                                appState.openSelectedFolderSplitPlan()
                            }
                            .controlSize(.large)
                        }

                        Button("Clear Scan Report") {
                            appState.clearAllHeaderFooterScans()
                        }
                        .controlSize(.large)
                        .disabled(appState.selectedFolderPath.isEmpty || appState.isHeaderFooterScanRunning)

                        Button("Open Config") {
                            appState.openConfigEditor()
                        }
                        .controlSize(.large)

                        Button("Close") {
                            NSApp.terminate(nil)
                        }
                        .controlSize(.large)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("EPUB Covers")
                            .font(.headline)

                        Spacer()

                        Text("\(appState.markdownChapterCount) Markdown chapters")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Apply CSS") {
                            appState.applyStylesheet()
                        }
                        .controlSize(.large)
                        .disabled(appState.selectedFolderPath.isEmpty)

                        Button(appState.isOCRRunning ? "Building EPUB..." : "Build EPUB") {
                            appState.buildBookEPUB()
                        }
                        .controlSize(.large)
                        .disabled(appState.isOCRRunning || appState.markdownChapterCount == 0)

                        if appState.bookEPUBFilePathIfExists != nil {
                            Button("View EPUB") {
                                appState.openBuiltEPUBFile()
                            }
                            .controlSize(.large)
                        }
                    }

                    HStack(spacing: 24) {
                        HStack(spacing: 10) {
                            Button("Front Cover") {
                                appState.chooseFrontCoverImage()
                            }

                            CoverThumbnailView(path: appState.frontCoverImagePath)
                        }

                        HStack(spacing: 10) {
                            Button("Back Cover") {
                                appState.chooseBackCoverImage()
                            }

                            CoverThumbnailView(path: appState.backCoverImagePath)
                        }

                        Spacer()
                    }

                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Sections")
                            .font(.headline)
                        Text("\(appState.pdfFiles.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(nsColor: .quaternaryLabelColor))
                            .clipShape(Capsule())
                        Spacer()
                    }

                    if appState.isHeaderFooterScanRunning {
                        HStack(spacing: 10) {
                            ProgressView(value: appState.headerFooterScanProgressPercent ?? 0, total: 100)
                                .frame(maxWidth: .infinity)
                            Text("\(Int(appState.headerFooterScanProgressPercent ?? 0))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                        Text(appState.headerFooterScanStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    PDFListView()
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .sheet(isPresented: $appState.isConfigEditorPresented) {
            ConfigEditorView()
                .environmentObject(appState)
        }
        .alert("EPUB Built", isPresented: $appState.isEPUBBuiltAlertPresented) {
            Button("Open File") {
                appState.openBuiltEPUBFile()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.builtEPUBPath)
        }
        .alert(appState.cssApplyAlertTitle, isPresented: $appState.isCSSAppliedAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.cssApplyAlertMessage)
        }
    }
}

struct ConfigEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.configEditorTitle)
                        .font(.title2.weight(.semibold))
                    Text(appState.configEditorPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if !appState.isHeaderFooterReviewOpen {
                    Button("Save") {
                        appState.saveConfigFile()
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                }

                Button("Close") {
                    dismiss()
                }
            }

            if appState.isHeaderFooterReviewOpen {
                HeaderFooterReviewView()
                    .environmentObject(appState)
                    .frame(minWidth: 640, minHeight: 360)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            } else {
                TextEditor(text: $appState.configText)
                    .font(.body.monospaced())
                    .frame(minWidth: 640, minHeight: 360)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }

            HStack {
                Text(appState.configStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
        }
        .padding(20)
    }
}

struct HeaderFooterReviewView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Approved Remove Items")
                    .font(.headline)

                if appState.headerFooterReviewRemoveItems.isEmpty {
                    Text("No remove items.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.headerFooterReviewRemoveItems, id: \.self) { item in
                        HStack(spacing: 10) {
                            Text(item)
                                .font(.body.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Remove") {
                                appState.removeHeaderFooterReviewItem(item)
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct PDFListView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.selectedFolderPath.isEmpty {
                EmptyStateView(title: "Choose a folder to load PDF files.")
            } else if appState.pdfFiles.isEmpty {
                VStack(spacing: 12) {
                    EmptyStateView(title: "No sections found in this folder.")
                        .frame(minHeight: 180)
                    Button("Add Section") {
                        appState.addManualSectionAtEnd()
                    }
                    .controlSize(.large)
                    .padding(.bottom, 16)
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("")
                            .frame(width: 34)
                        Text("Section")
                            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                        Text("Title")
                            .frame(width: 260, alignment: .leading)
                        Text("Command")
                            .frame(width: 260, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    List(appState.pdfFiles) { item in
                        HStack(spacing: 12) {
                            Button {
                                appState.addManualSection(after: item)
                            } label: {
                                Image(systemName: "plus")
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.bordered)
                            .help("Add manual section below")
                            .frame(width: 34)

                            HStack(spacing: 8) {
                                Image(systemName: item.isManualSection ? "text.badge.plus" : "doc.richtext")
                                    .foregroundStyle(item.isManualSection ? .blue : .red)

                                if appState.appleVisionMarkdownExists(for: item) {
                                    Text("MD")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                }

                                if item.isManualSection {
                                    Text(appState.displayName(for: item))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Button {
                                        NSWorkspace.shared.open(item.url)
                                    } label: {
                                        Text(appState.displayName(for: item))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.link)
                                    .help("Open PDF")
                                }
                            }
                            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

                            TextField("Title", text: appState.titleBinding(for: item))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)

                            HStack(spacing: 8) {
                                if item.isManualSection {
                                    Button("Process") {
                                        appState.beginOCR(for: item)
                                    }

                                    Button("Delete") {
                                        appState.deleteManualSection(item)
                                    }
                                    .foregroundStyle(.red)
                                } else {
                                    Button(appState.isScanningHeaderFooter(for: item) ? "Scanning..." : "Scan Header") {
                                        appState.scanHeaderFooterSample(for: item)
                                    }
                                    .disabled(appState.isScanningHeaderFooter(for: item))

                                    Button("Process") {
                                        appState.beginOCR(for: item)
                                    }
                                    .disabled((!appState.headerFooterScanned(for: item) && appState.titleBinding(for: item).wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || appState.isScanningHeaderFooter(for: item))
                                }
                            }
                            .frame(width: 260, alignment: .leading)
                        }
                        .padding(.vertical, 5)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: appState.pdfListMinHeight, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

struct CoverThumbnailView: View {
    let path: String

    var body: some View {
        Group {
            if !path.isEmpty, let image = NSImage(contentsOfFile: path) {
                Button {
                    openImagePreviewWindow(path: path)
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 34, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Open cover image")
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 44)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }
        }
    }

    private func openImagePreviewWindow(path: String) {
        guard let image = NSImage(contentsOfFile: path) else { return }
        let imageSize = image.size
        let maxWidth: CGFloat = 900
        let maxHeight: CGFloat = 900
        let scale = min(maxWidth / max(1, imageSize.width), maxHeight / max(1, imageSize.height), 1)
        let windowSize = NSSize(width: max(360, imageSize.width * scale), height: max(360, imageSize.height * scale))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = URL(fileURLWithPath: path).lastPathComponent
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CoverImagePreviewView(path: path))
        window.makeKeyAndOrderFront(nil)
    }
}

struct CoverImagePreviewView: View {
    let path: String

    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            EmptyStateView(title: "Image file not found.")
                .frame(minWidth: 360, minHeight: 360)
        }
    }
}

struct EmptyStateView: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StepTwoOCRView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isFilesPopoverPresented = false
    @State private var isMarkdownInfoPopoverPresented = false
    @State private var isSearchInfoPopoverPresented = false
    @State private var isReplacePopoverPresented = false
    @State private var replacementText = ""

    var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OCR")
                            .font(.largeTitle.weight(.semibold))
                        Text("Review the paths, then run OCR or load existing Markdown.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        isMarkdownInfoPopoverPresented.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .help("Show Markdown syntax")
                    .accessibilityLabel("Show Markdown syntax")
                    .popover(isPresented: $isMarkdownInfoPopoverPresented) {
                        MarkdownSyntaxPopoverView()
                    }

                    Button("Preview") {
                        appState.openOCRMarkdownPreviewWindow()
                    }
                    .controlSize(.large)
                    .disabled(appState.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.localAppleVisionOutputFolderPathIfExists == nil)

                    Button("Save") {
                        appState.saveOCRTextFile()
                    }
                    .controlSize(.large)
                    .disabled(appState.isOCRRunning || appState.selectedPDFPath.isEmpty || appState.localAppleVisionOutputFolderPathIfExists == nil)

                    Button("Close") {
                        NSApp.keyWindow?.close()
                    }
                    .controlSize(.large)
                }

                HStack(alignment: .top, spacing: 14) {
                    Group {
                        if appState.localAppleVisionOutputFolderPathIfExists != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Markdown Text")
                                        .font(.headline)
                                    Text(appState.shouldUsePlainOCRTextEditor ? "\(appState.ocrText.count) characters" : "\(appState.ocrParagraphs.count) paragraphs")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(nsColor: .quaternaryLabelColor))
                                        .clipShape(Capsule())
                                    OCRMarkdownPresenceBadge(label: "Image", exists: appState.hasOCRMarkdownImages) {
                                        appState.focusFirstOCRMarkdownImage()
                                    }
                                    OCRMarkdownPresenceBadge(label: "Footnote", exists: appState.hasOCRMarkdownFootnotes) {
                                        appState.focusFirstOCRMarkdownFootnote()
                                    }
                                    OCRMarkdownPresenceBadge(label: "Blockquote", exists: appState.hasOCRMarkdownBlockquotes) {
                                        appState.focusFirstOCRMarkdownBlockquote()
                                    }
                                    Spacer()
                                }
                                GeometryReader { proxy in
                                    HStack(spacing: 10) {
                                        TextField("Search Markdown", text: $appState.ocrSearchText)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: max(240, proxy.size.width * 0.68))
                                            .disabled(appState.ocrText.isEmpty)
                                        Button("Replace All") {
                                            replacementText = ""
                                            isReplacePopoverPresented = true
                                        }
                                        .frame(width: 140)
                                        .disabled(appState.ocrText.isEmpty || appState.ocrSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        .popover(isPresented: $isReplacePopoverPresented) {
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
                                        Button("Clear") {
                                            appState.ocrSearchText = ""
                                        }
                                        .frame(width: 80)
                                        .disabled(appState.ocrSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        Button {
                                            isSearchInfoPopoverPresented.toggle()
                                        } label: {
                                            Image(systemName: "info.circle")
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.secondary)
                                        .help("Search help")
                                        .accessibilityLabel("Search help")
                                        .popover(isPresented: $isSearchInfoPopoverPresented) {
                                            OCRSearchGuidelinePopoverView()
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                .frame(height: 28)
                                Text(appState.ocrSearchResultText.isEmpty ? " " : appState.ocrSearchResultText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Markdown Text")
                                    .font(.headline)
                                EmptyStateView(title: "Markdown will appear after OCR creates it.")
                                    .frame(minHeight: 360, maxHeight: .infinity)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                    )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Button("Files") {
                                isFilesPopoverPresented.toggle()
                            }
                            .controlSize(.large)
                            .popover(isPresented: $isFilesPopoverPresented) {
                                FilesPopoverView()
                                    .environmentObject(appState)
                            }

                            Text(appState.selectedItemIsManualSection ? "Manual Section" : "Ready for OCR")
                                .font(.headline)

                            Button {
                                if !appState.selectedPDFPath.isEmpty && !appState.selectedItemIsManualSection {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: appState.selectedPDFPath))
                                }
                            } label: {
                                Text(appState.selectedPDFName)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.link)
                            .help("Open PDF")
                            .disabled(appState.selectedPDFPath.isEmpty || appState.selectedItemIsManualSection)

                            HStack(spacing: 10) {
                                Button(appState.isOCRRunning ? "Processing..." : "Run OCR") {
                                    appState.sendSelectedPDFToOCREngine()
                                }
                                .disabled(appState.isOCRRunning || appState.selectedPDFPath.isEmpty || appState.selectedItemIsManualSection)

                                Button("Load Markdown") {
                                    appState.loadExistingMarkdownAsync()
                                }
                                .disabled(appState.isOCRRunning || appState.localAppleVisionOutputFolderPathIfExists == nil)
                            }

                            if appState.isOCRRunning {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        ProgressView(value: appState.ocrProgressPercent ?? 0, total: 100)
                                            .frame(maxWidth: .infinity)
                                        Text("\(Int(appState.ocrProgressPercent ?? 0))%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 42, alignment: .trailing)
                                    }

                                    Button(appState.isOCRCancelling ? "Cancelling..." : "Cancel") {
                                        appState.cancelOCR()
                                    }
                                    .disabled(appState.isOCRCancelling)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Log")
                                .font(.headline)

                            HStack(spacing: 10) {
                                if appState.isOCRRunning {
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                Text(appState.ocrStatus)
                                    .font(.caption)
                                    .foregroundStyle(appState.isOCRRunning ? .secondary : .primary)
                                    .lineLimit(2)
                            }

                            TextEditor(text: $appState.logOutput)
                                .font(.body.monospaced())
                                .frame(height: 220)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                )
                        }
                    }
                    .frame(minWidth: 320, idealWidth: 320, maxWidth: 320, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(22)
            .alert("Saved Successfully", isPresented: $appState.isOCRSaveAlertPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appState.ocrSaveAlertMessage)
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
        ("[^1]: Footnote text", "Footnote at bottom")
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

            Text("Image paths are relative to the Markdown folder. Put Caption: or Description: directly below an image; following lines stay in the same caption until a blank line. Use > for blockquotes. Footnotes use matching labels, such as [^1] or [^a]. Other Markdown characters stay as normal text unless the converter supports them later.")
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

            Text("Type exactly Image to show only detected image paragraphs.")
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
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .controlSize(.large)
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            WebPreviewView(url: previewURL, readAccessURL: readAccessURL)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

struct WebPreviewView: NSViewRepresentable {
    let url: URL
    let readAccessURL: URL

    func makeNSView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
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

struct ParagraphEditorView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let visibleIndexes = appState.visibleOCRParagraphIndexes

        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleIndexes, id: \.self) { index in
                        ParagraphItemView(
                            index: index,
                            text: appState.paragraphBinding(at: index)
                        )
                        .environmentObject(appState)
                        .id(index)
                    }

                    if visibleIndexes.isEmpty {
                        EmptyStateView(title: "No matching paragraphs found.")
                            .frame(minHeight: 220)
                    }
                }
                .padding(10)
            }
            .onReceive(appState.$paragraphScrollRequestID) { requestID in
                guard requestID > 0 else { return }
                DispatchQueue.main.async {
                    withAnimation {
                        proxy.scrollTo(appState.paragraphScrollTargetIndex, anchor: .center)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
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
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}

struct OCRMarkdownPresenceBadge: View {
    let label: String
    let exists: Bool
    let action: () -> Void

    var body: some View {
        Button {
            guard exists else { return }
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(exists ? .green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .quaternaryLabelColor))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .help(exists ? "Show first \(label.lowercased()) in Markdown" : "\(label) not found in Markdown")
        .accessibilityLabel("\(label) \(exists ? "exists" : "not found")")
    }
}

struct HighlightingTextEditor: NSViewRepresentable {
    @Binding var text: String
    let searchText: String

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
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 6)
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
        if textView.string != text {
            textView.string = text
        }

        context.coordinator.applyHighlights(searchText: searchText)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightingTextEditor
        weak var textView: NSTextView?
        private var markdownPopover: NSPopover?
        private var isApplyingMarkdownStyle = false

        init(_ parent: HighlightingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyHighlights(searchText: parent.searchText)
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
            popover.contentSize = NSSize(width: 428, height: 42)
            popover.contentViewController = NSHostingController(
                rootView: MarkdownStylePopoverView(
                    applyBold: { [weak self] in self?.applyMarkdownWrapper("**") },
                    applyItalic: { [weak self] in self?.applyMarkdownWrapper("*") },
                    applyBlockquote: { [weak self] in self?.applyBlockquote() },
                    applyHeading1: { [weak self] in self?.applyHeading(level: 1) },
                    applyHeading2: { [weak self] in self?.applyHeading(level: 2) },
                    applyHeading3: { [weak self] in self?.applyHeading(level: 3) }
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

            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }

            let source = textView.string as NSString
            var searchRange = fullRange
            while searchRange.location < source.length {
                let foundRange = source.range(
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
                searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
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

    var body: some View {
        HStack(spacing: 8) {
            Button {
                applyBold()
            } label: {
                Text("B")
                    .font(.body.weight(.bold))
                    .frame(width: 42)
            }
            .help("Bold")

            Button {
                applyItalic()
            } label: {
                Text("I")
                    .font(.body.italic())
                    .frame(width: 42)
            }
            .help("Italic")

            Button("Quote") {
                applyBlockquote()
            }
            .frame(width: 74)
            .help("BlockQuote")

            Button("H1") {
                applyHeading1()
            }
            .frame(width: 44)
            .help("Heading 1")

            Button("H2") {
                applyHeading2()
            }
            .frame(width: 44)
            .help("Heading 2")

            Button("H3") {
                applyHeading3()
            }
            .frame(width: 44)
            .help("Heading 3")
        }
        .padding(8)
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
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onPreferenceChange(ParagraphEditorWidthPreferenceKey.self) { width in
            guard width > 0 else { return }
            editorWidth = width
        }
    }

    private var currentEditorHeight: CGFloat {
        max(appState.ocrParagraphTextAreaMinHeight, automaticEditorHeight, editorHeight ?? automaticEditorHeight)
    }

    private var automaticEditorHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = max(font.ascender - font.descender + font.leading, 17)
        let usableWidth = max(editorWidth - 18, 180)
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
        return ceil(max(appState.ocrParagraphTextAreaMinHeight, measuredHeight + 28))
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
    private let onSectionsSaved: ([(URL, String)]) -> Void

    init(bookmarkData: Data, fallbackURL: URL, projectFolderURL: URL, onSectionsSaved: @escaping ([(URL, String)]) -> Void = { _ in }) {
        self.bookmarkData = bookmarkData
        self.pdfURL = fallbackURL
        self.projectFolderURL = projectFolderURL
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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Crop PDF - \(pdfName)"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: CropPDFWindowView()
                .environmentObject(self)
        )
        cropWindows.append(window)
        window.makeKeyAndOrderFront(nil)
    }

    func openAddSplitWindow() {
        guard !hasPDFBookmarks else {
            status = "Add Split is only available when this PDF has no bookmarks."
            return
        }
        guard pdfDocument?.page(at: 0) != nil else {
            status = "PDF is not loaded yet."
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add Split - \(pdfName)"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: AddSplitWindowView()
                .environmentObject(self)
        )
        addSplitWindows.append(window)
        window.makeKeyAndOrderFront(nil)
    }

    func nextAddSplitFromPage() -> Int {
        if isUsingFallbackRange {
            return 1
        }

        let lastTo = ranges.compactMap { Int($0.pageTo) }.max() ?? 0
        return min(max(lastTo + 1, 1), max(pageCount, 1))
    }

    func addSplit(title: String, pageFrom: String, pageTo: String, completion: @escaping (Bool, Int) -> Void) {
        guard !hasPDFBookmarks else {
            status = "Add Split is only available when this PDF has no bookmarks."
            completion(false, nextAddSplitFromPage())
            return
        }
        guard pdfDocument != nil, pageCount > 0 else {
            status = "PDF is not loaded yet."
            completion(false, nextAddSplitFromPage())
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            status = "Enter a title before splitting."
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
        let outputIndex = (isUsingFallbackRange ? 0 : ranges.count) + 1
        let range = SplitPlanRange(title: trimmedTitle, pageFrom: "\(from)", pageTo: "\(to)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let freshDocument = PDFDocument(url: sourceURL), freshDocument.pageCount > 0 else {
                    throw NSError(domain: "NewOCR", code: 41, userInfo: [NSLocalizedDescriptionKey: "Could not reload source PDF."])
                }
                let sectionDocument = try self.documentForRange(range, from: freshDocument)
                let outputURL = self.projectFolderURL.appendingPathComponent(String(format: "section-%03d.pdf", outputIndex))
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

    func cropPreviewImage(pageIndex: Int, size: CGSize = CGSize(width: 900, height: 1100)) -> NSImage? {
        guard let page = pdfDocument?.page(at: min(max(pageIndex, 0), max(pageCount - 1, 0))) else { return nil }
        return page.thumbnail(of: size, for: .cropBox)
    }

    func saveCrop(normalizedRect: CGRect, completion: @escaping (Bool) -> Void) {
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

                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("pdf")
                guard document.write(to: temporaryURL) else {
                    throw NSError(domain: "NewOCR", code: 32, userInfo: [NSLocalizedDescriptionKey: "Could not write cropped PDF."])
                }

                let backupURL = self.backupPDFURL(for: sourceURL)
                try self.replaceSourcePDF(at: sourceURL, with: temporaryURL, backupURL: backupURL)
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
                    self.loadPDF()
                    self.status = "Saved cropped PDF. Backup: \(backupURL.lastPathComponent)"
                    completion(true)
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

    func regenerateFiles() {
        guard let document = pdfDocument, pageCount > 0 else {
            status = "PDF is not loaded yet."
            return
        }

        isLoadingPDF = true
        status = "Re-generating split PDF files..."

        do {
            let bookmarkRanges = splitRangesFromBookmarks(in: document)
            hasPDFBookmarks = !bookmarkRanges.isEmpty
            isUsingFallbackRange = bookmarkRanges.isEmpty
            ranges = bookmarkRanges.isEmpty ? [
                SplitPlanRange(
                    title: pdfURL.deletingPathExtension().lastPathComponent,
                    pageFrom: "1",
                    pageTo: "\(document.pageCount)"
                )
            ] : bookmarkRanges

            try removeGeneratedSplitPDFs()
            let writtenCount = try writeSplitPDFs(from: document, ranges: ranges)
            loadProjectPDFs()
            status = "Re-generated \(writtenCount) split PDF files."
        } catch {
            status = "Could not re-generate split files: \(error.localizedDescription)"
        }

        isLoadingPDF = false
    }

    func saveRangesToSourcePDF(completion: @escaping (Bool) -> Void = { _ in }) {
        guard pageCount > 0 else {
            status = "PDF is not loaded yet."
            completion(false)
            return
        }

        isLoadingPDF = true
        status = "Saving split PDF files from current ranges..."
        let sourceURL = pdfURL
        let rangesSnapshot = ranges

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let document = PDFDocument(url: sourceURL), document.pageCount > 0 else {
                    throw NSError(domain: "NewOCR", code: 35, userInfo: [NSLocalizedDescriptionKey: "Could not reload source PDF for saving."])
                }

                try self.removeGeneratedSplitPDFs()
                let savedTitles = try self.writeOrderedSectionPDFs(from: document, ranges: rangesSnapshot)

                DispatchQueue.main.async {
                    self.loadProjectPDFs()
                    self.onSectionsSaved(savedTitles)
                    self.status = "Saved \(savedTitles.count) split PDF files."
                    self.isLoadingPDF = false
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "Could not save PDF: \(error.localizedDescription)"
                    self.isLoadingPDF = false
                    completion(false)
                }
            }
        }
    }

    func addRange() {
        let nextIndex = ranges.count + 1
        let lastTo = ranges.last.flatMap { Int($0.pageTo) } ?? 0
        let nextFrom = min(max(lastTo + 1, 1), max(pageCount, 1))
        ranges.append(
            SplitPlanRange(
                title: "Part \(nextIndex)",
                pageFrom: "\(nextFrom)",
                pageTo: "\(max(nextFrom, pageCount))"
            )
        )
    }

    func removeRange(_ range: SplitPlanRange) {
        guard ranges.count > 1 else { return }
        ranges.removeAll { $0.id == range.id }
    }

    func openRangePreview(_ range: SplitPlanRange) {
        guard let document = pdfDocument else {
            status = "PDF is not loaded yet."
            return
        }

        do {
            let previewDocument = try documentForRange(range, from: document)
            let previewURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("NewOCR-\(UUID().uuidString)")
                .appendingPathExtension("pdf")
            guard previewDocument.write(to: previewURL) else {
                throw NSError(domain: "NewOCR", code: 36, userInfo: [NSLocalizedDescriptionKey: "Could not write preview PDF."])
            }
            NSWorkspace.shared.open(previewURL)
        } catch {
            status = "Could not open range preview: \(error.localizedDescription)"
        }
    }

    func thumbnail(for range: SplitPlanRange, size: CGSize = CGSize(width: 128, height: 172)) -> NSImage? {
        guard let pdfDocument,
              let pageIndex = pageIndex(from: range.pageFrom),
              let page = pdfDocument.page(at: pageIndex) else {
            return nil
        }
        return page.thumbnail(of: size, for: .cropBox)
    }

    func rangeStatus(for range: SplitPlanRange) -> String {
        guard pageCount > 0 else { return "PDF is not loaded" }
        guard let from = Int(range.pageFrom), let to = Int(range.pageTo) else {
            return "Enter page numbers"
        }
        if from < 1 || to < 1 || from > pageCount || to > pageCount {
            return "Pages must be 1-\(pageCount)"
        }
        if from > to {
            return "Page From must be before Page To"
        }
        return "\(to - from + 1) pages"
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
            let bookmarkRanges = splitRangesFromBookmarks(in: document)
            hasPDFBookmarks = !bookmarkRanges.isEmpty
            isUsingFallbackRange = bookmarkRanges.isEmpty
            ranges = bookmarkRanges.isEmpty ? [
                SplitPlanRange(
                    title: resolvedURL.deletingPathExtension().lastPathComponent,
                    pageFrom: "1",
                    pageTo: "\(document.pageCount)"
                )
            ] : bookmarkRanges
            let loadedMessage = loadedFromPath ? "Loaded working PDF." : (isStale ? "Loaded PDF. Bookmark may need refreshing later." : "Loaded PDF from bookmark.")
            status = bookmarkRanges.isEmpty ? "\(loadedMessage) No PDF bookmarks found." : "\(loadedMessage) Created \(bookmarkRanges.count) split rows from PDF bookmarks."
            isLoadingPDF = false
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

    private func removeGeneratedSplitPDFs() throws {
        let fileManager = FileManager.default
        let sourcePath = pdfURL.standardizedFileURL.path
        let backupPath = backupPDFURL(for: pdfURL).standardizedFileURL.path
        let pdfURLs = (try? fileManager.contentsOfDirectory(
            at: projectFolderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in pdfURLs where url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame {
            guard url.standardizedFileURL.path != sourcePath else { continue }
            guard url.standardizedFileURL.path != backupPath else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private func backupPDFURL(for sourceURL: URL) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + "_bkp")
            .appendingPathExtension("pdf")
    }

    private func rebuildBookmarks(in document: PDFDocument, bookmarkStarts: [(title: String, pageIndex: Int)]) {
        let root = PDFOutline()
        for item in bookmarkStarts {
            guard let page = document.page(at: item.pageIndex) else { continue }
            let outline = PDFOutline()
            outline.label = item.title
            outline.destination = PDFDestination(page: page, at: .zero)
            root.insertChild(outline, at: root.numberOfChildren)
        }
        document.outlineRoot = root
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
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: projectFolderURL.appendingPathComponent("split-plan.json"), options: .atomic)
    }

    private func writeSplitPDFs(from document: PDFDocument, ranges: [SplitPlanRange]) throws -> Int {
        var usedNames: Set<String> = [pdfURL.lastPathComponent]
        var writtenCount = 0

        for (index, range) in ranges.enumerated() {
            guard let from = Int(range.pageFrom),
                  let to = Int(range.pageTo),
                  from >= 1,
                  to >= from,
                  to <= document.pageCount else {
                continue
            }

            let splitDocument = PDFDocument()
            for pageNumber in from...to {
                guard let page = document.page(at: pageNumber - 1) else { continue }
                splitDocument.insert(page, at: splitDocument.pageCount)
            }

            guard splitDocument.pageCount > 0 else { continue }

            let outputURL = uniqueSplitPDFURL(for: range, index: index + 1, usedNames: &usedNames)
            guard splitDocument.write(to: outputURL) else {
                throw NSError(domain: "NewOCR", code: 30, userInfo: [NSLocalizedDescriptionKey: "Could not write \(outputURL.lastPathComponent)."])
            }
            writtenCount += 1
        }

        return writtenCount
    }

    private func writeOrderedSectionPDFs(from document: PDFDocument, ranges: [SplitPlanRange]) throws -> [(URL, String)] {
        var savedTitles: [(URL, String)] = []

        for (index, range) in ranges.enumerated() {
            let sectionDocument = try documentForRange(range, from: document)
            let outputURL = projectFolderURL.appendingPathComponent(String(format: "section-%03d.pdf", index + 1))
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            guard sectionDocument.write(to: outputURL) else {
                throw NSError(domain: "NewOCR", code: 37, userInfo: [NSLocalizedDescriptionKey: "Could not write \(outputURL.lastPathComponent)."])
            }
            let title = range.title.trimmingCharacters(in: .whitespacesAndNewlines)
            savedTitles.append((outputURL, title.isEmpty ? outputURL.deletingPathExtension().lastPathComponent : title))
        }

        guard !savedTitles.isEmpty else {
            throw NSError(domain: "NewOCR", code: 38, userInfo: [NSLocalizedDescriptionKey: "No valid page ranges to save."])
        }

        return savedTitles
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

    private func uniqueSplitPDFURL(for range: SplitPlanRange, index: Int, usedNames: inout Set<String>) -> URL {
        let baseTitle = sanitizedFileName(range.title)
        let numberedBase = String(format: "%03d-%@", index, baseTitle)
        var fileName = numberedBase + ".pdf"
        var counter = 2

        while usedNames.contains(fileName) {
            fileName = "\(numberedBase)-\(counter).pdf"
            counter += 1
        }

        usedNames.insert(fileName)
        return projectFolderURL.appendingPathComponent(fileName)
    }

    private func sanitizedFileName(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)
        let cleaned = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Split" : cleaned
    }

    private func pageIndex(from value: String) -> Int? {
        guard pageCount > 0, let pageNumber = Int(value) else { return nil }
        let clampedPageNumber = min(max(pageNumber, 1), pageCount)
        return clampedPageNumber - 1
    }
}

struct SplitPlannerWindowView: View {
    @EnvironmentObject private var planner: SplitPlannerState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Split PDF")
                        .font(.largeTitle.weight(.semibold))
                    Text(planner.pdfName)
                        .font(.headline)
                    Text(planner.pdfURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Project: \(planner.projectFolderURL.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("\(planner.pageCount) pages")
                        .font(.headline.monospacedDigit())

                    Button("Crop") {
                        planner.openCropWindow()
                    }
                    .disabled(planner.isLoadingPDF || planner.pageCount == 0)

                    Button("Open PDF") {
                        planner.openPDF()
                    }
                    .disabled(planner.pageCount == 0)

                    Button("Add Split") {
                        planner.openAddSplitWindow()
                    }
                    .disabled(planner.isLoadingPDF || planner.pageCount == 0 || planner.hasPDFBookmarks)

                    Button("Re-Generate files") {
                        planner.regenerateFiles()
                    }
                    .disabled(planner.isLoadingPDF || planner.pageCount == 0)

                    Button("Add Range") {
                        planner.addRange()
                    }
                    .disabled(planner.pageCount == 0)

                    Button("Save") {
                        let window = NSApp.keyWindow
                        planner.saveRangesToSourcePDF { saved in
                            if saved {
                                window?.close()
                            }
                        }
                    }
                    .disabled(planner.isLoadingPDF || planner.pageCount == 0)

                    Button("Close") {
                        NSApp.keyWindow?.close()
                    }
                }
            }

            Text(planner.status)
                .font(.caption)
                .foregroundStyle(.secondary)

            if planner.isLoadingPDF {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Please wait while NewOCR reads the PDF bookmarks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !planner.projectPDFs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project PDFs")
                        .font(.headline)

                    LazyVStack(spacing: 6) {
                        ForEach(planner.projectPDFs) { item in
                            HStack(spacing: 10) {
                                Image(systemName: "doc.richtext")
                                    .foregroundStyle(.secondary)
                                Text(item.fileName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("Open") {
                                    planner.openProjectPDF(item)
                                }
                            }
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            HStack(spacing: 12) {
                Text("Preview")
                    .frame(width: 138, alignment: .leading)
                Text("Title")
                    .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                Text("Page From")
                    .frame(width: 90, alignment: .leading)
                Text("Page To")
                    .frame(width: 90, alignment: .leading)
                Text("Status")
                    .frame(width: 160, alignment: .leading)
                Text("")
                    .frame(width: 58)
                Text("")
                    .frame(width: 34)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach($planner.ranges) { $range in
                        SplitPlanRangeRow(range: $range)
                            .environmentObject(planner)
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 820, minHeight: 520)
    }
}

struct CropPDFWindowView: View {
    @EnvironmentObject private var planner: SplitPlannerState
    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var previewPageIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Crop PDF")
                        .font(.largeTitle.weight(.semibold))
                    Text(planner.pdfName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("Save") {
                    let window = NSApp.keyWindow
                    planner.saveCrop(normalizedRect: cropRect) { saved in
                        if saved {
                            window?.close()
                        }
                    }
                }
                .disabled(planner.isLoadingPDF)

                Button("Close") {
                    NSApp.keyWindow?.close()
                }
            }

            HStack(spacing: 10) {
                Button("<") {
                    previewPageIndex = max(previewPageIndex - 1, 0)
                }
                .frame(width: 44)
                .disabled(previewPageIndex <= 0 || planner.pageCount == 0)

                Text("Page \(min(previewPageIndex + 1, max(planner.pageCount, 1))) of \(max(planner.pageCount, 1))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 120)

                Button(">") {
                    previewPageIndex = min(previewPageIndex + 1, max(planner.pageCount - 1, 0))
                }
                .frame(width: 44)
                .disabled(previewPageIndex >= planner.pageCount - 1 || planner.pageCount == 0)

                Text("Drag the crop box or its corners. The same relative crop is applied to every page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if planner.isLoadingPDF {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(planner.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            } else {
                ContentUnavailableView("No PDF Preview", systemImage: "doc.richtext", description: Text("Load the source PDF before cropping."))
                    .frame(minWidth: 720, minHeight: 500)
            }
        }
        .padding(18)
        .frame(minWidth: 820, minHeight: 620)
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

struct AddSplitWindowView: View {
    @EnvironmentObject private var planner: SplitPlannerState
    @State private var previewPageIndex = 0
    @State private var titleText = ""
    @State private var pageFrom = "1"
    @State private var pageTo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Split")
                        .font(.largeTitle.weight(.semibold))
                    Text(planner.pdfName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("Close") {
                    NSApp.keyWindow?.close()
                }
            }

            HStack(spacing: 10) {
                Button("<") {
                    previewPageIndex = max(previewPageIndex - 1, 0)
                }
                .frame(width: 44)
                .disabled(previewPageIndex <= 0 || planner.pageCount == 0)

                Text("Page \(min(previewPageIndex + 1, max(planner.pageCount, 1))) of \(max(planner.pageCount, 1))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 120)

                Button(">") {
                    previewPageIndex = min(previewPageIndex + 1, max(planner.pageCount - 1, 0))
                }
                .frame(width: 44)
                .disabled(previewPageIndex >= planner.pageCount - 1 || planner.pageCount == 0)

                Spacer()
            }

            HStack(spacing: 10) {
                TextField("Title", text: $titleText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)

                Text("From")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("From", text: $pageFrom)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)

                Text("To")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("To", text: $pageTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)

                Button("Split") {
                    planner.addSplit(title: titleText, pageFrom: pageFrom, pageTo: pageTo) { saved, nextFrom in
                        if saved {
                            titleText = ""
                            pageFrom = "\(nextFrom)"
                            pageTo = "\(planner.pageCount)"
                            previewPageIndex = min(max(nextFrom - 1, 0), max(planner.pageCount - 1, 0))
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(planner.isLoadingPDF || titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || planner.pageCount == 0)
            }

            if planner.isLoadingPDF {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(planner.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(planner.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let image = planner.cropPreviewImage(pageIndex: previewPageIndex) {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .frame(minWidth: 720, minHeight: 500)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            } else {
                ContentUnavailableView("No PDF Preview", systemImage: "doc.richtext", description: Text("Load the source PDF before adding splits."))
                    .frame(minWidth: 720, minHeight: 500)
            }
        }
        .padding(18)
        .frame(minWidth: 820, minHeight: 620)
        .onAppear {
            resetRange()
        }
        .onChange(of: planner.pageCount) { _, _ in
            resetRange()
        }
    }

    private func resetRange() {
        let nextFrom = planner.nextAddSplitFromPage()
        pageFrom = "\(nextFrom)"
        pageTo = "\(max(planner.pageCount, nextFrom))"
        previewPageIndex = min(max(nextFrom - 1, 0), max(planner.pageCount - 1, 0))
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

struct SplitPlanRangeRow: View {
    @EnvironmentObject private var planner: SplitPlannerState
    @Binding var range: SplitPlanRange

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                if let thumbnail = planner.thumbnail(for: range) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else {
                    Text("No preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 138, height: 176)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            TextField("Title", text: $range.title)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: .infinity)

            TextField("1", text: $range.pageFrom)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)

            TextField("\(planner.pageCount)", text: $range.pageTo)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)

            Text(planner.rangeStatus(for: range))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
                .padding(.top, 6)

            Button("Open") {
                planner.openRangePreview(range)
            }
            .disabled(planner.isLoadingPDF || planner.pageCount == 0)
            .frame(width: 58)
            .padding(.top, 4)

            Button {
                planner.removeRange(range)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove range")
            .disabled(planner.ranges.count <= 1)
            .frame(width: 34)
            .padding(.top, 5)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
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
        }
        .windowStyle(.titleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
