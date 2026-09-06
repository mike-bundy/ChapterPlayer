//
//  MaskAndKeyEffects.swift
//  ChapterPlayer
//
//  MIRROR of MaestroKit/Sources/MaestroKit/MaskAndKeyEffects.swift (FL-09 … FL-13 player
//  parity). ChapterPlayer cannot depend on MaestroKit, so the one effect
//  evaluator is DUPLICATED here verbatim below this header, and
//  MaestroVision's EffectSeamTests render the same stack through both and
//  compare the pixels. Change one, change both.
//

import Foundation
import CoreImage
import ChapterScript

public enum MaskEffect {

    public static let effectId = "maestro.effect.mask"
    static let rasterizer = MaskRasterizer()

    public static let schema = EffectSchema(
        effectId: effectId,
        displayName: "Mask",
        family: "Mask",
        operatesOnColorValues: false,
        projectionClass: .projectionAware,
        parameters: [
            EffectParameterSchema(key: "shape", label: "Shape", kind: .shape,
                                  defaultValue: MaskShape.defaultRectangle.effectValue),
            EffectParameterSchema(key: "feather", label: "Feather", kind: .normalized,
                                  defaultValue: .number(0)),
            EffectParameterSchema(key: "falloff", label: "Falloff", kind: .normalized,
                                  defaultValue: .number(0.5)),
            EffectParameterSchema(key: "opacity", label: "Opacity", kind: .normalized,
                                  defaultValue: .number(1)),
            EffectParameterSchema(key: "invert", label: "Invert", kind: .boolean,
                                  defaultValue: .bool(false)),
            EffectParameterSchema(key: "offsetX", label: "Offset X", kind: .scalar,
                                  defaultValue: .number(0), range: -1...1, gang: "offset"),
            EffectParameterSchema(key: "offsetY", label: "Offset Y", kind: .scalar,
                                  defaultValue: .number(0), range: -1...1, gang: "offset"),
            EffectParameterSchema(key: "rotation", label: "Rotation", kind: .angle,
                                  defaultValue: .number(0), range: -180...180),
            EffectParameterSchema(key: "scale", label: "Scale", kind: .scalar,
                                  defaultValue: .number(1), range: 0.1...4),
            // FL-11's declared second input kind. ABSENT means the shape,
            // which is every mask authored before this field — so a mask
            // with no matte clip behaves exactly as it always did.
            EffectParameterSchema(key: "matteClip", label: "Matte from Clip",
                                  kind: .occurrenceReference,
                                  defaultValue: .string("")),
            EffectParameterSchema(key: "matteChannel", label: "Matte Channel",
                                  kind: .choice, defaultValue: .string("alpha"),
                                  choices: [("alpha", "Alpha"), ("luma", "Luminance")]),
        ])

    /// THE MATTE FROM ANOTHER CLIP (FL-11), when one is named.
    ///
    /// Returns the coverage image, or nil when there is no matte clip —
    /// in which case the shape is the input, exactly as before. A NAMED
    /// clip the host cannot resolve returns nil TOO, so the stage bypasses
    /// and the picture is untouched: a mask that silently became opaque
    /// black because a clip was trimmed away would look like lost footage.
    static func matteCoverage(parameters: [String: EffectValue],
                              environment: EffectRenderEnvironment,
                              extent: CGRect) -> CIImage? {
        guard let id = parameters["matteClip"]?.stringValue, !id.isEmpty,
              let source = environment.matteImage?(id) else { return nil }
        let fitted = source.cropped(to: source.extent)
        // The matte clip's own raster need not match this one's, so it is
        // FITTED rather than assumed — an unfitted matte would slide as
        // soon as the two clips differed in size.
        let sourceExtent = fitted.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0,
              extent.width > 0, extent.height > 0 else { return nil }
        let scaled = fitted
            .transformed(by: CGAffineTransform(scaleX: extent.width / sourceExtent.width,
                                               y: extent.height / sourceExtent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX - sourceExtent.minX,
                                               y: extent.minY - sourceExtent.minY))
            .cropped(to: extent)

        let channel = parameters["matteChannel"]?.stringValue ?? "alpha"
        if channel == "luma" {
            // LUMINANCE as coverage: bright is opaque. Rec. 709 weights,
            // the same ones every other luminance reading here uses.
            return scaled.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.2126, z: 0.2126, w: 0),
                "inputGVector": CIVector(x: 0.7152, y: 0.7152, z: 0.7152, w: 0),
                "inputBVector": CIVector(x: 0.0722, y: 0.0722, z: 0.0722, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        // ALPHA as coverage: the matte clip's own transparency, moved into
        // the color channels so the blend below reads it the same way it
        // reads a rasterized shape.
        return scaled.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Invert and opacity, shared by both input kinds — they are
    /// properties of the MASK, not of where its coverage came from.
    static func applyInvertAndOpacity(_ coverage: CIImage,
                                      parameters: [String: EffectValue]) -> CIImage {
        var result = coverage
        if parameters["invert"]?.boolValue == true {
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ])
        }
        let opacity = min(max(parameters["opacity"]?.numberValue ?? 1, 0), 1)
        if opacity < 0.9999 {
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0),
            ])
        }
        return result
    }

    public static let renderer: EffectRenderer = { image, parameters, environment in
        // A NAMED MATTE CLIP REPLACES THE SHAPE as the mask's input — the
        // two are alternatives, which is what "a selectable input kind"
        // means. Everything downstream (invert, opacity, the matte view,
        // the blend) is shared, because those are properties of the MASK
        // rather than of where its coverage came from.
        if let id = parameters["matteClip"]?.stringValue, !id.isEmpty {
            guard var coverage = matteCoverage(parameters: parameters,
                                               environment: environment,
                                               extent: image.extent)
            else { return image }
            coverage = applyInvertAndOpacity(coverage, parameters: parameters)
            if environment.showMatte { return coverage }
            return image.applyingFilter("CIBlendWithMask", parameters: [
                "inputBackgroundImage": CIImage.empty(),
                "inputMaskImage": coverage,
            ])
        }
        guard let shape = MaskShape(effectValue: parameters["shape"]),
              shape.isDrawable else { return image }
        let feather = parameters["feather"]?.numberValue ?? 0
        let falloff = parameters["falloff"]?.numberValue ?? 0.5
        guard var coverage = rasterizer.coverage(
            shape: shape, feather: feather * (0.5 + falloff),
            tier: environment.tier) else { return image }

        // Fit the coverage grid onto the image, then the WHOLE-SHAPE
        // transform — a re-SAMPLE of the cached raster, never a re-raster.
        let extent = image.extent
        let coverageExtent = coverage.extent
        guard coverageExtent.width > 0, extent.width > 0 else { return image }
        var transform = CGAffineTransform(
            scaleX: extent.width / coverageExtent.width,
            y: extent.height / coverageExtent.height)
        let offsetX = parameters["offsetX"]?.numberValue ?? 0
        let offsetY = parameters["offsetY"]?.numberValue ?? 0
        let rotation = (parameters["rotation"]?.numberValue ?? 0) * .pi / 180
        let scale = max(parameters["scale"]?.numberValue ?? 1, 0.01)
        let center = CGPoint(x: extent.midX, y: extent.midY)
        var placement = CGAffineTransform.identity
        placement = placement.translatedBy(
            x: center.x + offsetX * extent.width,
            y: center.y - offsetY * extent.height)
        placement = placement.rotated(by: -rotation)
        placement = placement.scaledBy(x: scale, y: scale)
        placement = placement.translatedBy(x: -center.x, y: -center.y)
        coverage = coverage
            .transformed(by: transform)
            .transformed(by: placement)
            .composited(over: CIImage(color: .black).cropped(to: extent))
            .cropped(to: extent)

        coverage = applyInvertAndOpacity(coverage, parameters: parameters)

        if environment.showMatte { return coverage }
        // The picture through its matte: alpha *= coverage.
        return image.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": CIImage.empty(),
            "inputMaskImage": coverage,
        ])
    }
}

// MARK: - The keyers

public enum KeyerEffects {

    public static let chromaId = "maestro.effect.chromaKey"
    public static let lumaId = "maestro.effect.lumaKey"

    public static let chromaSchema = EffectSchema(
        effectId: chromaId,
        displayName: "Chroma Key",
        family: "Key",
        operatesOnColorValues: true,
        projectionClass: .projectionAware,
        parameters: [
            EffectParameterSchema(key: "keyColor", label: "Key Color", kind: .color,
                                  defaultValue: .color(ColorRGBA(r: 0.1, g: 0.85, b: 0.15, a: 1))),
            EffectParameterSchema(key: "tolerance", label: "Tolerance", kind: .normalized,
                                  defaultValue: .number(0.2)),
            EffectParameterSchema(key: "softness", label: "Softness", kind: .normalized,
                                  defaultValue: .number(0.1)),
            EffectParameterSchema(key: "despill", label: "Despill", kind: .normalized,
                                  defaultValue: .number(0.5)),
            EffectParameterSchema(key: "shrinkGrow", label: "Shrink / Grow", kind: .scalar,
                                  defaultValue: .number(0), range: -1...1),
            EffectParameterSchema(key: "matteSoften", label: "Matte Soften", kind: .normalized,
                                  defaultValue: .number(0)),
        ])

    public static let lumaSchema = EffectSchema(
        effectId: lumaId,
        displayName: "Luma Key",
        family: "Key",
        operatesOnColorValues: true,
        projectionClass: .projectionAware,
        parameters: [
            EffectParameterSchema(key: "threshold", label: "Threshold", kind: .normalized,
                                  defaultValue: .number(0.5)),
            EffectParameterSchema(key: "tolerance", label: "Tolerance", kind: .normalized,
                                  defaultValue: .number(0.1)),
            EffectParameterSchema(key: "softness", label: "Softness", kind: .normalized,
                                  defaultValue: .number(0.1)),
            EffectParameterSchema(key: "keepBrighter", label: "Keep Brighter Side",
                                  kind: .boolean, defaultValue: .bool(true)),
            EffectParameterSchema(key: "shrinkGrow", label: "Shrink / Grow", kind: .scalar,
                                  defaultValue: .number(0), range: -1...1),
            EffectParameterSchema(key: "matteSoften", label: "Matte Soften", kind: .normalized,
                                  defaultValue: .number(0)),
        ])

    // MARK: The matte through one cube (color distance in Cb/Cr)

    static func chromaMatteCube(key: ColorRGBA, tolerance: Double,
                                softness: Double) -> Data {
        let n = 33
        func chroma(_ r: Double, _ g: Double, _ b: Double) -> (cb: Double, cr: Double) {
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return ((b - y) / 1.8556, (r - y) / 1.5748)
        }
        let keyChroma = chroma(Double(key.r), Double(key.g), Double(key.b))
        var rgba = [Float]()
        rgba.reserveCapacity(n * n * n * 4)
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1)
                    let g = Double(gi) / Double(n - 1)
                    let b = Double(bi) / Double(n - 1)
                    let c = chroma(r, g, b)
                    let distance = ((c.cb - keyChroma.cb) * (c.cb - keyChroma.cb)
                        + (c.cr - keyChroma.cr) * (c.cr - keyChroma.cr)).squareRoot()
                    // 0 at the key color, 1 far away — smooth over softness.
                    let t = tolerance * 0.5
                    let s = max(softness * 0.5, 0.0001)
                    let alpha = min(max((distance - t) / s, 0), 1)
                    let v = Float(alpha)
                    rgba.append(v); rgba.append(v); rgba.append(v); rgba.append(1)
                }
            }
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func lumaMatteCube(threshold: Double, tolerance: Double,
                              softness: Double, keepBrighter: Bool) -> Data {
        let n = 33
        var rgba = [Float]()
        rgba.reserveCapacity(n * n * n * 4)
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1)
                    let g = Double(gi) / Double(n - 1)
                    let b = Double(bi) / Double(n - 1)
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let distance = keepBrighter ? luma - threshold : threshold - luma
                    let s = max(softness * 0.5, 0.0001)
                    let alpha = min(max((distance + tolerance * 0.5) / s, 0), 1)
                    let v = Float(alpha)
                    rgba.append(v); rgba.append(v); rgba.append(v); rgba.append(1)
                }
            }
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func matte(for image: CIImage, cube: Data,
                      shrinkGrow: Double, soften: Double) -> CIImage {
        var matte = image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": 33,
            "inputCubeData": cube,
        ])
        // Simple cleanup: shrink/grow by morphology, then a soften — all
        // ON THE MATTE, never the picture.
        let extent = image.extent
        let radius = abs(shrinkGrow) * 8
        if radius > 0.01 {
            matte = matte.clampedToExtent()
                .applyingFilter(shrinkGrow < 0 ? "CIMorphologyMinimum"
                                : "CIMorphologyMaximum",
                                parameters: ["inputRadius": radius])
                .cropped(to: extent)
        }
        if soften > 0.001 {
            matte = matte.clampedToExtent()
                .applyingFilter("CIGaussianBlur",
                                parameters: ["inputRadius": soften * 12])
                .cropped(to: extent)
        }
        return matte
    }

    /// Despill: pull the key hue's contamination out of edges by limiting
    /// the dominant key channel toward the other channels' ceiling.
    static func despilled(_ image: CIImage, key: ColorRGBA,
                          amount: Double) -> CIImage {
        guard amount > 0.001 else { return image }
        // The backing's dominant channel decides which matrix runs.
        let r = key.r, g = key.g, b = key.b
        if g >= r && g >= b {
            // g' = g − amount·max(0, g − max(r, b)) approximated linearly:
            // pull green toward the average of red and blue.
            let keep = 1 - amount * 0.5
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputGVector": CIVector(x: CGFloat(amount * 0.25), y: CGFloat(keep),
                                         z: CGFloat(amount * 0.25), w: 0),
            ])
        }
        if b >= r && b >= g {
            let keep = 1 - amount * 0.5
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputBVector": CIVector(x: CGFloat(amount * 0.25),
                                         y: CGFloat(amount * 0.25),
                                         z: CGFloat(keep), w: 0),
            ])
        }
        let keep = 1 - amount * 0.5
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(keep), y: CGFloat(amount * 0.25),
                                     z: CGFloat(amount * 0.25), w: 0),
        ])
    }

    public static let chromaRenderer: EffectRenderer = { image, parameters, environment in
        let key = parameters["keyColor"]?.colorValue
            ?? ColorRGBA(r: 0.1, g: 0.85, b: 0.15, a: 1)
        let cube = chromaMatteCube(
            key: key,
            tolerance: parameters["tolerance"]?.numberValue ?? 0.2,
            softness: parameters["softness"]?.numberValue ?? 0.1)
        let matte = matte(for: image, cube: cube,
                          shrinkGrow: parameters["shrinkGrow"]?.numberValue ?? 0,
                          soften: parameters["matteSoften"]?.numberValue ?? 0)
        if environment.showMatte { return matte }
        let cleaned = despilled(image, key: key,
                                amount: parameters["despill"]?.numberValue ?? 0.5)
        return cleaned.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": CIImage.empty(),
            "inputMaskImage": matte,
        ])
    }

    public static let lumaRenderer: EffectRenderer = { image, parameters, environment in
        let cube = lumaMatteCube(
            threshold: parameters["threshold"]?.numberValue ?? 0.5,
            tolerance: parameters["tolerance"]?.numberValue ?? 0.1,
            softness: parameters["softness"]?.numberValue ?? 0.1,
            keepBrighter: parameters["keepBrighter"]?.boolValue ?? true)
        let matte = matte(for: image, cube: cube,
                          shrinkGrow: parameters["shrinkGrow"]?.numberValue ?? 0,
                          soften: parameters["matteSoften"]?.numberValue ?? 0)
        if environment.showMatte { return matte }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": CIImage.empty(),
            "inputMaskImage": matte,
        ])
    }
}
