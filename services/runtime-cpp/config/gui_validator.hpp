#pragma once

#include "value_constraints.hpp"

namespace telar::runtime::config {

class GuiValidator {
public:
  static void validate(const lua::Value &gui) {
    if (!gui.present()) {
      return;
    }

    gui.onlyFields({"font", "cursor", "window", "chrome", "sidebar", "max_fps"});
    font(gui.field("font"));
    cursor(gui.field("cursor"));
    window(gui.field("window"));
    chrome(gui.field("chrome"));
    sidebar(gui.field("sidebar"));
    optionalWholeNumber(gui.field("max_fps"), 30, 240);
  }

private:
  static void font(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"family", "style", "size", "line_height", "letter_spacing", "thicken", "thicken_strength"});
    optionalUtf8Text(table.field("family"), 256);
    optionalUtf8Text(table.field("style"), 256);
    table.field("size").boundedNumber(6, 6, 96);
    table.field("line_height").boundedNumber(1, 0.75, 3);
    table.field("letter_spacing").boundedNumber(0, -5, 20);
    table.field("thicken").boolean(false);
    optionalWholeNumber(table.field("thicken_strength"), 0, 255);
  }

  static void cursor(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"style", "blink", "blink_interval_ms"});
    optionalChoice(table.field("style"), {"block", "bar", "underline", "hollow"});
    table.field("blink").boolean(false);
    optionalWholeNumber(table.field("blink_interval_ms"), 100, 5000);
  }

  static void window(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"background_opacity", "background_blur", "titlebar", "padding"});
    table.field("background_opacity").boundedNumber(1, 0, 1);
    table.field("titlebar").boolean(true);
    const auto blur = table.field("background_blur");
    if (!blur.is(LUA_TBOOLEAN)) {
      optionalWholeNumber(blur, 0, 255);
    }

    const auto padding = table.field("padding");
    if (padding.present()) {
      padding.onlyFields({"x", "y"});
      padding.field("x").boundedNumber(0, 0, 256);
      padding.field("y").boundedNumber(0, 0, 256);
    }
  }

  static void chrome(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"scale"});
      table.field("scale").boundedNumber(1, 0.5, 2);
    }
  }

  static void sidebar(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"width"});
      table.field("width").boundedNumber(284, 220, 800);
    }
  }
};

}
