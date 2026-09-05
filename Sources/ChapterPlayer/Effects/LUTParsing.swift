//
//  LUTParsing.swift
//  ChapterPlayer
//
//  MIRROR of MaestroKit/Sources/MaestroKit/LUTParsing.swift (FL-09 … FL-13 player
//  parity). ChapterPlayer cannot depend on MaestroKit, so the one effect
//  evaluator is DUPLICATED here verbatim below this header, and
//  MaestroVision's EffectSeamTests render the same stack through both and
//  compare the pixels. Change one, change both.
//
import Foundation

public struct ParsedLUT: Sendable, Equatable {
    /// Edge size N of the N×N×N cube.
    public let size: Int
    /// r,g,b triples, red-fastest (the .cube convention): index =
    /// r + g*N + b*N*N.
    public let table: [Float]
    public let title: String?
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>

    public var entryCount: Int { size * size * size }
}

public enum LUTParsing {

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
        init(_ message: String) { self.message = message }
    }

    public static func parse(_ contents: String) throws -> ParsedLUT {
        var size: Int?
        var title: String?
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var table: [Float] = []

        let lines = contents.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let keyword = fields.first else { continue }

            switch keyword.uppercased() {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(
                    in: CharacterSet(charactersIn: " \""))
            case "LUT_3D_SIZE":
                guard fields.count == 2, let n = Int(fields[1]), n >= 2, n <= 256 else {
                    throw Refusal("Line \(lineNumber): LUT_3D_SIZE must be a number from 2 to 256.")
                }
                size = n
                table.reserveCapacity(n * n * n * 3)
            case "LUT_1D_SIZE":
                throw Refusal("Line \(lineNumber): this is a 1D LUT. Maestro applies 3D .cube LUTs.")
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard fields.count == 4,
                      let r = Float(fields[1]), let g = Float(fields[2]),
                      let b = Float(fields[3]) else {
                    throw Refusal("Line \(lineNumber): \(keyword) needs three numbers.")
                }
                if keyword.uppercased() == "DOMAIN_MIN" {
                    domainMin = SIMD3(r, g, b)
                } else {
                    domainMax = SIMD3(r, g, b)
                }
            default:
                // A data line: exactly three floats.
                guard fields.count == 3,
                      let r = Float(fields[0]), let g = Float(fields[1]),
                      let b = Float(fields[2]) else {
                    throw Refusal("Line \(lineNumber) is not a colour triple: \(line)")
                }
                guard size != nil else {
                    throw Refusal("Line \(lineNumber): colour data before LUT_3D_SIZE.")
                }
                table.append(contentsOf: [r, g, b])
            }
        }

        guard let n = size else {
            throw Refusal("The file has no LUT_3D_SIZE. It is not a 3D .cube LUT.")
        }
        let expected = n * n * n * 3
        guard table.count == expected else {
            throw Refusal("The table has \(table.count / 3) entries; a \(n)³ LUT needs \(expected / 3). The file is truncated or over-long.")
        }
        guard domainMax.x > domainMin.x, domainMax.y > domainMin.y,
              domainMax.z > domainMin.z else {
            throw Refusal("DOMAIN_MAX must exceed DOMAIN_MIN on every channel.")
        }
        return ParsedLUT(size: n, table: table, title: title,
                         domainMin: domainMin, domainMax: domainMax)
    }

    /// The RGBA float data `CIColorCube` wants (alpha = 1), red-fastest.
    public static func colorCubeData(_ lut: ParsedLUT) -> Data {
        var rgba = [Float]()
        rgba.reserveCapacity(lut.entryCount * 4)
        for i in 0..<lut.entryCount {
            rgba.append(lut.table[i * 3])
            rgba.append(lut.table[i * 3 + 1])
            rgba.append(lut.table[i * 3 + 2])
            rgba.append(1)
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
