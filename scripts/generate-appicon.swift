#!/usr/bin/env swift
//  generate-appicon.swift
//
//  Renders a self-contained ClaudeSync app icon set (16~512 + @2x) into
//  ClaudeSync/Resources/Assets.xcassets/AppIcon.appiconset/.
//
//  This is a *placeholder* design (gradient cloud + sync arrows) so the bundle
//  has a real icon for v1.0 RC builds. Replace with hand-designed assets when
//  branding is ready.

import Foundation
import AppKit

let outputDir = "ClaudeSync/Resources/Assets.xcassets/AppIcon.appiconset"

struct IconSpec {
    let pointSize: Int
    let scale: Int
    var pixelSize: Int { pointSize * scale }
    var fileName: String { "icon_\(pointSize)x\(pointSize)\(scale == 2 ? "@2x" : "").png" }
}

let specs: [IconSpec] = [
    IconSpec(pointSize: 16,  scale: 1),
    IconSpec(pointSize: 16,  scale: 2),
    IconSpec(pointSize: 32,  scale: 1),
    IconSpec(pointSize: 32,  scale: 2),
    IconSpec(pointSize: 128, scale: 1),
    IconSpec(pointSize: 128, scale: 2),
    IconSpec(pointSize: 256, scale: 1),
    IconSpec(pointSize: 256, scale: 2),
    IconSpec(pointSize: 512, scale: 1),
    IconSpec(pointSize: 512, scale: 2),
]

func renderIcon(pixelSize px: Int) -> Data {
    let size = CGFloat(px)
    let bitsPerComponent = 8
    let bytesPerRow = px * 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let ctx = CGContext(data: nil, width: px, height: px,
                              bitsPerComponent: bitsPerComponent,
                              bytesPerRow: bytesPerRow,
                              space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
        FileHandle.standardError.write(Data("ctx init failed\n".utf8))
        exit(1)
    }

    // 1) Rounded-rect background gradient (Apple-style "squircle" via continuous corners).
    let inset = size * 0.08
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let cornerRadius = rect.width * 0.225
    let path = CGPath(roundedRect: rect,
                      cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                      transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Vertical gradient indigo → blue.
    let topColor = CGColor(red: 0.27, green: 0.31, blue: 0.85, alpha: 1.0)
    let bottomColor = CGColor(red: 0.16, green: 0.55, blue: 0.92, alpha: 1.0)
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [topColor, bottomColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: rect.maxY),
                           end:   CGPoint(x: 0, y: rect.minY),
                           options: [])
    ctx.restoreGState()

    // 2) Two arrowed circles (sync glyph) centered.
    let cx = size / 2
    let cy = size / 2
    let glyphRadius = size * 0.28
    ctx.setLineWidth(size * 0.045)
    ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 1.0))
    ctx.setLineCap(.round)

    // Upper arc (left → right, clockwise to suggest motion).
    ctx.addArc(center: CGPoint(x: cx, y: cy),
               radius: glyphRadius,
               startAngle: .pi * 0.85,
               endAngle: .pi * 1.85,
               clockwise: false)
    ctx.strokePath()
    // Arrowhead at the end of the upper arc.
    let up_end_x = cx + glyphRadius * cos(.pi * 1.85)
    let up_end_y = cy + glyphRadius * sin(.pi * 1.85)
    drawArrowhead(ctx: ctx, at: CGPoint(x: up_end_x, y: up_end_y),
                  angle: .pi * 1.85 + .pi / 2, size: size * 0.07)

    // Lower arc (right → left).
    ctx.addArc(center: CGPoint(x: cx, y: cy),
               radius: glyphRadius,
               startAngle: .pi * -0.15,
               endAngle: .pi * 0.85,
               clockwise: false)
    ctx.strokePath()
    let lo_end_x = cx + glyphRadius * cos(.pi * 0.85)
    let lo_end_y = cy + glyphRadius * sin(.pi * 0.85)
    drawArrowhead(ctx: ctx, at: CGPoint(x: lo_end_x, y: lo_end_y),
                  angle: .pi * 0.85 + .pi / 2, size: size * 0.07)

    guard let cgImage = ctx.makeImage() else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:]) ?? Data()
}

func drawArrowhead(ctx: CGContext, at point: CGPoint, angle: CGFloat, size: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: point.x, y: point.y)
    ctx.rotate(by: angle)
    ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 0, y: 0))
    ctx.addLine(to: CGPoint(x: -size, y: -size * 0.6))
    ctx.addLine(to: CGPoint(x: -size, y:  size * 0.6))
    ctx.closePath()
    ctx.fillPath()
    ctx.restoreGState()
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for spec in specs {
    let data = renderIcon(pixelSize: spec.pixelSize)
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(spec.fileName)
    try data.write(to: url)
    print("wrote \(url.path) (\(data.count) bytes)")
}

// Update Contents.json to reference the rendered files.
let contents: [String: Any] = [
    "info": ["author": "claudesync", "version": 1],
    "images": specs.map { spec -> [String: Any] in
        [
            "idiom": "mac",
            "scale": "\(spec.scale)x",
            "size": "\(spec.pointSize)x\(spec.pointSize)",
            "filename": spec.fileName
        ]
    }
]
let json = try JSONSerialization.data(withJSONObject: contents,
                                      options: [.prettyPrinted, .sortedKeys])
let contentsURL = URL(fileURLWithPath: outputDir).appendingPathComponent("Contents.json")
try json.write(to: contentsURL)
print("wrote \(contentsURL.path)")

print("✅ icon set generated")
