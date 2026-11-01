#pragma once

#include "lua/value.hpp"
#include "memory/fixed_text.hpp"
#include "node.hpp"
#include "text/utf8.hpp"
#include "value_reader.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <lauxlib.h>
#include <lua.h>
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui::components {

enum class Position : std::uint8_t {
  bottom_left,
  bottom_center,
  bottom_right,
  top_right,
  footer_left,
  footer_center,
  footer_right,
  count,
};

enum class SourceKind : std::uint8_t {
  empty,
  tabs,
  metrics,
  machines,
  fixed,
  dynamic,
  command,
};

struct Source {
  static constexpr std::chrono::milliseconds default_interval{1000};
  static constexpr std::chrono::milliseconds default_timeout{2000};
  static constexpr std::uint64_t minimum_interval_ms = 100;
  static constexpr std::uint64_t maximum_interval_ms = 3600000;
  static constexpr std::uint64_t minimum_timeout_ms = 100;
  static constexpr std::uint64_t maximum_timeout_ms = 10000;
  SourceKind kind = SourceKind::empty;
  std::optional<std::chrono::milliseconds> interval = std::nullopt;
  std::chrono::milliseconds timeout = default_timeout;
  int reference = LUA_NOREF;
  bool has_render = false;

  static Source read(lua_State &state, const runtime::lua::Value &value, bool panel = false) {
    Source result;
    if (!value.present()) {
      return result;
    }

    const auto kind = value.field("bar_kind").string();
    constexpr std::array<std::string_view, 6> names{"tabs", "metrics", "machines", "static", "dynamic", "command"};
    const auto *const found = std::ranges::find(names, kind);
    if (found == names.end()) {
      value.fail("names an unsupported bar source");
    }

    result.kind = static_cast<SourceKind>(found - names.begin() + 1);
    if (result.kind == SourceKind::dynamic || result.kind == SourceKind::command) {
      const auto every = value.field("every_ms");
      if (!panel || every.present()) {
        result.interval = std::chrono::milliseconds{every.boundedInteger(default_interval.count(), minimum_interval_ms, maximum_interval_ms)};
      }

      result.has_render = value.field("render").present();
      result.timeout = std::chrono::milliseconds{value.field("timeout_ms").boundedInteger(default_timeout.count(), minimum_timeout_ms, maximum_timeout_ms)};
    }

    value.pushCopy();
    result.reference = luaL_ref(&state, LUA_REGISTRYINDEX);

    return result;
  }
};

struct Heading {
  static constexpr std::size_t maximum_name_bytes = 32;
  static constexpr std::size_t maximum_title_bytes = 128;
  runtime::FixedText<maximum_name_bytes> name;
  runtime::FixedText<maximum_title_bytes> title;

  void read(std::string_view key, const runtime::lua::Value &value) {
    name.assign(key);
    const auto text = value.field("title");
    title.assign(runtime::utf8Prefix(text.present() ? text.string() : key, maximum_title_bytes));
  }
};

struct Panel {
  static constexpr std::uint16_t default_width = 420;
  static constexpr std::uint16_t minimum_width = 240;
  static constexpr std::uint16_t maximum_width = 720;
  Heading heading;
  Source source;
  std::optional<Mark> mark = std::nullopt;
  std::optional<runtime::FixedText<Node::maximum_icon_bytes>> icon = std::nullopt;
  std::uint16_t width = default_width;
};

struct Pick {
  static constexpr std::uint64_t maximum_timeout_ms = 60000;
  Heading heading;
  std::chrono::milliseconds timeout = Source::default_timeout;
  int reference = LUA_NOREF;
  bool command = false;
  bool render = false;
  bool refresh = true;
};

class Definitions {
public:
  static constexpr std::size_t positions = static_cast<std::size_t>(Position::count);
  static constexpr std::size_t maximum_definitions = 16;

  Definitions() noexcept {
    sources_[static_cast<std::size_t>(Position::bottom_left)].kind = SourceKind::metrics;
    sources_[static_cast<std::size_t>(Position::bottom_right)].kind = SourceKind::tabs;
    sources_[static_cast<std::size_t>(Position::footer_left)].kind = SourceKind::metrics;
  }

  void apply(lua_State &state, const runtime::lua::Value &client) {
    if (!client.present()) {
      return;
    }

    bars(state, client.field("bars"));
    named(client.field("panels"), panel_count_, [&](std::string_view name, const runtime::lua::Value &value, std::size_t index) {
      auto &panel = panels_[index];
      panel.heading.read(name, value);
      panel.width = static_cast<std::uint16_t>(value.field("width").boundedInteger(Panel::default_width, Panel::minimum_width, Panel::maximum_width));
      panel.mark = ValueReader::mark(value.field("mark"));
      panel.icon = ValueReader::icon(value.field("icon"));
      panel.source = Source::read(state, value.field("source"), true);
    });
    named(client.field("picks"), pick_count_, [&](std::string_view name, const runtime::lua::Value &value, std::size_t index) {
      auto &pick = picks_[index];
      pick.heading.read(name, value);
      pick.timeout = std::chrono::milliseconds{value.field("timeout_ms").boundedInteger(Source::default_timeout.count(), Source::minimum_timeout_ms, Pick::maximum_timeout_ms)};
      pick.command = value.field("command").present();
      pick.render = value.field("items").is(LUA_TFUNCTION);
      pick.refresh = value.field("refresh").boolean(true);
      value.pushCopy();
      pick.reference = luaL_ref(&state, LUA_REGISTRYINDEX);
    });
  }

  [[nodiscard]] const Source &source(Position position) const {
    return sources_.at(static_cast<std::size_t>(position));
  }

  [[nodiscard]] std::span<const Panel> panels() const noexcept {
    return std::span{panels_}.first(panel_count_);
  }

  [[nodiscard]] std::span<const Pick> picks() const noexcept {
    return std::span{picks_}.first(pick_count_);
  }

private:
  void bars(lua_State &state, const runtime::lua::Value &value) {
    if (!value.present()) {
      return;
    }

    const auto bottom = value.field("bottom");
    if (bottom.present()) {
      constexpr std::array names{"left", "center", "right"};
      for (std::size_t index = 0; index < names.size(); ++index) {
        sources_[index] = Source::read(state, bottom.field(names[index]));
      }
    }

    const auto top = value.field("top");
    if (top.present()) {
      sources_[static_cast<std::size_t>(Position::top_right)] = Source::read(state, top.field("right"));
    }

    const auto footer = value.field("sidebar_footer");
    if (footer.present()) {
      constexpr std::size_t footer_slots = 3;
      const auto count = footer.arraySize();
      for (std::size_t index = 0; index < footer_slots; ++index) {
        sources_[static_cast<std::size_t>(Position::footer_left) + index] = index < count ? Source::read(state, footer.element(static_cast<lua_Integer>(index) + 1)) : Source{};
      }
    }
  }

  template <typename Read>
  static void named(const runtime::lua::Value &value, std::size_t &count, const Read &read) {
    if (!value.present()) {
      return;
    }

    std::array<std::string_view, maximum_definitions> names;
    count = 0;
    value.eachField([&](std::string_view name, const runtime::lua::Value &) {
      auto *const end = names.begin() + static_cast<std::ptrdiff_t>(count);
      auto *const place = std::lower_bound(names.begin(), end, name);
      if (count == names.size() && place == end) {
        return;
      }

      auto *const last = count < names.size() ? end : end - 1;
      std::move_backward(place, last, last + 1);
      *place = name;
      count = std::min(count + 1, names.size());
    });
    for (std::size_t index = 0; index < count; ++index) {
      read(names[index], value.entry(names[index]), index);
    }
  }

  std::array<Source, positions> sources_{};
  std::array<Panel, maximum_definitions> panels_{};
  std::array<Pick, maximum_definitions> picks_{};
  std::size_t panel_count_ = 0;
  std::size_t pick_count_ = 0;
};

}
