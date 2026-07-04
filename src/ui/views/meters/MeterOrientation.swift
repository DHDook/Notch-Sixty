import Foundation

/// Orientation mode for meter bars.
enum MeterOrientation {
    case vertical                // bottom-anchored, grows up
    case horizontalGrowingLeft   // anchored at trailing (right) edge, grows toward leading (left)
    case horizontalGrowingRight  // anchored at leading (left) edge, grows toward trailing (right)
}
