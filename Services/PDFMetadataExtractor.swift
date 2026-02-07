import Foundation
import PDFKit
import UIKit

enum PDFMetadataExtractor {
    static func extractMetadata(from url: URL) -> (author: String?, coverImage: Data?) {
        guard let document = PDFDocument(url: url) else {
            return (nil, nil)
        }

        let author = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String

        var coverImage: Data? = nil
        if let firstPage = document.page(at: 0) {
            let pageRect = firstPage.bounds(for: .mediaBox)
            let scale: CGFloat = 300.0 / max(pageRect.width, pageRect.height)
            let scaledSize = CGSize(
                width: pageRect.width * scale,
                height: pageRect.height * scale
            )

            let renderer = UIGraphicsImageRenderer(size: scaledSize)
            let image = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: scaledSize))

                context.cgContext.translateBy(x: 0, y: scaledSize.height)
                context.cgContext.scaleBy(x: scale, y: -scale)

                firstPage.draw(with: .mediaBox, to: context.cgContext)
            }

            coverImage = image.jpegData(compressionQuality: 0.7)
        }

        return (author, coverImage)
    }
}
