module;
#include <cstdio>

export module telar.gui.tools.probe_io;

import std;

export {
namespace telar::gui::probe {

template <typename Value>
  requires std::is_trivially_copyable_v<Value>
Value read() {
  Value value{};
  if (std::fread(std::addressof(value), sizeof(Value), 1, stdin) != 1) {
    throw std::runtime_error{"IncompleteProbeRequest"};
  }

  return value;
}

template <typename Value>
  requires std::is_trivially_copyable_v<Value>
void write(const Value &value) {
  if (std::fwrite(std::addressof(value), sizeof(Value), 1, stdout) != 1) {
    throw std::runtime_error{"ProbeWriteFailed"};
  }
}

}
}
