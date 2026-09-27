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
using vcam::product::ui::MoveFloatingButtonByTranslation;

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

bool TestFreeMoveX() {
    const auto point =
        MoveFloatingButtonByTranslation(
            {160.0, 300.0},
            {47.0, 0.0},
            kBounds,
            kInsets,
            kButton,
            kMargin);

    CHECK(Near(point.x, 207.0));
    CHECK(Near(point.y, 300.0));
    return true;
}

bool TestFreeMoveY() {
    const auto point =
        MoveFloatingButtonByTranslation(
            {180.0, 280.0},
            {0.0, 63.0},
            kBounds,
            kInsets,
            kButton,
            kMargin);

    CHECK(Near(point.x, 180.0));
    CHECK(Near(point.y, 343.0));
    return true;
}

bool TestClampLeft() {
    const auto point =
        ClampFloatingButtonCenter(
            {-100.0, 300.0},
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
    CHECK(Near(point.y, 300.0));
    return true;
}

bool TestClampRight() {
    const auto point =
        ClampFloatingButtonCenter(
            {1000.0, 300.0},
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
    CHECK(Near(point.y, 300.0));
    return true;
}

bool TestClampTop() {
    const auto point =
        ClampFloatingButtonCenter(
            {200.0, -100.0},
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

    CHECK(Near(point.x, 200.0));
    CHECK(Near(point.y, region.minY));
    return true;
}

bool TestClampBottom() {
    const auto point =
        ClampFloatingButtonCenter(
            {200.0, 1000.0},
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

    CHECK(Near(point.x, 200.0));
    CHECK(Near(point.y, region.maxY));
    return true;
}

bool TestArbitraryFinalPositionPreserved() {
    const FloatingButtonPoint expected {
        173.0,
        419.0,
    };
    const auto point =
        MoveFloatingButtonByTranslation(
            expected,
            {0.0, 0.0},
            kBounds,
            kInsets,
            kButton,
            kMargin);

    CHECK(Near(point.x, expected.x));
    CHECK(Near(point.y, expected.y));
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
        "free move x",
        TestFreeMoveX);
    Run(
        "free move y",
        TestFreeMoveY);
    Run(
        "clamp left",
        TestClampLeft);
    Run(
        "clamp right",
        TestClampRight);
    Run(
        "clamp top",
        TestClampTop);
    Run(
        "clamp bottom",
        TestClampBottom);
    Run(
        "arbitrary final position preserved",
        TestArbitraryFinalPositionPreserved);

    std::cout
        << "Floating button geometry tests run: "
        << gTests
        << ", failures: "
        << gFailures
        << std::endl;

    if (gFailures == 0) {
        std::cout
            << "FREE_DRAG_XY=PASS\n"
            << "USER_SELECTED_POSITION_PRESERVED=PASS\n"
            << "SAFE_REACHABLE_BOUNDS=PASS\n"
            << "NO_FORCED_EDGE_SNAP=PASS\n";
    }

    return gFailures == 0 ? 0 : 1;
}
