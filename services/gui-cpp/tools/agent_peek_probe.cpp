#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstddef>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.tools.probe_io;
import telar.gui.peek.screen;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::probe;
constexpr std::size_t maximum_input = 262144;
constexpr PeekTarget source{.agent = {.pane_id = 9, .pane_generation = 3}};

String<SystemAllocator> text(SystemAllocator &memory) {
  const auto size = read<std::uint32_t>();
  if (size > maximum_input) {
    throw std::length_error{"ProbeTextTooLong"};
  }

  String<SystemAllocator> result{AllocatorRef<char, SystemAllocator>{memory}};
  result.resize(size);
  if (std::fread(result.data(), 1, size, stdin) != size) {
    throw std::runtime_error{"IncompleteProbeText"};
  }

  return result;
}

void writeText(std::string_view value) {
  write(static_cast<std::uint32_t>(value.size()));
  if (std::fwrite(value.data(), 1, value.size(), stdout) != value.size()) {
    throw std::runtime_error{"ProbeTextWriteFailed"};
  }
}

void sample(SystemAllocator &memory) {
  const auto valid_pane = read<Byte>() != 0;
  const auto rows = read<std::uint16_t>();
  const auto input = text(memory);
  const auto command = text(memory);
  PeekScreen screen{memory};
  screen.show(source);
  constexpr std::uint64_t request_id = 1;
  if (!screen.request(request_id)) {
    throw std::runtime_error{"PeekProbeReadNotAdmitted"};
  }

  const auto dropped = screen.store(PaneText{.request_id = request_id, .pane_id = source.agent.pane_id + static_cast<std::uint64_t>(!valid_pane), .text = input, .exit_code = {}});
  write(dropped ? static_cast<std::uint32_t>(*dropped) : std::numeric_limits<std::uint32_t>::max());
  write(screen.revision());
  write(static_cast<Byte>(screen.reading()));
  writeText(screen.text());
  writeText(PeekScreen<SystemAllocator>::lastLines(screen.text(), rows));
  write(PeekInput::command(command));
  writeText(PeekInput::trim(command));
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
