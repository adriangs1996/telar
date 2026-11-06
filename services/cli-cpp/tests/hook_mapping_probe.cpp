#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/fixed_text.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include "telar_base/memory/allocator.hpp"
#include <exception>
#include <charconv>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include "telar_base/text/utf8.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <chrono>
#include <limits>
#include <cstring>
#include <unistd.h>
#include <concepts>
#include <dirent.h>
#include <cstdlib>
#include <openssl/md5.h>
#include "telar_platform/trace.hpp"
#include <cstdio>



import telar.cli.hook;

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::cli::hooks;

struct EmptyEnvironment {
  std::string_view lookup(const char *) const noexcept { return {}; }
};

int main() {
  SystemAllocator system;
  BudgetAllocator memory{system, 64 * 1024 * 1024};
  String<decltype(memory)> input{AllocatorRef<char, decltype(memory)>{memory}};
  input = R"({"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"fixture.txt","content":")";
  input.append(512 * 1024, 'x');
  input += "\"}}";
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  std::size_t iterations = 0;
  std::size_t checksum = 0;
  do {
    validateUtf8(input);
    const auto parsed = JsonValue::parse(input);
    validateUnicodeEscapes(memory, input);
    Object preliminary{memory, parsed, true};
    preliminary.text("hook_event_name");
    Payload payload{memory, AgentProvider::claude, std::move(preliminary)};
    Reports reports;
    SessionFiles files;
    map(payload, reports, files, EmptyEnvironment{});
    checksum += reports.event.view().size();
    ++iterations;
  } while (std::chrono::steady_clock::now() < deadline);
  std::printf("{\"iterations\":%zu,\"checksum\":%zu,\"allocations\":%zu,\"peak_bytes\":%zu}\n", iterations, checksum, memory.allocations(), memory.peakBytes());
}
