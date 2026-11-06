import AppKit
import CoreImage
import SwiftUI
import Vision

/// Funny face filters that follow your face, using Vision's on-device face
/// landmarks. Works on camera frames before they're scaled to the output.
enum FunnyFace: String, CaseIterable, Identifiable {
    case off
    // Eyes
    case googlyEyes, bigEyes, laserEyes, heartEyes, starEyes
    // Warps
    case bigHead, tinyFace, alienHead, longFace, wideFace, swirl, wobble
    // Props
    case clownNose, mustache, beard, nerdGlasses, sunglasses, pirate, partyHat, crown, halo, devilHorns, bunnyEars, cat
    // Masks
    case emoji, clownMask, dogMask, frogMask, alienMask, robotMask, skullMask, monkeyMask

    var id: String { rawValue }

    enum Category: String, CaseIterable { case eyes = "Eyes", warps = "Warps", props = "Props", masks = "Masks" }

    var category: Category? {
        switch self {
        case .off: return nil
        case .googlyEyes, .bigEyes, .laserEyes, .heartEyes, .starEyes: return .eyes
        case .bigHead, .tinyFace, .alienHead, .longFace, .wideFace, .swirl, .wobble: return .warps
        case .clownNose, .mustache, .beard, .nerdGlasses, .sunglasses, .pirate, .partyHat, .crown, .halo,
             .devilHorns, .bunnyEars, .cat: return .props
        case .emoji, .clownMask, .dogMask, .frogMask, .alienMask, .robotMask, .skullMask, .monkeyMask: return .masks
        }
    }

    var label: String {
        switch self {
        case .off: return "Off"
        case .googlyEyes: return "Googly Eyes"
        case .bigEyes: return "Big Eyes"
        case .laserEyes: return "Laser Eyes"
        case .heartEyes: return "Heart Eyes"
        case .starEyes: return "Star Eyes"
        case .bigHead: return "Big Head"
        case .tinyFace: return "Tiny Face"
        case .alienHead: return "Alien Head"
        case .longFace: return "Long Face"
        case .wideFace: return "Wide Face"
        case .swirl: return "Swirl"
        case .wobble: return "Wobble"
        case .clownNose: return "Clown Nose"
        case .mustache: return "Mustache"
        case .beard: return "Beard & Mustache"
        case .nerdGlasses: return "Nerd Glasses"
        case .sunglasses: return "Sunglasses"
        case .pirate: return "Pirate Patch"
        case .partyHat: return "Party Hat"
        case .crown: return "Crown"
        case .halo: return "Halo"
        case .devilHorns: return "Devil Horns"
        case .bunnyEars: return "Bunny Ears"
        case .cat: return "Cat"
        case .emoji: return "😎 Cool"
        case .clownMask: return "🤡 Clown"
        case .dogMask: return "🐶 Dog"
        case .frogMask: return "🐸 Frog"
        case .alienMask: return "👽 Alien"
        case .robotMask: return "🤖 Robot"
        case .skullMask: return "💀 Skull"
        case .monkeyMask: return "🐵 Monkey"
        }
    }

    var maskEmoji: String? {
        switch self {
        case .emoji: return "😎"
        case .clownMask: return "🤡"
        case .dogMask: return "🐶"
        case .frogMask: return "🐸"
        case .alienMask: return "👽"
        case .robotMask: return "🤖"
        case .skullMask: return "💀"
        case .monkeyMask: return "🐵"
        default: return nil
        }
    }
}

/// Menu items for a Funny Face picker: Off, then each category as a section.
struct FunnyFaceMenuItems: View {
    var body: some View {
        Text(FunnyFace.off.label).tag(FunnyFace.off)
        ForEach(FunnyFace.Category.allCases, id: \.self) { category in
            Section(category.rawValue) {
                ForEach(FunnyFace.allCases.filter { $0.category == category }) { Text($0.label).tag($0) }
            }
        }
    }
}

/// Draws the chosen filter, called from the render queue. Face detection takes
/// about 26 ms a frame, so it runs on its own queue: each frame is offered to
/// the tracker (skipped while it's busy) and drawing uses the latest face found.
/// The video keeps its full frame rate and tracking stays a frame or two behind.
final class FaceFilterRenderer {
    private let request: VNDetectFaceLandmarksRequest = {
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3
        return r
    }()
    private let handler = VNSequenceRequestHandler()
    private let detectQueue = DispatchQueue(label: "zoomie.faces", qos: .userInitiated)

    /// Face geometry, in image pixels (Core Image coordinates, origin bottom-left).
    private struct Face {
        var leftEye: CGPoint, rightEye: CGPoint
        var eyeSize: CGFloat
        var nose: CGPoint
        var mouth: CGPoint
        var center: CGPoint
        var size: CGFloat
        var roll: CGFloat

        /// Midpoint between the eyes: the origin for props.
        var eyeMid: CGPoint { CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2) }
        /// Distance between the eyes: the unit props are drawn in.
        var eyeDistance: CGFloat { max(hypot(leftEye.x - rightEye.x, leftEye.y - rightEye.y), 1) }
        /// Head tilt, from the line through the eyes (left-to-right on screen).
        var tilt: CGFloat {
            let (a, b) = leftEye.x < rightEye.x ? (leftEye, rightEye) : (rightEye, leftEye)
            return atan2(b.y - a.y, b.x - a.x)
        }
        /// A point on the face given in eye units (x along the eye line, y up the face).
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let d = eyeDistance, t = tilt
            return CGPoint(x: eyeMid.x + (x * cos(t) - y * sin(t)) * d,
                           y: eyeMid.y + (x * sin(t) + y * cos(t)) * d)
        }
    }

    // Shared with the detect queue, under `lock`.
    private let lock = NSLock()
    private var detecting = false
    private var detected: Face?
    private var detectedVersion = 0
    private var missedDetections = 0

    // Render-queue state.
    private var face: Face?
    private var seenVersion = 0

    /// Googly-eye physics: pupil offset and velocity per eye, relative to the eye center.
    private var pupilOffset = [CGVector.zero, .zero]
    private var pupilVelocity = [CGVector.zero, .zero]
    private var lastEyes: [CGPoint]?
    private var lastTime: CFTimeInterval?


    func apply(_ filter: FunnyFace, to image: CIImage, pixelBuffer: CVPixelBuffer, time: CFTimeInterval) -> CIImage {
        guard filter != .off else {
            lastEyes = nil
            return image
        }
        offer(pixelBuffer, imageSize: image.extent.size)
        updateFace()
        guard let face else { return image }

        let extent = image.extent
        let d = face.eyeDistance

        if let prop = FaceProps.image(for: filter) {
            return place(prop, on: face).composited(over: image)
        }
        if let emoji = filter.maskEmoji {
            guard let mask = Self.emojiImage(emoji) else { return image }
            return place(mask, centeredAt: face.point(0, -0.5), width: d * 3.3, face: face).composited(over: image)
        }

        switch filter {
        case .googlyEyes:
            return googlyEyes(on: image, face: face, time: time)
        case .bigEyes:
            var out = image
            for eye in [face.leftEye, face.rightEye] {
                out = out.applyingFilter("CIBumpDistortion", parameters: [
                    kCIInputCenterKey: CIVector(cgPoint: eye),
                    kCIInputRadiusKey: face.eyeSize * 1.9,
                    kCIInputScaleKey: 0.75,
                ])
            }
            return out.cropped(to: extent)
        case .laserEyes:
            var out = image
            for eye in [face.leftEye, face.rightEye] {
                // Wide red glow, then a hot white core, slightly flickering.
                let flicker = 1 + 0.08 * sin(CGFloat(time) * 31 + eye.x)
                out = Self.glow(at: eye, radius: d * 0.9 * flicker, color: CIColor(red: 1, green: 0.05, blue: 0.05, alpha: 0.85)).composited(over: out)
                out = Self.glow(at: eye, radius: d * 0.32 * flicker, color: CIColor(red: 1, green: 0.85, blue: 0.8, alpha: 1)).composited(over: out)
            }
            return out.cropped(to: extent)
        case .heartEyes, .starEyes:
            guard let symbol = Self.emojiImage(filter == .heartEyes ? "❤️" : "⭐️") else { return image }
            let pulse = 1 + 0.08 * sin(CGFloat(time) * 6)
            var out = image
            for eye in [face.leftEye, face.rightEye] {
                out = place(symbol, centeredAt: eye, width: d * 0.85 * pulse, face: face).composited(over: out)
            }
            return out
        case .tinyFace:
            return image.applyingFilter("CIPinchDistortion", parameters: [
                kCIInputCenterKey: CIVector(cgPoint: face.center),
                kCIInputRadiusKey: face.size * 0.85,
                kCIInputScaleKey: 0.7,
            ]).cropped(to: extent)
        case .bigHead:
            // Centered between the eyes and forehead, wide enough to inflate the whole head.
            return image.applyingFilter("CIBumpDistortion", parameters: [
                kCIInputCenterKey: CIVector(cgPoint: face.point(0, 0.25)),
                kCIInputRadiusKey: face.size * 1.3,
                kCIInputScaleKey: 0.65,
            ]).cropped(to: extent)
        case .alienHead:
            // Swollen forehead, shrunken chin.
            return image
                .applyingFilter("CIBumpDistortion", parameters: [
                    kCIInputCenterKey: CIVector(cgPoint: face.point(0, 1.1)),
                    kCIInputRadiusKey: d * 2.1,
                    kCIInputScaleKey: 0.9,
                ])
                .applyingFilter("CIPinchDistortion", parameters: [
                    kCIInputCenterKey: CIVector(cgPoint: face.point(0, -1.4)),
                    kCIInputRadiusKey: d * 1.3,
                    kCIInputScaleKey: 0.6,
                ]).cropped(to: extent)
        case .longFace:
            return stretched(image, face: face, sx: 1, sy: 1.5)
        case .wideFace:
            return stretched(image, face: face, sx: 1.55, sy: 1)
        case .swirl:
            return image.applyingFilter("CITwirlDistortion", parameters: [
                kCIInputCenterKey: CIVector(cgPoint: face.center),
                kCIInputRadiusKey: face.size * 0.75,
                kCIInputAngleKey: 2.6,
            ]).cropped(to: extent)
        case .wobble:
            // The head swells and shrinks a few times a second.
            let amount = 0.55 * sin(time * 5.5)
            return image.applyingFilter(amount >= 0 ? "CIBumpDistortion" : "CIPinchDistortion", parameters: [
                kCIInputCenterKey: CIVector(cgPoint: face.center),
                kCIInputRadiusKey: face.size * 1.05,
                kCIInputScaleKey: abs(amount),
            ]).cropped(to: extent)
        case .clownNose:
            return Self.ball(at: face.nose, radius: face.size * 0.11, color: CIColor(red: 0.9, green: 0.05, blue: 0.08))
                .composited(over: image)
        default:
            return image
        }
    }

    // MARK: Placing artwork on the face

    /// Puts a prop (drawn in eye units by FaceProps) onto the face.
    private func place(_ prop: CIImage, on face: Face) -> CIImage {
        let origin = FaceProps.originInImage
        let scale = face.eyeDistance / FaceProps.pixelsPerUnit
        return prop
            .transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(rotationAngle: face.tilt))
            .transformed(by: CGAffineTransform(translationX: face.eyeMid.x, y: face.eyeMid.y))
    }

    /// Puts an image of the given width centered on a point, tilted with the head.
    private func place(_ art: CIImage, centeredAt point: CGPoint, width: CGFloat, face: Face) -> CIImage {
        let scale = width / art.extent.width
        return art
            .transformed(by: CGAffineTransform(translationX: -art.extent.midX, y: -art.extent.midY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(rotationAngle: face.tilt))
            .transformed(by: CGAffineTransform(translationX: point.x, y: point.y))
    }

    /// Stretches the face area and blends it back in with a soft oval edge.
    private func stretched(_ image: CIImage, face: Face, sx: CGFloat, sy: CGFloat) -> CIImage {
        let c = face.center
        let big = image
            .transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: c.x, y: c.y))
        let r = face.size * 0.75
        let mask = CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(cgPoint: .zero),
            "inputRadius0": r * 0.7,
            "inputRadius1": r,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.black,
        ])!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: c.x, y: c.y))
        return big.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: image.extent)
    }

    // MARK: Tracking

    /// Starts a detection on this frame unless one is already running.
    private func offer(_ pixelBuffer: CVPixelBuffer, imageSize: CGSize) {
        lock.lock()
        guard !detecting else { lock.unlock(); return }
        detecting = true
        lock.unlock()
        detectQueue.async { [self] in
            let found = detect(in: pixelBuffer, imageSize: imageSize)
            lock.lock()
            if let found {
                detected = found
                missedDetections = 0
            } else {
                // Keep the last face briefly so a missed frame doesn't flicker.
                missedDetections += 1
                if missedDetections > 5 { detected = nil }
            }
            detectedVersion += 1
            detecting = false
            lock.unlock()
        }
    }

    /// Picks up the newest detection, lightly smoothed against landmark jitter.
    private func updateFace() {
        lock.lock()
        let version = detectedVersion, latest = detected
        lock.unlock()
        guard version != seenVersion else { return }
        seenVersion = version
        guard let new = latest else {
            face = nil
            lastEyes = nil
            return
        }
        guard let old = face else { face = new; return }
        let a: CGFloat = 0.6
        func mix(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * a, y: p.y + (q.y - p.y) * a) }
        func mix(_ p: CGFloat, _ q: CGFloat) -> CGFloat { p + (q - p) * a }
        face = Face(leftEye: mix(old.leftEye, new.leftEye), rightEye: mix(old.rightEye, new.rightEye),
                    eyeSize: mix(old.eyeSize, new.eyeSize), nose: mix(old.nose, new.nose),
                    mouth: mix(old.mouth, new.mouth), center: mix(old.center, new.center), size: mix(old.size, new.size),
                    roll: mix(old.roll, new.roll))
    }

    /// Runs on the detect queue.
    private func detect(in pixelBuffer: CVPixelBuffer, imageSize: CGSize) -> Face? {
        guard (try? handler.perform([request], on: pixelBuffer)) != nil,
              let observation = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let landmarks = observation.landmarks,
              let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye else { return nil }

        func points(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] { region.pointsInImage(imageSize: imageSize) }
        func centroid(_ pts: [CGPoint]) -> CGPoint {
            CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(max(pts.count, 1)),
                    y: pts.map(\.y).reduce(0, +) / CGFloat(max(pts.count, 1)))
        }
        func width(_ pts: [CGPoint]) -> CGFloat {
            let xs = pts.map(\.x)
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        let left = points(leftEye), right = points(rightEye)
        let eyeWidth = max(width(left), width(right))
        // The nose tip is the lowest part of the nose outline.
        var nose = centroid(landmarks.nose.map(points) ?? [])
        if let crest = landmarks.noseCrest.map(points), let tip = crest.min(by: { $0.y < $1.y }) {
            nose = CGPoint(x: (nose.x + tip.x) / 2, y: tip.y)
        }
        let box = observation.boundingBox
        let rect = CGRect(x: box.minX * imageSize.width, y: box.minY * imageSize.height,
                          width: box.width * imageSize.width, height: box.height * imageSize.height)
        let mouth = landmarks.outerLips.map { centroid(points($0)) }
            ?? CGPoint(x: nose.x, y: nose.y - rect.height * 0.15)
        return Face(leftEye: centroid(left), rightEye: centroid(right),
                    eyeSize: max(eyeWidth, rect.width * 0.12),
                    nose: nose, mouth: mouth, center: CGPoint(x: rect.midX, y: rect.midY),
                    size: max(rect.width, rect.height),
                    roll: CGFloat(observation.roll?.doubleValue ?? 0))
    }

    // MARK: Googly eyes

    private func googlyEyes(on image: CIImage, face: Face, time: CFTimeInterval) -> CIImage {
        let eyes = [face.leftEye, face.rightEye]
        let eyeRadius = face.eyeSize * 0.95
        let pupilRadius = eyeRadius * 0.48
        let travel = eyeRadius - pupilRadius - eyeRadius * 0.06

        let dt = CGFloat(min(max(time - (lastTime ?? time), 1.0 / 120), 1.0 / 15))
        lastTime = time
        for i in 0..<2 {
            // Pupils lag behind head movement (inertia)...
            if let last = lastEyes {
                let moved = CGVector(dx: eyes[i].x - last[i].x, dy: eyes[i].y - last[i].y)
                pupilOffset[i].dx -= moved.dx * 0.9
                pupilOffset[i].dy -= moved.dy * 0.9
            }
            // ...then fall back down under gravity with a bouncy, damped spring.
            let gravity = CGVector(dx: 0, dy: -travel * 9)
            let spring: CGFloat = 4, damping: CGFloat = 2.2
            pupilVelocity[i].dx += (gravity.dx - spring * pupilOffset[i].dx - damping * pupilVelocity[i].dx) * dt * 6
            pupilVelocity[i].dy += (gravity.dy - spring * pupilOffset[i].dy - damping * pupilVelocity[i].dy) * dt * 6
            pupilOffset[i].dx += pupilVelocity[i].dx * dt * 6
            pupilOffset[i].dy += pupilVelocity[i].dy * dt * 6
            // Keep the pupil inside the eye, bouncing off the rim.
            let length = hypot(pupilOffset[i].dx, pupilOffset[i].dy)
            if length > travel {
                let k = travel / length
                pupilOffset[i].dx *= k
                pupilOffset[i].dy *= k
                pupilVelocity[i].dx *= -0.35
                pupilVelocity[i].dy *= -0.35
            }
        }
        lastEyes = eyes

        var out = image
        for i in 0..<2 {
            let eye = eyes[i]
            let rim = Self.ball(at: eye, radius: eyeRadius * 1.08, color: CIColor(red: 0.08, green: 0.08, blue: 0.08), shaded: false)
            let white = Self.ball(at: eye, radius: eyeRadius, color: CIColor(red: 1, green: 1, blue: 1))
            let pupilCenter = CGPoint(x: eye.x + pupilOffset[i].dx, y: eye.y + pupilOffset[i].dy)
            let pupil = Self.ball(at: pupilCenter, radius: pupilRadius, color: CIColor(red: 0.02, green: 0.02, blue: 0.02))
            out = pupil.composited(over: white.composited(over: rim.composited(over: out)))
        }
        return out
    }

    // MARK: Drawing helpers

    /// A filled circle with a soft edge, optionally with a little highlight so it looks round.
    static func ball(at center: CGPoint, radius: CGFloat, color: CIColor, shaded: Bool = true) -> CIImage {
        let clear = CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0)
        let disc = CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(cgPoint: center),
            "inputRadius0": max(radius - 1.5, 0),
            "inputRadius1": radius,
            "inputColor0": color,
            "inputColor1": clear,
        ])!.outputImage!.cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        guard shaded else { return disc }
        let highlightCenter = CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 0.35)
        let highlight = CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(cgPoint: highlightCenter),
            "inputRadius0": 0,
            "inputRadius1": radius * 0.45,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.45),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])!.outputImage!.cropped(to: disc.extent)
        return highlight.composited(over: disc)
    }

    private static var emojiCache: [String: CIImage] = [:]
    private static let emojiLock = NSLock()

    static func emojiImage(_ emoji: String) -> CIImage? {
        emojiLock.lock(); defer { emojiLock.unlock() }
        if let cached = emojiCache[emoji] { return cached }
        let image = renderEmoji(emoji)
        emojiCache[emoji] = image
        return image
    }

    /// A soft glowing dot (laser eyes).
    static func glow(at center: CGPoint, radius: CGFloat, color: CIColor) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(cgPoint: center),
            "inputRadius0": radius * 0.15,
            "inputRadius1": radius,
            "inputColor0": color,
            "inputColor1": CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0),
        ])!.outputImage!.cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// Color emoji, drawn once with Core Text into a bitmap.
    static func renderEmoji(_ emoji: String, size: CGFloat = 512) -> CIImage? {
        let attributed = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: size * 0.8)])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.textPosition = CGPoint(x: (size - bounds.width) / 2 - bounds.minX, y: (size - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, ctx)
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}
