import SwiftUI
import UIKit

enum DominantColorExtractor {
    static func extractColor(from url: URL) async -> Color? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let uiImage = UIImage(data: data) else { return nil }
            guard let dominant = dominantColor(from: uiImage) else { return nil }
            return Color(dominant)
        } catch {
            return nil
        }
    }

    static func dominantColor(from image: UIImage) -> UIColor? {
        let size = CGSize(width: 40, height: 40)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        image.draw(in: CGRect(origin: .zero, size: size))
        let scaled = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let cgImage = scaled?.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totalR: CGFloat = 0, totalG: CGFloat = 0, totalB: CGFloat = 0, totalWeight: CGFloat = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * bytesPerPixel
                let r = CGFloat(pixelData[offset]) / 255.0
                let g = CGFloat(pixelData[offset + 1]) / 255.0
                let b = CGFloat(pixelData[offset + 2]) / 255.0

                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
                let brightness = maxC

                let weight = saturation * saturation + 0.01
                guard brightness > 0.1 && brightness < 0.95 else { continue }

                totalR += r * weight
                totalG += g * weight
                totalB += b * weight
                totalWeight += weight
            }
        }

        guard totalWeight > 0 else { return nil }

        let finalR = totalR / totalWeight
        let finalG = totalG / totalWeight
        let finalB = totalB / totalWeight

        let maxFinal = max(finalR, finalG, finalB)
        let minFinal = min(finalR, finalG, finalB)
        let finalSat = maxFinal > 0 ? (maxFinal - minFinal) / maxFinal : 0

        if finalSat < 0.15 { return nil }

        let hsl = UIColor(red: finalR, green: finalG, blue: finalB, alpha: 1.0)
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0
        hsl.getHue(&h, saturation: &s, brightness: &br, alpha: nil)

        br = max(br, 0.4)
        s = min(s * 1.2, 1.0)

        return UIColor(hue: h, saturation: s, brightness: br, alpha: 1.0)
    }
}
