#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.machines;
import telar.cli.machine_ssh;
import telar.cli.machine;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::cli;
  using namespace telar::runtime::machines;

  std::string failure(Memory& memory, const MachineProfiles& profiles, const MachineOptions& options) {
    try {
      machine::resolve(memory, profiles, options);
    } catch (const std::exception& error) {
      return error.what();
    }

    return {};
  }

  // `machine setup DESTINATION` names a new machine after its host: a host that makes no
  // label asks for --label, which then names it; a saved machine's destination is that
  // machine, not a second one.
  void resolveDerivesLabel() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    const auto profiles = MachineProfileCodec::parse(memory, R"({"version":2,"local_label":"local","machines":[{"id":"m-0123456789ab","label":"box","destination":"dev@host","enabled":true}]})");

    check(failure(memory, profiles, {.action = MachineOptions::Action::setup, .label = "_svc"}) == "MachineLabelNeeded");

    const auto named = machine::resolve(memory, profiles, {.action = MachineOptions::Action::setup, .label = "_svc", .new_label = "svc"});

    check(named.label == "svc" && named.destination == "_svc" && !named.saved);

    const auto saved = machine::resolve(memory, profiles, {.action = MachineOptions::Action::setup, .label = "dev@host"});

    check(saved.label == "box" && saved.destination == "dev@host" && saved.saved && saved.saved->label() == "box");
  }

  const telar::testing::Case case_resolve_derives_label{"setup.resolve_derives_label", resolveDerivesLabel};

}
