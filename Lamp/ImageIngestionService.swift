import CryptoKit
import UIKit
import Vision

enum ImageIngestionService {
    struct PreparedImage: Sendable {
        var data: Data
        var mimeType: String
        var sha256: String

        var base64: String { data.base64EncodedString() }
    }

    static func prepareForVision(_ data: Data) async throws -> PreparedImage {
        try await Task.detached(priority: .userInitiated) {
            guard let source = UIImage(data: data) else { throw IngestionError.invalidImage }
            let maxDimension: CGFloat = 2_048
            let longest = max(source.size.width, source.size.height)
            let scale = longest > maxDimension ? maxDimension / longest : 1
            let targetSize = CGSize(
                width: max(1, floor(source.size.width * scale)),
                height: max(1, floor(source.size.height * scale))
            )
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            let normalized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                UIColor.systemBackground.setFill()
                UIRectFill(CGRect(origin: .zero, size: targetSize))
                source.draw(in: CGRect(origin: .zero, size: targetSize))
            }

            var quality: CGFloat = 0.86
            var output = normalized.jpegData(compressionQuality: quality)
            while let bytes = output, bytes.count > 4_000_000, quality > 0.42 {
                quality -= 0.08
                output = normalized.jpegData(compressionQuality: quality)
            }
            guard let output, output.count <= 4_000_000 else { throw IngestionError.imageTooLarge }
            let digest = SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
            return PreparedImage(data: output, mimeType: "image/jpeg", sha256: digest)
        }.value
    }

    static func recognizeText(in data: Data) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                throw IngestionError.invalidImage
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    enum IngestionError: LocalizedError {
        case invalidImage
        case imageTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidImage: "无法读取这张图片"
            case .imageTooLarge: "图片压缩后仍然过大，请先裁剪后重试"
            }
        }
    }
}
