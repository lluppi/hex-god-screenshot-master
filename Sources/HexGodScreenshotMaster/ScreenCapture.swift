import AppKit
import CoreGraphics
import ScreenCaptureKit

private struct DisplayCapture {
  let intersection: CGRect
  let scale: CGFloat
  let image: CGImage
}

enum CaptureError: LocalizedError {
  case noDisplay
  case noColor
  case cannotCreateImage

  var errorDescription: String? {
    switch self {
    case .noDisplay:
      return "The selected area is not on an available display."
    case .noColor:
      return "The pixel color could not be read."
    case .cannotCreateImage:
      return "The screenshot image could not be created."
    }
  }
}

enum PixelColor {
  static func hex(in image: CGImage) -> String? {
    let bitmap = NSBitmapImageRep(cgImage: image)
    let x = max(0, min(bitmap.pixelsWide - 1, bitmap.pixelsWide / 2))
    let y = max(0, min(bitmap.pixelsHigh - 1, bitmap.pixelsHigh / 2))
    guard
      let sampled = bitmap.colorAt(x: x, y: y),
      let color = sampled.usingColorSpace(.sRGB)
    else { return nil }

    let red = Int((color.redComponent * 255).rounded())
    let green = Int((color.greenComponent * 255).rounded())
    let blue = Int((color.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", red, green, blue)
  }
}

enum CaptureService {
  private static var cachedContent: SCShareableContent?

  static func screenshot(of rect: CGRect) async throws -> CGImage {
    let content = try await shareableContent()
    let matches = content.displays.compactMap { display -> (SCDisplay, CGRect)? in
      let intersection = display.frame.intersection(rect)
      guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
        return nil
      }
      return (display, intersection)
    }

    guard !matches.isEmpty else { throw CaptureError.noDisplay }

    var captures: [DisplayCapture] = []
    for (display, intersection) in matches {
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let scale = max(1, CGFloat(filter.pointPixelScale))
      let configuration = SCStreamConfiguration()
      configuration.sourceRect = CGRect(
        x: intersection.minX - display.frame.minX,
        y: intersection.minY - display.frame.minY,
        width: intersection.width,
        height: intersection.height
      )
      configuration.width = max(1, Int((intersection.width * scale).rounded()))
      configuration.height = max(1, Int((intersection.height * scale).rounded()))
      configuration.showsCursor = false

      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
      )
      captures.append(
        DisplayCapture(
          intersection: intersection,
          scale: scale,
          image: image
        )
      )
    }

    if captures.count == 1, let image = captures.first?.image {
      return image
    }

    return try composite(captures, selection: rect)
  }

  static func magnifiedPixels(at point: CGPoint) async throws -> CGImage {
    let content = try await shareableContent()
    guard let display = content.displays.first(where: { $0.frame.contains(point) }) else {
      throw CaptureError.noDisplay
    }

    let ownApplications = content.applications.filter {
      $0.bundleIdentifier == Bundle.main.bundleIdentifier
    }
    let filter = SCContentFilter(
      display: display,
      excludingApplications: ownApplications,
      exceptingWindows: []
    )
    let scale = max(1, CGFloat(filter.pointPixelScale))
    let samplePixels = 21
    let halfSample = samplePixels / 2
    let displayPixelWidth = max(samplePixels, Int((display.frame.width * scale).rounded()))
    let displayPixelHeight = max(samplePixels, Int((display.frame.height * scale).rounded()))
    let pointedPixelX = Int(floor((point.x - display.frame.minX) * scale))
    let pointedPixelY = Int(floor((point.y - display.frame.minY) * scale))
    let originPixelX = min(
      max(0, pointedPixelX - halfSample),
      displayPixelWidth - samplePixels
    )
    let originPixelY = min(
      max(0, pointedPixelY - halfSample),
      displayPixelHeight - samplePixels
    )

    let configuration = SCStreamConfiguration()
    configuration.sourceRect = CGRect(
      x: CGFloat(originPixelX) / scale,
      y: CGFloat(originPixelY) / scale,
      width: CGFloat(samplePixels) / scale,
      height: CGFloat(samplePixels) / scale
    )
    configuration.width = samplePixels
    configuration.height = samplePixels
    configuration.showsCursor = false

    return try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: configuration
    )
  }

  static func hexColor(at point: CGPoint) async throws -> String {
    let pixelRect = CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)
    let image = try await screenshot(of: pixelRect)
    guard let hex = PixelColor.hex(in: image) else {
      throw CaptureError.noColor
    }
    return hex
  }

  private static func shareableContent() async throws -> SCShareableContent {
    if let cachedContent {
      return cachedContent
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    cachedContent = content
    return content
  }

  private static func composite(
    _ captures: [DisplayCapture],
    selection: CGRect
  ) throws -> CGImage {
    let outputScale = captures.map(\.scale).max() ?? 1
    let width = max(1, Int((selection.width * outputScale).rounded()))
    let height = max(1, Int((selection.height * outputScale).rounded()))
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw CaptureError.cannotCreateImage
    }

    context.interpolationQuality = .high
    for capture in captures {
      let destination = CGRect(
        x: (capture.intersection.minX - selection.minX) * outputScale,
        y: (selection.maxY - capture.intersection.maxY) * outputScale,
        width: capture.intersection.width * outputScale,
        height: capture.intersection.height * outputScale
      )
      context.draw(capture.image, in: destination)
    }

    guard let image = context.makeImage() else {
      throw CaptureError.cannotCreateImage
    }
    return image
  }
}
