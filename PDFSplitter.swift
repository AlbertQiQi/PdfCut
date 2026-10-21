import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SliceLayout {
    var vertical: [Double] = []    // Left to right, 0...1.
    var horizontal: [Double] = []  // Top to bottom, 0...1.
}

enum SliceError: LocalizedError {
    case unreadablePDF
    case invalidLines(Int)
    case imageTooLarge(Int, Int)
    case imageFailed

    var errorDescription: String? {
        switch self {
        case .unreadablePDF: "无法读取 PDF。"
        case .invalidLines(let page): "PDF 第 \(page) 页的分割线重叠或超出页面。"
        case .imageTooLarge(let page, let dpi): "PDF 第 \(page) 页在 \(dpi) DPI 下切片过大；请改用较低分辨率。"
        case .imageFailed: "无法生成 PNG。"
        }
    }
}

enum PDFSlicer {
    static func equalCuts(columns: Int) -> [Double] {
        guard columns > 1 else { return [] }
        return (1..<columns).map { Double($0) / Double(columns) }
    }

    static func suggestedColumns(width: CGFloat, height: CGFloat) -> Int {
        guard height > 0 else { return 1 }
        return min(10, max(1, Int((width / height / 0.7).rounded())))
    }

    static func newLine(in lines: [Double]) -> Double? {
        let edges = [0.0] + lines + [1.0]
        guard let gap = zip(edges, edges.dropFirst()).max(by: { $0.1 - $0.0 < $1.1 - $1.0 }),
              gap.1 - gap.0 >= 0.04 else { return nil }
        return (gap.0 + gap.1) / 2
    }

    static func export(source: URL, layouts: [SliceLayout], dpi: Int) throws -> URL {
        guard [150, 300, 600].contains(dpi),
              let pdf = CGPDFDocument(source as CFURL), pdf.numberOfPages == layouts.count else {
            throw SliceError.unreadablePDF
        }
        for (index, layout) in layouts.enumerated() {
            for lines in [layout.vertical, layout.horizontal] {
                guard lines.count < 10,
                      lines.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }),
                      zip(lines, lines.dropFirst()).allSatisfy({ $0 < $1 }) else {
                    throw SliceError.invalidLines(index + 1)
                }
            }
        }

        let parent = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + "-切片"
        var folder = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        let staging = parent.appendingPathComponent(".pdf-slicer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }

        for (pageIndex, layout) in layouts.enumerated() {
            guard let page = pdf.page(at: pageIndex + 1) else { throw SliceError.unreadablePDF }
            let box = page.getBoxRect(.cropBox)
            let quarterTurn = page.rotationAngle % 180 != 0
            let pageSize = CGSize(width: quarterTurn ? box.height : box.width,
                                  height: quarterTurn ? box.width : box.height)
            let drawingTransform = page.getDrawingTransform(
                .cropBox, rect: CGRect(origin: .zero, size: pageSize),
                rotate: 0, preserveAspectRatio: false)
            let xs = [0.0] + layout.vertical + [1.0]
            let ys = [0.0] + layout.horizontal + [1.0]
            for row in 0..<(ys.count - 1) {
                for column in 0..<(xs.count - 1) {
                    let section = CGRect(
                        x: pageSize.width * xs[column],
                        y: pageSize.height * (1 - ys[row + 1]),
                        width: pageSize.width * (xs[column + 1] - xs[column]),
                        height: pageSize.height * (ys[row + 1] - ys[row])
                    )
                    let scale = CGFloat(dpi) / 72
                    let width = Int(ceil(section.width * scale))
                    let height = Int(ceil(section.height * scale))
                    guard width > 0, height > 0, width <= 25000, height <= 25000,
                          Double(width) * Double(height) <= 80_000_000 else {
                        throw SliceError.imageTooLarge(pageIndex + 1, dpi)
                    }
                    guard let context = CGContext(
                        data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ) else { throw SliceError.imageFailed }
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    context.scaleBy(x: scale, y: scale)
                    context.translateBy(x: -section.minX, y: -section.minY)
                    context.concatenate(drawingTransform)
                    context.drawPDFPage(page)
                    guard let image = context.makeImage() else { throw SliceError.imageFailed }
                    let name = String(format: "page-%03d-r%02d-c%02d.png", pageIndex + 1, row + 1, column + 1)
                    let destination = staging.appendingPathComponent(name)
                    guard let writer = CGImageDestinationCreateWithURL(
                        destination as CFURL, UTType.png.identifier as CFString, 1, nil
                    ) else { throw SliceError.imageFailed }
                    CGImageDestinationAddImage(writer, image, nil)
                    guard CGImageDestinationFinalize(writer) else { throw SliceError.imageFailed }
                }
            }
        }
        try FileManager.default.moveItem(at: staging, to: folder)
        return folder
    }
}
