#pragma once

#include "core/configuration.hpp"
#include "core/json_writer.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

class GuiQuery {
public:
  [[nodiscard]] static std::string_view write(const Configuration &configuration, std::span<char> output, bool default_titlebar) {
    JsonWriter writer{output};
    writer.object([&](JsonWriter &object) {
      object.member("font", [&](JsonWriter &value) {
        writeFont(value, configuration.font);
      });
      object.member("cursor", [&](JsonWriter &value) {
        value.object([&](JsonWriter &cursor) {
          cursor.member("style", cursorStyle(configuration.cursor));
          cursor.member("blink", configuration.cursor_blink);
          cursor.member("blink_interval_ms", configuration.blink_interval.count());
        });
      });
      object.member("window", [&](JsonWriter &value) {
        writeWindow(value, configuration, default_titlebar);
      });
      object.member("chrome", [&](JsonWriter &value) {
        value.object([&](JsonWriter &chrome) {
          chrome.member("scale", configuration.chrome_scale);
        });
      });
      object.member("sidebar", [&](JsonWriter &value) {
        value.object([&](JsonWriter &sidebar) {
          sidebar.member("width", configuration.sidebar_width);
        });
      });
    });

    return writer.view();
  }

private:
  static void writeFont(JsonWriter &writer, const FontConfiguration &font) {
    writer.object([&](JsonWriter &object) {
      object.member("family", font.family.view());
      object.member("style", font.style.view());
      object.member("size", font.size);
      object.member("line_height", font.line_height);
      object.member("letter_spacing", font.letter_spacing);
      object.member("thicken", font.thicken);
      object.member("thicken_strength", font.thicken_strength);
    });
  }

  static void writeWindow(JsonWriter &writer, const Configuration &configuration, bool default_titlebar) {
    writer.object([&](JsonWriter &window) {
      window.member("background_opacity", configuration.background_opacity);
      window.member("background_blur", configuration.background_blur);
      window.member("titlebar", configuration.titlebar.value_or(default_titlebar));
      window.member("padding", [&](JsonWriter &value) {
        value.object([&](JsonWriter &padding) {
          padding.member("x", configuration.padding_x);
          padding.member("y", configuration.padding_y);
        });
      });
    });
  }

  static std::string_view cursorStyle(CursorShape cursor) {
    switch (cursor) {
    case CursorShape::block:
      return "block";
    case CursorShape::bar:
      return "bar";
    case CursorShape::underline:
      return "underline";
    case CursorShape::hollow:
      return "hollow";
    case CursorShape::default_shape:
      break;
    }

    throw std::invalid_argument{"Unknown cursor shape"};
  }
};

}
