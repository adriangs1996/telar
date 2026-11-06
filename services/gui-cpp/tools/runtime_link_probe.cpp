#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <charconv>
#include <concepts>
#include <cstring>
#include <string_view>
#include <system_error>
#include <span>
#include "telar_base/memory/fixed_text.hpp"
#include <optional>
#include "probe_io.hpp"
#include <algorithm>
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <chrono>
#include <limits>
#include <cstdio>
#include <exception>
#include <iostream>

#include "core/memory.hpp"


import telar.gui.machines.picker;
import telar.gui.transport.runtime_link;

namespace {

using namespace telar::gui;
using namespace telar::gui::probe;
constexpr std::size_t maximum_input = 65536;

String<SystemAllocator> text(SystemAllocator &memory) {
  const auto size = read<std::uint32_t>();
  if (size > maximum_input) {
    throw std::length_error{"ProbeTextTooLong"};
  }

  String<SystemAllocator> value{AllocatorRef<char, SystemAllocator>{memory}};
  value.resize(size);
  if (std::fread(value.data(), 1, size, stdin) != size) {
    throw std::runtime_error{"IncompleteProbeText"};
  }

  return value;
}

void writeText(std::string_view value) {
  write(static_cast<std::uint32_t>(value.size()));
  if (std::fwrite(value.data(), 1, value.size(), stdout) != value.size()) {
    throw std::runtime_error{"ProbeTextWriteFailed"};
  }
}

void sample(SystemAllocator &memory) {
  RuntimeLink link;
  link.phase = read<MachinePhase>();
  link.attempt = read<std::uint16_t>();
  link.sessions = read<std::uint32_t>();
  link.setup_repairs = read<std::uint8_t>() != 0;
  link.name(text(memory));
  link.fail(text(memory));
  writeText(link.target());
  writeText(link.failure().value_or(std::string_view{}));
  writeText(link.headline().view());
  write(link.retryDelayMilliseconds());
}

}

int main() {
  try {
    SystemAllocator memory;
    while (std::getchar() != EOF) {
      sample(memory);
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
