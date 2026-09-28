#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO

// Original Funston mark: a single doorway framing the two leaves of an open
// book. This is intentionally distinct from Internet Archive's columned logo.
// Run from the repository root: swift Scripts/GenerateAppIcon.swift
let side = 1024
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Funston/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
guard let bitmap = CGContext(data: nil, width: side, height: side,
    bitsPerComponent: 8, bytesPerRow: side * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not create the icon drawing surface")
}
let context = NSGraphicsContext(cgContext: bitmap, flipped: false)

let ink = NSColor(srgbRed: 29 / 255, green: 47 / 255, blue: 49 / 255, alpha: 1)
let paper = NSColor(srgbRed: 244 / 255, green: 237 / 255, blue: 222 / 255, alpha: 1)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.shouldAntialias = true
ink.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()

// A generous silhouette survives small home-screen and Spotlight sizes.
let doorway = NSBezierPath()
doorway.move(to: NSPoint(x: 224, y: 216))
doorway.line(to: NSPoint(x: 224, y: 544))
doorway.curve(to: NSPoint(x: 512, y: 832), controlPoint1: NSPoint(x: 224, y: 703), controlPoint2: NSPoint(x: 353, y: 832))
doorway.curve(to: NSPoint(x: 800, y: 544), controlPoint1: NSPoint(x: 671, y: 832), controlPoint2: NSPoint(x: 800, y: 703))
doorway.line(to: NSPoint(x: 800, y: 216))
doorway.line(to: NSPoint(x: 704, y: 216))
doorway.line(to: NSPoint(x: 704, y: 544))
doorway.curve(to: NSPoint(x: 512, y: 736), controlPoint1: NSPoint(x: 704, y: 650), controlPoint2: NSPoint(x: 618, y: 736))
doorway.curve(to: NSPoint(x: 320, y: 544), controlPoint1: NSPoint(x: 406, y: 736), controlPoint2: NSPoint(x: 320, y: 650))
doorway.line(to: NSPoint(x: 320, y: 216))
doorway.close()
paper.setFill()
doorway.fill()

func leaf(_ points: [NSPoint]) {
    let path = NSBezierPath()
    path.move(to: points[0])
    points.dropFirst().forEach { path.line(to: $0) }
    path.close()
    path.fill()
}
leaf([NSPoint(x: 364, y: 512), NSPoint(x: 496, y: 464), NSPoint(x: 496, y: 264), NSPoint(x: 364, y: 312)])
leaf([NSPoint(x: 528, y: 464), NSPoint(x: 660, y: 512), NSPoint(x: 660, y: 312), NSPoint(x: 528, y: 264)])
NSGraphicsContext.restoreGraphicsState()

guard let image = bitmap.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Could not encode the app icon")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not save the app icon") }
print(output.path)
