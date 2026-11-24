// MIT License
// Copyright (c) 2026 RawTouch contributors

import AppKit

/// The menubar glyph with the update mark — an up arrow in a filled circle —
/// drawn into its top-trailing corner, as ONE template image. `MenuBarExtra`
/// draws only the first image of its label and ignores SwiftUI overlays, so
/// the mark has to be part of the image itself; being a template, it follows
/// the menu bar's light, dark and tinted appearances like the plain glyph.
enum MenuBarIconImage {
    /// The update mark's symbol.
    static let markSymbolName = "arrow.up.circle.fill"

    /// `symbolName` at the size the menu bar gives a plain SF Symbol label,
    /// with the mark over its top-trailing corner, ringed by a transparent
    /// gap so it stays legible against the glyph. Nil only if a symbol is
    /// missing from the system.
    static func marked(_ symbolName: String) -> NSImage? {
        // The menu bar sizes a symbol label like text in its own font at
        // medium symbol scale; matching that keeps the glyph from changing
        // size when the mark comes and goes.
        let pointSize = NSFont.menuBarFont(ofSize: 0).pointSize
        let baseConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .medium)
        let markConfig = NSImage.SymbolConfiguration(pointSize: pointSize * 0.7, weight: .semibold, scale: .small)
        guard
            let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(baseConfig),
            let mark = NSImage(systemSymbolName: markSymbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(markConfig)
        else {
            return nil
        }
        let gap: CGFloat = 1.5
        // The mark overhangs the glyph's top-trailing corner, by half its
        // width sideways and upward as far as a 22 pt canvas allows (the
        // thinnest menu bar), so it covers little of the glyph. The canvas
        // grows vertically on both sides, so the glyph stays centred where
        // the unmarked icon has it.
        let overhangX = (mark.size.width / 2).rounded(.up)
        let overhangY = max(0, (22 - base.size.height) / 2)
        let size = NSSize(width: base.size.width + overhangX, height: base.size.height + 2 * overhangY)
        let markRect = NSRect(
            x: size.width - mark.size.width,
            y: size.height - mark.size.height,
            width: mark.size.width,
            height: mark.size.height
        )
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: NSPoint(x: 0, y: overhangY), size: base.size))
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: markRect.insetBy(dx: -gap, dy: -gap)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            mark.draw(in: markRect)
            return true
        }
        image.isTemplate = true
        return image
    }
}
