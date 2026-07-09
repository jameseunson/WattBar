// Masks the source icon art into a transparent rounded-square (squircle)
// so the baked-in white canvas doesn't ship as part of the app icon.
// Usage: swift mask.swift <input.png> <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let source = CGImageSourceCreateWithURL(
          URL(fileURLWithPath: arguments[1]) as CFURL, nil
      ),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    print("usage: swift mask.swift <input.png> <output.png>")
    exit(1)
}

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let scan = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
scan.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

// Find the tile's bounding box: columns/rows containing any pixel that
// isn't near-white. The soft drop shadow reads as content too, so the
// square is anchored to the top edge and sized by content width.
let pixels = scan.data!.bindMemory(to: UInt8.self, capacity: size * size * 4)
func isContent(_ x: Int, _ y: Int) -> Bool {
    let offset = (y * size + x) * 4
    return pixels[offset] < 240 || pixels[offset + 1] < 240 || pixels[offset + 2] < 240
}

var minX = size, maxX = 0, minY = size, maxY = 0
for y in 0..<size {
    for x in 0..<size where isContent(x, y) {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else { exit(1) }

// CG rows are bottom-up; content maxY is the visual top of the tile.
let visualTop = size - 1 - maxY
let width = maxX - minX + 1
let side = CGFloat(width)
let originX = CGFloat(minX)
let originY = CGFloat(size - visualTop) - side
let tile = CGRect(x: originX, y: originY, width: side, height: side)
FileHandle.standardError.write(
    "tile: x=\(Int(originX)) visualTop=\(visualTop) side=\(width)\n".data(using: .utf8)!
)

guard let output = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

// ~22.4% corner radius matches Apple's icon squircle proportions.
let path = CGPath(
    roundedRect: tile,
    cornerWidth: side * 0.224,
    cornerHeight: side * 0.224,
    transform: nil
)
output.addPath(path)
output.clip()
output.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

guard let result = output.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: arguments[2]) as CFURL,
          UTType.png.identifier as CFString, 1, nil
      )
else { exit(1) }
CGImageDestinationAddImage(destination, result, nil)
CGImageDestinationFinalize(destination)
