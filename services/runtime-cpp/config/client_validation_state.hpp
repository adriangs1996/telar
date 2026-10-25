#pragma once

#include "binding_keymap.hpp"
#include "command_tab_registry.hpp"

namespace telar::runtime::config {

struct ClientValidationState {
  CommandTabRegistry commands;
  BindingKeymap keymap;
};

}
