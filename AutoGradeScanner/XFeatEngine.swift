import UIKit
import CoreML
import Accelerate

// On-device XFeat feature extraction ("XFeat: Accelerated Features for
// Lightweight Image Matching", CVPR 2024). The bundled XFeat.mlmodel wraps
// the backbone plus every fixed-shape step of the reference detectAndCompute
// pipeline (keypoint softmax + depth-to-space, and the 5x5 max-pool used by
// NMS), so this file only implements the dynamic-shape parts: NMS,
// reliability scoring, top-k selection and sparse descriptor sampling.
//
// The model comes from export_coreml.py in the accelerated_features repo
// (branch coreml-export). Swapping the .mlmodel changes the input resolution;
// the engine reads the size from the model description.

enum XFeatError: Error {
    case modelMissing
    case badImage
    case unexpectedModel
}

// Sparse features of one image. Keypoints are normalized to 0...1 within the
// source image so they stay comparable across images of different sizes.
struct XFeatFeatures {
    let keypoints: [CGPoint]
    let scores: [Float]
    let descriptors: [Float]   // count x 64 row-major, each row L2-normalized

    var count: Int { keypoints.count }
}

final class XFeatEngine {
    static let shared = try? XFeatEngine()

    private let model: MLModel
    let inputWidth: Int
    let inputHeight: Int
    private var gridWidth: Int { inputWidth / 8 }
    private var gridHeight: Int { inputHeight / 8 }

    init() throws {
        guard let url = Bundle.main.url(forResource: "XFeat", withExtension: "mlmodelc") else {
            throw XFeatError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: configuration)

        guard let shape = model.modelDescription.inputDescriptionsByName["image"]?
                .multiArrayConstraint?.shape, shape.count == 4 else {
            throw XFeatError.unexpectedModel
        }
        inputHeight = shape[2].intValue
        inputWidth = shape[3].intValue
    }

    // MARK: - Extraction

    func extract(from image: UIImage,
                 topK: Int = 2048,
                 detectionThreshold: Float = 0.05) throws -> XFeatFeatures {
        let inputArray = try grayInput(from: image)
        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(multiArray: inputArray)])
        let output = try model.prediction(from: provider)

        let planeSize = gridWidth * gridHeight
        guard let heat = floats(output, "keypointHeatmap"),
              let heatMax = floats(output, "keypointHeatmapMax"),
              let reliability = floats(output, "reliability"),
              let descriptorMap = floats(output, "descriptors"),
              heat.count == inputWidth * inputHeight,
              heatMax.count == heat.count,
              reliability.count == planeSize,
              descriptorMap.count == 64 * planeSize else {
            throw XFeatError.unexpectedModel
        }

        // NMS: a pixel is a keypoint iff it survives the threshold and equals
        // its own 5x5 neighborhood max (computed inside the model). Its score
        // is the keypoint probability times the bilinearly sampled reliability.
        var candidates: [(x: Int, y: Int, score: Float)] = []
        for y in 0..<inputHeight {
            let row = y * inputWidth
            let gy = gridCoordinate(y, size: inputHeight, gridSize: gridHeight)
            for x in 0..<inputWidth {
                let value = heat[row + x]
                guard value > detectionThreshold, value == heatMax[row + x] else { continue }
                let gx = gridCoordinate(x, size: inputWidth, gridSize: gridWidth)
                let score = value * bilinear(reliability, offset: 0,
                                             width: gridWidth, height: gridHeight, x: gx, y: gy)
                if score > 0 {
                    candidates.append((x, y, score))
                }
            }
        }
        candidates.sort { $0.score > $1.score }
        if candidates.count > topK {
            candidates.removeSubrange(topK...)
        }

        // Sample the 64-D descriptor at each keypoint and re-normalize,
        // mirroring InterpolateSparse2d + F.normalize in the reference code.
        var keypoints: [CGPoint] = []
        var scores: [Float] = []
        var descriptors = [Float](repeating: 0, count: candidates.count * 64)
        keypoints.reserveCapacity(candidates.count)
        scores.reserveCapacity(candidates.count)

        for (i, candidate) in candidates.enumerated() {
            keypoints.append(CGPoint(x: Double(candidate.x) / Double(inputWidth),
                                     y: Double(candidate.y) / Double(inputHeight)))
            scores.append(candidate.score)

            let gx = gridCoordinate(candidate.x, size: inputWidth, gridSize: gridWidth)
            let gy = gridCoordinate(candidate.y, size: inputHeight, gridSize: gridHeight)
            var sumOfSquares: Float = 0
            for d in 0..<64 {
                let value = bilinear(descriptorMap, offset: d * planeSize,
                                     width: gridWidth, height: gridHeight, x: gx, y: gy)
                descriptors[i * 64 + d] = value
                sumOfSquares += value * value
            }
            let inverseNorm = 1 / max(sumOfSquares.squareRoot(), 1e-6)
            for d in 0..<64 {
                descriptors[i * 64 + d] *= inverseNorm
            }
        }

        return XFeatFeatures(keypoints: keypoints, scores: scores, descriptors: descriptors)
    }

    // MARK: - Pre/post-processing helpers

    // Grayscale, stretched to the model's fixed input size. Value range does
    // not matter: the model starts with an InstanceNorm layer.
    private func grayInput(from image: UIImage) throws -> MLMultiArray {
        let prepared = image.normalizedForUpload(maxDimension: CGFloat(max(inputWidth, inputHeight)))
        guard let cgImage = prepared.cgImage else { throw XFeatError.badImage }

        var pixels = [UInt8](repeating: 0, count: inputWidth * inputHeight)
        guard let context = CGContext(data: &pixels,
                                      width: inputWidth,
                                      height: inputHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: inputWidth,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw XFeatError.badImage
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight))

        let array = try MLMultiArray(shape: [1, 1,
                                             NSNumber(value: inputHeight),
                                             NSNumber(value: inputWidth)],
                                     dataType: .float32)
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            vDSP_vfltu8(pixels, 1, buffer.baseAddress!, 1, vDSP_Length(pixels.count))
        }
        return array
    }

    private func floats(_ provider: MLFeatureProvider, _ name: String) -> [Float]? {
        guard let array = provider.featureValue(for: name)?.multiArrayValue else { return nil }
        switch array.dataType {
        case .float32:
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        case .double:
            return array.withUnsafeBufferPointer(ofType: Double.self) { $0.map(Float.init) }
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { $0.map(Float.init) }
        default:
            return nil
        }
    }

    // Full-resolution pixel index -> H/8 grid coordinate, matching
    // grid_sample(align_corners: false) with positions normalized by (size-1)
    // as done by InterpolateSparse2d in the reference code.
    private func gridCoordinate(_ pixel: Int, size: Int, gridSize: Int) -> Float {
        Float(pixel) * Float(gridSize) / Float(size - 1) - 0.5
    }

    private func bilinear(_ data: [Float], offset: Int,
                          width: Int, height: Int, x: Float, y: Float) -> Float {
        let cx = min(max(x, 0), Float(width - 1))
        let cy = min(max(y, 0), Float(height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let top = data[offset + y0 * width + x0] * (1 - fx)
                + data[offset + y0 * width + x1] * fx
        let bottom = data[offset + y1 * width + x0] * (1 - fx)
                   + data[offset + y1 * width + x1] * fx
        return top * (1 - fy) + bottom * fy
    }
}
