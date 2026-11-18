#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.vocabulary;
import telar.platform.process;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  constexpr std::array<std::string_view, 5> pane_identity{"SSH_AUTH_SOCK", "TELAR_PANE_ID", "TELAR_PANE_GENERATION", "TELAR_WORKSPACE_ID", "TELAR_TAB_ID"};

  // A helper the runtime runs for itself reaches neither the user's ssh-agent nor the identity
  // of a pane, so an agent hook gated on TELAR_PANE_ID does not fire from it; a helper the
  // user configured keeps the environment it was given.
  void testAdministrationCommandDropsPaneIdentity() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    const std::array<std::string_view, 1> arguments{"/bin/sh"};
    const std::array<EnvironmentEntry, 6> environment{{
        {"SSH_AUTH_SOCK", "/tmp/agent.sock"},
        {"TELAR_PANE_ID", "7"},
        {"TELAR_PANE_GENERATION", "2"},
        {"TELAR_WORKSPACE_ID", "3"},
        {"TELAR_TAB_ID", "4"},
        {"PATH", "/usr/bin:/bin"},
    }};

    const Launch launch{.cwd = "/", .arguments = arguments, .environment_mode = EnvironmentMode::replace, .environment = environment};

    const Command administration{memory, launch, CommandPurpose::administration};

    for (const auto name : pane_identity) {
      check(!administration.environment(name).has_value());
    }

    check(administration.environment("PATH") == "/usr/bin:/bin");

    const Command helper{memory, launch, CommandPurpose::configured_helper};

    for (const auto& entry : environment) {
      check(helper.environment(entry.name) == entry.value);
    }
  }

  // Input and output are pumped together: a program that echoes a large input as it reads
  // it finishes, instead of both ends blocking on full pipes.
  void testLargeInputDoesNotDeadlock() {
    std::atomic<bool> finished{false};
    std::thread watchdog{[&] {
      for (int tick = 0; tick < 300 && !finished.load(); ++tick) {
        std::this_thread::sleep_for(std::chrono::milliseconds{100});
      }

      check(finished.load(), "a large input to cat did not finish");
    }};

    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    std::string input(std::size_t{4} << 20, '\0');

    for (std::size_t index = 0; index < input.size(); ++index) {
      input[index] = static_cast<char>(index * 31 % 251);
    }

    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    const std::array<std::string_view, 1> pieces{input};
    Command command{memory, Launch{.arguments = arguments}, CommandPurpose::configured_helper};
    CommandOutput<Memory> process{memory, 0};
    std::string output;
    const auto status = process.streamWithInput(
        command,
        std::chrono::steady_clock::now() + std::chrono::seconds{5},
        pieces,
        [&](std::span<const Byte> bytes) {
          output.append(reinterpret_cast<const char*>(bytes.data()), bytes.size());
          return true;
        },
        [](std::span<const Byte>) {}
    );

    finished = true;
    watchdog.join();
    check(status == 0);
    check(output == input);
  }

  const telar::testing::Case case_administration_environment{"process.administration_command_drops_pane_identity", testAdministrationCommandDropsPaneIdentity};
  const telar::testing::Case case_large_input{"process.large_input_does_not_deadlock", testLargeInputDoesNotDeadlock};

}
