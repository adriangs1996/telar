#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <stdexcept>
#include "telar_base/memory/allocator.hpp"
#include <string_view>
#include "telar_base/text/utf8.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <concepts>
#include <cstdlib>
#include <exception>
#include <charconv>
#include <cstdint>
#include <optional>
#include <span>
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <limits.h>
#include <unistd.h>
#include "telar_platform/random_bytes.hpp"
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#include <algorithm>
#include "integration_assets.hpp"
#include <cstring>
#include <limits>
#include <type_traits>

import telar.cli.tests.check;
import telar.cli.integration.settings;
import telar.cli.tab;

using namespace telar;
using namespace telar::runtime;
using telar::AgentProvider;
using namespace telar::runtime::cli;

namespace {

template <Allocator Memory>
void testSettings(Memory &memory) {
  for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::cursor}) {
    const auto specification = integration::Provider::describe(provider);
    const integration::HookSettings hooks{memory, specification, "/fixture/telar"};
    auto settings = JsonNode<Memory>::parse(memory, "{}");
    check(hooks.install(settings));
    check(!hooks.install(settings));
    for (const auto event : specification.events) {
      check(hooks.installed(settings, event));
      const auto &entry = settings.find("hooks")->find(event)->children().front();
      const auto &hook = specification.flat_hooks ? entry : entry.find("hooks")->children().front();
      const auto expected = std::string{"[ -n \"$TELAR_PANE_ID\" ] && [ -n \"$TELAR_PANE_GENERATION\" ] || exit 0; telar_hook_bin=${TELAR_BIN_PATH:-'/fixture/telar'}; exec \"$telar_hook_bin\" hook "} + std::string{specification.name};
      check(hook.find("command")->text() == expected);
    }

    const integration::HookSettings upgraded{memory, specification, "/new path/telar"};
    check(upgraded.install(settings) && !upgraded.install(settings));
    const auto formatted = settings.format();
    check(formatted.contains("/new path/telar") && !formatted.contains("/fixture/telar"));
    check(upgraded.uninstall(settings) && !upgraded.uninstall(settings));
    check(settings.find("hooks")->children().empty());
    for (const auto event : specification.events) {
      check(!hooks.installed(settings, event));
    }
  }
}

template <Allocator Memory>
void testMixedHooks(Memory &memory) {
  auto settings = JsonNode<Memory>::parse(memory, R"({"custom":{"keep":[1,true,null,"text"]},"hooks":{"Stop":[{"matcher":"*","hooks":[{"command":"first hook claude","timeout":99},{"command":"keep me"},{"command":"second hook claude"}]},{"hooks":[]},{"custom":true}]}})");
  const integration::HookSettings hooks{memory, integration::Provider::describe(AgentProvider::claude), "/fixture/telar"};
  check(hooks.install(settings));
  const auto &group = settings.find("hooks")->find("Stop")->children()[0];
  const auto commands = group.find("hooks")->children();
  check(commands.size() == 3 && commands[0].find("command")->text().contains("/fixture/telar"));
  check(commands[0].find("timeout")->text() == "99" && commands[2].find("command")->text() == "second hook claude");
  check(hooks.uninstall(settings));
  const auto entries = settings.find("hooks")->find("Stop")->children();
  check(entries.size() == 2 && entries[0].find("matcher")->text() == "*");
  check(entries[0].find("hooks")->children().size() == 1 && entries[0].find("hooks")->children()[0].find("command")->text() == "keep me");
  check(settings.find("custom")->find("keep")->children().size() == 4);
}

template <Allocator Memory>
void testJsonDocument(Memory &memory) {
  for (const auto source : {R"({"key":1,"key":2})", R"({"nested":{"a":true,"\u0061":false}})", R"({"x":[{"a":0,"a":1}]})", "{", "[] trailing"}) {
    bool rejected = false;
    try {
      JsonNode<Memory>::parse(memory, source);
    } catch (const std::exception &) {
      rejected = true;
    }

    check(rejected);
  }

  auto document = JsonNode<Memory>::parse(memory, R"({"unicode":"λ\n\"","nested":[{},[],1e30,null,false]})");
  auto restored = JsonNode<Memory>::parse(memory, document.format());
  check(document.format() == restored.format());
}

}

int main() {
  try {
    SystemAllocator system;
    BudgetAllocator memory{system, 16 * 1024 * 1024};
    testSettings(memory);
    testMixedHooks(memory);
    testJsonDocument(memory);
    check(memory.liveBytes() == 0);
    std::puts("Integration tests passed");
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
