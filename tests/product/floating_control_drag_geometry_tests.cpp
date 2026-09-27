#include "SpringBoardFloatingButtonGeometry.h"

#include <cmath>
#include <functional>
#include <iostream>

namespace {

using vcam::product::ui::ClampFloatingButtonCenter;
using vcam::product::ui::FloatingButtonBounds;
using vcam::product::ui::FloatingButtonInsets;
using vcam::product::ui::FloatingButtonPoint;
using vcam::product::ui::FloatingButtonSize;
using vcam::product::ui::MakeFloatingButtonSafeRegion;
using vcam::product::ui::SnapFloatingButtonCenterToNearestEdge;

int gTests = 0;
int gFailures = 0;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::cerr << "CHECK failed at " \
                      << __FILE__ << ":" \
                      << __LINE__ << ": " \
                      << #condition << std::endl; \
            return false; \
        } \
    } while (false)

bool Near(
    double left,
    double right) {
    return std::fabs(left - right) <
        0.0001;
}

constexpr FloatingButtonBounds kBounds {
    414.0,
    736.0,
};
constexpr FloatingButtonInsets kInsets {
    20.0,
    0.0,
    34.0,
    0.0,
};
constexpr FloatingButtonSize kButton {
    56.0,
    56.0,
};
constexpr double kMargin = 10.0;

bool TestClampLeftTop() {
    const auto point =
        ClampFloatingButtonCenter(
            {-100.0, -100.0},
            kBounds,
            kInsets,
            kButton,
            kMargin);
    const auto region =
        MakeFloatingButtonSafeRegion(
            kBounds,
            kInsets,
            kButton,
            kMargin);

    CHECK(Near(point.x, region.minX));
    CHECK(Near(point.y, region.minY));
    return true;
}

bool TestClampRightBottom() {
    const auto point =
        ClampFloatingButtonCenter(
            {1000.0, 1000.0},
            kBounds,
            kInsets,
            kButton,
            kMargin);
    const auto region =
        MakeFloatingButtonSafeRegion(
            kBounds,
            kInsets,
            kButton,
            kMargin);

    CHECK(Near(point.x, region.maxX));
    CHECK(Near(point.y, region.maxY));
    return true;
}

bool TestInsidePositionPreserved() {
    const FloatingButtonPoint expected {
        180.0,
        300.0,
    };
    const auto point =
        ClampFloatingButtonCenter(
            expected,
            kBounds,
            kInsets,
            kButton,
            kMargin);

    CHECK(Near(point.x, expected.x));
    CHECK(Near(point.y, expected.y));
    return true;
}

bool TestSnapLeftPreservesVertical() {
    const auto point =
        SnapFloatingButtonCenterToNearestEdge(
            {120.0, 333.0},
            kBounds,
            kInsets,
            kButton,
            kMargin);
    const auto region =
        MakeFloatingButtonSafeRegion(
            kBounds,
            kInsets,
            kButton,
            kMargin);

    CHECK(Near(point.x, region.minX));
    CHECK(Near(point.y, 333.0));
    return true;
}

bool TestSnapRightPreservesVertical() {
    const auto point =
        SnapFloatingButtonCenterToNearestEdge(
            {330.0, 410.0},
            kBounds,
            kInsets,
            kButton,
            kMargin);
    const auto region =
        MakeFloatingButtonSafeRegion(
            kBounds,
            kInsets,
            kButton,
            kMargin);

    CHECK(Near(point.x, region.maxX));
    CHECK(Near(point.y, 410.0));
    return true;
}

bool TestNarrowBoundsRemainValid() {
    const FloatingButtonBounds bounds {
        40.0,
        44.0,
    };
    const FloatingButtonInsets insets {
        10.0,
        10.0,
        10.0,
        10.0,
    };
    const FloatingButtonSize button {
        56.0,
        56.0,
    };

    const auto region =
        MakeFloatingButtonSafeRegion(
            bounds,
            insets,
            button,
            10.0);
    const auto point =
        ClampFloatingButtonCenter(
            {-50.0, 500.0},
            bounds,
            insets,
            button,
            10.0);

    CHECK(Near(region.minX, region.maxX));
    CHECK(Near(region.minY, region.maxY));
    CHECK(Near(point.x, region.minX));
    CHECK(Near(point.y, region.minY));
    return true;
}

void Run(
    const char* name,
    const std::function<bool()>& test) {
    ++gTests;
    const bool passed = test();

    std::cout
        << (passed ? "PASS " : "FAIL ")
        << name
        << std::endl;

    if (!passed) {
        ++gFailures;
    }
}

}  // namespace

int main() {
    Run(
        "clamp left top",
        TestClampLeftTop);
    Run(
        "clamp right bottom",
        TestClampRightBottom);
    Run(
        "inside position preserved",
        TestInsidePositionPreserved);
    Run(
        "snap left preserves vertical",
        TestSnapLeftPreservesVertical);
    Run(
        "snap right preserves vertical",
        TestSnapRightPreservesVertical);
    Run(
        "narrow bounds remain valid",
        TestNarrowBoundsRemainValid);

    std::cout
        << "Floating button geometry tests run: "
        << gTests
        << ", failures: "
        << gFailures
        << std::endl;

    if (gFailures == 0) {
        std::cout
            << "SAFE_SCREEN_BOUNDS=PASS\n"
            << "EDGE_SNAP=PASS\n";
    }

    return gFailures == 0 ? 0 : 1;
}
