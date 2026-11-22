import UIKit

/// Visibility and clipping for a supplied, typed surface. This never discovers backgrounds or changes app clipping.
@MainActor public enum AtmosphericSurfaceLayout {
    public static func hierarchyAllowsDecoration(in container: UIView, minimumScale: CGFloat = 0.15) -> Bool {
        var ancestor: UIView? = container
        for _ in 0 ..< 3 {
            guard let view = ancestor else {
                break
            }
            let transform = view.layer.transform
            let sublayerTransform = view.layer.sublayerTransform
            if view.isHidden || view.alpha <= 0.05
                || hypot(transform.m11, transform.m12) <= minimumScale
                || hypot(transform.m21, transform.m22) <= minimumScale
                || hypot(sublayerTransform.m11, sublayerTransform.m12) <= minimumScale
                || hypot(sublayerTransform.m21, sublayerTransform.m22) <= minimumScale {
                return false
            }
            ancestor = view.superview
        }
        return true
    }

    /// The existing ancestor clips and the owner's own window are authoritative, including a scrolled viewport.
    public static func clippedRect(_ rect: CGRect, in container: UIView) -> CGRect {
        guard let window = container.window, !rect.isEmpty else {
            return .null
        }
        var result = rect.intersection(container.convert(window.bounds, from: window))
        var ancestor: UIView? = container
        while let view = ancestor {
            if view.clipsToBounds {
                result = result.intersection(container.convert(view.bounds, from: view))
            }
            ancestor = view.superview
        }
        return result
    }

    public static func actionHasVisibleArea(_ rect: CGRect, in container: UIView) -> Bool {
        let clipped = self.clippedRect(rect, in: container)
        return !clipped.isNull && clipped.width >= 12.0 && clipped.height >= 14.0
            && clipped.height >= rect.height * 0.65
    }
}
