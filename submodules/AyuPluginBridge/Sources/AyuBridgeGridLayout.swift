import CoreGraphics

/// Child placement of a horizontal `android.widget.GridLayout` whose cells span one row and one
/// column and carry no weight (`GridLayout.spec(index)` or the default spec).
/// Not modelled: spans, weights, explicit alignments, default margins, baseline alignment of a row.
enum AyuBridgeGridLayout {
    enum AlignmentMode: Int { case bounds = 0, margins = 1 }

    struct Child: Equatable {
        var row: Int?
        var column: Int?
        var size: CGSize
        var left: CGFloat = 0
        var top: CGFloat = 0
        var right: CGFloat = 0
        var bottom: CGFloat = 0
    }

    struct Cell: Equatable {
        var row: Int
        var column: Int
    }

    struct Placement: Equatable {
        var size: CGSize
        var frames: [CGRect]
    }

    /// `GridLayout.validateLayoutParams` for the horizontal orientation; nil where Android throws
    /// `IllegalArgumentException` (an index outside a defined count).
    static func cells(_ children: [Child], rowCount: Int?, columnCount: Int?) -> [Cell]? {
        let count = max(columnCount ?? 0, 0)
        var major = 0
        var minor = 0
        var maxSizes = [Int](repeating: 0, count: count)
        var result: [Cell] = []
        for child in children {
            if let row = child.row {
                guard row >= 0 else { return nil }
                major = row
            }
            if let column = child.column {
                guard column >= 0, count == 0 || column < count else { return nil }
                minor = column
            }
            if count != 0, child.row == nil || child.column == nil {
                while minor + 1 > count || maxSizes[minor] > major {
                    if child.column != nil {
                        major += 1
                    } else if minor + 1 <= count {
                        minor += 1
                    } else {
                        minor = 0
                        major += 1
                    }
                }
            }
            if minor < count { maxSizes[minor] = major + 1 }
            if let rowCount, major >= rowCount { return nil }
            result.append(Cell(row: major, column: minor))
            minor += 1
        }
        return result
    }

    static func place(_ children: [Child], rowCount: Int?, columnCount: Int?, alignmentMode: AlignmentMode = .margins) -> Placement? {
        guard let cells = self.cells(children, rowCount: rowCount, columnCount: columnCount) else { return nil }
        let columns = max(columnCount ?? 0, (cells.map(\.column).max() ?? -1) + 1)
        let rows = max(rowCount ?? 0, (cells.map(\.row).max() ?? -1) + 1)
        var left = children.map(\.left), right = children.map(\.right), top = children.map(\.top), bottom = children.map(\.bottom)
        if alignmentMode == .bounds {
            // ALIGN_BOUNDS: every child of a column (row) takes the largest margin found at that edge.
            var leading = [CGFloat](repeating: 0, count: columns), trailing = leading
            var above = [CGFloat](repeating: 0, count: rows), below = above
            for (index, cell) in cells.enumerated() {
                leading[cell.column] = max(leading[cell.column], left[index])
                trailing[cell.column] = max(trailing[cell.column], right[index])
                above[cell.row] = max(above[cell.row], top[index])
                below[cell.row] = max(below[cell.row], bottom[index])
            }
            for (index, cell) in cells.enumerated() {
                left[index] = leading[cell.column]
                right[index] = trailing[cell.column]
                top[index] = above[cell.row]
                bottom[index] = below[cell.row]
            }
        }
        var widths = [CGFloat](repeating: 0, count: columns)
        var heights = [CGFloat](repeating: 0, count: rows)
        for (index, cell) in cells.enumerated() {
            widths[cell.column] = max(widths[cell.column], children[index].size.width + left[index] + right[index])
            heights[cell.row] = max(heights[cell.row], children[index].size.height + top[index] + bottom[index])
        }
        var x = [CGFloat](repeating: 0, count: columns + 1)
        var y = [CGFloat](repeating: 0, count: rows + 1)
        for column in 0..<columns { x[column + 1] = x[column] + widths[column] }
        for row in 0..<rows { y[row + 1] = y[row] + heights[row] }
        let frames = cells.enumerated().map { index, cell in
            CGRect(origin: CGPoint(x: x[cell.column] + left[index], y: y[cell.row] + top[index]), size: children[index].size)
        }
        return Placement(size: CGSize(width: x[columns], height: y[rows]), frames: frames)
    }
}
