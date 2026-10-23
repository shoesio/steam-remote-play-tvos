import AppKit

struct LayerSpec {
    let width: Int
    let height: Int
    let path: String
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brandRoot = root.appendingPathComponent("CloudNow/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
let sourceURL = root.appendingPathComponent("CloudNow/Assets.xcassets/StreamIconSource.imageset/stream-icon-source.png")

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func bitmap(from image: NSImage) -> NSBitmapImageRep {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff)
    else {
        fatalError("Could not decode source image")
    }
    return bitmap
}

func image(width: Int, height: Int, draw: () -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "IconGenerator", code: 1)
    }
    try png.write(to: url)
}

func transparentImage(width: Int, height: Int) -> NSImage {
    image(width: width, height: height) {
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
    }
}

func sourceImage() -> NSImage {
    guard let image = NSImage(contentsOf: sourceURL) else {
        fatalError("Missing Stream icon source at \(sourceURL.path)")
    }
    return image
}

func drawSourceIcon(width: Int, height: Int) -> NSImage {
    let source = sourceImage()
    let sourceSize = source.size
    let targetAspect = CGFloat(width) / CGFloat(height)
    let sourceAspect = sourceSize.width / sourceSize.height
    let crop: NSRect

    if sourceAspect > targetAspect {
        let cropWidth = sourceSize.height * targetAspect
        crop = NSRect(
            x: (sourceSize.width - cropWidth) / 2,
            y: 0,
            width: cropWidth,
            height: sourceSize.height
        )
    } else {
        let cropHeight = sourceSize.width / targetAspect
        crop = NSRect(
            x: 0,
            y: (sourceSize.height - cropHeight) / 2,
            width: sourceSize.width,
            height: cropHeight
        )
    }

    return image(width: width, height: height) {
        source.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: crop,
            operation: .sourceOver,
            fraction: 1
        )
    }
}

func extractWaveLogo() -> NSImage {
    let source = sourceImage()
    let sourceBitmap = bitmap(from: source)
    let width = sourceBitmap.pixelsWide
    let height = sourceBitmap.pixelsHigh
    let out = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    var minX = width
    var minY = height
    var maxX = 0
    var maxY = 0

    for y in 0..<height {
        for x in 0..<width {
            guard let pixel = sourceBitmap.colorAt(x: x, y: y) else { continue }
            let r = pixel.redComponent
            let g = pixel.greenComponent
            let b = pixel.blueComponent
            let brightness = max(r, max(g, b))
            let saturation = brightness - min(r, min(g, b))
            let alpha = min(1, max(0, min((brightness - 0.30) / 0.22, (saturation - 0.10) / 0.18)))

            if alpha > 0.04 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }

            out.setColor(NSColor(calibratedRed: r, green: g, blue: b, alpha: alpha), atX: x, y: y)
        }
    }

    let padding = 18
    let crop = NSRect(
        x: max(0, minX - padding),
        y: max(0, minY - padding),
        width: min(width - max(0, minX - padding), maxX - minX + padding * 2),
        height: min(height - max(0, minY - padding), maxY - minY + padding * 2)
    )

    guard let cgImage = out.cgImage?.cropping(to: crop) else {
        fatalError("Could not crop Stream logo")
    }

    return NSImage(cgImage: cgImage, size: NSSize(width: crop.width, height: crop.height))
}

let backSpecs = [
    LayerSpec(width: 400, height: 240, path: "App Icon.imagestack/Back.imagestacklayer/Content.imageset/bg_400x240.png"),
    LayerSpec(width: 800, height: 480, path: "App Icon.imagestack/Back.imagestacklayer/Content.imageset/bg_800x480.png"),
    LayerSpec(width: 1280, height: 768, path: "App Icon - App Store.imagestack/Back.imagestacklayer/Content.imageset/bg_1280x768.png")
]
let middleSpecs = [
    LayerSpec(width: 400, height: 240, path: "App Icon.imagestack/Middle.imagestacklayer/Content.imageset/middle_400x240.png"),
    LayerSpec(width: 800, height: 480, path: "App Icon.imagestack/Middle.imagestacklayer/Content.imageset/middle_800x480.png"),
    LayerSpec(width: 1280, height: 768, path: "App Icon - App Store.imagestack/Middle.imagestacklayer/Content.imageset/middle_1280x768.png")
]
let frontSpecs = [
    LayerSpec(width: 400, height: 240, path: "App Icon.imagestack/Front.imagestacklayer/Content.imageset/icon_400x240.png"),
    LayerSpec(width: 800, height: 480, path: "App Icon.imagestack/Front.imagestacklayer/Content.imageset/icon_800x480.png"),
    LayerSpec(width: 1280, height: 768, path: "App Icon - App Store.imagestack/Front.imagestacklayer/Content.imageset/icon_1280x768.png")
]

for spec in backSpecs {
    try writePNG(drawSourceIcon(width: spec.width, height: spec.height), to: brandRoot.appendingPathComponent(spec.path))
}

for spec in middleSpecs {
    try writePNG(transparentImage(width: spec.width, height: spec.height), to: brandRoot.appendingPathComponent(spec.path))
}

for spec in frontSpecs {
    try writePNG(transparentImage(width: spec.width, height: spec.height), to: brandRoot.appendingPathComponent(spec.path))
}

let logo = extractWaveLogo()
try writePNG(logo, to: root.appendingPathComponent("CloudNow/Assets.xcassets/StreamLogo.imageset/stream-logo.png"))
try writePNG(logo, to: root.appendingPathComponent("CloudNow/Assets.xcassets/Icon.icon/Assets/stream-logo.png"))
