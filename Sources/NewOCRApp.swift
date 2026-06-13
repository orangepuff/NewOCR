import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct PDFFileItem: Identifiable, Equatable {
    let id: String
    let url: URL

    var fileName: String {
        url.lastPathComponent
    }
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

    @Published var pdfListMinHeight: CGFloat = 420
    @Published var mainWindowWidth: CGFloat = 780
    @Published var mainWindowHeight: CGFloat = 520
    @Published var shouldOpenMainWindowFullScreen: Bool = false
    @Published var ocrParagraphTextAreaMinHeight: CGFloat = 58
    @Published var ocrWindowWidth: CGFloat = 820
    @Published var ocrWindowHeight: CGFloat = 620
    @Published var shouldOpenOCRWindowFullScreen: Bool = false

    @Published private(set) var pdfFiles: [PDFFileItem] = []

    private let defaults = UserDefaults.standard
    private var isRestoring = false
    private var ocrWindows: [NSWindow] = []
    private var activeConfigFileURL: URL?

    init() {
        restore()
    }

    var selectedPDFName: String {
        guard !selectedPDFPath.isEmpty else { return "No PDF selected" }
        return URL(fileURLWithPath: selectedPDFPath).lastPathComponent
    }

    var selectedPDFTitle: String {
        guard !selectedPDFPath.isEmpty else { return "" }
        return pdfTitles[selectedPDFPath]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    var localAppleVisionOutputFolderURL: URL? {
        guard !selectedPDFPath.isEmpty else { return nil }
        let pdfURL = URL(fileURLWithPath: selectedPDFPath)
        return appleVisionOutputFolderURL(for: pdfURL)
            .appendingPathComponent(pdfURL.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    var bookEPUBFileURL: URL? {
        guard !selectedFolderPath.isEmpty else { return nil }
        let folderURL = URL(fileURLWithPath: selectedFolderPath)
        return folderURL
            .appendingPathComponent("AppleVision", isDirectory: true)
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

    var localAppleVisionOutputFolderPathIfExists: String? {
        guard let folderURL = localAppleVisionOutputFolderURL else {
            return nil
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
        panel.prompt = "Select Folder"
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

    func beginOCR(for item: PDFFileItem) {
        selectedPDFPath = item.url.path
        currentStep = 1
        isOCRRunning = false
        logOutput = ""
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

    func reloadSelectedFolder() {
        pdfTitles = [:]
        loadPDFFiles()
    }

    func clearSelectedFolder() {
        selectedFolderPath = ""
        selectedPDFPath = ""
        currentStep = 1
    }

    func openConfigEditor() {
        openTextConfig(title: "Config File", url: configFileURL)
    }

    func openOCRInstructionEditor() {
        openTextConfig(title: "OCRInstruction", url: ocrInstructionFileURL)
    }

    func chooseFrontCoverImage() {
        chooseCoverImage(title: "Select Front Cover Image") { path in
            self.frontCoverImagePath = path
        }
    }

    func chooseBackCoverImage() {
        chooseCoverImage(title: "Select Back Cover Image") { path in
            self.backCoverImagePath = path
        }
    }

    private func chooseCoverImage(title: String, assign: (String) -> Void) {
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

        assign(url.path)
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
        logOutput = "Run OCR first to create Markdown files."
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
        logOutput = "Run OCR first to create Markdown files."
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
            let markdownFolder = appleVisionOutputFolderURL(for: item.url)
                .appendingPathComponent(item.url.deletingPathExtension().lastPathComponent, isDirectory: true)
            let markdownFiles = appleVisionMarkdownPageFiles(in: markdownFolder)
            guard !markdownFiles.isEmpty else {
                return nil
            }
            let title = pdfTitles[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? item.url.deletingPathExtension().lastPathComponent
            return [
                "pdf": item.url.path,
                "title": title.isEmpty ? item.url.deletingPathExtension().lastPathComponent : title,
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
            .appendingPathComponent("AppleVision", isDirectory: true)
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
                        self.epubStatus = epubPath.isEmpty
                            ? "EPUB built from \(chapters.count) chapters."
                            : "EPUB built: \(epubPath)"
                        self.logOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.isEPUBBuiltAlertPresented = !epubPath.isEmpty
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
        guard !builtEPUBPath.isEmpty else {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: builtEPUBPath))
    }

    func appleVisionMarkdownExists(for item: PDFFileItem) -> Bool {
        let folderURL = appleVisionOutputFolderURL(for: item.url)
            .appendingPathComponent(item.url.deletingPathExtension().lastPathComponent, isDirectory: true)
        let pageFiles = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        return pageFiles.contains { $0.pathExtension.lowercased() == "md" }
    }

    var markdownChapterCount: Int {
        pdfFiles.filter { appleVisionMarkdownExists(for: $0) }.count
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
            }
        )
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

    var ocrSearchResultText: String {
        let query = ocrSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "" }

        let matches = ocrParagraphs.enumerated().compactMap { index, paragraph -> (Int, Int)? in
            let count = countOccurrences(of: query, in: paragraph)
            return count > 0 ? (index + 1, count) : nil
        }
        let total = matches.reduce(0) { $0 + $1.1 }

        guard total > 0 else {
            return "Found 0 times"
        }

        let paragraphList = matches.map { "\($0.0)" }.joined(separator: ", ")
        return "Found \(total) times in p#\(paragraphList)"
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
    }

    func addParagraphAfter(_ index: Int) {
        var paragraphs = ocrParagraphs
        let insertIndex = max(0, min(index + 1, paragraphs.count))
        paragraphs.insert("", at: insertIndex)
        setOCRParagraphs(paragraphs)
    }

    func mergeParagraphBefore(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard index > 0, paragraphs.indices.contains(index) else { return }
        paragraphs[index - 1] = mergeParagraphText(paragraphs[index - 1], paragraphs[index])
        paragraphs.remove(at: index)
        setOCRParagraphs(paragraphs)
    }

    func mergeParagraphAfter(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index), index + 1 < paragraphs.count else { return }
        paragraphs[index] = mergeParagraphText(paragraphs[index], paragraphs[index + 1])
        paragraphs.remove(at: index + 1)
        setOCRParagraphs(paragraphs)
    }

    func removeParagraph(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index) else { return }
        paragraphs.remove(at: index)
        setOCRParagraphs(paragraphs)
    }

    func moveParagraphUp(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard index > 0, paragraphs.indices.contains(index) else { return }
        paragraphs.swapAt(index, index - 1)
        setOCRParagraphs(paragraphs)
    }

    func moveParagraphDown(_ index: Int) {
        var paragraphs = ocrParagraphs
        guard paragraphs.indices.contains(index), index + 1 < paragraphs.count else { return }
        paragraphs.swapAt(index, index + 1)
        setOCRParagraphs(paragraphs)
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
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
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
            return
        }

        let folderURL = URL(fileURLWithPath: selectedFolderPath)
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        pdfFiles = urls
            .filter { $0.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { PDFFileItem(id: $0.path, url: $0) }
    }

    private func appleVisionOutputFolderURL(for pdfURL: URL) -> URL {
        pdfURL
            .deletingLastPathComponent()
            .appendingPathComponent("AppleVision", isDirectory: true)
            .appendingPathComponent("MD", isDirectory: true)
    }

    private func ensureConfigFilesExist() {
        let folderURL = configFileURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

            if !FileManager.default.fileExists(atPath: configFileURL.path) {
                try defaultConfigText().write(to: configFileURL, atomically: true, encoding: .utf8)
            }

            if !FileManager.default.fileExists(atPath: ocrInstructionFileURL.path) {
                try defaultOCRInstructionText().write(to: ocrInstructionFileURL, atomically: true, encoding: .utf8)
            }

        } catch {
            configStatus = "Could not prepare config: \(error.localizedDescription)"
        }
    }

    private func loadAppConfigValues() {
        let values = readKeyValueConfig(from: configFileURL)
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
        PDF_LIST_MIN_HEIGHT=420
        # Set MAIN_WINDOW_WIDTH=FULL to open the main window at full screen size.
        MAIN_WINDOW_WIDTH=780
        MAIN_WINDOW_HEIGHT=520
        # Set OCR_WINDOW_WIDTH=FULL to open the OCR window at full screen size.
        OCR_WINDOW_WIDTH=820
        OCR_WINDOW_HEIGHT=620
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
                        Button("Select Folder") {
                            appState.chooseFolder()
                        }
                        .controlSize(.large)
                        .keyboardShortcut("o", modifiers: [.command])

                        Text(appState.selectedFolderPath.isEmpty ? "No folder selected yet" : appState.selectedFolderPath)
                            .foregroundStyle(appState.selectedFolderPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 220, maxWidth: 520, alignment: .leading)

                        Button("Refresh") {
                            appState.reloadSelectedFolder()
                        }
                        .controlSize(.large)
                        .disabled(appState.selectedFolderPath.isEmpty)

                        Button("Clear") {
                            appState.clearSelectedFolder()
                        }
                        .controlSize(.large)
                        .disabled(appState.selectedFolderPath.isEmpty)

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

                        Button(appState.isOCRRunning ? "Building EPUB..." : "Build EPUB") {
                            appState.buildBookEPUB()
                        }
                        .controlSize(.large)
                        .disabled(appState.isOCRRunning || appState.markdownChapterCount == 0)
                    }

                    HStack(spacing: 18) {
                        HStack(spacing: 10) {
                            Button("Front Cover") {
                                appState.chooseFrontCoverImage()
                            }

                            Text(appState.frontCoverImagePath.isEmpty ? "No front cover selected" : appState.frontCoverImagePath)
                                .foregroundStyle(appState.frontCoverImagePath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 10) {
                            Button("Back Cover") {
                                appState.chooseBackCoverImage()
                            }

                            Text(appState.backCoverImagePath.isEmpty ? "No back cover selected" : appState.backCoverImagePath)
                                .foregroundStyle(appState.backCoverImagePath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !appState.epubStatus.isEmpty {
                        Text(appState.epubStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("PDF Files")
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
                EmptyStateView(title: "No PDF files found in this folder.")
            } else {
                List(appState.pdfFiles) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.richtext")
                            .foregroundStyle(.red)

                        if appState.appleVisionMarkdownExists(for: item) {
                            Text("MD")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }

                        Button {
                            NSWorkspace.shared.open(item.url)
                        } label: {
                            Text(item.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.link)
                        .help("Open PDF")

                        Text("Title")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        TextField("Title", text: appState.titleBinding(for: item))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)

                        if appState.headerFooterScanned(for: item) {
                            Text("Scanned")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }

                        Button(appState.isScanningHeaderFooter(for: item) ? "Scanning..." : "Scan Header") {
                            appState.scanHeaderFooterSample(for: item)
                        }
                        .disabled(appState.isScanningHeaderFooter(for: item))

                        Button("Process") {
                            appState.beginOCR(for: item)
                        }
                        .disabled(!appState.headerFooterScanned(for: item) || appState.isScanningHeaderFooter(for: item))

                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
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

                    Button("Close Window") {
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
                                    Spacer()
                                    Button("Save") {
                                        appState.saveOCRTextFile()
                                    }
                                    .disabled(appState.isOCRRunning || appState.selectedPDFPath.isEmpty)
                                }
                                HStack(spacing: 10) {
                                    TextField("Search Markdown", text: $appState.ocrSearchText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 260)
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
                                    Spacer()
                                }
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

                        VStack(alignment: .leading, spacing: 10) {
                            Button("Files") {
                                isFilesPopoverPresented.toggle()
                            }
                            .controlSize(.large)
                            .popover(isPresented: $isFilesPopoverPresented) {
                                FilesPopoverView()
                                    .environmentObject(appState)
                            }

                            Text("Ready for OCR")
                                .font(.headline)

                            Button {
                                if !appState.selectedPDFPath.isEmpty {
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
                            .disabled(appState.selectedPDFPath.isEmpty)

                            HStack(spacing: 10) {
                                Button(appState.isOCRRunning ? "Processing..." : "Run OCR") {
                                    appState.sendSelectedPDFToOCREngine()
                                }
                                .disabled(appState.isOCRRunning || appState.selectedPDFPath.isEmpty)

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
                    }
                    .frame(minWidth: 320, idealWidth: 320, maxWidth: 320, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(22)
    }
}

struct MarkdownSyntaxPopoverView: View {
    private let examples: [(syntax: String, result: String)] = [
        ("# Chapter title", "Heading 1"),
        ("## Section title", "Heading 2"),
        ("### Subsection title", "Heading 3"),
        ("A blank line", "Starts a new paragraph"),
        ("**bold text**", "Bold text"),
        ("*italic text*", "Italic text"),
        ("![Alt text](Images/example.png)", "Image")
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

            Text("Image paths are relative to the Markdown folder. Other Markdown characters stay as normal text unless the converter supports them later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 430, alignment: .leading)
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
        let paragraphs = appState.ocrParagraphs

        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(paragraphs.indices), id: \.self) { index in
                    ParagraphItemView(
                        index: index,
                        text: appState.paragraphBinding(at: index)
                    )
                    .environmentObject(appState)
                }
            }
            .padding(10)
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

        init(_ parent: HighlightingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyHighlights(searchText: parent.searchText)
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

struct ParagraphItemView: View {
    @EnvironmentObject private var appState: AppState
    let index: Int
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Paragraph \(index + 1)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Menu("Actions") {
                    Button("Add Paragraph Before") {
                        appState.addParagraphBefore(index)
                    }

                    Button("Add Paragraph After") {
                        appState.addParagraphAfter(index)
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

                    Button("Remove Paragraph", role: .destructive) {
                        appState.removeParagraph(index)
                    }
                    .disabled(appState.ocrParagraphs.count <= 1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let imageURL = appState.markdownImageURL(from: text) {
                OCRMarkdownImagePreview(imageURL: imageURL, markdownText: text)
            } else {
                HighlightingTextEditor(
                    text: $text,
                    searchText: appState.ocrSearchText
                )
                    .frame(minHeight: appState.ocrParagraphTextAreaMinHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct OCRMarkdownImagePreview: View {
    let imageURL: URL
    let markdownText: String

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

            Text(markdownText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
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
