#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <array>
#include <cerrno>
#include <charconv>
#include <concepts>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <fcntl.h>
#include <filesystem>
#include <limits.h>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#include <algorithm>
#include <cstring>
#include <limits>
#include <type_traits>

import telar.testing;
import telar.cli.commands.integration.settings;
import telar.base.text.json;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.base.memory.allocators;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using telar::AgentProvider;
  using namespace telar::runtime::cli;

  namespace {

    template <Allocator Memory>
    void testSettings(Memory& memory) {
      for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::cursor}) {
        const auto specification = integration::Provider::describe(provider);
        const integration::HookSettings hooks{memory, specification, "/fixture/telar"};
        auto settings = JsonNode<Memory>::parse(memory, "{}");

        check(hooks.install(settings));
        check(!hooks.install(settings));
        for (const auto event : specification.events) {
          check(hooks.installed(settings, event));
          const auto& entry = settings.find("hooks")->find(event)->children().front();
          const auto& hook = specification.flat_hooks ? entry : entry.find("hooks")->children().front();
          const auto expected = std::string{"[ -n \"$TELAR_PANE_ID\" ] && [ -n \"$TELAR_PANE_GENERATION\" ] || exit 0; telar_hook_bin=${TELAR_BIN_PATH:-'/fixture/telar'}; exec \"$telar_hook_bin\" hook "} + std::string{specification.name};

          check(hook.find("command")->text() == expected);
        }

        // Worktree hooks answer Claude outside telar too: they carry no pane guard.
        for (const auto event : specification.worktree_events) {
          check(hooks.installed(settings, event));
          const auto& entry = settings.find("hooks")->find(event)->children().front();
          const auto command = entry.find("hooks")->children().front().find("command")->text();

          check(command.contains("'/fixture/telar'") && !command.contains("TELAR_PANE_ID"));
        }

        const integration::HookSettings upgraded{memory, specification, "/new path/telar"};

        check(upgraded.install(settings) && !upgraded.install(settings));
        const auto formatted = settings.format();

        check(formatted.view().contains("/new path/telar") && !formatted.view().contains("/fixture/telar"));
        check(upgraded.uninstall(settings) && !upgraded.uninstall(settings));
        check(settings.find("hooks")->children().empty());
        for (const auto event : specification.events) {
          check(!hooks.installed(settings, event));
        }
      }
    }

    template <Allocator Memory>
    void testMixedHooks(Memory& memory) {
      auto settings = JsonNode<Memory>::parse(memory, R"({"custom":{"keep":[1,true,null,"text"]},"hooks":{"Stop":[{"matcher":"*","hooks":[{"command":"first hook claude","timeout":99},{"command":"keep me"},{"command":"second hook claude"}]},{"hooks":[]},{"custom":true}]}})");
      const integration::HookSettings hooks{memory, integration::Provider::describe(AgentProvider::claude), "/fixture/telar"};

      check(hooks.install(settings));
      const auto& group = settings.find("hooks")->find("Stop")->children()[0];
      const auto commands = group.find("hooks")->children();

      check(commands.size() == 3 && commands[0].find("command")->text().contains("/fixture/telar"));
      check(commands[0].find("timeout")->text() == "99" && commands[2].find("command")->text() == "second hook claude");
      check(hooks.uninstall(settings));
      const auto entries = settings.find("hooks")->find("Stop")->children();

      check(entries.size() == 2 && entries[0].find("matcher")->text() == "*");
      check(entries[0].find("hooks")->children().size() == 1 && entries[0].find("hooks")->children()[0].find("command")->text() == "keep me");
      check(settings.find("custom")->find("keep")->children().size() == 4);
    }

    // What /bin/sh prints running `command`, with a pane's identity set.
    std::string ranInPane(std::string_view command) {
      check(::setenv("TELAR_PANE_ID", "1", 1) == 0 && ::setenv("TELAR_PANE_GENERATION", "1", 1) == 0 && ::unsetenv("TELAR_BIN_PATH") == 0);
      FILE* pipe = ::popen(std::string{command}.c_str(), "r");

      check(pipe != nullptr);
      std::string output;
      ds::Array<char, 256> buffer;

      while (const auto count = std::fread(buffer.dataMut(), 1, buffer.size(), pipe)) {
        output.append(buffer.data(), count);
      }

      ::pclose(pipe);
      return output;
    }

    // The executable reaches the shell as one quoted word: spaces and `$(…)` in its path run
    // nothing, and a quote, which would close the word, is refused.
    template <Allocator Memory>
    void testExecutableQuoting(Memory& memory) {
      const auto specification = integration::Provider::describe(AgentProvider::claude);
      ds::Array<char, 64> temporary{};

      std::strcpy(temporary.dataMut(), "/tmp/telar-hook-quote-XXXXXX");
      check(::mkdtemp(temporary.dataMut()) != nullptr);
      const std::string root = temporary.data();
      const auto directory = root + "/a b $(touch ran)";
      const auto executable = directory + "/telar";

      check(::mkdir(directory.c_str(), 0700) == 0);
      {
        FILE* script = std::fopen(executable.c_str(), "w");

        check(script != nullptr);
        std::fputs("#!/bin/sh\nprintf '%s ' \"$@\"\n", script);
        std::fclose(script);
      }

      check(::chmod(executable.c_str(), 0700) == 0);
      {
        const integration::HookSettings hooks{memory, specification, executable};
        auto settings = JsonNode<Memory>::parse(memory, "{}");

        check(hooks.install(settings));
        const auto& entry = settings.find("hooks")->find("Stop")->children().front();
        const auto command = entry.find("hooks")->children().front().find("command")->text();

        check(::chdir(root.c_str()) == 0);
        const auto ran = ranInPane(command);

        check(ran == "hook claude ", ran);
        check(::access((root + "/ran").c_str(), F_OK) != 0);
      }

      bool refused = false;

      try {
        const integration::HookSettings quoted{memory, specification, root + "/it's/telar"};
      } catch (const std::exception&) {
        refused = true;
      }

      check(refused);
      std::filesystem::remove_all(root);
    }

    template <Allocator Memory>
    void testJsonDocument(Memory& memory) {
      for (const auto source : {R"({"key":1,"key":2})", R"({"nested":{"a":true,"\u0061":false}})", R"({"x":[{"a":0,"a":1}]})", "{", "[] trailing"}) {
        bool rejected = false;

        try {
          JsonNode<Memory>::parse(memory, source);
        } catch (const std::exception&) {
          rejected = true;
        }

        check(rejected);
      }

      auto document = JsonNode<Memory>::parse(memory, R"({"unicode":"λ\n\"","nested":[{},[],1e30,null,false]})");
      auto restored = JsonNode<Memory>::parse(memory, document.format());

      check(document.format() == restored.format());
    }

  }

  // Each case owns the budget its calls share and leaves nothing allocated there.
  template <auto body>
  void budgeted() {
    SystemAllocator system;
    BudgetAllocator budget{system, 16 * 1024 * 1024};
    MemoryAdapter adapter{budget};
    Memory& memory = adapter;

    body(memory);
    check(budget.liveBytes() == 0);
  }

  static const telar::testing::Case case_settings{
      "integration.settings",
      budgeted<[](auto& memory) {
        testSettings(memory);
      }>,
  };
  static const telar::testing::Case case_mixed_hooks{
      "integration.mixed_hooks",
      budgeted<[](auto& memory) {
        testMixedHooks(memory);
      }>,
  };
  static const telar::testing::Case case_executable_quoting{
      "integration.executable_quoting",
      budgeted<[](auto& memory) {
        testExecutableQuoting(memory);
      }>,
  };
  static const telar::testing::Case case_json_document{
      "integration.json_document",
      budgeted<[](auto& memory) {
        testJsonDocument(memory);
      }>,
  };

}
