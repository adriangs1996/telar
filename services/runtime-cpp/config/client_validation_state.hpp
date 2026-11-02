#pragma once

#include "binding_keymap.hpp"
#include "command_tab_registry.hpp"

namespace telar::runtime::config {

template <CommandTabStore Commands>
struct BasicClientValidationState {
  Commands commands;
  BindingKeymap keymap;
};

using ClientValidationState = BasicClientValidationState<CommandTabRegistry>;
using RetainedClientValidationState = BasicClientValidationState<RetainedCommandTabRegistry>;

}
