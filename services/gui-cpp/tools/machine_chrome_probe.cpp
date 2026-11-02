#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "machines/limits.hpp"
#include "presentation/machine_chrome_geometry.hpp"
#include "probe_io.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <span>

namespace {

using namespace telar::gui;
using namespace telar::gui::probe;
using Geometry = MachineChromeGeometry;

enum class Event : std::uint8_t { end, fill, text, band };
constexpr std::uint8_t picker = 255;

struct Fixture {
  bool segment = false;
  ChromeMetrics chrome;
  Rect area;
  std::uint8_t count = 0;
  std::uint8_t active = 0;
  std::uint32_t attention = 0;
  float more = 0;
  float fold = 0;
  std::array<float, MachineLimits::window_slots> advances{};
};

void rectangle(Event event, Rect area) {
  write(event);
  write(area.x);
  write(area.y);
  write(area.width);
  write(area.height);
}

void control(const Geometry::Control &value, bool active, bool attention, std::uint8_t target) {
  if (active) {
    rectangle(Event::fill, value.bounds);
  }

  rectangle(Event::text, value.label);
  if (attention) {
    rectangle(Event::fill, value.attention);
  }

  rectangle(Event::band, value.bounds);
  write(target);
  if (!value.disc.empty()) {
    rectangle(Event::fill, value.disc);
  }
}

void scene(const Fixture &fixture) {
  if (fixture.segment) {
    write(Geometry::preferredSegment(fixture.chrome, fixture.advances.at(fixture.active)));
    if (fixture.count > 1 && !fixture.area.empty()) {
      const bool attention = (fixture.attention & ~(std::uint32_t{1} << fixture.active)) != 0;
      control(Geometry::control(fixture.area, fixture.chrome, Geometry::Kind::segment, 0, attention), false, attention, picker);
    }
  } else {
    write(0.0F);
    const auto row = Geometry::switcher(fixture.area, fixture.chrome, std::span{fixture.advances}.first(fixture.count), fixture.more);
    for (std::size_t index = 0; index < row.count; ++index) {
      const bool active = index == fixture.active;
      const bool attention = !active && (fixture.attention & (std::uint32_t{1} << index)) != 0;
      control(Geometry::control(row.controls[index], fixture.chrome, Geometry::Kind::switcher, 0, attention), active, attention, static_cast<std::uint8_t>(index));
    }

    if (row.hidden != 0 && !row.fold.empty()) {
      control(Geometry::control(row.fold, fixture.chrome, Geometry::Kind::fold, fixture.fold, false), false, false, picker);
    }
  }

  write(Event::end);
}

Fixture readFixture() {
  Fixture fixture;
  fixture.segment = read<std::uint8_t>() != 0;
  fixture.chrome.ratio = read<float>();
  fixture.area = {.x = read<float>(), .y = read<float>(), .width = read<float>(), .height = read<float>()};
  fixture.count = read<std::uint8_t>();
  fixture.active = read<std::uint8_t>();
  fixture.attention = read<std::uint32_t>();
  fixture.more = read<float>();
  fixture.fold = read<float>();
  for (auto &advance : fixture.advances) {
    advance = read<float>();
  }

  return fixture;
}

}

int main() {
  try {
    while (std::getchar() != EOF) {
      scene(readFixture());
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
