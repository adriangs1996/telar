#pragma once

#include "action_description_reader.hpp"
#include "action_descriptions.hpp"
#include "action_reader.hpp"
#include "core/memory.hpp"
#include "input/action.hpp"
#include "telar_config/client_definitions.hpp"
#include "telar_lua/value.hpp"
#include <optional>

namespace telar::gui {

template <Allocator Memory>
class RecordingActionReader {
public:
  explicit RecordingActionReader(const BindingActionReader &reader, ActionDescriptions<Memory> &descriptions, const runtime::config::ClientDefinitions &definitions)
      : reader_(reader),
        descriptions_(descriptions),
        definitions_(definitions) {}

  [[nodiscard]] std::optional<BindingAction> read(const runtime::lua::Value &value, bool expression = false) const {
    auto action = reader_.read(value, expression);
    if (!action) {
      return {};
    }

    if (action->kind == BindingActionKind::callback || action->kind == BindingActionKind::expression) {
      action->parameter = descriptions_.registerCallback();
    } else if (action->kind == BindingActionKind::extended) {
      action->parameter = descriptions_.retain(ActionDescriptionReader::read(value, definitions_));
    }

    return action;
  }

private:
  const BindingActionReader &reader_;
  ActionDescriptions<Memory> &descriptions_;
  const runtime::config::ClientDefinitions &definitions_;
};

}
