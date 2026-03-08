import Foundation
import PDFKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

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

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: Int(scaledSize.width),
                height: Int(scaledSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return (author, nil) }

            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: scaledSize))
            ctx.translateBy(x: 0, y: scaledSize.height)
            ctx.scaleBy(x: scale, y: -scale)
            firstPage.draw(with: .mediaBox, to: ctx)

            if let cgImage = ctx.makeImage() {
                #if os(iOS)
                coverImage = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7)
                #else
                let nsImage = NSImage(cgImage: cgImage, size: scaledSize)
                coverImage = nsImage.jpegData(compressionQuality: 0.7)
                #endif
            }
        }

        return (author, coverImage)
    }
}
