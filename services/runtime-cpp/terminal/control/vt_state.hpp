#pragma once

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

  void write(std::span<const std::uint8_t> bytes) {
    palette_valid_ = false;
    if (separate_media_) {
      graphics_cursor_.feed(terminal_, bytes, size_);
    } else {
      ghostty_terminal_vt_write(terminal_, bytes.data(), bytes.size());
    }
  }

  void configureSize(TerminalSize size) noexcept {
    size_ = size;
  }

  void invalidateColors() noexcept {
    palette_valid_ = false;
  }

  TerminalSize size() const {
    auto result = size_;
    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_COLS, &result.cols));
    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_ROWS, &result.rows));
    return result;
  }

  bool mode(std::uint16_t number, bool ansi = false) const {
    GhosttyTerminalModeConfig query{.mode = ghostty_mode_new(number, ansi), .value = false};
    return ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_MODE, &query) == GHOSTTY_SUCCESS && query.value;
  }

  Position cursor() const {
    Position result{};
    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_CURSOR_X, &result.column));
    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &result.row));
    return result;
  }

  Margins margins() const {
    Margins result{};
    const GhosttyTerminalData keys[] = {GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_TOP, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_BOTTOM, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_LEFT, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_RIGHT};
    void *values[] = {&result.top, &result.bottom, &result.left, &result.right};
    checkGhostty(ghostty_terminal_get_multi(terminal_, std::size(keys), keys, values, nullptr));
    return result;
  }

  std::uint8_t keyboard() const {
    std::uint8_t result = 0;
    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &result));
    return result;
  }

  GhosttyStyle style() const {
    auto result = ghosttySized<GhosttyStyle>();
    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_CURSOR_STYLE, &result));
    return result;
  }

  GhosttyRenderStateCursor visualCursor() const {
    checkGhostty(ghostty_render_state_update(render_, terminal_));
    auto result = ghosttySized<GhosttyRenderStateCursor>();
    checkGhostty(ghostty_render_state_get(render_, GHOSTTY_RENDER_STATE_DATA_CURSOR, &result));
    return result;
  }

  std::optional<GhosttyColorRgb> color(unsigned selector) {
    if (selector < palette_.size()) {
      if (!palette_valid_) {
        checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, palette_.data()));
        palette_valid_ = true;
      }
      return palette_[selector];
    }

    const auto key = selector == foreground ? GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND : selector == background ? GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND : GHOSTTY_TERMINAL_DATA_COLOR_CURSOR;
    GhosttyColorRgb result{};
    if (ghostty_terminal_get(terminal_, key, &result) != GHOSTTY_SUCCESS) {
      return std::nullopt;
    }
    return result;
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
  GhosttyTerminal terminal_ = nullptr;
  GhosttyRenderState render_ = nullptr;
  GraphicsCursor graphics_cursor_;
  TerminalSize size_{};
  std::array<GhosttyColorRgb, 256> palette_;
  bool palette_valid_ = false;
  bool separate_media_ = false;
};

}
