import AppKit
import CoreImage

/// Original cartoon props (hats, glasses, ears…) drawn with Core Graphics.
///
/// Every prop is drawn once into a transparent bitmap, in "eye units": the
/// origin is midway between the eyes, x runs along the eye line, y points up
/// the face, and 1 unit is the distance between the eyes. At draw time the
/// bitmap is scaled, rotated and moved onto the face, so props follow the head.
enum FaceProps {
    /// Area each prop can draw in, in eye units.
    static let minX: CGFloat = -2.2, maxX: CGFloat = 2.2
    static let minY: CGFloat = -2.6, maxY: CGFloat = 3.6
    /// Bitmap pixels per eye unit.
    static let pixelsPerUnit: CGFloat = 160

    private static var cache: [FunnyFace: CIImage] = [:]
    private static let lock = NSLock()

    static func image(for filter: FunnyFace) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[filter] { return cached }
        let onTopOfHead: Set<FunnyFace> = [.partyHat, .crown, .halo, .devilHorns, .bunnyEars]
        guard let drawing = drawing(for: filter),
              let image = render(drawing, headOffset: onTopOfHead.contains(filter) ? -0.35 : 0) else { return nil }
        cache[filter] = image
        return image
    }

    /// Where a prop's eye-unit origin sits inside its bitmap.
    static var originInImage: CGPoint { CGPoint(x: -minX * pixelsPerUnit, y: -minY * pixelsPerUnit) }

    /// Hats and ears are drawn from y ≈ 1.2 up, but the top of a real head is
    /// closer to the eyes than that, so they're shifted down to sit on the head.
    private static var headOffset: CGFloat = 0

    private static func render(_ draw: (CGContext) -> Void, headOffset offset: CGFloat = 0) -> CIImage? {
        headOffset = offset
        defer { headOffset = 0 }
        let width = Int((maxX - minX) * pixelsPerUnit), height = Int((maxY - minY) * pixelsPerUnit)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: originInImage.x, y: originInImage.y)
        ctx.scaleBy(x: pixelsPerUnit, y: pixelsPerUnit)
        ctx.translateBy(x: 0, y: headOffset)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        draw(ctx)
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func drawing(for filter: FunnyFace) -> ((CGContext) -> Void)? {
        switch filter {
        case .mustache:
            return { ctx in mustache(ctx, y: -0.92, width: 1.0) }

        case .beard:
            return { ctx in
                let p = CGMutablePath()
                p.move(to: CGPoint(x: -1.08, y: -0.25))
                p.addQuadCurve(to: CGPoint(x: 0, y: -2.25), control: CGPoint(x: -1.1, y: -2.1))
                p.addQuadCurve(to: CGPoint(x: 1.08, y: -0.25), control: CGPoint(x: 1.1, y: -2.1))
                p.addLine(to: CGPoint(x: 0.82, y: -0.3))
                // Leave the mouth uncovered.
                p.addQuadCurve(to: CGPoint(x: 0.45, y: -1.25), control: CGPoint(x: 0.8, y: -1.15))
                p.addQuadCurve(to: CGPoint(x: -0.45, y: -1.25), control: CGPoint(x: 0, y: -1.45))
                p.addQuadCurve(to: CGPoint(x: -0.82, y: -0.3), control: CGPoint(x: -0.8, y: -1.15))
                p.closeSubpath()
                ctx.addPath(p)
                ctx.setFillColor(color(0.33, 0.2, 0.11, 0.96))
                ctx.fillPath()
                mustache(ctx, y: -0.9, width: 1.05)
            }

        case .nerdGlasses:
            return { ctx in
                ctx.setStrokeColor(color(0.06, 0.06, 0.06))
                ctx.setLineWidth(0.1)
                for s in [-1.0, 1.0] as [CGFloat] {
                    ctx.setFillColor(color(0.85, 0.92, 1, 0.18))
                    ctx.fillEllipse(in: CGRect(x: s * 0.52 - 0.37, y: -0.36, width: 0.74, height: 0.72))
                    ctx.strokeEllipse(in: CGRect(x: s * 0.52 - 0.37, y: -0.36, width: 0.74, height: 0.72))
                    ctx.move(to: CGPoint(x: s * 0.89, y: 0.08))
                    ctx.addLine(to: CGPoint(x: s * 1.12, y: 0.16))
                    ctx.strokePath()
                }
                ctx.move(to: CGPoint(x: -0.15, y: 0.06))
                ctx.addQuadCurve(to: CGPoint(x: 0.15, y: 0.06), control: CGPoint(x: 0, y: 0.2))
                ctx.strokePath()
            }

        case .sunglasses:
            return { ctx in
                for s in [-1.0, 1.0] as [CGFloat] {
                    let lens = CGPath(roundedRect: CGRect(x: s * 0.53 - 0.44, y: -0.3, width: 0.88, height: 0.56),
                                      cornerWidth: 0.2, cornerHeight: 0.2, transform: nil)
                    ctx.addPath(lens)
                    ctx.setFillColor(color(0.04, 0.04, 0.07, 0.96))
                    ctx.fillPath()
                    // Shine
                    ctx.setStrokeColor(color(1, 1, 1, 0.35))
                    ctx.setLineWidth(0.05)
                    ctx.move(to: CGPoint(x: s * 0.53 - 0.25, y: 0.12))
                    ctx.addLine(to: CGPoint(x: s * 0.53 - 0.08, y: 0.18))
                    ctx.strokePath()
                }
                ctx.setStrokeColor(color(0.04, 0.04, 0.07))
                ctx.setLineWidth(0.09)
                ctx.move(to: CGPoint(x: -0.1, y: 0.12))
                ctx.addLine(to: CGPoint(x: 0.1, y: 0.12))
                ctx.move(to: CGPoint(x: -0.97, y: 0.15)); ctx.addLine(to: CGPoint(x: -1.15, y: 0.18))
                ctx.move(to: CGPoint(x: 0.97, y: 0.15)); ctx.addLine(to: CGPoint(x: 1.15, y: 0.18))
                ctx.strokePath()
            }

        case .pirate:
            return { ctx in
                ctx.setStrokeColor(color(0.05, 0.05, 0.05))
                ctx.setLineWidth(0.07)
                ctx.move(to: CGPoint(x: 0.2, y: 0.3)); ctx.addLine(to: CGPoint(x: -1.2, y: 1.05))
                ctx.move(to: CGPoint(x: 0.85, y: 0.15)); ctx.addLine(to: CGPoint(x: 1.2, y: 0.05))
                ctx.strokePath()
                ctx.setFillColor(color(0.05, 0.05, 0.05))
                ctx.fillEllipse(in: CGRect(x: 0.52 - 0.42, y: -0.36, width: 0.84, height: 0.7))
            }

        case .partyHat:
            return { ctx in
                let cone = CGMutablePath()
                cone.move(to: CGPoint(x: -0.75, y: 1.2))
                cone.addLine(to: CGPoint(x: 0.75, y: 1.2))
                cone.addLine(to: CGPoint(x: 0.1, y: 3.2))
                cone.closeSubpath()
                ctx.saveGState()
                ctx.addPath(cone)
                ctx.clip()
                let stripes: [CGColor] = [color(0.95, 0.2, 0.55), color(0.2, 0.7, 0.95), color(1, 0.82, 0.15)]
                for i in 0..<14 {
                    ctx.setFillColor(stripes[i % stripes.count])
                    let y0 = 1.0 + CGFloat(i) * 0.18
                    let band = CGMutablePath()
                    band.move(to: CGPoint(x: -1.2, y: y0))
                    band.addLine(to: CGPoint(x: 1.2, y: y0 + 0.35))
                    band.addLine(to: CGPoint(x: 1.2, y: y0 + 0.53))
                    band.addLine(to: CGPoint(x: -1.2, y: y0 + 0.18))
                    band.closeSubpath()
                    ctx.addPath(band)
                    ctx.fillPath()
                }
                ctx.restoreGState()
                ctx.setFillColor(color(1, 1, 1))
                ctx.fillEllipse(in: CGRect(x: -0.85, y: 1.08, width: 1.7, height: 0.26))
                ctx.setFillColor(color(1, 0.85, 0.2))
                ctx.fillEllipse(in: CGRect(x: 0.1 - 0.2, y: 3.2 - 0.2, width: 0.4, height: 0.4))
            }

        case .crown:
            return { ctx in
                let p = CGMutablePath()
                p.move(to: CGPoint(x: -0.95, y: 1.2))
                p.addLine(to: CGPoint(x: -1.0, y: 2.15))
                p.addLine(to: CGPoint(x: -0.55, y: 1.7))
                p.addLine(to: CGPoint(x: 0, y: 2.35))
                p.addLine(to: CGPoint(x: 0.55, y: 1.7))
                p.addLine(to: CGPoint(x: 1.0, y: 2.15))
                p.addLine(to: CGPoint(x: 0.95, y: 1.2))
                p.closeSubpath()
                ctx.addPath(p)
                ctx.setFillColor(color(1, 0.78, 0.12))
                ctx.fillPath()
                ctx.addPath(p)
                ctx.setStrokeColor(color(0.7, 0.45, 0.02))
                ctx.setLineWidth(0.05)
                ctx.strokePath()
                ctx.setFillColor(color(0.9, 0.12, 0.2))
                for x in [-0.5, 0, 0.5] as [CGFloat] {
                    ctx.fillEllipse(in: CGRect(x: x - 0.1, y: 1.38, width: 0.2, height: 0.2))
                }
                ctx.setFillColor(color(1, 0.95, 0.6))
                for (x, y) in [(-1.0, 2.15), (0.0, 2.35), (1.0, 2.15)] as [(CGFloat, CGFloat)] {
                    ctx.fillEllipse(in: CGRect(x: x - 0.09, y: y - 0.09, width: 0.18, height: 0.18))
                }
            }

        case .halo:
            return { ctx in
                let ring = CGRect(x: -0.8, y: 2.05, width: 1.6, height: 0.42)
                ctx.setStrokeColor(color(1, 0.95, 0.5, 0.35))
                ctx.setLineWidth(0.28)
                ctx.strokeEllipse(in: ring)
                ctx.setStrokeColor(color(1, 0.85, 0.2))
                ctx.setLineWidth(0.12)
                ctx.strokeEllipse(in: ring)
            }

        case .devilHorns:
            return { ctx in
                for s in [-1.0, 1.0] as [CGFloat] {
                    let p = CGMutablePath()
                    p.move(to: CGPoint(x: s * 0.35, y: 1.2))
                    p.addQuadCurve(to: CGPoint(x: s * 1.05, y: 2.35), control: CGPoint(x: s * 0.45, y: 2.0))
                    p.addQuadCurve(to: CGPoint(x: s * 0.85, y: 1.15), control: CGPoint(x: s * 1.05, y: 1.6))
                    p.closeSubpath()
                    ctx.addPath(p)
                    ctx.setFillColor(color(0.85, 0.08, 0.08))
                    ctx.fillPath()
                    ctx.addPath(p)
                    ctx.setStrokeColor(color(0.45, 0.02, 0.02))
                    ctx.setLineWidth(0.05)
                    ctx.strokePath()
                }
            }

        case .bunnyEars:
            return { ctx in
                for s in [-1.0, 1.0] as [CGFloat] {
                    ctx.saveGState()
                    ctx.translateBy(x: s * 0.55, y: 2.35)
                    ctx.rotate(by: -s * 0.18)
                    ctx.setFillColor(color(0.98, 0.98, 0.98))
                    ctx.fillEllipse(in: CGRect(x: -0.3, y: -1.05, width: 0.6, height: 2.1))
                    ctx.setStrokeColor(color(0.75, 0.75, 0.78))
                    ctx.setLineWidth(0.04)
                    ctx.strokeEllipse(in: CGRect(x: -0.3, y: -1.05, width: 0.6, height: 2.1))
                    ctx.setFillColor(color(1, 0.7, 0.78))
                    ctx.fillEllipse(in: CGRect(x: -0.15, y: -0.8, width: 0.3, height: 1.6))
                    ctx.restoreGState()
                }
            }

        case .cat:
            return { ctx in
                for s in [-1.0, 1.0] as [CGFloat] {
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: -0.35)
                    let ear = CGMutablePath()
                    ear.move(to: CGPoint(x: s * 0.25, y: 1.35))
                    ear.addLine(to: CGPoint(x: s * 1.05, y: 2.35))
                    ear.addLine(to: CGPoint(x: s * 1.1, y: 1.15))
                    ear.closeSubpath()
                    ctx.addPath(ear)
                    ctx.setFillColor(color(0.2, 0.2, 0.22))
                    ctx.fillPath()
                    let inner = CGMutablePath()
                    inner.move(to: CGPoint(x: s * 0.5, y: 1.42))
                    inner.addLine(to: CGPoint(x: s * 0.98, y: 2.05))
                    inner.addLine(to: CGPoint(x: s * 1.0, y: 1.35))
                    inner.closeSubpath()
                    ctx.addPath(inner)
                    ctx.setFillColor(color(1, 0.6, 0.72))
                    ctx.fillPath()
                    ctx.restoreGState()
                    // Whiskers
                    ctx.setStrokeColor(color(0.1, 0.1, 0.1))
                    ctx.setLineWidth(0.035)
                    for (dy, ey) in [(-0.62, -0.5), (-0.7, -0.74), (-0.78, -0.98)] as [(CGFloat, CGFloat)] {
                        ctx.move(to: CGPoint(x: s * 0.35, y: dy))
                        ctx.addLine(to: CGPoint(x: s * 1.35, y: ey))
                    }
                    ctx.strokePath()
                }
                let nose = CGMutablePath()
                nose.move(to: CGPoint(x: -0.14, y: -0.52))
                nose.addLine(to: CGPoint(x: 0.14, y: -0.52))
                nose.addLine(to: CGPoint(x: 0, y: -0.7))
                nose.closeSubpath()
                ctx.addPath(nose)
                ctx.setFillColor(color(1, 0.45, 0.6))
                ctx.fillPath()
            }

        default:
            return nil
        }
    }

    private static func mustache(_ ctx: CGContext, y: CGFloat, width w: CGFloat) {
        let p = CGMutablePath()
        for s in [-1.0, 1.0] as [CGFloat] {
            p.move(to: CGPoint(x: 0, y: y + 0.08))
            p.addQuadCurve(to: CGPoint(x: s * 0.62 * w, y: y - 0.08), control: CGPoint(x: s * 0.3 * w, y: y + 0.22))
            p.addQuadCurve(to: CGPoint(x: s * 0.82 * w, y: y + 0.18), control: CGPoint(x: s * 0.92 * w, y: y - 0.12))
            p.addQuadCurve(to: CGPoint(x: s * 0.6 * w, y: y - 0.22), control: CGPoint(x: s * 0.95 * w, y: y - 0.32))
            p.addQuadCurve(to: CGPoint(x: 0, y: y - 0.1), control: CGPoint(x: s * 0.3 * w, y: y - 0.3))
            p.closeSubpath()
        }
        ctx.addPath(p)
        ctx.setFillColor(color(0.18, 0.1, 0.06))
        ctx.fillPath()
    }
}
