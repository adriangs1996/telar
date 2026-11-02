#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "presentation/palette_geometry.hpp"
#include "presentation/suggestion_geometry.hpp"
#include "presentation/suggestion_labels.hpp"
#include "presentation/suggestion_preview.hpp"
#include "probe_geometry.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include "suggestions/state.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "terminal/font_grid.hpp"
#include <cstdint>
#include <cstdio>
#include <exception>
#include <stdexcept>
#include <string_view>

namespace {

using namespace telar::gui;
using namespace telar::gui::probe;
using telar::SuggestionStatus;

enum class Operation : std::uint8_t {
  transition = 1,
  panel,
};
enum class Transition : std::uint8_t {
  reset,
  begin,
  expect,
  invalidate,
  receive,
};
enum class Drawing : std::uint8_t {
  end,
  fill,
  rounded,
  text,
  button,
};
enum class Ink : std::uint8_t {
  text,
  red,
  surface0,
  surface1,
};
enum class Face : std::uint8_t {
  terminal,
  sans,
};
enum class Size : std::uint8_t {
  terminal,
  title,
  body,
  small,
};

struct Label {
  std::string_view text;
  Face face = Face::sans;
  Size size = Size::body;
  bool bold = false;
  Ink ink = Ink::text;
  float alpha = 1;
};

void label(Rect bounds, Label value) {
  write(Drawing::text);
  writeRect(bounds);
  writeText(value.text);
  write(value.face);
  write(value.size);
  write(static_cast<std::uint8_t>(value.bold));
  write(value.ink);
  write(value.alpha);
}

void transitionCase(SystemAllocator &memory, SuggestionState &state) {
  const auto operation = read<Transition>();
  bool received = false;
  switch (operation) {
  case Transition::reset:
    state = {};
    break;
  case Transition::begin:
    state.begin();
    break;
  case Transition::expect:
    state.expect(read<std::uint64_t>());
    break;
  case Transition::invalidate:
    state.invalidate();
    break;
  case Transition::receive: {
    const auto request_id = read<std::uint64_t>();
    const auto status = read<SuggestionStatus>();
    const auto text = readText(memory);
    received = state.receive({.request_id = request_id, .status = status, .text = text});
    break;
  }
  }

  write(static_cast<std::uint8_t>(received));
  write(state.revision());
  write(state.pendingRequest());
  write(state.phase());
  write(state.status());
  writeText(state.text());
}

void preview(Rect body, const ChromeMetrics &chrome, const FontGrid &grid, std::string_view text) {
  write(Drawing::rounded);
  writeRect(body);
  write(Ink::surface0);
  write(chrome.px(SuggestionGeometry::preview_radius));
  SuggestionPreview lines{text, PaletteGeometry::inset(body, chrome.px(SuggestionGeometry::preview_inset)), grid};
  while (const auto line = lines.next()) {
    label(line->bounds, {
                            .text = line->text,
                            .face = line->shortened ? Face::sans : Face::terminal,
                            .size = line->shortened ? Size::small : Size::terminal,
                            .alpha = line->shortened ? SuggestionGeometry::message_alpha : 1,
                        });
  }
}

void panelCase(SystemAllocator &memory) {
  const auto bounds = readRect();
  const auto footer = readRect();
  ChromeMetrics chrome;
  chrome.ratio = read<float>();
  chrome.body = read<std::uint16_t>();
  chrome.small = read<std::uint16_t>();
  FontGrid grid;
  grid.width = read<std::uint16_t>();
  grid.height = read<std::uint16_t>();
  const auto phase = read<SuggestionPhase>();
  const auto status = read<SuggestionStatus>();
  const auto text = readText(memory);
  const auto query = readText(memory);
  PaletteGeometry palette;
  palette.results = bounds;
  palette.footer = footer;
  const auto geometry = SuggestionGeometry::measure(palette, chrome, false);
  label(geometry.heading, {.text = SuggestionLabels::heading(phase), .bold = true, .ink = phase == SuggestionPhase::failed ? Ink::red : Ink::text});
  if (phase == SuggestionPhase::ready) {
    preview(geometry.body, chrome, grid, text);
  } else {
    label(geometry.message, {.text = SuggestionLabels::message(phase, status), .alpha = SuggestionGeometry::message_alpha});
  }

  write(Drawing::fill);
  writeRect(geometry.separator);
  write(Ink::surface1);
  label(geometry.footer_caption, {.text = SuggestionLabels::footer(phase), .size = Size::small, .alpha = SuggestionGeometry::message_alpha});
  write(Drawing::button);
  writeRect(geometry.button);
  writeText(SuggestionLabels::button(phase));
  write(static_cast<std::uint8_t>(SuggestionLabels::canSubmit(phase, query)));
  write(std::uint8_t{1});
  write(Drawing::end);
}

}

int main() {
  try {
    SystemAllocator memory;
    SuggestionState state;
    int operation = 0;
    while ((operation = std::getchar()) != EOF) {
      switch (static_cast<Operation>(operation)) {
      case Operation::transition:
        transitionCase(memory, state);
        break;
      case Operation::panel:
        panelCase(memory);
        break;
      default:
        throw std::runtime_error{"Unknown suggestion probe operation"};
      }
    }
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));

    return 1;
  }
}
