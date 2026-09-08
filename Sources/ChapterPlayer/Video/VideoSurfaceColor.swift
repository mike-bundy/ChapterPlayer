import CoreImage
import CoreVideo
import Metal

/// The final color boundary of an owned RealityKit video texture. Effect
/// stacks keep their encoded source domain; only their completed raster is
/// converted to the renderer's linear Display P3 domain. A plain UNorm
/// texture carries neither a transfer function nor source primaries.
@MainActor
public final class VideoSurfaceColor {
    public static let linearSpace = CGColorSpace(name: CGColorSpace.linearDisplayP3)!
    private let context: CIContext

    public init(device: MTLDevice) {
        context = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .workingColorSpace: Self.linearSpace,
            .outputColorSpace: Self.linearSpace,
            // RealityKit samples straight-alpha material textures. Keep the
            // effects scratch premultiplied and convert only at this boundary.
            .outputPremultiplied: false
        ])
    }

    public static func sourceSpace(for buffer: CVPixelBuffer) -> CGColorSpace {
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
        if transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String,
           primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String {
            // Display-referred SDR uses the BT.1886 display EOTF. Inverting
            // the camera's 709 OETF here lifts shadows relative to native
            // video presentation, even when the primaries are correct.
            return rec709DisplaySpace
        }
        let decodedSpace = CIImage(cvPixelBuffer: buffer).colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String,
           primaries == kCVImageBufferColorPrimaries_SMPTE_C as String {
            // VideoToolbox supplies SMPTE-C/601 metadata for untagged SD
            // footage. Retain those primaries while using the same display
            // EOTF as native SDR video; the Composite NTSC profile's camera
            // transfer otherwise lifts the owned surface.
            if smpteCDisplaySpace == nil {
                smpteCDisplaySpace = displaySpace(preservingPrimariesOf: decodedSpace)
            }
            return smpteCDisplaySpace ?? decodedSpace
        }
        return decodedSpace
    }

    private static var smpteCDisplaySpace: CGColorSpace?

    private static func displaySpace(preservingPrimariesOf source: CGColorSpace) -> CGColorSpace? {
        guard let xyz = CGColorSpace(name: CGColorSpace.genericXYZ) else { return nil }
        func components(_ rgb: [CGFloat]) -> [CGFloat]? {
            CGColor(colorSpace: source, components: rgb + [1])?
                .converted(to: xyz, intent: .relativeColorimetric, options: nil)?
                .components.map { Array($0.prefix(3)) }
        }
        guard let white = components([1, 1, 1]),
              let red = components([1, 0, 0]),
              let green = components([0, 1, 0]),
              let blue = components([0, 0, 1]) else { return nil }
        return CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: nil,
                            gamma: [2.4, 2.4, 2.4], matrix: red + green + blue)
    }

    private static let rec709DisplaySpace: CGColorSpace = {
        let white: [CGFloat] = [0.95047, 1, 1.08883]
        let gamma: [CGFloat] = [2.4, 2.4, 2.4]
        let matrix: [CGFloat] = [0.4124564, 0.2126729, 0.0193339,
                                 0.3575761, 0.7151522, 0.1191920,
                                 0.1804375, 0.0721750, 0.9503041]
        return CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: nil,
                            gamma: gamma, matrix: matrix)!
    }()

    public func render(encoded: MTLTexture, sourceSpace: CGColorSpace,
                       to destination: MTLTexture, in commandBuffer: MTLCommandBuffer) {
        guard let image = CIImage(mtlTexture: encoded, options: [.colorSpace: sourceSpace])
        else { return }
        context.render(image, to: destination, commandBuffer: commandBuffer,
                       bounds: CGRect(x: 0, y: 0, width: destination.width,
                                      height: destination.height),
                       colorSpace: Self.linearSpace)
    }
}
