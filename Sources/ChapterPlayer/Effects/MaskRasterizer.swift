//
//  MaskRasterizer.swift
//  ChapterPlayer
//
//  MIRROR of MaestroKit/Sources/MaestroKit/MaskRasterizer.swift (FL-09 … FL-13 player
//  parity). ChapterPlayer cannot depend on MaestroKit, so the one effect
//  evaluator is DUPLICATED here verbatim below this header, and
//  MaestroVision's EffectSeamTests render the same stack through both and
//  compare the pixels. Change one, change both.
//
import Foundation
import CoreGraphics
import CoreImage
import ChapterScript

public final class MaskRasterizer: @unchecked Sendable {

    private let lock = NSLock()

    public struct Key: Hashable, Sendable {
        let shape: MaskShape
        let featherBits: UInt32
        let tier: PlayerResolutionTier
    }

    private var cache: [Key: CIImage] = [:]
    private var order: [Key] = []
    private let limit = 32
    /// TEST SEAM: actual rasterizations — a transform-only change must
    /// not advance it.
    public private(set) var rasterizations = 0

    public init() {}

    /// The coverage image (white = inside), at the tier's mask grid.
    /// Feather is normalized to the mask's width.
    public func coverage(shape: MaskShape, feather: Double,
                         tier: PlayerResolutionTier = .full) -> CIImage? {
        guard shape.isDrawable else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let key = Key(shape: shape,
                      featherBits: Float(max(0, feather)).bitPattern,
                      tier: tier)
        if let hit = cache[key] { return hit }

        let edge = Int(512 * tier.factor)
        let size = CGSize(width: edge, height: edge)
        guard let context = CGContext(
            data: nil, width: edge, height: edge,
            bitsPerComponent: 8, bytesPerRow: edge,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        // Authored points and Viewer handles use a top-left origin. Convert
        // once at rasterization to Core Image's bottom-left pixel space.
        context.translateBy(x: 0, y: CGFloat(edge))
        context.scaleBy(x: 1, y: -1)
        context.addPath(shape.path(in: size))
        context.fillPath()
        guard let cgImage = context.makeImage() else { return nil }
        rasterizations += 1

        var image = CIImage(cgImage: cgImage)
        if feather > 0.0005 {
            // A blur of the MATTE. Clamp first so the shape's own edge at
            // the frame boundary feathers symmetrically, then re-crop.
            let radius = feather * Double(edge)
            image = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur",
                                parameters: ["inputRadius": radius])
                .cropped(to: CGRect(x: 0, y: 0, width: edge, height: edge))
        }

        if cache[key] == nil { order.append(key) }
        cache[key] = image
        while order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return image
    }
}
