import SwiftUI

/// A wrapping row — chips and word-by-word prose both need one, and `HStack` can't wrap.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    /// `.firstTextBaseline` sits mixed type sizes on a shared baseline, the way inline text does.
    var alignment: VerticalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(for: subviews, in: width)
        let height =
            rows.reduce(CGFloat.zero) { $0 + self.height(of: $1) }
            + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let dimensions = subviews[index].dimensions(in: .unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + offset(for: dimensions, in: row)),
                    proposal: ProposedViewSize(width: dimensions.width, height: dimensions.height)
                )
                x += dimensions.width + spacing
            }
            y += height(of: row) + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var tallest: CGFloat = 0
        /// Deepest distance from a subview's top to its first baseline, and from that baseline down.
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
    }

    private func height(of row: Row) -> CGFloat {
        alignment == .firstTextBaseline ? row.ascent + row.descent : row.tallest
    }

    private func offset(for dimensions: ViewDimensions, in row: Row) -> CGFloat {
        alignment == .firstTextBaseline
            ? row.ascent - dimensions[.firstTextBaseline]
            : (row.tallest - dimensions.height) / 2
    }

    private func rows(for subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let dimensions = subviews[index].dimensions(in: .unspecified)
            let advance =
                current.indices.isEmpty ? dimensions.width : current.width + spacing + dimensions.width

            if !current.indices.isEmpty, advance > width {
                rows.append(current)
                current = Row(indices: [index], width: dimensions.width)
            } else {
                current.indices.append(index)
                current.width = advance
            }

            let baseline = dimensions[.firstTextBaseline]
            current.tallest = max(current.tallest, dimensions.height)
            current.ascent = max(current.ascent, baseline)
            current.descent = max(current.descent, dimensions.height - baseline)
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
