// MBKArrowView.swift
// MenuBarKit
//
// Custom arrow-and-body background used by the nuclear-option replacement
// of NSPopover (see PopoverController.swift). Draws a single filled shape:
// rounded-rect body + triangular arrow tip pointing up, at a caller-set x
// position. Entirely under our control — no AppKit-internal positioning
// or relayout math involved anywhere.

import AppKit

final class MBKArrowView: NSView {

    var arrowXInWindow: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    private let arrowHeight: CGFloat = 10
    private let arrowHalfWidth: CGFloat = 10
    private let cornerRadius: CGFloat = 12
    private let fillColor: NSColor

    init(fillColor: NSColor = .windowBackgroundColor) {
        self.fillColor = fillColor
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { false }

    /// Body rect sits below the arrow strip at the top of the view.
    var bodyRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - arrowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let body = bodyRect
        let arrowTipX = min(max(arrowXInWindow, cornerRadius + arrowHalfWidth),
                             bounds.width - cornerRadius - arrowHalfWidth)
        let arrowBaseY = body.maxY

        let combined = CGMutablePath()
        combined.addPath(CGPath(roundedRect: body, cornerWidth: cornerRadius,
                                 cornerHeight: cornerRadius, transform: nil))
        combined.move(to: CGPoint(x: arrowTipX - arrowHalfWidth, y: arrowBaseY))
        combined.addLine(to: CGPoint(x: arrowTipX, y: arrowBaseY + arrowHeight))
        combined.addLine(to: CGPoint(x: arrowTipX + arrowHalfWidth, y: arrowBaseY))
        combined.closeSubpath()

        ctx.addPath(combined)
        ctx.setFillColor(fillColor.cgColor)
        ctx.fillPath()
    }
}
