#pragma once

#include "color.hpp"
#include "background_opacity.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>

namespace telar::gui {

struct FontConfiguration {
  static constexpr std::size_t name_capacity = 256;
  static constexpr float default_size = 15;
  static constexpr float minimum_size = 6;
  static constexpr float maximum_size = 96;
  static constexpr float minimum_line_height = 0.75F;
  static constexpr float maximum_line_height = 3;
  static constexpr float minimum_letter_spacing = -5;
  static constexpr float maximum_letter_spacing = 20;
  static constexpr std::uint8_t maximum_thicken_strength = 255;

  runtime::FixedText<name_capacity> family;
  runtime::FixedText<name_capacity> style;
  float size = default_size;
  float line_height = 1;
  float letter_spacing = 0;
  bool thicken = false;
  std::uint8_t thicken_strength = maximum_thicken_strength;
};

struct HistoryConfiguration {
  bool show_agent_commands = false;
  bool enter_runs = false;
  bool match_fts = false;
};

struct SoundPolicy {
  bool enabled = true;
  bool ready = true;
  bool needs_input = true;
};

enum class NotificationDelivery : std::uint8_t {
  telar,
  system,
};

struct Configuration {
  static constexpr std::size_t maximum_editor_bytes = 4096;
  static constexpr std::size_t maximum_window_title_bytes = 128;
  static constexpr std::chrono::milliseconds default_blink_interval{600};
  static constexpr std::chrono::milliseconds minimum_blink_interval{100};
  static constexpr std::chrono::milliseconds maximum_blink_interval{5000};
  static constexpr float default_sidebar_width = 284;
  static constexpr float minimum_sidebar_width = 220;
  static constexpr float maximum_sidebar_width = 800;
  static constexpr float minimum_chrome_scale = 0.5F;
  static constexpr float maximum_chrome_scale = 2;
  static constexpr float maximum_padding = 256;
  static constexpr std::uint16_t minimum_fps = 30;
  static constexpr std::uint16_t maximum_fps = 240;
  static constexpr std::uint16_t default_fps = 60;
  static constexpr std::uint8_t default_background_blur = 20;
  static constexpr std::uint8_t maximum_background_blur = 255;

  FontConfiguration font;
  runtime::FixedText<maximum_editor_bytes> editor;
  runtime::FixedText<maximum_window_title_bytes> window_title;
  HistoryConfiguration history;
  SoundPolicy sound;
  NotificationDelivery notification_delivery = NotificationDelivery::telar;
  Theme theme;
  ThemeSelection themes;
  CursorShape cursor = CursorShape::block;
  bool cursor_blink = true;
  std::chrono::milliseconds blink_interval = default_blink_interval;
  float background_opacity = 1;
  BackgroundOpacity opacity;
  std::uint8_t background_blur = 0;
  float padding_x = 0;
  float padding_y = 0;
  float chrome_scale = 1;
  float sidebar_width = default_sidebar_width;
  std::uint16_t max_fps = 0;
  bool sidebar_visible = true;
  bool pane_gaps = true;
  std::optional<bool> titlebar;
};

}
