import AppKit

/// The single gesture resolves to either a pixel color or a rectangular screenshot.
enum SelectionResult {
  case color(at: CGPoint)
  case screenshot(rect: CGRect)
}

final class SelectionCoordinator {
  var selectionRect: CGRect?
  private(set) var currentPoint: CGPoint?
  var onHover: ((CGPoint) -> Void)?
  var onSelectionChanged: (() -> Void)?
  var onFinish: ((SelectionResult) -> Void)?
  var onCancel: (() -> Void)?

  private var startPoint: CGPoint?
  private var hasFinished = false

  var isSelecting: Bool { startPoint != nil }

  func hover(at point: CGPoint) {
    guard !isSelecting, !hasFinished else { return }
    currentPoint = point
    onHover?(point)
  }

  func begin(at point: CGPoint) {
    guard !hasFinished else { return }
    startPoint = point
    currentPoint = point
    selectionRect = CGRect(origin: point, size: .zero)
    onSelectionChanged?()
  }

  func move(to point: CGPoint) {
    guard let startPoint, !hasFinished else { return }
    currentPoint = point
    selectionRect = CGRect(
      x: min(startPoint.x, point.x),
      y: min(startPoint.y, point.y),
      width: abs(point.x - startPoint.x),
      height: abs(point.y - startPoint.y)
    )
    onSelectionChanged?()
  }

  func end(at point: CGPoint) {
    guard let startPoint, !hasFinished else { return }
    move(to: point)
    hasFinished = true

    let distance = hypot(point.x - startPoint.x, point.y - startPoint.y)
    if distance < 4 {
      onFinish?(.color(at: startPoint))
    } else if let selectionRect {
      onFinish?(.screenshot(rect: selectionRect))
    }
  }

  func cancel() {
    guard !hasFinished else { return }
    hasFinished = true
    onCancel?()
  }
}

final class SelectionWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
  private let coordinator: SelectionCoordinator
  private var pointerTrackingArea: NSTrackingArea?

  init(coordinator: SelectionCoordinator) {
    self.coordinator = coordinator
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var acceptsFirstResponder: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func updateTrackingAreas() {
    if let pointerTrackingArea {
      removeTrackingArea(pointerTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .inVisibleRect, .mouseMoved],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    pointerTrackingArea = trackingArea
    super.updateTrackingAreas()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
  }

  override func mouseMoved(with event: NSEvent) {
    guard let window else { return }
    coordinator.hover(at: window.convertPoint(toScreen: event.locationInWindow))
  }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    coordinator.begin(at: window.convertPoint(toScreen: event.locationInWindow))
  }

  override func mouseDragged(with event: NSEvent) {
    coordinator.move(to: NSEvent.mouseLocation)
  }

  override func mouseUp(with event: NSEvent) {
    coordinator.end(at: NSEvent.mouseLocation)
  }

  override func rightMouseDown(with event: NSEvent) {
    coordinator.cancel()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      coordinator.cancel()
    } else {
      super.keyDown(with: event)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.withAlphaComponent(0.04).setFill()
    dirtyRect.fill()

    guard let globalSelection = coordinator.selectionRect, let window else { return }
    let windowRect = window.convertFromScreen(globalSelection)
    let localRect = convert(windowRect, from: nil).intersection(bounds)
    guard !localRect.isEmpty else { return }

    NSGraphicsContext.saveGraphicsState()
    NSColor.clear.setFill()
    localRect.fill(using: .copy)
    NSGraphicsContext.restoreGraphicsState()

    let border = NSBezierPath(rect: localRect.insetBy(dx: 0.5, dy: 0.5))
    border.lineWidth = 1
    NSColor.white.setStroke()
    border.stroke()

    drawMeasurement(for: globalSelection, in: window)
  }

  private func drawMeasurement(for selection: CGRect, in window: NSWindow) {
    guard
      selection.width >= 1 || selection.height >= 1,
      let currentPoint = coordinator.currentPoint,
      window.frame.contains(currentPoint)
    else { return }

    let text =
      "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded())) px" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let textSize = text.size(withAttributes: attributes)
    let badgeSize = NSSize(width: textSize.width + 14, height: textSize.height + 8)
    let windowPoint = window.convertPoint(fromScreen: currentPoint)
    let localPoint = convert(windowPoint, from: nil)
    let origin = NSPoint(
      x: min(max(8, localPoint.x + 14), bounds.maxX - badgeSize.width - 8),
      y: min(max(8, localPoint.y - badgeSize.height - 14), bounds.maxY - badgeSize.height - 8)
    )
    let badgeRect = NSRect(origin: origin, size: badgeSize)

    NSColor.black.withAlphaComponent(0.82).setFill()
    NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5).fill()
    text.draw(
      at: NSPoint(x: badgeRect.minX + 7, y: badgeRect.minY + 4),
      withAttributes: attributes
    )
  }
}
