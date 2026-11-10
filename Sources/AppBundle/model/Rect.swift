import AppKit
import Common

struct Rect: Withable, AeroAny, Equatable {
    var topLeftX: CGFloat
    var topLeftY: CGFloat

    private var _width: CGFloat
    var width: CGFloat {
        get { max(_width, 0) }
        set(newValue) { _width = newValue }
    }

    private var _height: CGFloat
    var height: CGFloat {
        get { max(_height, 0) }
        set(newValue) { _height = newValue }
    }

    init(topLeftX: CGFloat, topLeftY: CGFloat, width: CGFloat, height: CGFloat) {
        self.topLeftX = topLeftX
        self.topLeftY = topLeftY
        self._width = width
        self._height = height
    }
}

extension CGRect {
    func toRect() -> Rect {
        Rect(topLeftX: minX, topLeftY: maxY, width: width, height: height)
    }
}

extension Rect {
    func contains(_ point: CGPoint) -> Bool {
        minX.until(excl: maxX)?.contains(point.x) == true && minY.until(excl: maxY)?.contains(point.y) == true
    }

    var center: CGPoint {
        CGPoint(x: topLeftX + width / 2, y: topLeftY + height / 2)
    }

    var topLeftCorner: CGPoint { CGPoint(x: topLeftX, y: topLeftY) }
    // periphery:ignore
    var topRightCorner: CGPoint { CGPoint(x: maxX, y: minY) }
    var bottomRightCorner: CGPoint { CGPoint(x: maxX, y: maxY) }
    var bottomLeftCorner: CGPoint { CGPoint(x: minX, y: maxY) }

    var minY: CGFloat { topLeftY }
    var maxY: CGFloat { topLeftY + height }
    var minX: CGFloat { topLeftX }
    var maxX: CGFloat { topLeftX + width }

    var size: CGSize { CGSize(width: width, height: height) }

    func getDimension(_ orientation: Orientation) -> CGFloat { orientation == .h ? width : height }

    func inset(by outer: ResolvedGaps.Outer) -> Rect {
        Rect(
            topLeftX: topLeftX + outer.left.toDouble(),
            topLeftY: topLeftY + outer.top.toDouble(),
            width: width - outer.left.toDouble() - outer.right.toDouble(),
            height: height - outer.top.toDouble() - outer.bottom.toDouble(),
        )
    }

    func intersection(_ other: Rect) -> Rect {
        let minX = max(self.minX, other.minX)
        let minY = max(self.minY, other.minY)
        return Rect(
            topLeftX: minX,
            topLeftY: minY,
            width: min(maxX, other.maxX) - minX,
            height: min(maxY, other.maxY) - minY,
        )
    }

    /// Moves inside `bounds` without resizing. When bigger than `bounds`, the top-left corner wins
    func clamped(in bounds: Rect) -> Rect {
        Rect(
            topLeftX: topLeftX.coerce(in: bounds.minX ... max(bounds.minX, bounds.maxX - width)),
            topLeftY: topLeftY.coerce(in: bounds.minY ... max(bounds.minY, bounds.maxY - height)),
            width: width,
            height: height,
        )
    }
}
