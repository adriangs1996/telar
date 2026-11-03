#include "../hooks/input.hpp"
#include "../hooks/map.hpp"
#include "../hooks/target.hpp"
#include "check.hpp"
#include "telar_platform/temporary_directory.hpp"
#include <fstream>

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::cli::hooks;

struct EmptyEnvironment {
  std::string_view lookup(const char *) const noexcept { return {}; }
};

static void allocationFailures() {
  SystemAllocator system;
  constexpr std::string_view input = R"({"hook_event_name":"PostToolUse","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"Step with enough text to require allocated storage","status":"in_progress"}]}})";
  bool completed = false;
  for (std::size_t capacity = 0; capacity <= 64 * 1024; capacity += 128) {
    BudgetAllocator memory{system, capacity};
    try {
      Payload payload{memory, AgentProvider::claude, JsonValue::parse(input)};
      Reports reports;
      SessionFiles files;
      map(payload, reports, files, EmptyEnvironment{});
      check(reports.progress && reports.progress->plan_total == 1);
      check(reports.progress->plan_text == "Step with enough text to require allocated storage");
      completed = true;
    } catch (const std::bad_alloc &) {
    }

    check(memory.liveBytes() == 0);
  }

  check(completed);
}

static void boundedInput() {
  SystemAllocator system;
  BudgetAllocator memory{system, 64 * 1024 * 1024};
  TemporaryDirectory directory{"/tmp/telar-hook-input-XXXXXX"};
  FileDescriptor file{::openat(directory.descriptor(), "input", O_RDWR | O_CREAT | O_CLOEXEC, 0600)};
  check(static_cast<bool>(file));
  constexpr std::string_view prefix = R"({"hook_event_name":"SessionStart","number":17,"tool_input":{"content":")";
  check(::write(file.get(), prefix.data(), prefix.size()) == static_cast<ssize_t>(prefix.size()));
  std::array<char, 4096> padding;
  padding.fill('x');
  for (std::size_t written = prefix.size(); written <= Input<SystemAllocator>::maximum_bytes; written += padding.size()) {
    check(::write(file.get(), padding.data(), padding.size()) == static_cast<ssize_t>(padding.size()));
  }

  const auto size = ::lseek(file.get(), 0, SEEK_CUR);
  check(::lseek(file.get(), 0, SEEK_SET) == 0);
  {
    Input input{memory};
    input.read(file.get());
    check(input.limited() && input.received() == static_cast<std::uint64_t>(size));
    Object object{memory, JsonValue::parse(input.text())};
    check(object.text("hook_event_name") == "SessionStart");
    check(object.integer<unsigned>("number") == 17);
    check(!object.value("tool_input"));
    char byte;
    check(::read(file.get(), &byte, 1) == 0);
  }

  check(memory.liveBytes() == 0);
}

int main() {
  allocationFailures();
  boundedInput();
  std::puts("All hook tests passed");
}
