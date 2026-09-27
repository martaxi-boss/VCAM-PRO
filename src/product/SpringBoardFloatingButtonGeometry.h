#pragma once

#include <algorithm>

namespace vcam::product::ui {

struct FloatingButtonPoint {
    double x = 0.0;
    double y = 0.0;
};

struct FloatingButtonSize {
    double width = 0.0;
    double height = 0.0;
};

struct FloatingButtonInsets {
    double top = 0.0;
    double left = 0.0;
    double bottom = 0.0;
    double right = 0.0;
};

struct FloatingButtonBounds {
    double width = 0.0;
    double height = 0.0;
};

struct FloatingButtonSafeRegion {
    double minX = 0.0;
    double maxX = 0.0;
    double minY = 0.0;
    double maxY = 0.0;
};

inline FloatingButtonSafeRegion
MakeFloatingButtonSafeRegion(
    FloatingButtonBounds bounds,
    FloatingButtonInsets insets,
    FloatingButtonSize button,
    double margin) noexcept {
    const double safeMargin =
        std::max(0.0, margin);
    const double halfWidth =
        std::max(0.0, button.width) * 0.5;
    const double halfHeight =
        std::max(0.0, button.height) * 0.5;

    double minX =
        std::max(0.0, insets.left) +
        safeMargin +
        halfWidth;
    double maxX =
        std::max(0.0, bounds.width) -
        std::max(0.0, insets.right) -
        safeMargin -
        halfWidth;

    double minY =
        std::max(0.0, insets.top) +
        safeMargin +
        halfHeight;
    double maxY =
        std::max(0.0, bounds.height) -
        std::max(0.0, insets.bottom) -
        safeMargin -
        halfHeight;

    if (maxX < minX) {
        const double midpoint =
            std::max(0.0, bounds.width) * 0.5;
        minX = midpoint;
        maxX = midpoint;
    }

    if (maxY < minY) {
        const double midpoint =
            std::max(0.0, bounds.height) * 0.5;
        minY = midpoint;
        maxY = midpoint;
    }

    return {
        minX,
        maxX,
        minY,
        maxY,
    };
}

inline FloatingButtonPoint
ClampFloatingButtonCenter(
    FloatingButtonPoint point,
    FloatingButtonBounds bounds,
    FloatingButtonInsets insets,
    FloatingButtonSize button,
    double margin) noexcept {
    const auto region =
        MakeFloatingButtonSafeRegion(
            bounds,
            insets,
            button,
            margin);

    return {
        std::clamp(
            point.x,
            region.minX,
            region.maxX),
        std::clamp(
            point.y,
            region.minY,
            region.maxY),
    };
}

inline FloatingButtonPoint
MoveFloatingButtonByTranslation(
    FloatingButtonPoint current,
    FloatingButtonPoint translation,
    FloatingButtonBounds bounds,
    FloatingButtonInsets insets,
    FloatingButtonSize button,
    double margin) noexcept {
    return
        ClampFloatingButtonCenter(
            {
                current.x + translation.x,
                current.y + translation.y,
            },
            bounds,
            insets,
            button,
            margin);
}

}  // namespace vcam::product::ui
