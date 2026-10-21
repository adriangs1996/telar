#pragma once

namespace lua {
  struct Vm;
}

class RuntimeSession;
class DesktopSession;

namespace ui {
  struct Services {
    lua::Vm &vm;
    RuntimeSession &runtime;
    DesktopSession &desktop;
  };
} // namespace ui
