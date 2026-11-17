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

  const telar::testing::Case case_administration_environment{"process.administration_command_drops_pane_identity", testAdministrationCommandDropsPaneIdentity};

}
