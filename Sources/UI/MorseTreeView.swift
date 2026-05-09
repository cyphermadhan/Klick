import SwiftUI

/// Pure-visualization binary Morse tree. The parent owns `MorseTree`
/// (state) and the dit/dah buttons; this view only draws the nodes and
/// highlights the active path.
///
/// Shape convention from the keychain photo:
///   - left branch = dah step → **square** node
///   - right branch = dit step → **circle** node
///   - root = antenna glyph
///
/// Nodes are drawn for every defined ITU character (depths 1–6). Letters
/// (depths 1–4) render full-size with a 9 pt label. Digits (depth 5) drop
/// to 14 pt markers with a 7 pt label since horizontal spacing halves each
/// level. Punctuation (depth 6) is too tight for text on a phone, so those
/// nodes are label-less 10 pt markers — the live path still highlights the
/// exact terminal so users can see where they are, and the composed
/// character appears in the `currentLetter` readout next to the tree.
struct MorseTreeView: View {
    @ObservedObject var tree: MorseTree
    /// Character that should briefly glow orange. The parent sets this
    /// on commit (via `.onChange` of `tree.buffer`) and clears it after
    /// a short delay — matching the keychain's "A" flash state.
    var flashChar: Character?

    /// Max depth we lay out vertically. ITU punctuation tops out at 6.
    private let maxDepth = 6

    /// Per-depth visual tuning. Node size shrinks so deep branches fit
    /// without overlapping their siblings; the label font shrinks in
    /// tandem, dropping to zero (no label) at depth 6.
    private func nodeSide(for depth: Int) -> CGFloat {
        switch depth {
        case ...4:  return 18
        case 5:     return 14
        default:    return 10
        }
    }

    private func labelSize(for depth: Int) -> CGFloat? {
        switch depth {
        case ...4:  return 9
        case 5:     return 7
        default:    return nil
        }
    }

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .drawingGroup()
        .animation(.easeOut(duration: 0.12), value: tree.currentPath)
        .animation(.easeOut(duration: 0.2), value: flashChar)
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let rowHeight = size.height / CGFloat(maxDepth + 1)
        drawGhostTree(ctx: ctx, size: size, rowHeight: rowHeight)
        drawActivePath(ctx: ctx, size: size, rowHeight: rowHeight)
        drawRoot(ctx: ctx, rowHeight: rowHeight, size: size)
    }

    /// Dim reference drawing of every defined character — the "keychain"
    /// layer. Letters get full labels; digits get smaller labels;
    /// punctuation is label-less markers.
    private func drawGhostTree(ctx: GraphicsContext, size: CGSize, rowHeight: CGFloat) {
        let rootCenter = CGPoint(x: size.width / 2, y: rowHeight / 2)

        // Draw shallower paths first so deeper nodes overlap them cleanly.
        let sortedEntries = MorseCode.alphabet.sorted { $0.value.count < $1.value.count }

        for (char, path) in sortedEntries where !path.isEmpty {
            let depth = path.count

            // Edges: parent → child, drawn incrementally so overlapping
            // trunks don't require a separate "visited" set.
            var from = rootCenter
            for i in 0..<depth {
                let to = position(for: Array(path.prefix(i + 1)), size: size, rowHeight: rowHeight)
                var line = Path()
                line.move(to: from)
                line.addLine(to: to)
                ctx.stroke(line, with: .color(DT.textFaint), lineWidth: 0.5)
                from = to
            }

            let p = position(for: path, size: size, rowHeight: rowHeight)
            drawNodeShape(ctx: ctx, at: p, last: path.last,
                          color: nodeColor(for: char),
                          filled: flashChar == char,
                          side: nodeSide(for: depth))
            if let fontSize = labelSize(for: depth) {
                let label = Text(String(char))
                    .font(DT.mono(fontSize, weight: .bold))
                    .foregroundColor(flashChar == char ? DT.warn : DT.textDim)
                ctx.draw(label, at: p)
            }
        }
    }

    /// Active traversal — drawn on top in ok-green (or warn-red if off-tree).
    private func drawActivePath(ctx: GraphicsContext, size: CGSize, rowHeight: CGFloat) {
        guard !tree.currentPath.isEmpty else { return }
        let color = tree.isOffTree ? DT.tx : DT.ok
        let rootCenter = CGPoint(x: size.width / 2, y: rowHeight / 2)

        var from = rootCenter
        for i in 0..<tree.currentPath.count {
            let to = position(for: Array(tree.currentPath.prefix(i + 1)), size: size, rowHeight: rowHeight)
            var line = Path()
            line.move(to: from)
            line.addLine(to: to)
            ctx.stroke(line, with: .color(color), lineWidth: 2)
            from = to
        }

        // Emphasize the terminal (currently-keyed) node. Slightly larger
        // than the ghost node at that depth so it reads as "this is where
        // you are" even on the tight depth-6 layer.
        let depth = tree.currentPath.count
        let terminalSide = nodeSide(for: depth) + 4
        let terminal = position(for: tree.currentPath, size: size, rowHeight: rowHeight)
        drawNodeShape(ctx: ctx, at: terminal, last: tree.currentPath.last,
                      color: color, filled: true, side: terminalSide)
        if let char = tree.currentLetter {
            let label = Text(String(char))
                .font(DT.mono(depth <= 4 ? 11 : 9, weight: .heavy))
                .foregroundColor(color)
            ctx.draw(label, at: terminal)
        }
    }

    private func drawRoot(ctx: GraphicsContext, rowHeight: CGFloat, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: rowHeight / 2)
        let active = tree.currentPath.isEmpty
        let color = active ? DT.ok : DT.textDim

        // Antenna glyph: small triangle with a dot on top.
        var p = Path()
        p.move(to: CGPoint(x: center.x - 7, y: center.y + 6))
        p.addLine(to: CGPoint(x: center.x + 7, y: center.y + 6))
        p.addLine(to: CGPoint(x: center.x, y: center.y - 4))
        p.closeSubpath()
        ctx.stroke(p, with: .color(color), lineWidth: active ? 2 : 1)

        let dot = Path(ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 8, width: 3, height: 3))
        ctx.fill(dot, with: .color(color))
    }

    private func drawNodeShape(ctx: GraphicsContext, at p: CGPoint,
                               last: MorseElement?, color: Color,
                               filled: Bool, side: CGFloat) {
        let rect = CGRect(x: p.x - side/2, y: p.y - side/2, width: side, height: side)
        switch last {
        case .dah:
            if filled { ctx.fill(Path(rect), with: .color(color.opacity(0.3))) }
            ctx.stroke(Path(rect), with: .color(color), lineWidth: filled ? 1.5 : 1)
        case .dit:
            let path = Path(ellipseIn: rect)
            if filled { ctx.fill(path, with: .color(color.opacity(0.3))) }
            ctx.stroke(path, with: .color(color), lineWidth: filled ? 1.5 : 1)
        case .none:
            break
        }
    }

    // MARK: - Geometry

    /// Position of the node at the end of `path`. Horizontal spacing
    /// shrinks geometrically each level; vertical is fixed row height.
    private func position(for path: [MorseElement], size: CGSize, rowHeight: CGFloat) -> CGPoint {
        var x = size.width / 2
        for (i, step) in path.enumerated() {
            // 0.55 picked empirically so depth-4 leaves fit with a safe
            // horizontal margin on an iPhone SE (375pt).
            let offset = (size.width / 2) * pow(0.55, CGFloat(i + 1))
            x += (step == .dah) ? -offset : offset
        }
        let y = rowHeight * (CGFloat(path.count) + 0.5)
        return CGPoint(x: x, y: y)
    }

    private func nodeColor(for char: Character) -> Color {
        flashChar == char ? DT.warn : DT.textDim
    }
}
