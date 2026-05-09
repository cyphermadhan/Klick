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
/// Letters (max depth 4) are rendered with their label. Digits and
/// punctuation (depth 5–6) are still reachable via keying and show up as
/// the active path highlight, but we don't paint the full sub-tree — the
/// density past depth 4 doesn't fit on an iPhone screen without scrolling,
/// and this keeps the reference tree legible.
struct MorseTreeView: View {
    @ObservedObject var tree: MorseTree
    /// Character that should briefly glow orange. The parent sets this
    /// on commit (via `.onChange` of `tree.buffer`) and clears it after
    /// a short delay — matching the keychain's "A" flash state.
    var flashChar: Character?

    /// Letters max out at depth 4 of the ITU tree. Past this we stop
    /// drawing the ghost tree, but the live path still animates into the
    /// empty space below for punctuation-length inputs.
    private let labelledDepth = 4

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
        let rowHeight = size.height / CGFloat(labelledDepth + 1)
        drawGhostTree(ctx: ctx, size: size, rowHeight: rowHeight)
        drawActivePath(ctx: ctx, size: size, rowHeight: rowHeight)
        drawRoot(ctx: ctx, rowHeight: rowHeight, size: size)
    }

    /// Dim reference drawing of every letter — the "keychain" layer.
    private func drawGhostTree(ctx: GraphicsContext, size: CGSize, rowHeight: CGFloat) {
        let rootCenter = CGPoint(x: size.width / 2, y: rowHeight / 2)

        for (char, path) in MorseCode.alphabet where path.count <= labelledDepth {
            // Edges: parent → child, drawn incrementally so overlapping
            // trunks don't require a separate "visited" set.
            var from = rootCenter
            for i in 0..<path.count {
                let to = position(for: Array(path.prefix(i + 1)), size: size, rowHeight: rowHeight)
                var line = Path()
                line.move(to: from)
                line.addLine(to: to)
                ctx.stroke(line, with: .color(DT.textFaint), lineWidth: 0.5)
                from = to
            }

            let p = position(for: path, size: size, rowHeight: rowHeight)
            drawNodeShape(ctx: ctx, at: p, last: path.last, color: nodeColor(for: char),
                          filled: flashChar == char, side: 18)
            let label = Text(String(char))
                .font(DT.mono(9, weight: .bold))
                .foregroundColor(flashChar == char ? DT.warn : DT.textDim)
            ctx.draw(label, at: p)
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

        // Emphasize the terminal (currently-keyed) node.
        let terminal = position(for: tree.currentPath, size: size, rowHeight: rowHeight)
        drawNodeShape(ctx: ctx, at: terminal, last: tree.currentPath.last,
                      color: color, filled: true, side: 22)
        if let char = tree.currentLetter {
            let label = Text(String(char))
                .font(DT.mono(11, weight: .heavy))
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
