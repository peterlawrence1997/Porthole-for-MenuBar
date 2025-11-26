import Cocoa

// Configuration
let size = 1024
let symbolScale: CGFloat = 0.6
let backgroundColor = NSColor(white: 0.95, alpha: 1.0)  // Ultra light grey
let symbolColor = NSColor.black

// Create Image
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Draw Background (Rounded Squircle)
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(
    roundedRect: rect, xRadius: CGFloat(size) * 0.22, yRadius: CGFloat(size) * 0.22)
backgroundColor.setFill()
path.fill()

// Draw Symbol
let symbolConfig = NSImage.SymbolConfiguration(
    pointSize: CGFloat(size) * symbolScale, weight: .regular)
if let symbol = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfig)
{
    symbol.isTemplate = true
    symbolColor.set()

    let symbolRect = NSRect(
        x: (CGFloat(size) - symbol.size.width) / 2,
        y: (CGFloat(size) - symbol.size.height) / 2,
        width: symbol.size.width,
        height: symbol.size.height
    )

    symbol.draw(in: symbolRect)
}

image.unlockFocus()

// Save to PNG
if let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
{
    let url = URL(fileURLWithPath: "AppIcon.png")
    try? pngData.write(to: url)
    print("Icon generated at \(url.path)")
}
