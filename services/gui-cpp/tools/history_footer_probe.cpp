#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "core/theme_values.hpp"
#include "presentation/history_actions.hpp"
#include "presentation/history_footer.hpp"
#include "presentation/history_footer_geometry.hpp"
#include "probe_geometry.hpp"
#include "probe_history_hint.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>

namespace {

using namespace telar::gui;

enum class Flag : std::uint8_t {
  enter_runs = 1,
  inspecting = 2,
  has_more = 4,
  fuzzy = 8,
};

bool contains(std::uint8_t flags, Flag flag) noexcept {
  return (flags & static_cast<std::uint8_t>(flag)) != 0;
}

void footer(SystemAllocator &memory) {
  const auto area = probe::readRect();
  ChromeMetrics chrome;
  chrome.ratio = probe::read<float>();
  chrome.small = probe::read<std::uint16_t>();
  const auto style = probe::read<HistoryKeyStyle>();
  const auto flags = probe::read<std::uint8_t>();
  const auto offset = probe::read<std::uint32_t>();
  const auto count = probe::read<std::uint16_t>();
  const auto error = probe::readText(memory);
  const auto query = probe::readText(memory);
  const HistoryFooterOptions options{
      .key_style = style,
      .offset = offset,
      .count = count,
      .inspecting = contains(flags, Flag::inspecting),
      .enter_runs = contains(flags, Flag::enter_runs),
      .has_more = contains(flags, Flag::has_more),
      .fuzzy = contains(flags, Flag::fuzzy),
      .has_query = !query.empty(),
  };
  const auto footer = HistoryFooter::resolve(options);
  const auto range = HistoryFooter::range(options);
  HistoryFooterMeasurements measured;
  for (auto &hint : measured.hints) {
    hint = {.key = probe::read<float>(), .word = probe::read<float>()};
  }

  measured.count = footer.count;
  measured.range = probe::read<float>();
  measured.empty = count == 0;
  measured.error = !error.empty();
  const auto layout = HistoryFooterGeometry::derive(area, chrome, measured);

  probe::write(static_cast<std::uint8_t>(footer.count));
  for (std::size_t index = 0; index < footer.count; ++index) {
    const auto hint = footer.hints[index];
    probe::writeText(hint.key);
    probe::writeText(hint.word);
    probe::write(hint.action);
  }

  if (!layout.separator.empty()) {
    probe::write(probe::HistoryDrawEvent::fill);
    probe::writeRect(layout.separator);
    probe::writeText("surface1");
  }

  if (layout.error_visible) {
    if (!layout.error.empty()) {
      probe::writeHistoryLabel(layout.error, error, PaletteRole::red, 1);
    }
  } else {
    for (std::size_t index = 0; index < layout.count; ++index) {
      if (!layout.hints[index].bounds.empty()) {
        probe::writeHistoryHint(layout.hints[index], chrome, footer.hints[index]);
      }
    }

    if (layout.range_visible) {
      probe::writeHistoryLabel(layout.range, range.view(), PaletteRole::subtext0, 1);
    }
  }

  probe::write(probe::HistoryDrawEvent::end);
}

}

int main() try {
  SystemAllocator memory;
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return 0;
    }

    if (operation != 0) {
      return 1;
    }

    footer(memory);
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
