import AppKit
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let coordinator = SelectionCoordinator()
  private let magnifierView = MagnifierView(frame: .zero)
  private var windows: [NSWindow] = []
  private var magnifierWindow: NSWindow?
  private var pendingMagnifierPoint: CGPoint?
  private var magnifierTask: Task<Void, Never>?
  private var escapeMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      showPermissionAlert()
      return
    }

    coordinator.onHover = { [weak self] point in
      self?.updateMagnifier(at: point)
    }
    coordinator.onSelectionChanged = { [weak self] in
      guard let self else { return }
      for window in windows {
        window.contentView?.needsDisplay = true
      }
      hideMagnifier()
    }
    coordinator.onFinish = { [weak self] result in
      self?.complete(result)
    }
    coordinator.onCancel = {
      NSApplication.shared.terminate(nil)
    }

    createOverlays()
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53 {
        self?.coordinator.cancel()
        return nil
      }
      return event
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    magnifierTask?.cancel()
    if let escapeMonitor {
      NSEvent.removeMonitor(escapeMonitor)
    }
  }

  private func createOverlays() {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.activate(ignoringOtherApps: true)

    windows = NSScreen.screens.map { screen in
      let window = SelectionWindow(
        contentRect: screen.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false,
        screen: screen
      )
      window.level = .screenSaver
      window.backgroundColor = .clear
      window.isOpaque = false
      window.hasShadow = false
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.contentView = SelectionView(coordinator: coordinator)
      window.acceptsMouseMovedEvents = true
      window.makeKeyAndOrderFront(nil)
      return window
    }

    windows.first?.makeKey()
    windows.first?.contentView?.window?.makeFirstResponder(windows.first?.contentView)
    createMagnifier()
    coordinator.hover(at: NSEvent.mouseLocation)
  }

  private func createMagnifier() {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: MagnifierView.windowSize),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.contentView = magnifierView
    magnifierWindow = window
  }

  private func updateMagnifier(at appKitPoint: CGPoint) {
    guard !coordinator.isSelecting, let magnifierWindow else { return }
    magnifierWindow.setFrameOrigin(
      NSPoint(
        x: appKitPoint.x - MagnifierView.cursorOffset.x,
        y: appKitPoint.y - MagnifierView.cursorOffset.y
      )
    )
    magnifierWindow.orderFrontRegardless()
    pendingMagnifierPoint = appKitPoint

    guard magnifierTask == nil else { return }
    magnifierTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while let point = pendingMagnifierPoint, !Task.isCancelled {
        pendingMagnifierPoint = nil
        let coreGraphicsPoint = convertToCoreGraphics(point)
        if let image = try? await CaptureService.magnifiedPixels(at: coreGraphicsPoint),
          !Task.isCancelled,
          !coordinator.isSelecting
        {
          magnifierView.image = image
        }
      }
      magnifierTask = nil
    }
  }

  private func hideMagnifier() {
    pendingMagnifierPoint = nil
    magnifierTask?.cancel()
    magnifierTask = nil
    magnifierWindow?.orderOut(nil)
  }

  private func complete(_ result: SelectionResult) {
    hideMagnifier()
    for window in windows {
      window.orderOut(nil)
    }

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(120))
      do {
        switch result {
        case .color(let appKitPoint):
          let point = convertToCoreGraphics(appKitPoint)
          let hex = try await CaptureService.hexColor(at: point)
          copyText(hex)
          print(hex)
        case .screenshot(let appKitRect):
          let rect = convertToCoreGraphics(appKitRect)
          let image = try await CaptureService.screenshot(of: rect)
          try copyImage(image)
          print("Screenshot copied to clipboard")
        }
        NSApplication.shared.terminate(nil)
      } catch {
        showError(error)
      }
    }
  }

  private func convertToCoreGraphics(_ point: CGPoint) -> CGPoint {
    let mainScreenTop = NSScreen.screens.first?.frame.maxY ?? 0
    return CGPoint(x: point.x, y: mainScreenTop - point.y)
  }

  private func convertToCoreGraphics(_ rect: CGRect) -> CGRect {
    let mainScreenTop = NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(
      x: rect.minX,
      y: mainScreenTop - rect.maxY,
      width: rect.width,
      height: rect.height
    )
  }

  private func copyText(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func copyImage(_ image: CGImage) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw CaptureError.cannotCreateImage
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.declareTypes([.png, .tiff], owner: nil)
    pasteboard.setData(png, forType: .png)

    let nsImage = NSImage(cgImage: image, size: .zero)
    if let tiff = nsImage.tiffRepresentation {
      pasteboard.setData(tiff, forType: .tiff)
    }
  }

  private func showPermissionAlert() {
    let alert = NSAlert()
    alert.messageText = "Screen Recording permission is required"
    alert.informativeText =
      "Allow Hex God Screenshot Master in System Settings → Privacy & Security → Screen & System Audio Recording, then launch it again."
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Quit")
    if alert.runModal() == .alertFirstButtonReturn,
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    {
      NSWorkspace.shared.open(url)
    }
    NSApplication.shared.terminate(nil)
  }

  private func showError(_ error: Error) {
    let alert = NSAlert(error: error)
    alert.messageText = "Hex God Screenshot Master could not capture the screen"
    alert.runModal()
    NSApplication.shared.terminate(nil)
  }
}
