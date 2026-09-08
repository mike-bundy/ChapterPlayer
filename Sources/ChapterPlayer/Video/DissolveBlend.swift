import Foundation
import CoreImage

/// Cross Dissolve in the encoded effect domain. Progress zero is the outgoing
/// shot; one is the incoming shot. All premultiplied color and alpha channels
/// are linearly interpolated, including when masks make either side transparent.
/// Mirrored in ChapterPlayer; the runtime pixel seam pins both implementations.
public enum DissolveBlend {
    public static func mix(incoming: CIImage, outgoing: CIImage,
                           progress: Double, extent: CGRect) -> CIImage {
        incoming.cropped(to: extent).applyingFilter("CIMix", parameters: [
            "inputBackgroundImage": outgoing.cropped(to: extent),
            "inputAmount": min(max(progress, 0), 1)
        ])
    }
}
