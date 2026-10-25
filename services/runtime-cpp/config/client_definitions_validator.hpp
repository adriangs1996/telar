#pragma once

#include "dynamic_source_validator.hpp"
#include "named_definitions_validator.hpp"
#include "pick_items_validator.hpp"

namespace telar::runtime::config {

class ClientDefinitionsValidator {
public:
  static void validate(const lua::Value &client, LimitNotices &limits) {
    NamedDefinitionsValidator::validate(client.field("panels"), {"panels.max_panels", "panels", NamedDefinitionsValidator::maximum_definitions, {}, {}}, limits, [&](std::string_view name, const lua::Value &definition) {
      definition.onlyFields({"panel_kind", "title", "mark", "icon", "width", "source", "refresh"});
      NamedDefinitionsValidator::heading(name, definition, limits);
      const auto mark = definition.field("mark");
      if (mark.is(LUA_TSTRING)) {
        uiMark(mark);
      }
      const auto icon = definition.field("icon");
      if (icon.is(LUA_TSTRING)) {
        uiIcon(icon);
      }

      definition.field("width").boundedInteger(420, 240, 720);
      DynamicSourceValidator::validate(definition.field("source"));
    });

    NamedDefinitionsValidator::validate(client.field("picks"), {"picks.max_picks", "picks", NamedDefinitionsValidator::maximum_definitions, {}, {}}, limits, [&](std::string_view name, const lua::Value &definition) {
      definition.onlyFields({"pick_kind", "title", "command", "items", "on_select", "timeout_ms", "refresh"});
      NamedDefinitionsValidator::heading(name, definition, limits);
      definition.field("timeout_ms").boundedInteger(2000, 100, 60000);
      const auto command = definition.field("command");
      if (command.present()) {
        CommandArgumentsValidator::validate(command);
      }

      const auto items = definition.field("items");
      if (items.present()) {
        if (command.present()) {
          if (!items.is(LUA_TFUNCTION)) {
            items.fail("must be a function when a command is provided");
          }
        } else {
          PickItemsValidator{limits}.validate(items);
        }
      } else if (!command.present()) {
        definition.fail("requires items or a command");
      }

      if (!CommandArgumentsValidator::validate(definition.field("on_select"))) {
        definition.fail("requires a choice placeholder after the program");
      }
      definition.field("refresh").boolean(false);
    });
  }
};

}
