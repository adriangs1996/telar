#pragma once

#include "../../memory/allocator.hpp"
#include "../graphics_cursor.hpp"
#include "../ghostty_handle.hpp"
#include <array>
#include <optional>

namespace telar::runtime::control {

struct Position {
  std::uint16_t column;
  std::uint16_t row;
};

struct Margins {
  std::uint16_t top;
  std::uint16_t bottom;
  std::uint16_t left;
  std::uint16_t right;
};

// These handles are borrowed from one nonmovable Terminal. No query is fed
// through this adapter; getters expose only current VT state. The owner must
// destroy the controller before freeing either handle.
class VtState {
public:
  void bind(GhosttyTerminal terminal, GhosttyRenderState render, bool separate_media) noexcept {
    terminal_ = terminal;
    render_ = render;
    separate_media_ = separate_media;
  }

  void write(std::span<const std::uint8_t> bytes) { writeInput<true>(bytes); }

  // The caller verifies that each ESC begins a complete numeric SGR.
  // Partial graphics framing still observes every byte through the old path.
  void writeNonGraphics(std::span<const std::uint8_t> bytes) { writeInput<false>(bytes); }

  bool canWriteAscii() const noexcept { return !separate_media_ || graphics_cursor_.ground(); }


  void failWrite() noexcept { write_failed_ = true; }

  // An intercepted ESC must still resolve a partial UTF-8 character in the
  // non-query backend at that exact stream position. Only framing/cancellation
  // is forwarded; the query itself never enters the external handler.
  bool needsEscapeBoundary() const noexcept {
    return possibly_pending_input_;
  }

  void escapeBoundary() {
    if (!possibly_pending_input_) {
      return;
    }
    bool ground = false;
    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_VT_GROUND, &ground));
    if (!ground) {
      constexpr std::array<std::uint8_t, 2> boundary{0x1b, 0x18};
      write(boundary);
    }
    possibly_pending_input_ = false;
  }

  void configureSize(TerminalSize size) noexcept {
    size_ = size;
    invalidate();
  }

  void invalidateColors() noexcept {
    palette_valid_ = false;
    color_valid_.fill(false);
  }

  TerminalSize size() const {
    return cached(size_cache_, [&] {
      auto result = size_;
      checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_COLS, &result.cols));
      checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_ROWS, &result.rows));
      return result;
    });
  }

  bool mode(std::uint16_t number, bool ansi = false) const {
    auto &entry = modes_[(number ^ (ansi ? mode_ansi_hash : 0)) % modes_.size()];
    if (entry.epoch != epoch_ || entry.number != number || entry.ansi != ansi) {
      GhosttyTerminalModeConfig query{.mode = ghostty_mode_new(number, ansi), .value = false};
      entry.value = ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_MODE, &query) == GHOSTTY_SUCCESS && query.value;
      entry.number = number;
      entry.ansi = ansi;
      entry.epoch = epoch_;
    }
    return entry.value;
  }

  void setMode(std::uint16_t number, bool enabled) {
    const GhosttyTerminalModeConfig config{.mode = ghostty_mode_new(number, false), .value = enabled};
    checkGhostty(ghostty_terminal_set(terminal_, GHOSTTY_TERMINAL_OPT_MODE, &config));
    invalidate();
  }

  [[gnu::always_inline]] Position cursor() const {
    [[clang::noinline]] return cached(cursor_cache_, [&] {
      const auto snapshot = readCursorState();
      const Position result{snapshot.x, snapshot.y};

      return result;
    });
  }

  Margins margins() const {
    return cached(margin_cache_, [&] {
      Margins result{};
      const GhosttyTerminalData keys[] = {GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_TOP, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_BOTTOM, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_LEFT, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_RIGHT};
      void *values[] = {&result.top, &result.bottom, &result.left, &result.right};
      checkGhostty(ghostty_terminal_get_multi(terminal_, std::size(keys), keys, values, nullptr));
      return result;
    });
  }

  std::uint8_t keyboard() const {
    return cached(keyboard_cache_, [&] {
      std::uint8_t result = 0;
      checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &result));
      return result;
    });
  }

  GhosttyStyle style() const {
    return cached(style_cache_, [&] {
      auto result = ghosttySized<GhosttyStyle>();
      checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_CURSOR_STYLE, &result));
      return result;
    });
  }

  GhosttyRenderStateCursor visualCursor() const {
    return cached(visual_cursor_cache_, [&] {
      checkGhostty(ghostty_render_state_update(render_, terminal_));
      auto result = ghosttySized<GhosttyRenderStateCursor>();
      checkGhostty(ghostty_render_state_get(render_, GHOSTTY_RENDER_STATE_DATA_CURSOR, &result));
      return result;
    });
  }

  std::optional<GhosttyColorRgb> color(unsigned selector) {
    if (selector < palette_.size()) {
      if (!palette_valid_) {
        checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, palette_.data()));
        palette_valid_ = true;
      }
      return palette_[selector];
    }

    if (selector > cursor_color) {
      return std::nullopt;
    }
    const auto index = selector - foreground;
    if (!color_valid_[index]) {
      const auto key = selector == foreground ? GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND : selector == background ? GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND : GHOSTTY_TERMINAL_DATA_COLOR_CURSOR;
      GhosttyColorRgb result{};
      colors_[index] = ghostty_terminal_get(terminal_, key, &result) == GHOSTTY_SUCCESS ? std::optional{result} : std::nullopt;
      color_valid_[index] = true;
    }
    return colors_[index];
  }

  std::optional<GhosttyGridRef> reference(Position position) const {
    auto result = ghosttySized<GhosttyGridRef>();
    const GhosttyPoint point{.tag = GHOSTTY_POINT_TAG_ACTIVE, .value = {.coordinate = {position.column, position.row}}};
    if (ghostty_terminal_grid_ref(terminal_, point, &result) != GHOSTTY_SUCCESS) {
      return std::nullopt;
    }
    return result;
  }

  std::string_view title() const {
    GhosttyString result{};
    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_TITLE, &result));
    return {reinterpret_cast<const char *>(result.ptr), result.len};
  }

  static constexpr unsigned foreground = 256;
  static constexpr unsigned background = 257;
  static constexpr unsigned cursor_color = 258;

private:
  template <Allocator Memory>
  friend class Engine;

  // Engine admits the graphics scanner once before entering its ASCII loop.
  // Only synchronous widening and queue release intervene; no scanner mutation
  // occurs. The C bridge still validates its input and partial application.
  void writeAscii(std::span<const std::uint32_t> codepoints) {
    if (codepoints.empty()) {
      return;
    }

    invalidate();
    possibly_pending_input_ = codepoints.back() < 0x20;
    std::size_t consumed = 0;
    checkGhostty(ghostty_terminal_vt_write_ascii(terminal_, codepoints.data(), codepoints.size(), &consumed));
    if (consumed != codepoints.size()) {
      throw TerminalError{GHOSTTY_INVALID_VALUE};
    }
    if (write_failed_) {
      throw TerminalError{GHOSTTY_OUT_OF_MEMORY};
    }
  }


  template <bool CheckGraphics>
  void writeInput(std::span<const std::uint8_t> bytes) {
    invalidate();
    if (!bytes.empty()) {
      const auto last = bytes.back();
      possibly_pending_input_ = last >= 0x80 || last < 0x20;
    }
    if (separate_media_ && (CheckGraphics || !graphics_cursor_.ground())) {
      graphics_cursor_.feed(terminal_, bytes, size_);
    } else {
      ghostty_terminal_vt_write(terminal_, bytes.data(), bytes.size());
    }
    if (write_failed_) {
      throw TerminalError{GHOSTTY_OUT_OF_MEMORY};
    }
  }

  template <typename Value>
  struct Cached {
    std::uint64_t epoch = 0;
    Value value{};
  };

  struct ModeCache {
    std::uint64_t epoch = 0;
    std::uint16_t number = 0;
    bool ansi = false;
    bool value = false;
  };

  template <typename Value, typename Read>
  Value cached(Cached<Value> &cache, Read &&read) const {
    if (cache.epoch != epoch_) {
      cache.value = read();
      cache.epoch = epoch_;
    }
    return cache.value;
  }

  // This adapter is the sole VT mutation boundary for the controller. Cached
  // values are copied scalars/structs, never borrowed terminal storage.
  void invalidate() noexcept {
    if (++epoch_ == 0) {
      epoch_ = 1;
      size_cache_.epoch = cursor_cache_.epoch = margin_cache_.epoch = keyboard_cache_.epoch = style_cache_.epoch = visual_cursor_cache_.epoch = 0;
      for (auto &entry : modes_) {
        entry.epoch = 0;
      }
    }
    invalidateColors();
  }

  static constexpr std::uint16_t origin_mode = 6;
  static constexpr unsigned mode_ansi_hash = 32;
  std::uint64_t epoch_ = 1;
  mutable Cached<TerminalSize> size_cache_;
  mutable Cached<Position> cursor_cache_;
  mutable Cached<Margins> margin_cache_;
  mutable Cached<std::uint8_t> keyboard_cache_;
  mutable Cached<GhosttyStyle> style_cache_;
  mutable Cached<GhosttyRenderStateCursor> visual_cursor_cache_;
  mutable std::array<ModeCache, 64> modes_;
  std::array<std::optional<GhosttyColorRgb>, 3> colors_;
  std::array<bool, 3> color_valid_{};
  GhosttyTerminal terminal_ = nullptr;
  GhosttyRenderState render_ = nullptr;
  GraphicsCursor graphics_cursor_;
  TerminalSize size_{};
  std::array<GhosttyColorRgb, 256> palette_;
  bool palette_valid_ = false;
  bool possibly_pending_input_ = false;
  bool separate_media_ = false;
  bool write_failed_ = false;

  GhosttyTerminalCursorState readCursorState() const {
    GhosttyTerminalCursorState result{};
    checkGhostty(ghostty_terminal_cursor_state(terminal_, &result));
    margin_cache_ = {epoch_, {result.top, result.bottom, result.left, result.right}};
    auto &origin = modes_[origin_mode % modes_.size()];
    origin = {epoch_, origin_mode, false, result.origin != 0};
    return result;
  }
};

}
