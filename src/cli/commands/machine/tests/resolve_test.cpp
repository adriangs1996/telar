#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.machines;
import telar.cli.commands.machine_ssh;
import telar.cli.commands.machine;

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

  // `machine setup ADDRESS` names a new machine after the host of its gateway's address: a
  // host that makes no label asks for --label, which then names it; a saved machine's address
  // is that machine, not a second one; and what is not a gateway's address names no machine.
  void resolveDerivesLabel() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    const std::string_view saved_address = "telar://host:8352#00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const std::string_view unlabelled = "telar://_svc:8352#00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const std::string_view fresh = "telar://fresh.example:8352#00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const auto profiles = MachineProfileCodec::parse(memory, R"({"version":2,"local_label":"local","machines":[{"id":"m-0123456789ab","label":"box","destination":"telar://host:8352#00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","enabled":true}]})");

    check(failure(memory, profiles, {.action = MachineOptions::Action::setup, .label = unlabelled}) == "MachineLabelNeeded");

    const auto named = machine::resolve(memory, profiles, {.action = MachineOptions::Action::setup, .label = unlabelled, .new_label = "svc"});

    check(named.label == "svc" && named.destination == unlabelled && !named.saved);

    const auto derived = machine::resolve(memory, profiles, {.action = MachineOptions::Action::setup, .label = fresh});

    check(derived.label == "fresh.example" && derived.destination == fresh && !derived.saved);

    const auto saved = machine::resolve(memory, profiles, {.action = MachineOptions::Action::setup, .label = saved_address});

    check(saved.label == "box" && saved.destination == saved_address && saved.saved && saved.saved->label() == "box");

    for (const std::string_view destination : {"_svc", "dev@host", "ssh://dev@new:22", "telar://new:8352"}) {
      check(failure(memory, profiles, {.action = MachineOptions::Action::setup, .label = destination, .new_label = "svc"}) == MachineFailure::name(MachineError::invalid_destination));
    }
  }

  const telar::testing::Case case_resolve_derives_label{"setup.resolve_derives_label", resolveDerivesLabel};

}
