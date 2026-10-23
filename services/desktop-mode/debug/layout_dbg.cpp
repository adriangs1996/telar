// Prints how the workbench layout arranges a tab: a pane and four other applications' windows
// arriving one after another, halving the focused element as a user's split does and filling
// the area as a grid as adoption does, then with the narrowest window keeping a minimum width
// larger than its share, as an application that refuses a smaller size does.

#include "ui/workbench/layout.hpp"
#include <cstdio>
#include <string>

namespace {
  using workbench::Element;
  using workbench::Layout;

  constexpr QRectF area{0, 0, 3530, 2100};
  constexpr double gap = 8;
  constexpr double scale = 2;
  constexpr double kept_width = 1200;

  void print(const char *label, const Layout &layout) {
    std::printf("%s\n", label);
    for (const auto &placement : layout.arrange(area, gap, scale)) {
      std::printf("  %-12s x %6.0f y %6.0f  %6.0f x %6.0f\n",
                  qPrintable(placement.id),
                  placement.frame.x(),
                  placement.frame.y(),
                  placement.frame.width(),
                  placement.frame.height());
    }
  }

  Layout tab(bool grid) {
    Layout layout;
    layout.insert({"pane:1"});
    layout.focus("pane:1");
    for (const auto *name : {"spotify", "gather", "chrome", "telar"}) {
      Element element{QString("window:") + name, workbench::ContentKind::external};
      if (grid) {
        layout.insertBesideLargest(element, area, gap);
      } else {
        layout.insert(element);
      }
    }

    return layout;
  }
} // namespace

int main() {
  print("halving the focused element (before)", tab(false));
  auto layout = tab(true);
  print("beside the largest element (adoption)", layout);
  layout.element("window:telar")->constraints.minimum.setWidth(kept_width);
  print("telar keeps 1200 points of width", layout);
  return 0;
}
