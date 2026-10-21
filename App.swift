import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PDFPanelCutterApp: App {
    var body: some Scene {
        WindowGroup("PDF 切片") {
            CutterView().frame(minWidth: 950, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 760)
    }
}

enum SliceLine: Equatable {
    case vertical(Int), horizontal(Int)
}

struct CutterView: View {
    @State private var rootFolder: URL?
    @State private var selectedFolder: URL?
    @State private var folderPDFs: [URL] = []
    @State private var sourceURL: URL?
    @State private var document: PDFDocument?
    @State private var selectedPage = 0
    @State private var selectedLine: SliceLine?
    @State private var layouts: [SliceLayout] = []
    @State private var dpi = 300
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var currentPage: PDFPage? { document?.page(at: selectedPage) }
    private var sliceCount: Int {
        layouts.reduce(0) { $0 + ($1.vertical.count + 1) * ($1.horizontal.count + 1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("打开文件夹…", action: openFolder)
                    .disabled(isExporting)
                Button("打开 PDF…", action: openPDF)
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(isExporting)
                Text(sourceURL?.lastPathComponent ?? "选择一份 PDF 开始")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if document != nil {
                    Text("预计 \(sliceCount) 张 PNG")
                        .foregroundStyle(.secondary)
                }
                Button(isExporting ? "正在导出…" : "导出 PNG 切片", action: exportImages)
                    .disabled(document == nil || isExporting)
                    .keyboardShortcut("e", modifiers: .command)
            }
            .padding(16)
            Divider()

            HStack(spacing: 0) {
                fileSidebar
                    .frame(width: 230)
                Divider()
                if document != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("第 \(selectedPage + 1) 页预览").font(.headline)
                            Spacer()
                            Text("拖动分割线；点选后按 Backspace 删除")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let page = currentPage {
                            SlicePreview(page: page, layout: layouts[selectedPage], selectedLine: selectedLine,
                                         selectLine: { selectedLine = $0 },
                                         moveVertical: { index, value in moveLine(index, to: value, vertical: true) },
                                         moveHorizontal: { index, value in moveLine(index, to: value, vertical: false) })
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.25)))
                        }
                        Text("切片按原 PDF 页码、从上到下、从左到右命名；原 PDF 不变。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("分割线").font(.headline)
                            HStack {
                                Button("＋ 竖线 (E)") { addLine(vertical: true) }
                                    .disabled(layouts[selectedPage].vertical.count >= 9)
                                Button("＋ 横线 (Q)") { addLine(vertical: false) }
                                    .disabled(layouts[selectedPage].horizontal.count >= 9)
                            }
                            Text("竖线")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.blue)
                            lineControls(vertical: true)
                            Text("横线")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                            lineControls(vertical: false)
                            Divider()
                            Button("竖线等宽排列") {
                                layouts[selectedPage].vertical = PDFSlicer.equalCuts(
                                    columns: layouts[selectedPage].vertical.count + 1)
                            }
                            Button("将本页分割线应用到全部页") {
                                let template = layouts[selectedPage]
                                layouts = layouts.map { _ in template }
                            }
                            Divider()
                            Picker("PNG 分辨率", selection: $dpi) {
                                Text("150 DPI").tag(150)
                                Text("300 DPI").tag(300)
                                Text("600 DPI").tag(600)
                            }
                            Text("输出到原 PDF 所在目录的“文件名-切片”文件夹；同名文件夹已存在时自动加序号。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                    .frame(width: 260)
                } else {
                    ContentUnavailableView("从左侧选择 PDF", systemImage: "doc.richtext",
                                           description: Text("先打开文件夹，再展开目录并选择 PDF；也可以直接打开 PDF。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .alert("处理失败", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("好") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .alert("导出完成", isPresented: Binding(
            get: { successMessage != nil }, set: { if !$0 { successMessage = nil } }
        )) { Button("好") { successMessage = nil } } message: { Text(successMessage ?? "") }
        .background(ShortcutMonitor { keyCode in handleShortcut(keyCode) })
    }

    private var fileSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("文件夹").font(.headline)
                Spacer()
                if rootFolder != nil {
                    Button("更换…", action: openFolder).controlSize(.small)
                }
            }
            .padding(12)
            ScrollView {
                if let rootFolder {
                    FolderTreeRow(url: rootFolder, selected: selectedFolder,
                                  isRoot: true, onSelect: selectFolder)
                        .id(rootFolder)
                } else {
                    Text("点上方“打开文件夹…”选择目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .frame(height: 170)
            Divider()
            HStack {
                Text("PDF 文件").font(.headline)
                Spacer()
                if selectedFolder != nil {
                    Button("刷新") { if let selectedFolder { selectFolder(selectedFolder) } }
                        .controlSize(.small)
                }
            }
            .padding(12)
            List(folderPDFs, id: \.self) { url in
                Button {
                    loadPDF(url)
                } label: {
                    Label(url.lastPathComponent, systemImage: "doc.richtext")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .listRowBackground(sourceURL == url ? Color.accentColor.opacity(0.14) : Color.clear)
            }
            .frame(height: 170)
            Divider()
            Text("PDF 页面").font(.headline).padding(12)
            if let document {
                List(0..<document.pageCount, id: \.self) { index in
                    Button {
                        selectedPage = index
                        selectedLine = nil
                    } label: {
                        HStack {
                            Text("第 \(index + 1) 页")
                            Spacer()
                            Text("\(layouts[index].horizontal.count + 1)×\(layouts[index].vertical.count + 1)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selectedPage == index ? Color.accentColor.opacity(0.14) : Color.clear)
                }
            } else {
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func lineControls(vertical: Bool) -> some View {
        let lines = vertical ? layouts[selectedPage].vertical : layouts[selectedPage].horizontal
        if lines.isEmpty {
            Text("无").foregroundStyle(.secondary)
        } else {
            ForEach(lines.indices, id: \.self) { index in
                let line: SliceLine = vertical ? .vertical(index) : .horizontal(index)
                HStack {
                    Text("\(index + 1)").frame(width: 18, alignment: .leading)
                    TextField("百分比", value: Binding(
                        get: {
                            let current = vertical ? layouts[selectedPage].vertical : layouts[selectedPage].horizontal
                            return current[index] * 100
                        },
                        set: { moveLine(index, to: $0 / 100, vertical: vertical) }
                    ), format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 68)
                    Text("%")
                    Spacer()
                    Button("删除") { removeLine(index, vertical: vertical) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 4)
                .background(selectedLine == line ? Color.accentColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { selectedLine = line }
            }
        }
    }

    private func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootFolder = url.deletingLastPathComponent()
        selectFolder(url.deletingLastPathComponent())
        loadPDF(url)
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootFolder = url
        selectFolder(url)
    }

    private func selectFolder(_ url: URL) {
        selectedFolder = url
        folderPDFs = FolderFiles.pdfs(in: url)
    }

    private func loadPDF(_ url: URL) {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else {
            errorMessage = "PDF 无法读取、已加密，或没有页面。"
            return
        }
        sourceURL = url
        document = pdf
        selectedPage = 0
        selectedLine = nil
        layouts = (0..<pdf.pageCount).map { index in
            let page = pdf.page(at: index)!
            let size = page.bounds(for: .cropBox).size
            let quarterTurn = page.rotation % 180 != 0
            return SliceLayout(vertical: PDFSlicer.equalCuts(
                columns: PDFSlicer.suggestedColumns(
                    width: quarterTurn ? size.height : size.width,
                    height: quarterTurn ? size.width : size.height)))
        }
    }

    private func addLine(vertical: Bool) {
        let lines = vertical ? layouts[selectedPage].vertical : layouts[selectedPage].horizontal
        guard lines.count < 9 else { return }
        guard let fraction = PDFSlicer.newLine(in: lines) else { return }
        if vertical {
            layouts[selectedPage].vertical = (lines + [fraction]).sorted()
            selectedLine = .vertical(layouts[selectedPage].vertical.firstIndex(of: fraction) ?? 0)
        } else {
            layouts[selectedPage].horizontal = (lines + [fraction]).sorted()
            selectedLine = .horizontal(layouts[selectedPage].horizontal.firstIndex(of: fraction) ?? 0)
        }
    }

    private func removeLine(_ index: Int, vertical: Bool) {
        if vertical { layouts[selectedPage].vertical.remove(at: index) }
        else { layouts[selectedPage].horizontal.remove(at: index) }
        switch selectedLine {
        case .vertical(let selected) where vertical:
            selectedLine = selected == index ? nil : .vertical(selected > index ? selected - 1 : selected)
        case .horizontal(let selected) where !vertical:
            selectedLine = selected == index ? nil : .horizontal(selected > index ? selected - 1 : selected)
        default: break
        }
    }

    private func handleShortcut(_ keyCode: UInt16) -> Bool {
        guard let document, !isExporting else { return false }
        switch keyCode {
        case 13: // W
            guard selectedPage > 0 else { return true }
            selectedPage -= 1
            selectedLine = nil
        case 1: // S
            guard selectedPage + 1 < document.pageCount else { return true }
            selectedPage += 1
            selectedLine = nil
        case 12: addLine(vertical: false) // Q
        case 14: addLine(vertical: true)  // E
        case 51, 117: // Backspace / forward Delete
            guard let selectedLine else { return false }
            switch selectedLine {
            case .vertical(let index): removeLine(index, vertical: true)
            case .horizontal(let index): removeLine(index, vertical: false)
            }
        default: return false
        }
        return true
    }

    private func moveLine(_ index: Int, to fraction: Double, vertical: Bool) {
        var lines = vertical ? layouts[selectedPage].vertical : layouts[selectedPage].horizontal
        guard lines.indices.contains(index) else { return }
        let left = index == 0 ? 0 : lines[index - 1]
        let right = index == lines.count - 1 ? 1 : lines[index + 1]
        lines[index] = min(right - 0.01, max(left + 0.01, fraction))
        if vertical { layouts[selectedPage].vertical = lines }
        else { layouts[selectedPage].horizontal = lines }
    }

    private func exportImages() {
        guard let sourceURL else { return }
        let snapshot = layouts
        let selectedDPI = dpi
        isExporting = true
        Task.detached {
            do {
                let folder = try PDFSlicer.export(source: sourceURL, layouts: snapshot, dpi: selectedDPI)
                await MainActor.run {
                    isExporting = false
                    successMessage = folder.path
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct ShortcutMonitor: NSViewRepresentable {
    let onKey: (UInt16) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, event.window === coordinator.view?.window,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(event.window?.firstResponder is NSTextView),
                  !(event.window?.firstResponder is NSTextField) else { return event }
            return coordinator.onKey(event.keyCode) ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var onKey: (UInt16) -> Bool = { _ in false }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

enum FolderFiles {
    private static func entries(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
    }

    static func subfolders(in folder: URL) -> [URL] {
        entries(in: folder).filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func pdfs(in folder: URL) -> [URL] {
        entries(in: folder).filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true && url.pathExtension.lowercased() == "pdf"
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

struct FolderTreeRow: View {
    let url: URL
    let selected: URL?
    let onSelect: (URL) -> Void
    @State private var expanded: Bool

    init(url: URL, selected: URL?, isRoot: Bool = false, onSelect: @escaping (URL) -> Void) {
        self.url = url
        self.selected = selected
        self.onSelect = onSelect
        _expanded = State(initialValue: isRoot)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(FolderFiles.subfolders(in: url), id: \.self) { child in
                FolderTreeRow(url: child, selected: selected, onSelect: onSelect)
                    .padding(.leading, 8)
            }
        } label: {
            Button {
                onSelect(url)
            } label: {
                Label(url.lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .background(selected == url ? Color.accentColor.opacity(0.14) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
    }
}

struct SlicePreview: NSViewRepresentable {
    let page: PDFPage
    let layout: SliceLayout
    let selectedLine: SliceLine?
    let selectLine: (SliceLine?) -> Void
    let moveVertical: (Int, Double) -> Void
    let moveHorizontal: (Int, Double) -> Void

    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView() }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.configure(page: page, layout: layout, selectedLine: selectedLine,
                       selectLine: selectLine,
                       moveVertical: moveVertical, moveHorizontal: moveHorizontal)
    }
}

final class PreviewNSView: NSView {
    private var page: PDFPage?
    private var thumbnail: NSImage?
    private var layout = SliceLayout()
    private var selectedLine: SliceLine?
    private var selectLine: ((SliceLine?) -> Void)?
    private var moveVertical: ((Int, Double) -> Void)?
    private var moveHorizontal: ((Int, Double) -> Void)?
    private var dragging: SliceLine?

    func configure(page: PDFPage, layout: SliceLayout, selectedLine: SliceLine?,
                   selectLine: @escaping (SliceLine?) -> Void,
                   moveVertical: @escaping (Int, Double) -> Void,
                   moveHorizontal: @escaping (Int, Double) -> Void) {
        if self.page !== page {
            self.page = page
            thumbnail = page.thumbnail(of: NSSize(width: 1800, height: 1100), for: .cropBox)
        }
        self.layout = layout
        self.selectedLine = selectedLine
        self.selectLine = selectLine
        self.moveVertical = moveVertical
        self.moveHorizontal = moveHorizontal
        needsDisplay = true
    }

    private var imageRect: NSRect {
        guard let thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 else { return .zero }
        let scale = min(bounds.width / thumbnail.size.width, bounds.height / thumbnail.size.height)
        let size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let rect = imageRect
        thumbnail?.draw(in: rect)
        for (index, fraction) in layout.vertical.enumerated() {
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath()
            path.lineWidth = selectedLine == .vertical(index) ? 4 : 2
            let x = rect.minX + rect.width * fraction
            path.move(to: NSPoint(x: x, y: rect.minY))
            path.line(to: NSPoint(x: x, y: rect.maxY))
            path.stroke()
            drawLabel("V\(index + 1)", at: NSPoint(x: x + 4, y: rect.maxY - 19), color: .systemBlue)
        }
        for (index, fraction) in layout.horizontal.enumerated() {
            NSColor.systemOrange.setStroke()
            let path = NSBezierPath()
            path.lineWidth = selectedLine == .horizontal(index) ? 4 : 2
            let y = rect.maxY - rect.height * fraction
            path.move(to: NSPoint(x: rect.minX, y: y))
            path.line(to: NSPoint(x: rect.maxX, y: y))
            path.stroke()
            drawLabel("H\(index + 1)", at: NSPoint(x: rect.minX + 5, y: y + 4), color: .systemOrange)
        }
    }

    private func drawLabel(_ label: String, at point: NSPoint, color: NSColor) {
        (label as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: color
        ])
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.contains(point) else { return }
        let candidates: [(CGFloat, SliceLine)] =
            layout.vertical.enumerated().map { index, fraction in
                (abs(rect.minX + rect.width * fraction - point.x), .vertical(index))
            } + layout.horizontal.enumerated().map { index, fraction in
                (abs(rect.maxY - rect.height * fraction - point.y), .horizontal(index))
            }
        if let nearest = candidates.min(by: { $0.0 < $1.0 }), nearest.0 <= 18 {
            dragging = nearest.1
            selectLine?(nearest.1)
        } else {
            selectLine?(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return }
        switch dragging {
        case .vertical(let index): moveVertical?(index, (point.x - rect.minX) / rect.width)
        case .horizontal(let index): moveHorizontal?(index, (rect.maxY - point.y) / rect.height)
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) { dragging = nil }
}
