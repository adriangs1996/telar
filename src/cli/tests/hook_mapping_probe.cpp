#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <openssl/md5.h>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.base.text.json;
import telar.base.text.utf8;
import telar.platform.primitives;
import telar.cli.hook;
import telar.platform.paths;
import telar.wire.vocabulary;

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::cli::hooks;

int main() {
  SystemAllocator system;
  BudgetAllocator budget{system, 64 * 1024 * 1024};
  MemoryAdapter adapter{budget};
  Memory& memory = adapter;
  String<Memory> input{AllocatorRef<char, Memory>{memory}};

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

    // A Claude payload maps without reading the environment.
    map(payload, reports, files, process_environment);
    checksum += reports.event.view().size();
    ++iterations;
  } while (std::chrono::steady_clock::now() < deadline);

  std::printf("{\"iterations\":%zu,\"checksum\":%zu,\"allocations\":%zu,\"peak_bytes\":%zu}\n", iterations, checksum, budget.allocations(), budget.peakBytes());
}
