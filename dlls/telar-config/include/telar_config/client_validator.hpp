#pragma once

#include "telar_config/bars_validator.hpp"
#include "telar_config/binding_validator.hpp"
#include "telar_config/client_definitions_validator.hpp"
#include "telar_config/client_validation_state.hpp"

namespace telar::runtime::config {

class ClientValidator {
public:
  template <CommandTabStore Commands>
  static void validate(const lua::Value &client, LimitNotices &limits, BasicClientValidationState<Commands> &state, const lua::Value *inherited = nullptr) {
    if (!client.present()) {
      return;
    }

    client.onlyFields({"prefix", "theme", "icons", "sidebar", "pane_gaps", "editor", "window_title", "sound", "notifications", "appearance", "input", "keybindings", "bars", "panels", "picks", "history"});
    const auto prefix = client.field("prefix");
    if (prefix.present()) {
      state.keymap.setPrefix(KeyChordValidator::parse(prefix));
    }

    client.field("pane_gaps").boolean(false);
    printableText(client.field("editor"), 4096, false);
    printableText(client.field("window_title"), 128, true);
    sidebar(client.field("sidebar"));
    sound(client.field("sound"));
    notifications(client.field("notifications"));
    input(client.field("input"));
    history(client.field("history"));
    ClientDefinitionsValidator::validate(client, limits);
    const ClientDefinitions definitions{client, inherited};
    const BasicActionValidator actions{definitions, limits, state.commands};
    BindingValidator::validate(client.field("keybindings"), actions, state.keymap, limits);
    BarsValidator{actions, limits}.validate(client.field("bars"));
  }

private:
  static void printableText(const lua::Value &value, std::size_t maximum, bool allow_empty) {
    if (!value.present()) {
      return;
    }

    optionalUtf8Text(value, maximum);
    const auto text = value.string();
    if ((!allow_empty && text.empty()) || std::ranges::any_of(text, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; })) {
      value.fail("must contain printable text");
    }
  }

  static void sidebar(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"visible", "renderer"});
      table.field("visible").boolean(true);
    }
  }

  static void sound(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"enabled", "ready", "needs_input"});
      for (const auto *name : {"enabled", "ready", "needs_input"}) {
        table.field(name).boolean(false);
      }
    }
  }

  static void notifications(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"delivery"});
      optionalChoice(table.field("delivery"), {"telar", "system", "terminal"});
    }
  }

  static void input(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"escape_timeout_ms", "sequence_timeout_ms"});
      table.field("sequence_timeout_ms").boundedInteger(1000, 10, 10000);
    }
  }

  static void history(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"show_agent_commands", "enter", "match"});
      table.field("show_agent_commands").boolean(false);
      optionalChoice(table.field("enter"), {"paste", "run"});
      optionalChoice(table.field("match"), {"fuzzy", "fts"});
    }
  }
};

}
