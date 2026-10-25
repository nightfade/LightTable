import CoreGraphics
import CoreImage
import CoreML
import Foundation

/// MobileCLIP-S2 image and text embeddings for modules outside TravelCutCore (the shooting-habit
/// report classifies photos by subject with it). Uses the same model files, compiled-model cache and
/// preprocessing as `MobileCLIPAnalyzer`, so the two never disagree about what an image looks like,
/// and installing the model once serves both.
public final class MobileCLIPEncoder: @unchecked Sendable {
    public static let modelName = "MobileCLIP-S2"
    /// Bytes to download when nothing is installed yet, for the "needs 199 MB" prompt.
    public static var downloadSize: Int64 { ModelInstaller.mobileCLIP.totalSize }

    /// Every model file present at its expected size. Checking sizes, not just existence, keeps a
    /// half-finished download from being loaded.
    public static var isInstalled: Bool {
        guard let directory = ModelInstaller.installedDirectory(for: ModelInstaller.mobileCLIP) else { return false }
        return ModelInstaller.mobileCLIP.files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(file.name).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    /// Downloads whatever is missing, resuming partial files. `progress` gets 0…1.
    public static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await ModelInstaller(ModelInstaller.mobileCLIP).install(progress: progress)
    }

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// Core ML models are not documented as safe for concurrent predictions.
    private let lock = NSLock()

    public init() throws {
        imageModel = try Self.loadModel(named: "mobileclip_s2_image")
        textModel = try Self.loadModel(named: "mobileclip_s2_text")
        tokenizer = try CLIPTokenizer()
    }

    /// L2-normalised embedding of the centre square of `image`.
    public func imageEmbedding(_ image: CGImage) throws -> [Float] {
        let buffer = try makePixelBuffer(image)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        let prediction = try lock.withLock { try imageModel.prediction(from: provider) }
        guard let output = prediction.featureValue(for: "final_emb_1")?.multiArrayValue else {
            throw TravelCutError.invalidArguments("MobileCLIP image output is unavailable")
        }
        return Self.normalized(output)
    }

    /// L2-normalised embedding of one prompt.
    public func textEmbedding(_ text: String) throws -> [Float] {
        let tokens = tokenizer.encode(text)
        let input = try MLMultiArray(shape: [1, 77], dataType: .int32)
        for (index, token) in tokens.enumerated() { input[index] = NSNumber(value: token) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["text": MLFeatureValue(multiArray: input)])
        let prediction = try lock.withLock { try textModel.prediction(from: provider) }
        guard let output = prediction.featureValue(for: "final_emb_1")?.multiArrayValue else {
            throw TravelCutError.invalidArguments("MobileCLIP text output is unavailable")
        }
        return Self.normalized(output)
    }

    private static func normalized(_ array: MLMultiArray) -> [Float] {
        let values = (0..<array.count).map { array[$0].floatValue }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? values.map { $0 / norm } : values
    }

    /// Same centre crop to 256×256 as `MobileCLIPAnalyzer`.
    private func makePixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
        let input = CIImage(cgImage: image)
        let side = min(input.extent.width, input.extent.height)
        let crop = CGRect(x: input.extent.midX - side / 2, y: input.extent.midY - side / 2, width: side, height: side)
        let cropped = input.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scale = 256 / side
        let resized = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_32ARGB, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw TravelCutError.invalidArguments("无法创建 MobileCLIP 图像缓冲区")
        }
        ciContext.render(resized, to: buffer, bounds: CGRect(x: 0, y: 0, width: 256, height: 256),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }

    /// Compiles the package once into the cache `MobileCLIPAnalyzer` also uses.
    private static func loadModel(named name: String) throws -> MLModel {
        guard let directory = ModelInstaller.installedDirectory(for: ModelInstaller.mobileCLIP) else {
            throw TravelCutError.modelUnavailable("无法访问 Application Support")
        }
        let packageURL = directory.appendingPathComponent("\(name).mlpackage", isDirectory: true)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw TravelCutError.modelUnavailable("缺少本地模型：\(name)")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let manager = FileManager.default
        let cacheRoot = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TravelCut/MobileCLIP-S2-v1", isDirectory: true)
        let cachedURL = cacheRoot.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        if manager.fileExists(atPath: cachedURL.path),
           let cached = try? MLModel(contentsOf: cachedURL, configuration: configuration) {
            return cached
        }
        try manager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let compiled = try MLModel.compileModel(at: packageURL)
        if manager.fileExists(atPath: cachedURL.path) { try manager.removeItem(at: cachedURL) }
        try manager.copyItem(at: compiled, to: cachedURL)
        return try MLModel(contentsOf: cachedURL, configuration: configuration)
    }
}
