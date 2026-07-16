#!/usr/bin/env swift
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let pixelWidth = 1200
private let pixelHeight = 800
private let scale: CGFloat = 2
private let outputDPI = 144

private enum BackgroundError: LocalizedError {
    case missingMaster(URL)
    case unreadableMaster(URL)
    case invalidMasterSize(width: Int, height: Int)
    case contextCreationFailed
    case imageCreationFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingMaster(let url):
            return "Missing DMG background master: \(url.path)"
        case .unreadableMaster(let url):
            return "Could not read DMG background master: \(url.path)"
        case .invalidMasterSize(let width, let height):
            return "DMG background master must be 1200x800 pixels, got \(width)x\(height)"
        case .contextCreationFailed:
            return "Could not create the sRGB bitmap context"
        case .imageCreationFailed:
            return "Could not create the rendered DMG background image"
        case .encodingFailed:
            return "Could not encode the rendered DMG background as PNG"
        }
    }
}

private func scriptDirectory() -> URL {
    let workingDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
    return URL(
        fileURLWithPath: CommandLine.arguments[0],
        relativeTo: workingDirectory
    )
    .standardizedFileURL
    .deletingLastPathComponent()
}

private func loadMaster(at url: URL) throws -> CGImage {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw BackgroundError.missingMaster(url)
    }
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw BackgroundError.unreadableMaster(url)
    }
    guard image.width == pixelWidth, image.height == pixelHeight else {
        throw BackgroundError.invalidMasterSize(width: image.width, height: image.height)
    }
    return image
}

private func makeContext() throws -> CGContext {
    guard
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        throw BackgroundError.contextCreationFailed
    }
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    return context
}

private func drawInstallGuide(in context: CGContext) {
    let logicalWidth: CGFloat = 600
    let logicalHeight: CGFloat = 400
    let iconCenterY: CGFloat = 175
    let guideY = (logicalHeight - iconCenterY) * scale
    let centerX = logicalWidth * scale / 2

    let systemFont = NSFont.systemFont(ofSize: 11 * scale, weight: .semibold)
    let font = CTFontCreateWithName(systemFont.fontName as CFString, 11 * scale, nil)
    let textColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
        NSAttributedString.Key(kCTKernAttributeName as String): 1.5 * scale,
    ]
    let attributedText = NSAttributedString(string: "INSTALL KRIT", attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributedText)
    let textBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    let textOrigin = CGPoint(
        x: centerX - textBounds.midX,
        y: guideY - textBounds.midY
    )

    let padding = 12 * scale
    let leftLineStart = 200 * scale
    let leftLineEnd = textOrigin.x + textBounds.minX - padding
    let rightLineStart = textOrigin.x + textBounds.maxX + padding
    let rightLineEnd = 400 * scale

    context.saveGState()
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.42))
    context.setLineWidth(1 * scale)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    context.move(to: CGPoint(x: leftLineStart, y: guideY))
    context.addLine(to: CGPoint(x: leftLineEnd, y: guideY))
    context.move(to: CGPoint(x: rightLineStart, y: guideY))
    context.addLine(to: CGPoint(x: rightLineEnd, y: guideY))

    let arrowHead = 6 * scale
    context.move(to: CGPoint(x: rightLineEnd, y: guideY))
    context.addLine(to: CGPoint(x: rightLineEnd - arrowHead, y: guideY + arrowHead * 0.8))
    context.move(to: CGPoint(x: rightLineEnd, y: guideY))
    context.addLine(to: CGPoint(x: rightLineEnd - arrowHead, y: guideY - arrowHead * 0.8))
    context.strokePath()

    context.textMatrix = .identity
    context.textPosition = textOrigin
    CTLineDraw(line, context)
    context.restoreGState()
}

private func pngData(for image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw BackgroundError.encodingFailed
    }
    let properties: [CFString: Any] = [
        kCGImagePropertyDPIWidth: outputDPI,
        kCGImagePropertyDPIHeight: outputDPI,
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw BackgroundError.encodingFailed
    }
    return data as Data
}

do {
    let directory = scriptDirectory()
    let masterURL = directory.appendingPathComponent("Branding/dmg-precision-monolith.png")
    let outputURL = directory.appendingPathComponent("dmg-background.png")
    let master = try loadMaster(at: masterURL)
    let context = try makeContext()

    context.draw(
        master,
        in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
    )
    drawInstallGuide(in: context)

    guard let renderedImage = context.makeImage() else {
        throw BackgroundError.imageCreationFailed
    }
    let data = try pngData(for: renderedImage)
    try data.write(to: outputURL, options: .atomic)
    print("Created \(outputURL.path) (1200x800, sRGB, 144 DPI)")
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
