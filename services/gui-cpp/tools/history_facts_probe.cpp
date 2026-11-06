#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "../core/memory.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include <bit>
#include <stdexcept>
#include <ghostty/vt/unicode.h>
#include <limits>
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include "probe_geometry.hpp"
#include "probe_history_hint.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include <cstdio>
#include <exception>
#include <iostream>

#include "core/memory.hpp"


import telar.gui.core.metrics;
import telar.gui.presentation.history_filter_geometry;
import telar.gui.presentation.history_meta_geometry;
import telar.gui.presentation.history_inspection;

namespace {

using namespace telar::gui;

enum class Operation : std::uint8_t {
  path,
  meta,
  hint,
};

using Event = probe::HistoryDrawEvent;

enum class Flag : std::uint8_t {
  selected = 1,
  pane_open = 2,
  loaded = 4,
  show_directory = 8,
  truncated = 16,
  has_exit = 32,
  agent = 64,
  has_time = 128,
};

bool contains(std::uint16_t flags, Flag value) noexcept {
  return (flags & static_cast<std::uint16_t>(value)) != 0;
}

std::int64_t saturatingSubtract(std::int64_t left, std::int64_t right) noexcept {
  if (right > 0 && left < std::numeric_limits<std::int64_t>::min() + right) {
    return std::numeric_limits<std::int64_t>::min();
  }

  if (right < 0 && left > std::numeric_limits<std::int64_t>::max() + right) {
    return std::numeric_limits<std::int64_t>::max();
  }

  return left - right;
}

void meta(SystemAllocator &memory) {
  const auto style = probe::read<HistoryKeyStyle>();
  const auto bounds = probe::readRect();
  ChromeMetrics chrome;
  chrome.ratio = probe::read<float>();
  chrome.small = probe::read<std::uint16_t>();
  const auto flags = probe::read<std::uint16_t>();
  const auto status = probe::read<telar::HistoryStatus>();
  const auto exit_code = probe::read<std::int32_t>();
  const auto duration_ns = probe::read<std::int64_t>();
  const auto now_ms = probe::read<std::int64_t>();
  const auto started_ms = probe::read<std::int64_t>();
  const auto more = probe::read<std::uint16_t>();
  const auto directory = probe::readText(memory);
  const auto provider = probe::readText(memory);
  const auto path = HistoryPath::compact(directory);
  const auto duration = HistoryLabels::duration(duration_ns);
  const auto age = HistoryLabels::age(saturatingSubtract(now_ms, started_ms));
  const HistoryFactData data{
      .directory = path.view(),
      .provider = provider,
      .duration = duration.view(),
      .age = age.view(),
      .exit_code = contains(flags, Flag::has_exit) ? std::optional{exit_code} : std::nullopt,
      .status = status,
      .key_style = style,
      .more = more,
      .truncated = contains(flags, Flag::truncated),
      .loaded = contains(flags, Flag::loaded),
      .show_directory = contains(flags, Flag::show_directory) && !directory.empty(),
      .has_time = contains(flags, Flag::has_time),
      .agent = contains(flags, Flag::agent),
  };
  HistoryMetaMeasurements measured;
  for (auto &width : measured.facts) {
    width = probe::read<float>();
  }

  for (auto &action : measured.actions) {
    action = {.key = probe::read<float>(), .word = probe::read<float>()};
  }

  measured.selected = contains(flags, Flag::selected);
  measured.pane_open = contains(flags, Flag::pane_open);
  auto count = [&](std::string_view, PaletteRole) {
    ++measured.fact_count;
  };
  HistoryFacts::visit(data, count);
  const auto layout = HistoryMetaGeometry::derive(bounds, chrome, measured);
  const auto labels = HistoryActions::labels(style);
  for (std::size_t index = 0; index < layout.action_count; ++index) {
    probe::writeHistoryHint(layout.actions[index], chrome, labels[index]);
  }

  std::size_t index = 0;
  auto write = [&](std::string_view text, PaletteRole color) {
    if (index < layout.fact_count) {
      probe::writeHistoryLabel(layout.facts[index], text, color, 1);
    }

    ++index;
  };
  HistoryFacts::visit(data, write);
  probe::write(Event::end);
}

void hint() {
  const auto style = probe::read<HistoryKeyStyle>();
  const auto bounds = probe::readRect();
  ChromeMetrics chrome;
  chrome.ratio = probe::read<float>();
  chrome.small = probe::read<std::uint16_t>();
  const HistoryHintMeasurements measured{.key = probe::read<float>(), .word = probe::read<float>()};
  probe::write(HistoryHintGeometry::width(chrome, measured));
  if (!bounds.empty()) {
    probe::writeHistoryHint(HistoryHintGeometry::derive(bounds, chrome, measured), chrome, HistoryActions::labels(style).front());
  }

  probe::write(Event::end);
}

}

int main() try {
  SystemAllocator memory;
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return 0;
    }

    switch (static_cast<Operation>(operation)) {
    case Operation::path:
      probe::writeText(HistoryPath::compact(probe::readText(memory)).view());
      break;
    case Operation::meta:
      meta(memory);
      break;
    case Operation::hint:
      hint();
      break;
    default:
      return 1;
    }
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
