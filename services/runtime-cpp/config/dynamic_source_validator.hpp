#pragma once

#include "command_arguments_validator.hpp"

namespace telar::runtime::config {

class DynamicSourceValidator {
public:
  static void validate(const lua::Value &source) {
    const auto kind = source.field("bar_kind");
    const bool command = kind.string() == "command";
    if (command) {
      source.onlyFields({"bar_kind", "command", "every_ms", "timeout_ms", "render"});
      source.field("timeout_ms").boundedInteger(2000, 100, 10000);
      CommandArgumentsValidator::validate(source.field("command"));
    } else {
      if (kind.string() != "dynamic") {
        kind.fail("requires a render function or a command");
      }
      source.onlyFields({"bar_kind", "every_ms", "render"});
    }

    source.field("every_ms").boundedInteger(1000, 100, 3600000);
    const auto render = source.field("render");
    if ((!command || render.present()) && !render.is(LUA_TFUNCTION)) {
      render.fail("must be a function");
    }
  }
};

}
