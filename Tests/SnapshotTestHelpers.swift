import AppKit
import SwiftUI
import Testing

@MainActor
enum SnapshotTestHelpers {
    private static let recordKey = "ZSPEAK_RECORD_SNAPSHOTS"

    static func assertSnapshot<V: View>(
        named name: String,
        of view: V,
        size: CGSize,
        filePath: String = #filePath
    ) throws {
        let image = try render(view: view, size: size)
        let baselineURL = snapshotURL(named: name, filePath: filePath)

        if ProcessInfo.processInfo.environment[recordKey] == "1" {
            try FileManager.default.createDirectory(
                at: baselineURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData(for: image).write(to: baselineURL, options: .atomic)
            return
        }

        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            Issue.record("Snapshot baseline ausente: \(baselineURL.path). Rode com \(recordKey)=1 para gravar.")
            return
        }

        guard let baselineImage = NSImage(contentsOf: baselineURL) else {
            Issue.record("Não foi possível ler snapshot baseline: \(baselineURL.path)")
            return
        }

        let diffRatio = try differenceRatio(lhs: baselineImage, rhs: image)
        #expect(diffRatio <= 0.005, "Snapshot \(name) divergiu: diff=\(diffRatio)")
    }

    private static func snapshotURL(named name: String, filePath: String) -> URL {
        let fileURL = URL(fileURLWithPath: filePath)
        let directory = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent, isDirectory: true)
        return directory.appendingPathComponent("\(name).png")
    }

    private static func render<V: View>(view: V, size: CGSize) throws -> NSImage {
        _ = NSApplication.shared

        let rootView = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try makeBitmap(for: hostingView)
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func makeBitmap(for view: NSView) throws -> NSBitmapImageRep {
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            return rep
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(view.bounds.width), 1),
            pixelsHigh: max(Int(view.bounds.height), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw SnapshotError.bitmapCreationFailed
        }

        return rep
    }

    private static func pngData(for image: NSImage) throws -> Data {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            throw SnapshotError.encodingFailed
        }

        return png
    }

    private static func differenceRatio(lhs: NSImage, rhs: NSImage) throws -> Double {
        guard
            let lhsRep = NSBitmapImageRep(data: try pngData(for: lhs)),
            let rhsRep = NSBitmapImageRep(data: try pngData(for: rhs))
        else {
            throw SnapshotError.bitmapCreationFailed
        }

        guard lhsRep.pixelsWide == rhsRep.pixelsWide, lhsRep.pixelsHigh == rhsRep.pixelsHigh else {
            return 1
        }

        guard let lhsData = lhsRep.bitmapData, let rhsData = rhsRep.bitmapData else {
            throw SnapshotError.bitmapCreationFailed
        }

        let totalPixels = lhsRep.pixelsWide * lhsRep.pixelsHigh
        let bytesPerPixel = max(lhsRep.bitsPerPixel / 8, 4)
        let bytesCount = totalPixels * bytesPerPixel
        var differentPixels = 0

        for offset in stride(from: 0, to: bytesCount, by: bytesPerPixel) {
            let delta =
                abs(Int(lhsData[offset]) - Int(rhsData[offset])) +
                abs(Int(lhsData[offset + 1]) - Int(rhsData[offset + 1])) +
                abs(Int(lhsData[offset + 2]) - Int(rhsData[offset + 2])) +
                abs(Int(lhsData[offset + 3]) - Int(rhsData[offset + 3]))

            if delta > 8 {
                differentPixels += 1
            }
        }

        return Double(differentPixels) / Double(totalPixels)
    }

    enum SnapshotError: Error {
        case bitmapCreationFailed
        case encodingFailed
    }
}
