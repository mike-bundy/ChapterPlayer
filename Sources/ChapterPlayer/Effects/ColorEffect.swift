//
//  ColorEffect.swift
//  ChapterPlayer
//
//  MIRROR of MaestroKit/Sources/MaestroKit/ColorEffect.swift (FL-09 … FL-13 player
//  parity). ChapterPlayer cannot depend on MaestroKit, so the one effect
//  evaluator is DUPLICATED here verbatim below this header, and
//  MaestroVision's EffectSeamTests render the same stack through both and
//  compare the pixels. Change one, change both.
//
import Foundation
import CoreImage
import ChapterScript

public enum ColorEffect {

    public static let effectId = "maestro.effect.color"

    // MARK: - The schema (ten parameters, one Effect)

    public static let schema = EffectSchema(
        effectId: effectId,
        displayName: "Color",
        family: "Colour",
        operatesOnColorValues: true,
        projectionClass: .projectionIndependent,
        parameters: [
            EffectParameterSchema(key: "exposure", label: "Exposure", kind: .scalar,
                                  defaultValue: .number(0), range: -4...4),
            EffectParameterSchema(key: "contrast", label: "Contrast", kind: .scalar,
                                  defaultValue: .number(0), range: -1...1),
            EffectParameterSchema(key: "saturation", label: "Saturation", kind: .scalar,
                                  defaultValue: .number(1), range: 0...2),
            EffectParameterSchema(key: "temperature", label: "Temperature", kind: .scalar,
                                  defaultValue: .number(0), range: -1...1, gang: "whiteBalance"),
            EffectParameterSchema(key: "tint", label: "Tint", kind: .scalar,
                                  defaultValue: .number(0), range: -1...1, gang: "whiteBalance"),
            EffectParameterSchema(key: "highlights", label: "Highlights", kind: .scalar,
                                  defaultValue: .number(0), range: -1...1),
            EffectParameterSchema(key: "shadows", label: "Shadows", kind: .scalar,
                                  defaultValue: .number(0), range: -1...1),
            EffectParameterSchema(key: "curve", label: "Curve", kind: .curve,
                                  defaultValue: ColorCurve.identity.effectValue),
            EffectParameterSchema(key: "lut", label: "LUT", kind: .sourceReference,
                                  defaultValue: .string("")),
            EffectParameterSchema(key: "lutStrength", label: "Strength", kind: .normalized,
                                  defaultValue: .number(1)),
        ])

    /// Neutral in, unchanged out — what makes "reset" meaningful.
    public static var neutralParameters: [String: EffectValue] { [:] }

    // MARK: - The renderer (THE fixed order — one code path)

    public static let renderer: EffectRenderer = { image, parameters, environment in
        apply(image, parameters: parameters, environment: environment)
    }

    static func apply(_ input: CIImage,
                      parameters: [String: EffectValue],
                      environment: EffectRenderEnvironment) -> CIImage {
        var image = input

        // 1. EXPOSURE — stops.
        let exposure = parameters["exposure"]?.numberValue ?? 0
        if abs(exposure) > 0.0001 {
            image = image.applyingFilter("CIExposureAdjust",
                                         parameters: ["inputEV": exposure])
        }

        // 2. CONTRAST — alone, so the order with saturation is FIXED here
        //    rather than inside one combined filter.
        let contrast = parameters["contrast"]?.numberValue ?? 0
        if abs(contrast) > 0.0001 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputContrast": 1 + contrast,
                "inputSaturation": 1, "inputBrightness": 0,
            ])
        }

        // 3. SATURATION.
        let saturation = parameters["saturation"]?.numberValue ?? 1
        if abs(saturation - 1) > 0.0001 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputSaturation": saturation,
                "inputContrast": 1, "inputBrightness": 0,
            ])
        }

        // 4. WHITE BALANCE — temperature/tint as one thought.
        let temperature = parameters["temperature"]?.numberValue ?? 0
        let tint = parameters["tint"]?.numberValue ?? 0
        if abs(temperature) > 0.0001 || abs(tint) > 0.0001 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + CGFloat(temperature) * 3000,
                                         y: CGFloat(tint) * 60),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }

        // 5. HIGHLIGHTS / SHADOWS — a monotone tonal curve of its own, so
        //    the two recover and lift without ever crossing.
        let highlights = parameters["highlights"]?.numberValue ?? 0
        let shadows = parameters["shadows"]?.numberValue ?? 0
        if abs(highlights) > 0.0001 || abs(shadows) > 0.0001,
           let tonal = ColorCurve(points: [
               .init(x: 0, y: 0),
               .init(x: 0.3, y: min(max(0.3 + shadows * 0.15, 0.02), 0.66)),
               .init(x: 0.7, y: min(max(0.7 + highlights * 0.15, 0.34), 0.98)),
               .init(x: 1, y: 1),
           ]) {
            image = applyCube(curve: tonal, to: image)
        }

        // 6. THE CURVE — only when authored: an identity curve costs
        //    nothing and clamps nothing.
        if let curve = ColorCurve(effectValue: parameters["curve"]),
           !curve.isIdentity {
            image = applyCube(curve: curve, to: image)
        }

        // 7. THE LUT — one unit, exactly once, with the linear strength
        //    mix exact at both endpoints. Missing bytes ⇒ the stage
        //    bypasses (the reference is kept; the Inspector reports).
        let lutFile = parameters["lut"]?.stringValue ?? ""
        let strength = min(max(parameters["lutStrength"]?.numberValue ?? 1, 0), 1)
        if !lutFile.isEmpty, strength > 0,
           let bytes = environment.sourceData?(lutFile),
           let lut = try? LUTParsing.parse(String(decoding: bytes, as: UTF8.self)) {
            let source = image
            let lutted = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": lut.size,
                "inputCubeData": LUTParsing.colorCubeData(lut),
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
            ])
            if strength >= 0.9999 {
                image = lutted                       // exact at 1
            } else {
                image = lutted.applyingFilter("CIMix", parameters: [
                    "inputBackgroundImage": source,
                    "inputAmount": strength,         // exact at 0 by the guard above
                ])
            }
        }

        return image
    }

    /// A 1D curve applied per channel through a 3D cube — ONE mechanism
    /// for the tonal stage and the authored curve.
    private static func applyCube(curve: ColorCurve, to image: CIImage) -> CIImage {
        let n = 33
        let samples = curve.sampled(count: n).map(Float.init)
        var rgba = [Float]()
        rgba.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    rgba.append(samples[r])
                    rgba.append(samples[g])
                    rgba.append(samples[b])
                    rgba.append(1)
                }
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": n,
            "inputCubeData": data,
        ])
    }
}
