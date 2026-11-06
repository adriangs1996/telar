#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../diagnostics/line.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <chrono>
#include <cstdint>
#include <charconv>
#include <cstring>
#include <limits>
#include <optional>
#include <utility>



import telar.runtime.command_capture.tracker;

using namespace telar;
using namespace telar::runtime;

namespace {

struct Completion {
  std::optional<int> exit_code;

  void complete(CommandCompletion completion) noexcept {
    exit_code = completion.exit_code;
  }
};

std::span<const Byte> bytes(std::string_view text) {
  return {reinterpret_cast<const Byte *>(text.data()), text.size()};
}

}

extern "C" std::int64_t command_exit_status(const char *input, std::size_t length) {
  CommandZones zones{"/"};
  Completion completion;
  zones.feed(bytes("\x1b]133;A\x07\x1b]133;B\x07"), {}, completion);
  zones.input(bytes("command\r"));
  zones.feed(bytes("\x1b]133;C\x07\x1b]133;D;"), {}, completion);
  zones.feed(bytes({input, length}), {}, completion);
  zones.feed(bytes("\x07"), {}, completion);
  return completion.exit_code ? *completion.exit_code : std::numeric_limits<std::int64_t>::min();
}
