#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../diagnostics/line.hpp"
#include "telar_platform/trace.hpp"
#include "../graphics/kitty_framing.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstring>
#include <variant>
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <algorithm>
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "telar_base/memory/allocator.hpp"
#include <stdexcept>
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <optional>
#include "telar_base/diagnostics/config.hpp"
#include "telar_config/graphics/limits.hpp"
#include <limits>
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <cassert>
#include "control_clipboard_fixture.hpp"
#include <chrono>
#include <memory>



import telar.runtime.terminal.text_reader;

using namespace telar;
using namespace telar::runtime;

namespace {
volatile std::uint64_t observed_terminal_output;

struct Probe {
  inline static thread_local Probe *active = nullptr;
  std::uint64_t foreign_calls = 0;

  struct Active {
    explicit Active(Probe &probe) : previous(std::exchange(active, &probe)) {}
    ~Active() { active = previous; }
    Probe *previous;
  };

  static void foreignReply(GhosttyTerminal, void *, const Byte *, std::size_t) noexcept {
    if (active != nullptr) {
      ++active->foreign_calls;
    }
  }

  static GhosttyClipboardWriteResult foreignClipboard(GhosttyTerminal, void *, const GhosttyClipboardWrite *) noexcept {
    if (active != nullptr) {
      ++active->foreign_calls;
    }
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
  }
  SystemAllocator system;
  BudgetAllocator<SystemAllocator> memory{system, 64 * 1024 * 1024};
  Terminal<BudgetAllocator<SystemAllocator>> terminal;
  std::unique_ptr<control_test::MemoryClipboard> clipboard;

  explicit Probe(TerminalSize size) : terminal(memory, size, TerminalPurpose::separate_media) {
    ConfigureTerminalColors colors{};
    colors.foreground = {255, 255, 255};
    colors.background = {0, 0, 0};
    terminal.configureColors(colors);
    checkGhostty(ghostty_terminal_set(terminal.handle(), GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void *>(&foreignReply)));
    checkGhostty(ghostty_terminal_set(terminal.handle(), GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, reinterpret_cast<const void *>(&foreignClipboard)));
  }
};
}

extern "C" void *query_probe_new(std::uint16_t columns, std::uint16_t rows, std::uint16_t width, std::uint16_t height) noexcept {
  try {
    return new Probe{TerminalSize{columns, rows, width, height}};
  } catch (...) {
    return nullptr;
  }
}

extern "C" void query_probe_free(void *context) noexcept {
  delete static_cast<Probe *>(context);
}

extern "C" bool query_probe_feed(void *context, const Byte *bytes, std::size_t size) noexcept {
  try {
    auto &probe = *static_cast<Probe *>(context);
    const Probe::Active active{probe};
    probe.terminal.feed({bytes, size});
    if (probe.clipboard) {
      probe.clipboard->settle(probe.terminal);
    }
    return true;
  } catch (...) {
    return false;
  }
}

extern "C" std::size_t query_probe_drain(void *context, Byte *destination, std::size_t capacity) noexcept {
  auto &probe = *static_cast<Probe *>(context);
  const Probe::Active active{probe};
  auto &terminal = probe.terminal;
  std::size_t written = 0;
  while (!terminal.responses().empty()) {
    const auto bytes = terminal.responses();
    if (bytes.size() > capacity - written) {
      break;
    }

    std::copy(bytes.begin(), bytes.end(), destination + written);
    written += bytes.size();
    terminal.consumeResponses(bytes.size());
  }

  return written;
}

extern "C" std::uint64_t query_probe_benchmark(const Byte *bytes, std::size_t size, std::size_t iterations, std::size_t fragment) noexcept {
  try {
    Probe probe{TerminalSize{80, 24, 9, 18}};
    std::array<Byte, 65536> output;
    const Probe::Active active{probe};
    std::uint64_t observed = 0;
    const auto started = std::chrono::steady_clock::now();
    for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
      for (std::size_t offset = 0; offset < size;) {
        const auto count = std::min(fragment == 0 ? size : fragment, size - offset);
        probe.terminal.feed({bytes + offset, count});
        offset += count;
        const auto written = query_probe_drain(&probe, output.data(), output.size());
        if (written != 0) {
          observed += output.front() + output[written - 1];
        }
      }
    }

    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    observed_terminal_output = observed;
    return elapsed;
  } catch (...) {
    return 0;
  }
}

extern "C" bool query_probe_policy(void *context, std::uint32_t flags, const char *answerback, std::size_t length) noexcept {
  auto &policy = static_cast<Probe *>(context)->terminal.controlPolicy();
  if (length > policy.answerback.size()) {
    return false;
  }
  policy.title_report = (flags & 1) != 0;
  policy.checksum_report = (flags & 2) != 0;
  policy.color_format = (flags & 4) != 0 ? control::ColorFormat::eight_bit : (flags & 8) != 0 ? control::ColorFormat::none : control::ColorFormat::sixteen_bit;
  policy.clipboard_write = (flags & 16) != 0 ? control::Access::deny : control::Access::allow;
  if (length != 0) {
    std::copy_n(answerback, length, policy.answerback.begin());
  }
  policy.answerback_length = static_cast<std::uint16_t>(length);
  return true;
}

extern "C" bool query_probe_facts(void *context, bool light, bool visible, bool focused) noexcept {
  auto &probe = *static_cast<Probe *>(context);
  try {
    const Probe::Active active{probe};
    probe.terminal.configureClientFacts({.light = light, .visible = visible, .focused = focused});
    return true;
  } catch (...) {
    return false;
  }
}

extern "C" std::uint64_t query_probe_foreign_calls(void *context) noexcept {
  return static_cast<Probe *>(context)->foreign_calls;
}

extern "C" bool query_probe_clipboard_config(void *context, std::uint32_t flags) noexcept {
  try {
    auto &probe = *static_cast<Probe *>(context);
    if (!probe.clipboard) {
      probe.clipboard = std::make_unique<control_test::MemoryClipboard>();
      constexpr std::array<control::ClipboardRoute, 1> routes{{{1, 13}}};
      probe.terminal.clipboardControl().routes(routes, routes[0]);
    }
    const auto access = [](unsigned value) { return value == 0 ? control::Access::deny : value == 1 ? control::Access::ask : control::Access::allow; };
    auto &policy = probe.terminal.controlPolicy();
    policy.clipboard_read = access(flags & 3);
    policy.clipboard_write = access((flags >> 2) & 3);
    probe.clipboard->consent = (flags >> 4 & 3) == 0 ? control_test::ClipboardConsent::deny : (flags >> 4 & 3) == 1 ? control_test::ClipboardConsent::once : control_test::ClipboardConsent::session;
    return true;
  } catch (...) {
    return false;
  }
}

extern "C" void query_probe_clipboard_clear(void *context) noexcept {
  static_cast<Probe *>(context)->clipboard->contents.clear();
}

extern "C" bool query_probe_clipboard_put(void *context, const char *mime, const Byte *data, std::size_t length) noexcept {
  try {
    auto &contents = static_cast<Probe *>(context)->clipboard->contents;
    if (contents.size() == 16 || std::char_traits<char>::length(mime) > 256 || length > 4 * 1024 * 1024) {
      return false;
    }
    contents.push_back({mime, {data, data + length}});
    return true;
  } catch (...) {
    return false;
  }
}

extern "C" std::size_t query_probe_clipboard_get(void *context, const char *mime, Byte *data, std::size_t capacity) noexcept {
  for (const auto &content : static_cast<Probe *>(context)->clipboard->contents) {
    if (content.mime == mime) {
      std::copy_n(content.data.begin(), std::min(capacity, content.data.size()), data);
      return content.data.size();
    }
  }
  return SIZE_MAX;
}

extern "C" std::uint64_t query_probe_clipboard_count(void *context, std::uint32_t kind) noexcept {
  auto &fixture = *static_cast<Probe *>(context)->clipboard;
  return kind == 0 ? fixture.reads : kind == 1 ? fixture.writes : fixture.prompts;
}

extern "C" bool query_probe_clipboard_paste(void *context, bool primary) noexcept {
  try {
    auto &probe = *static_cast<Probe *>(context);
    const Probe::Active active{probe};
    if (!probe.clipboard) {
      return false;
    }
    if (probe.terminal.pasteEvents()) {
      std::array<std::string_view, 16> available;
      std::size_t count = 0;
      for (const auto &content : probe.clipboard->contents) {
        if (count == available.size()) {
          break;
        }
        available[count++] = content.mime;
      }
      if (!probe.terminal.clipboardControl().paste({1, 13}, primary, std::span{available}.first(count))) {
        return false;
      }
      probe.terminal.resumeControl();
    }
    return true;
  } catch (...) {
    return false;
  }
}
