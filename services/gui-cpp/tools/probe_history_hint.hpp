#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include "probe_geometry.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include <concepts>

#pragma once


import telar.gui.core.metrics;
import telar.gui.presentation.history_meta_geometry;

namespace telar::gui::probe {

enum class HistoryDrawEvent : std::uint8_t {
  end,
  ring,
  text,
  clip,
  fill,
};

template <typename Label>
concept HintLabel = requires(const Label &label) {
  { label.key } -> std::convertible_to<std::string_view>;
  { label.word } -> std::convertible_to<std::string_view>;
};

inline void writeHistoryLabel(Rect bounds, std::string_view text, PaletteRole color, float alpha) {
  write(HistoryDrawEvent::text);
  writeRect(bounds);
  writeText(text);
  writeText(palette_names[static_cast<std::size_t>(color)]);
  write(alpha);
}

template <HintLabel Label>
void writeHistoryHint(const HistoryHintGeometry &layout, ChromeMetrics chrome, Label label) {
  write(HistoryDrawEvent::ring);
  writeRect(layout.keycap);
  write(HistoryHintGeometry::key_ring_alpha);
  write(chrome.px(HistoryHintGeometry::ring_width));
  write(chrome.px(HistoryHintGeometry::corner_radius));
  writeText("text");
  writeHistoryLabel(layout.key_text, label.key, PaletteRole::text, HistoryHintGeometry::key_text_alpha);
  writeHistoryLabel(layout.word, label.word, PaletteRole::subtext0, 1);
  write(HistoryDrawEvent::clip);
  writeRect(layout.bounds);
}

}
