import AppKit

final class MagnifierView: NSView {
  static let windowSize = NSSize(width: 116, height: 145)
  static let cursorOffset = NSPoint(x: 58, y: 87)

  var image: CGImage? {
    didSet { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let imageRect = NSRect(x: 3, y: 32, width: 110, height: 110)

    context.saveGState()
    context.addEllipse(in: imageRect)
    context.clip()
    NSColor.windowBackgroundColor.setFill()
    imageRect.fill()

    if let image {
      context.interpolationQuality = .none
      context.draw(image, in: imageRect)
      drawPixelGrid(image: image, in: imageRect)
    }
    context.restoreGState()

    let outline = NSBezierPath(ovalIn: imageRect)
    outline.lineWidth = 1.25
    NSColor.white.setStroke()
    outline.stroke()

    let darkOutline = NSBezierPath(ovalIn: imageRect.insetBy(dx: 1, dy: 1))
    darkOutline.lineWidth = 0.5
    NSColor.black.withAlphaComponent(0.72).setStroke()
    darkOutline.stroke()

    drawHexBadge()
  }

  private func drawHexBadge() {
    guard let image, let hex = PixelColor.hex(in: image) else { return }
    let text = hex as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let textSize = text.size(withAttributes: attributes)
    let badgeRect = NSRect(
      x: (bounds.width - textSize.width - 14) / 2,
      y: 2,
      width: textSize.width + 14,
      height: textSize.height + 8
    )
    NSColor.black.withAlphaComponent(0.82).setFill()
    NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5).fill()
    text.draw(
      at: NSPoint(x: badgeRect.minX + 7, y: badgeRect.minY + 4),
      withAttributes: attributes
    )
  }

  private func drawPixelGrid(image: CGImage, in rect: CGRect) {
    let columns = image.width
    let rows = image.height
    guard columns > 0, rows > 0 else { return }

    let cellWidth = rect.width / CGFloat(columns)
    let cellHeight = rect.height / CGFloat(rows)
    let grid = NSBezierPath()
    grid.lineWidth = 0.35
    for column in 1..<columns {
      let x = rect.minX + CGFloat(column) * cellWidth
      grid.move(to: NSPoint(x: x, y: rect.minY))
      grid.line(to: NSPoint(x: x, y: rect.maxY))
    }
    for row in 1..<rows {
      let y = rect.minY + CGFloat(row) * cellHeight
      grid.move(to: NSPoint(x: rect.minX, y: y))
      grid.line(to: NSPoint(x: rect.maxX, y: y))
    }
    NSColor.black.withAlphaComponent(0.28).setStroke()
    grid.stroke()

    let centerColumn = columns / 2
    let centerRow = rows / 2
    let targetRect = CGRect(
      x: rect.minX + CGFloat(centerColumn) * cellWidth,
      y: rect.minY + CGFloat(centerRow) * cellHeight,
      width: cellWidth,
      height: cellHeight
    )
    let outerTarget = NSBezierPath(rect: targetRect.insetBy(dx: -1, dy: -1))
    outerTarget.lineWidth = 3
    NSColor.black.setStroke()
    outerTarget.stroke()

    let innerTarget = NSBezierPath(rect: targetRect)
    innerTarget.lineWidth = 1.5
    NSColor.white.setStroke()
    innerTarget.stroke()
  }
}
