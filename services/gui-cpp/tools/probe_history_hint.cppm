module;
#include <cmath>
#include <cstdint>
#include <cstddef>

export module telar.gui.tools.probe_history_hint;

import std;
export import telar.client.protocol;
export import telar.base.memory;
export import telar.gui.core.primitives;
export import telar.gui.tools.probe_geometry;
export import telar.gui.tools.probe_io;
export import telar.gui.tools.probe_text;
export import telar.gui.core.metrics;
export import telar.gui.presentation.history_meta_geometry;

export {
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
}
