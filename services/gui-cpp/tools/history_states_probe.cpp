#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cmath>
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cstdio>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.tools.probe_io;
import telar.gui.tools.probe_text;
import telar.gui.core.metrics;
import telar.gui.history.browser;
import telar.gui.presentation.history_filter_geometry;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.application_mark;

namespace {

using namespace telar::gui;

enum class Operation : std::uint8_t { empty, cue, line, reset };
enum class Draw : std::uint8_t { end, text, rounded, button };
enum class Tone : std::uint8_t { text, muted, surface };
enum class Face : std::uint8_t { mono, sans };
enum class Size : std::uint8_t { terminal, body, small };
enum class Flag : std::uint8_t { has_page = 1, has_query = 2, failed_only = 4 };

struct Style {
  Face face = Face::sans;
  Size size = Size::body;
  Tone tone = Tone::text;
  bool emphasized = false;
};

Rect readRect() {
  return {.x = probe::read<float>(), .y = probe::read<float>(), .width = probe::read<float>(), .height = probe::read<float>()};
}

void writeRect(Rect area) {
  probe::write(area.x);
  probe::write(area.y);
  probe::write(area.width);
  probe::write(area.height);
}

void text(Rect area, std::string_view value, Style style) {
  probe::write(Draw::text);
  writeRect(area);
  probe::writeText(value);
  probe::write(style.face);
  probe::write(style.size);
  probe::write(style.tone);
  probe::write(static_cast<std::uint8_t>(style.emphasized));
}

void recordEmpty(SystemAllocator &memory) {
  const auto phase = probe::read<HistoryPhase>();
  const auto scope = probe::read<telar::HistoryScope>();
  const auto author = probe::read<telar::HistoryAuthorFilter>();
  const auto flags = probe::read<std::uint8_t>();
  const auto offset = probe::read<std::uint32_t>();
  const auto workspace = probe::readText(memory);
  const auto area = readRect();
  const ChromeMetrics chrome{.ratio = probe::read<float>(), .body = probe::read<std::uint16_t>(), .small = probe::read<std::uint16_t>()};
  HistoryEmptyMeasurements measured{.title = probe::read<float>(), .subtitle = probe::read<float>(), .import = probe::read<float>()};
  const auto flag = [flags](Flag value) { return (flags & static_cast<std::uint8_t>(value)) != 0; };
  const auto content = HistoryEmpty::derive({.phase = phase, .scope = scope, .author = author, .workspace = workspace, .page_offset = offset, .has_page = flag(Flag::has_page), .has_query = flag(Flag::has_query), .failed_only = flag(Flag::failed_only)});
  measured.action = content.action;
  const auto geometry = HistoryEmptyGeometry::derive(area, chrome, measured);
  if (!area.empty()) {
    text(geometry.title, content.title.view(), {.emphasized = content.emphasized});
    if (!content.subtitle.empty()) {
      text(geometry.subtitle, content.subtitle, {.size = Size::small, .tone = Tone::muted});
    }

    if (content.action == HistoryEmpty::Action::import) {
      probe::write(Draw::rounded);
      writeRect(geometry.action);
      probe::write(chrome.px(HistoryEmptyGeometry::import_radius));
      probe::write(Tone::surface);
      auto bounds = geometry.action;
      bounds.x += chrome.px(HistoryEmptyGeometry::import_inset);
      bounds.width = std::max(0.0F, bounds.width - chrome.px(HistoryEmptyGeometry::import_inset * 2));
      text(bounds, "telar history import", {.face = Face::mono, .size = Size::terminal});
    } else if (content.action == HistoryEmpty::Action::everywhere) {
      probe::write(Draw::button);
      writeRect(geometry.action);
      probe::writeText("Search everywhere");
    }
  }

  probe::write(Draw::end);
}

std::optional<std::uint64_t> timestamp() {
  const auto has_clock = probe::read<std::uint8_t>() != 0;
  const auto now_ns = probe::read<std::uint64_t>();

  return has_clock ? std::optional{now_ns} : std::nullopt;
}

void recordCue(LoadingCue &cue) {
  const auto waiting = probe::read<std::uint8_t>() != 0;
  const auto now_ns = timestamp();
  const auto visible = cue.sample(waiting, now_ns);
  const auto deadline = waiting && now_ns && !visible ? cue.deadline() : std::nullopt;
  probe::write(static_cast<std::uint8_t>(visible));
  probe::write(static_cast<std::uint8_t>(deadline.has_value()));
  probe::write(deadline.value_or(0));
}

void recordLine() {
  const auto area = readRect();
  const ChromeMetrics chrome{.ratio = probe::read<float>()};
  const auto now_ns = timestamp();
  writeRect(HistoryLoading::line(area, chrome, now_ns));
  writeRect(area);
}

}

int main() {
  try {
    SystemAllocator memory;
    LoadingCue cue;
    while (true) {
      const auto incoming = std::getc(stdin);
      if (incoming == EOF) {
        return 0;
      }

      switch (static_cast<Operation>(incoming)) {
      case Operation::empty: recordEmpty(memory); break;
      case Operation::cue: recordCue(cue); break;
      case Operation::line: recordLine(); break;
      case Operation::reset: cue = LoadingCue{}; break;
      }
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
