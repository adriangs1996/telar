#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstddef>
#include <cstring>
#include <ghostty/vt/unicode.h>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.tools.probe_io;
import telar.gui.tools.probe_text;
import telar.gui.core.unicode_scalar;
import telar.gui.core.metrics;
import telar.gui.history.browser;
import telar.gui.presentation.history_inspection;

namespace {

using namespace telar::gui;

std::uint8_t tone(PaletteRole color) noexcept {
  enum class Tone : std::uint8_t {
    text,
    muted,
    red,
    green,
    teal,
    yellow,
  };
  switch (color) {
  case PaletteRole::subtext0:
    return static_cast<std::uint8_t>(Tone::muted);
  case PaletteRole::red:
    return static_cast<std::uint8_t>(Tone::red);
  case PaletteRole::green:
    return static_cast<std::uint8_t>(Tone::green);
  case PaletteRole::teal:
    return static_cast<std::uint8_t>(Tone::teal);
  case PaletteRole::yellow:
    return static_cast<std::uint8_t>(Tone::yellow);
  default:
    return static_cast<std::uint8_t>(Tone::text);
  }
}

void record(SystemAllocator &memory) {
  HistoryInspectionEntry entry;
  entry.id = probe::read<std::uint64_t>();
  entry.pane_id = probe::read<std::uint64_t>();
  entry.started_at_ms = probe::read<std::int64_t>();
  entry.duration_ns = probe::read<std::int64_t>();
  const CalendarSample sampled{.now_ms = probe::read<std::int64_t>(), .utc_offset_min = probe::read<std::int16_t>()};
  entry.status = probe::read<telar::HistoryStatus>();
  const auto has_exit = probe::read<std::uint8_t>() != 0;
  const auto exit_code = probe::read<std::int32_t>();
  entry.exit_code = has_exit ? std::optional{exit_code} : std::nullopt;
  entry.author = probe::read<telar::HistoryAuthor>();
  entry.origin = probe::read<telar::HistoryOrigin>();
  entry.pane_open = probe::read<std::uint8_t>() != 0;
  const auto phase = probe::read<HistoryPhase>();
  const auto truncated = probe::read<std::uint8_t>() != 0;
  const auto columns = probe::read<std::uint16_t>();
  const auto command = probe::readText(memory);
  const auto directory = probe::readText(memory);
  const auto provider = probe::readText(memory);
  const auto tab = probe::readText(memory);
  const auto output = probe::readText(memory);
  entry.directory = directory;
  entry.provider = provider;
  entry.tab = tab;
  const auto details = HistoryInspectionFacts::derive(entry, sampled);
  const auto facts = details.lines();
  const auto heading = HistoryInspectionFacts::outputHeading(phase, truncated, output.size());
  HistoryInspectionLines lines{{.command = command, .facts = facts, .heading = heading.view(), .output = output}, columns};
  probe::write(lines.count());
  while (const auto line = lines.next()) {
    probe::write(static_cast<std::uint8_t>(line->kind));
    probe::write(tone(line->color));
    probe::write(static_cast<std::uint8_t>(line->mono));
    probe::writeText(line->label);
    probe::writeText(line->text);
  }
}

}

int main() {
  try {
    SystemAllocator memory;
    while (std::getc(stdin) != EOF) {
      record(memory);
    }

    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
