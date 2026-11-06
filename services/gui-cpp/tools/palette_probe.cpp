#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include "../core/terminal_size.hpp"
#include <span>
#include <stdexcept>
#include <tuple>
#include <bit>
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include <utility>

#include "probe_io.hpp"
#include <cstdio>
#include <exception>
#include <iostream>




import telar.gui.core.metrics;
import telar.gui.input.key_encoder;
import telar.gui.palette.navigation_label;
import telar.gui.presentation.suggestion_geometry;

import telar.gui.config.gui_query;

namespace {

using namespace telar::gui;
using probe::read;
using probe::write;

enum class Operation : std::uint8_t {
  query = 1,
  label,
  ranking,
  geometry,
  catalogue,
  key_label,
};

enum class LabelKind : std::uint8_t {
  workspace,
  tab,
  agent,
};

constexpr std::size_t maximum_text_bytes = 1024;
constexpr std::size_t maximum_results = 192;
using Buffer = std::array<char, maximum_text_bytes>;

std::string_view readText(Buffer &buffer) {
  const auto length = read<std::uint16_t>();
  if (length > buffer.size() || std::fread(buffer.data(), 1, length, stdin) != length) {
    throw std::runtime_error{"InvalidPaletteText"};
  }

  return {buffer.data(), length};
}

void writeText(std::string_view text) {
  write(static_cast<std::uint16_t>(text.size()));
  if (std::fwrite(text.data(), 1, text.size(), stdout) != text.size()) {
    throw std::runtime_error{"PaletteTextWriteFailed"};
  }
}

void query() {
  Buffer buffer{};
  const auto parsed = PaletteQuery::parse(readText(buffer));
  write(static_cast<std::uint8_t>(parsed.mode));
  writeText(parsed.text);
}

void label() {
  const auto kind = read<LabelKind>();
  Buffer first{};
  Buffer second{};
  Buffer third{};
  const auto primary = readText(first);
  const auto detail = readText(second);
  const auto context = readText(third);
  NavigationLabel result;
  if (kind == LabelKind::tab) {
    result.append(NavigationLabel::tab_prefix);
  }

  result.append(primary);
  if (kind != LabelKind::tab) {
    result.appendDetail(detail);
  }

  if (kind == LabelKind::agent) {
    result.appendDetail(context);
  }

  writeText(result.view());
}

void ranking() {
  Buffer query_buffer{};
  Buffer label_buffer{};
  const auto needle = readText(query_buffer);
  const auto count = read<std::uint16_t>();
  RankedMatches<std::uint16_t, maximum_results> matches;
  for (std::uint16_t index = 0; index < count; ++index) {
    matches.add(index, readText(label_buffer), needle);
  }

  write(static_cast<std::uint16_t>(matches.rows().size()));
  for (const auto &match : matches.rows()) {
    write(match.target);
    write(match.score);
  }
}

void catalogue() {
  Buffer query_buffer{};
  const auto needle = readText(query_buffer);
  RankedMatches<std::uint16_t, palette_actions.size()> matches;
  for (std::size_t index = 0; index < palette_actions.size(); ++index) {
    matches.add(static_cast<std::uint16_t>(index), palette_actions[index].label, needle);
  }

  write(static_cast<std::uint16_t>(matches.rows().size()));
  for (const auto &match : matches.rows()) {
    write(match.target);
    writeText(palette_actions[match.target].label);
    write(match.score);
  }
}

KeyChord readChord() {
  const auto key = read<KeyChord::Key>();
  const auto character = read<std::uint32_t>();
  const auto modifiers = read<std::uint32_t>();

  return {.key = key, .character = character, .modifiers = modifiers};
}

void keyLabel() {
  const auto style = read<KeyLabelStyle>();
  const auto has_prefix = read<std::uint8_t>() != 0;
  const auto prefix = readChord();
  const auto key = readChord();
  const auto text = KeyLabel::chord(has_prefix ? std::optional{prefix} : std::nullopt, key, style);
  writeText(text.view());
}

void geometry() {
  const auto width = read<std::uint32_t>();
  const auto height = read<std::uint32_t>();
  ChromeMetrics chrome;
  chrome.ratio = read<float>();
  chrome.title = read<std::uint16_t>();
  chrome.body = read<std::uint16_t>();
  chrome.small = read<std::uint16_t>();
  const auto pick = read<std::uint8_t>() != 0;
  const auto rows = read<std::uint16_t>();
  const auto suggest = read<std::uint8_t>() != 0;
  const PaletteGeometry::Options options{.pick_rows = pick ? std::optional{rows} : std::nullopt, .suggest = suggest};
  const auto layout = PaletteGeometry::measure({.width = static_cast<float>(width), .height = static_cast<float>(height)}, chrome, options);
  for (const auto bounds : {layout.viewport, layout.bounds, layout.heading, layout.search, layout.tabs, layout.results, layout.footer}) {
    write(bounds.x);
    write(bounds.y);
    write(bounds.width);
    write(bounds.height);
  }

  write(layout.row_height);
  write(layout.agent_height);
  write(layout.group_height);
}

}

int main() {
  try {
    Operation operation = Operation::query;
    while (std::fread(&operation, sizeof(operation), 1, stdin) == 1) {
      switch (operation) {
      case Operation::query:
        query();
        break;
      case Operation::label:
        label();
        break;
      case Operation::ranking:
        ranking();
        break;
      case Operation::geometry:
        geometry();
        break;
      case Operation::catalogue:
        catalogue();
        break;
      case Operation::key_label:
        keyLabel();
        break;
      default:
        throw std::runtime_error{"UnknownPaletteOperation"};
      }
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
