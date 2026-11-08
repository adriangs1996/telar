module;
#include <cstdint>
#include <cstdio>

export module telar.gui.tools.probe_text;

import std;
export import telar.gui.core.primitives;
export import telar.gui.tools.probe_io;

export {
namespace telar::gui::probe {

template <Allocator Memory>
String<Memory> readText(Memory &memory) {
  const auto length = read<std::uint16_t>();
  String<Memory> text(length, '\0', AllocatorRef<char, Memory>{memory});
  if (length != 0 && std::fread(text.data(), length, 1, stdin) != 1) {
    throw std::runtime_error{"IncompleteProbeText"};
  }

  return text;
}

inline void writeText(std::string_view text) {
  if (text.size() > std::numeric_limits<std::uint16_t>::max()) {
    throw std::length_error{"ProbeTextExceeded"};
  }

  write(static_cast<std::uint16_t>(text.size()));
  if (!text.empty() && std::fwrite(text.data(), text.size(), 1, stdout) != 1) {
    throw std::runtime_error{"ProbeWriteFailed"};
  }
}

}
}
