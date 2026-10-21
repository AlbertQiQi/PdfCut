import CoreGraphics
import Foundation
import ImageIO

@main
struct TestSlicer {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: TestSlicer /path/to/sample.pdf")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-slicer-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.pdf")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: source)
        guard let pdf = CGPDFDocument(source as CFURL), pdf.numberOfPages > 0 else {
            fatalError("Test PDF unreadable")
        }
        var layouts = (0..<pdf.numberOfPages).map { _ in
            SliceLayout(vertical: PDFSlicer.equalCuts(columns: 5))
        }
        layouts[0].horizontal = [0.5]
        assert(PDFSlicer.newLine(in: []) == 0.5)
        var invalid = layouts
        invalid[0].vertical = [0.7, 0.3]
        do {
            _ = try PDFSlicer.export(source: source, layouts: invalid, dpi: 150)
            fatalError("Invalid cut lines were accepted")
        } catch SliceError.invalidLines(1) {
            // Expected.
        }
        let folder = try PDFSlicer.export(source: source, layouts: layouts, dpi: 300)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        assert(files.count == pdf.numberOfPages * 5 + 5)
        assert(files.contains { $0.lastPathComponent == "page-001-r01-c01.png" })
        assert(files.contains { $0.lastPathComponent == "page-001-r02-c05.png" })
        let firstPage = pdf.page(at: 1)!
        let box = firstPage.getBoxRect(.cropBox)
        let quarterTurn = firstPage.rotationAngle % 180 != 0
        let displayedWidth = quarterTurn ? box.height : box.width
        let displayedHeight = quarterTurn ? box.width : box.height
        for file in files {
            guard let imageSource = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                fatalError("PNG unreadable: \(file.lastPathComponent)")
            }
            assert(image.width > 0 && image.height > 0)
            if file.lastPathComponent == "page-001-r01-c01.png" {
                assert(image.width == Int(ceil(displayedWidth / 5 * 300 / 72)))
                assert(image.height == Int(ceil(displayedHeight / 2 * 300 / 72)))
            }
        }
        let second = try PDFSlicer.export(source: source, layouts: layouts, dpi: 150)
        assert(folder != second && folder.lastPathComponent == "sample-切片")
        print("PASS: \(files.count) PNG 切片、命名与同名文件夹保护")
    }
}
