import CoreImage

// MARK: - Frame compositing (for the shared copy of the screen)

/// Paints the blur into a captured frame, so it exists only in the copy that is
/// shared and never on the real display.
struct FrameCompositor {
    let context = CIContext(options: [.cacheIntermediates: false])

    /// A white-on-black image of the regions to cover. `rects` are in points with a
    /// bottom-left origin relative to the display; the result is in frame pixels.
    static func mask(rects: [CGRect], size: CGSize, scale: CGFloat) -> CIImage? {
        guard !rects.isEmpty,
              let bitmap = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                     bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(CGRect(origin: .zero, size: size))
        bitmap.setFillColor(gray: 1, alpha: 1)
        rects.forEach { bitmap.fill($0) }
        guard let image = bitmap.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    func compose(_ frame: CIImage, mask: CIImage?, solid: Bool, scale: CGFloat) -> CIImage {
        guard let mask else { return frame }
        let cover = solid
            ? CIImage(color: .black).cropped(to: frame.extent)
            : frame.clampedToExtent().applyingGaussianBlur(sigma: 12 * scale).cropped(to: frame.extent)
        return cover.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: frame, kCIInputMaskImageKey: mask,
        ])
    }
}
