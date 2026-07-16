import AppKit
import CoreGraphics

// Regenerates the KRIT app icon as a machined graphite monolith with two
// opposing coral crop brackets and a quiet cobalt edge light. Every size is
// rendered independently so the mark remains deliberate at 16 px.
//
//   swiftc Branding/make-icon.swift -o /tmp/krit-make-icon
//   /tmp/krit-make-icon Branding
//
// Produces Branding/KRIT.iconset, Branding/KRIT-preview.png, and
// Branding/KRIT.icns.

enum IconBuildError: Error, CustomStringConvertible {
    case contextCreation(Int)
    case gradientCreation
    case imageCreation(Int)
    case pngEncoding(String)
    case invalidArtifact(String)
    case invalidPermissions(path: String, expected: Int, actual: Int)
    case iconutilLaunch(Error)
    case iconutilFailure(Int32)

    var description: String {
        switch self {
        case let .contextCreation(size):
            return "could not create a \(size)x\(size) bitmap context"
        case .gradientCreation:
            return "could not create a color gradient"
        case let .imageCreation(size):
            return "could not create a \(size)x\(size) image"
        case let .pngEncoding(path):
            return "could not encode PNG at \(path)"
        case let .invalidArtifact(reason):
            return "invalid build artifact: \(reason)"
        case let .invalidPermissions(path, expected, actual):
            return "invalid permissions at \(path): expected \(String(expected, radix: 8)), got \(String(actual, radix: 8))"
        case let .iconutilLaunch(error):
            return "could not launch iconutil: \(error.localizedDescription)"
        case let .iconutilFailure(status):
            return "iconutil exited with status \(status)"
        }
    }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let graphiteTop = CGColor(srgbRed: 0.165, green: 0.176, blue: 0.192, alpha: 1)
let graphiteMid = CGColor(srgbRed: 0.090, green: 0.098, blue: 0.112, alpha: 1)
let graphiteBase = CGColor(srgbRed: 0.038, green: 0.043, blue: 0.052, alpha: 1)
let coralFace = CGColor(srgbRed: 1.0, green: 0.33, blue: 0.145, alpha: 1)
let coralLight = CGColor(srgbRed: 1.0, green: 0.61, blue: 0.37, alpha: 1)
let coralDeep = CGColor(srgbRed: 0.55, green: 0.105, blue: 0.035, alpha: 1)
let cobalt = CGColor(srgbRed: 0.11, green: 0.47, blue: 0.92, alpha: 1)
let iconSpecifications: [(pixels: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

func squircle(_ rect: CGRect) -> CGPath {
    let radius = rect.width * 0.2237
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func topRimPath(_ rect: CGRect) -> CGPath {
    let radius = rect.width * 0.2237
    let control = radius * 0.55228475
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
    path.addCurve(
        to: CGPoint(x: rect.minX + radius, y: rect.maxY),
        control1: CGPoint(x: rect.minX, y: rect.maxY - radius + control),
        control2: CGPoint(x: rect.minX + radius - control, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
    path.addCurve(
        to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
        control1: CGPoint(x: rect.maxX - radius + control, y: rect.maxY),
        control2: CGPoint(x: rect.maxX, y: rect.maxY - radius + control)
    )
    return path
}

func rightEdgePath(_ rect: CGRect) -> CGPath {
    let radius = rect.width * 0.2237
    let control = radius * 0.55228475
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
    path.addCurve(
        to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
        control1: CGPoint(x: rect.maxX - radius + control, y: rect.maxY),
        control2: CGPoint(x: rect.maxX, y: rect.maxY - radius + control)
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
    path.addCurve(
        to: CGPoint(x: rect.maxX - radius, y: rect.minY),
        control1: CGPoint(x: rect.maxX, y: rect.minY + radius - control),
        control2: CGPoint(x: rect.maxX - radius + control, y: rect.minY)
    )
    return path
}

func linearGradient(
    _ context: CGContext,
    colors: [CGColor],
    locations: [CGFloat],
    from start: CGPoint,
    to end: CGPoint
) throws {
    guard let gradient = CGGradient(
        colorsSpace: sRGB,
        colors: colors as CFArray,
        locations: locations
    ) else {
        throw IconBuildError.gradientCreation
    }
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
}

func bracketPaths(frame: CGRect, arm: CGFloat) -> [CGPath] {
    let topLeft = CGMutablePath()
    topLeft.move(to: CGPoint(x: frame.minX + arm, y: frame.maxY))
    topLeft.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
    topLeft.addLine(to: CGPoint(x: frame.minX, y: frame.maxY - arm))

    let bottomRight = CGMutablePath()
    bottomRight.move(to: CGPoint(x: frame.maxX - arm, y: frame.minY))
    bottomRight.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
    bottomRight.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + arm))

    return [topLeft, bottomRight]
}

func stroke(
    _ paths: [CGPath],
    in context: CGContext,
    color: CGColor,
    width: CGFloat,
    shadow: (blur: CGFloat, color: CGColor)? = nil
) {
    context.saveGState()
    if let shadow {
        context.setShadow(offset: .zero, blur: shadow.blur, color: shadow.color)
    }
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for path in paths {
        context.addPath(path)
        context.strokePath()
    }
    context.restoreGState()
}

func drawBracketFaces(
    _ paths: [CGPath],
    in context: CGContext,
    width: CGFloat,
    bounds: CGRect,
    compact: Bool
) throws {
    for path in paths {
        context.saveGState()
        context.addPath(path)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()

        if compact {
            context.setFillColor(coralFace)
            context.fill(bounds)
        } else {
            try linearGradient(
                context,
                colors: [coralLight, coralFace, coralDeep],
                locations: [0, 0.46, 1],
                from: CGPoint(x: bounds.midX, y: bounds.maxY),
                to: CGPoint(x: bounds.midX, y: bounds.minY)
            )
        }
        context.restoreGState()
    }
}

func drawIcon(size: Int) throws -> CGImage {
    let side = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconBuildError.contextCreation(size)
    }

    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)

    let compact = size <= 32
    let margin = compact ? max(1, floor(side * 0.075)) : side * 0.085
    let tile = CGRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin)
    let tilePath = squircle(tile)

    // A narrow, hard shadow gives the tile weight without a diffuse halo.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -max(1, side * 0.012)),
        blur: compact ? 1 : side * 0.018,
        color: CGColor(gray: 0, alpha: 0.62)
    )
    context.addPath(tilePath)
    context.setFillColor(CGColor(gray: 0.018, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    try linearGradient(
        context,
        colors: [graphiteTop, graphiteMid, graphiteBase],
        locations: [0, 0.50, 1],
        from: CGPoint(x: tile.midX, y: tile.maxY),
        to: CGPoint(x: tile.midX, y: tile.minY)
    )

    if !compact {
        // Deterministic brushed-metal grain. At small sizes the lines disappear
        // entirely instead of aliasing into visual noise.
        context.setLineWidth(max(0.5, side * 0.00065))
        for index in 1..<20 {
            let y = tile.minY + tile.height * CGFloat(index) / 20
            let alpha: CGFloat = index.isMultiple(of: 3) ? 0.018 : 0.010
            context.setStrokeColor(CGColor(gray: 1, alpha: alpha))
            context.move(to: CGPoint(x: tile.minX + tile.width * 0.08, y: y))
            context.addLine(to: CGPoint(x: tile.maxX - tile.width * 0.08, y: y))
            context.strokePath()
        }
    }
    context.restoreGState()

    // The cobalt counter-light lives only on the right edge and stays secondary.
    context.saveGState()
    let edgeTile = tile.insetBy(dx: max(0.5, side * 0.004), dy: max(0.5, side * 0.004))
    context.addPath(rightEdgePath(edgeTile))
    context.setStrokeColor(cobalt.copy(alpha: compact ? 0.38 : 0.50)!)
    context.setLineWidth(compact ? 1 : max(1, side * 0.0065))
    context.strokePath()
    context.restoreGState()

    // A precise top rim separates the face from the machined outer wall.
    context.saveGState()
    context.addPath(topRimPath(edgeTile))
    context.setStrokeColor(CGColor(gray: 1, alpha: compact ? 0.22 : 0.28))
    context.setLineWidth(compact ? 1 : max(1, side * 0.0045))
    context.strokePath()
    context.restoreGState()

    let frameInset = compact ? tile.width * 0.25 : tile.width * 0.255
    let frame = tile.insetBy(dx: frameInset, dy: frameInset)
    let arm = compact ? tile.width * 0.24 : tile.width * 0.238
    let faceWidth = compact ? max(2, floor(tile.width * 0.105)) : tile.width * 0.073
    let paths = bracketPaths(frame: frame, arm: arm)

    // The dark and copper strokes form a recessed machined channel around the
    // illuminated face. The compact rendering keeps only one-pixel borders.
    stroke(
        paths,
        in: context,
        color: CGColor(gray: 0.012, alpha: 0.95),
        width: faceWidth + (compact ? 2 : side * 0.020),
        shadow: compact ? nil : (side * 0.010, CGColor(gray: 0, alpha: 0.70))
    )
    stroke(
        paths,
        in: context,
        color: coralDeep,
        width: faceWidth + (compact ? 1 : side * 0.009)
    )
    try drawBracketFaces(paths, in: context, width: faceWidth, bounds: tile, compact: compact)

    if !compact {
        // A thin hard highlight replaces a broad neon bloom.
        stroke(
            paths,
            in: context,
            color: coralLight.copy(alpha: 0.62)!,
            width: max(0.75, side * 0.0018)
        )
    }

    guard let image = context.makeImage() else {
        throw IconBuildError.imageCreation(size)
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw IconBuildError.pngEncoding(url.path)
    }
    try data.write(to: url, options: .atomic)
}

func setPermissions(_ mode: Int, at url: URL, fileManager: FileManager) throws {
    try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

func validatePermissions(_ mode: Int, at url: URL, fileManager: FileManager) throws {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let number = attributes[.posixPermissions] as? NSNumber else {
        throw IconBuildError.invalidArtifact("missing permissions for \(url.path)")
    }
    let actual = number.intValue & 0o777
    guard actual == mode else {
        throw IconBuildError.invalidPermissions(path: url.path, expected: mode, actual: actual)
    }
}

func permissions(at url: URL, fileManager: FileManager) throws -> Int {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let number = attributes[.posixPermissions] as? NSNumber else {
        throw IconBuildError.invalidArtifact("missing permissions for \(url.path)")
    }
    return number.intValue & 0o777
}

func validatePNG(at url: URL, pixels: Int) throws {
    let data = try Data(contentsOf: url)
    guard
        let representation = NSBitmapImageRep(data: data),
        representation.pixelsWide == pixels,
        representation.pixelsHigh == pixels
    else {
        throw IconBuildError.invalidArtifact("\(url.lastPathComponent) is not \(pixels)x\(pixels)")
    }
}

func validateBuildArtifacts(at directory: URL, fileManager: FileManager) throws {
    let iconset = directory.appendingPathComponent("KRIT.iconset", isDirectory: true)
    let preview = directory.appendingPathComponent("KRIT-preview.png")
    let icns = directory.appendingPathComponent("KRIT.icns")

    let rootNames = try Set(
        fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
    )
    guard rootNames == ["KRIT.iconset", "KRIT-preview.png", "KRIT.icns"] else {
        throw IconBuildError.invalidArtifact("staging directory contains unexpected files")
    }

    let actualNames = try Set(
        fileManager.contentsOfDirectory(at: iconset, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
    )
    let expectedNames = Set(iconSpecifications.map(\.name))
    guard actualNames == expectedNames else {
        throw IconBuildError.invalidArtifact("iconset does not contain the expected ten PNG files")
    }

    for specification in iconSpecifications {
        try validatePNG(
            at: iconset.appendingPathComponent(specification.name),
            pixels: specification.pixels
        )
    }
    try validatePNG(at: preview, pixels: 512)

    let icnsAttributes = try fileManager.attributesOfItem(atPath: icns.path)
    guard
        let type = icnsAttributes[.type] as? FileAttributeType,
        type == .typeRegular,
        let size = icnsAttributes[.size] as? NSNumber,
        size.intValue > 0
    else {
        throw IconBuildError.invalidArtifact("KRIT.icns is missing or empty")
    }
}

@discardableResult
func normalizeBuildPermissions(at directory: URL, fileManager: FileManager) throws -> Bool {
    let iconset = directory.appendingPathComponent("KRIT.iconset", isDirectory: true)
    let preview = directory.appendingPathComponent("KRIT-preview.png")
    let icns = directory.appendingPathComponent("KRIT.icns")

    try setPermissions(0o755, at: directory, fileManager: fileManager)
    try setPermissions(0o755, at: iconset, fileManager: fileManager)
    for specification in iconSpecifications {
        try setPermissions(
            0o644,
            at: iconset.appendingPathComponent(specification.name),
            fileManager: fileManager
        )
    }
    try setPermissions(0o644, at: preview, fileManager: fileManager)
    try setPermissions(0o644, at: icns, fileManager: fileManager)

    let directoryMode = try permissions(at: directory, fileManager: fileManager)
    let fileMode = try permissions(at: icns, fileManager: fileManager)
    if directoryMode == fileMode {
        // ExFAT volumes mounted with noowners expose one volume-wide mode and
        // cannot store independent POSIX permissions. Git still records the
        // generated ICNS as a non-executable 100644 file.
        return false
    }

    try validatePermissions(0o755, at: directory, fileManager: fileManager)
    try validatePermissions(0o755, at: iconset, fileManager: fileManager)
    for specification in iconSpecifications {
        try validatePermissions(
            0o644,
            at: iconset.appendingPathComponent(specification.name),
            fileManager: fileManager
        )
    }
    try validatePermissions(0o644, at: preview, fileManager: fileManager)
    try validatePermissions(0o644, at: icns, fileManager: fileManager)
    return true
}

func promote(_ staged: URL, to destination: URL, fileManager: FileManager) throws {
    if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(
            destination,
            withItemAt: staged,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
    } else {
        try fileManager.moveItem(at: staged, to: destination)
    }
}

func buildIcon(at outputDirectory: URL) throws {
    let fileManager = FileManager.default
    let destination = outputDirectory.standardizedFileURL
    let parent = destination.deletingLastPathComponent()
    let destinationExisted = fileManager.fileExists(atPath: destination.path)
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    if !destinationExisted {
        try setPermissions(0o755, at: destination, fileManager: fileManager)
    }

    let staging = parent.appendingPathComponent(
        ".KRIT-icon-staging-\(UUID().uuidString)",
        isDirectory: true
    )
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: staging) }

    let stagedIconset = staging.appendingPathComponent("KRIT.iconset", isDirectory: true)
    let stagedPreview = staging.appendingPathComponent("KRIT-preview.png")
    let stagedICNS = staging.appendingPathComponent("KRIT.icns")
    try fileManager.createDirectory(at: stagedIconset, withIntermediateDirectories: false)

    for specification in iconSpecifications {
        let image = try drawIcon(size: specification.pixels)
        try writePNG(image, to: stagedIconset.appendingPathComponent(specification.name))
    }
    try writePNG(try drawIcon(size: 512), to: stagedPreview)

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", stagedIconset.path, "-o", stagedICNS.path]
    do {
        try iconutil.run()
    } catch {
        throw IconBuildError.iconutilLaunch(error)
    }
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw IconBuildError.iconutilFailure(iconutil.terminationStatus)
    }

    try validateBuildArtifacts(at: staging, fileManager: fileManager)
    let normalizedPermissions = try normalizeBuildPermissions(at: staging, fileManager: fileManager)
    if !normalizedPermissions {
        fputs(
            "make-icon: warning: destination filesystem does not preserve independent POSIX permissions\n",
            stderr
        )
    }

    let finalIconset = destination.appendingPathComponent("KRIT.iconset", isDirectory: true)
    let finalPreview = destination.appendingPathComponent("KRIT-preview.png")
    let finalICNS = destination.appendingPathComponent("KRIT.icns")

    try promote(stagedIconset, to: finalIconset, fileManager: fileManager)
    try promote(stagedPreview, to: finalPreview, fileManager: fileManager)
    try promote(stagedICNS, to: finalICNS, fileManager: fileManager)

    print("iconset written to \(finalIconset.path)")
    print("preview written to \(finalPreview.path)")
    print("icns written to \(finalICNS.path)")
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
do {
    try buildIcon(at: URL(fileURLWithPath: outputPath, isDirectory: true))
} catch {
    fputs("make-icon: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
