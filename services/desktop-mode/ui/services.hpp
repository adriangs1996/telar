#pragma once

#include <string>

namespace workbench {
  class Controller;
}

namespace lua {
  struct Vm;
}

class RuntimeSession;
class DesktopSession;
class Shortcuts;

namespace ui {
  class ModuleWatch;

  struct Services {
    lua::Vm &vm;
    RuntimeSession &runtime;
    DesktopSession &desktop;
    Shortcuts &shortcuts;
    std::string runtime_socket;
    workbench::Controller *workbench = nullptr;
    // Owned by the desktop UI; null without one, and then nothing reloads on change.
    ModuleWatch *modules = nullptr;
  };
} // namespace ui
