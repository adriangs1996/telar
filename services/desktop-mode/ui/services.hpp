#pragma once

namespace lua {
  struct Vm;
}

class RuntimeSession;
class DesktopSession;
class Shortcuts;

namespace ui {
  struct Services {
    lua::Vm &vm;
    RuntimeSession &runtime;
    DesktopSession &desktop;
    Shortcuts &shortcuts;
  };
} // namespace ui
