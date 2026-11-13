#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include "../core/memory.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <string_view>
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include <span>
#include "telar_base/memory/fixed_text.hpp"
#include <optional>
#include "telar_base/memory/allocator.hpp"
#include <exception>
#include <bit>
#include <limits>
#include <new>
#include <iostream>
#include <string>

#include "core/memory.hpp"


import telar.gui.machines.discovery;
import telar.gui.machines.profile_store;

namespace {

using namespace telar::gui;
using telar::gui::test::require;

template <typename Operation>
void rejects(MachineError expected, Operation operation) {
  try {
    operation();
  } catch (const MachineFailure &failure) {
    require(failure.code() == expected, "machine operation must retain the original error category");

    return;
  }

  throw std::runtime_error{"Machine operation unexpectedly succeeded"};
}

void identitiesKeepTheirStableRepresentationAndInjectedEntropy() {
  const auto identity = MachineId::parse("m-0123456789ab");
  require(identity.format().view() == "m-0123456789ab", "machine identities must retain all twelve lowercase hexadecimal digits");
  rejects(MachineError::invalid_id, [] {
    static_cast<void>(MachineId::parse("m-000000000000"));
  });
  rejects(MachineError::invalid_id, [] {
    static_cast<void>(MachineId::parse("m-0123456789AB"));
  });

  struct Random {
    unsigned calls = 0;

    void fill(std::span<std::uint8_t> bytes) {
      std::ranges::fill(bytes, 0);
      if (++calls > 1) {
        bytes.back() = 1;
      }
    }
  };

  Random random;
  const auto generated = MachineId::generate(random);
  require(random.calls == 2 && generated.format().view() == "m-010000000000", "zero entropy must retry and the generated identity must use the original upper 48 little-endian bits");
}

void profilesPreserveIdentityOrderAndRejectedEdits() {
  MachineProfiles profiles;
  profiles.relabelLocal("local");
  const auto first = MachineId::fromRaw(1);
  const auto second = MachineId::fromRaw(2);
  profiles.add(MachineProfile::create(first, {.label = "one", .destination = "user@one"}));
  profiles.add(MachineProfile::create(second, {.label = "two", .destination = "user@two"}));
  profiles.rename("one", "renamed");
  require(profiles.rows().front().identity() == first && profiles.find("renamed") == 0, "renaming must preserve the connection identity and row position");
  rejects(MachineError::duplicate_label, [&] {
    profiles.rename("renamed", "two");
  });
  rejects(MachineError::duplicate_label, [&] {
    profiles.rename("renamed", "local");
  });
  rejects(MachineError::invalid_label, [&] {
    profiles.rename("renamed", "bad name");
  });
  require(profiles.rows().front().label() == "renamed", "a rejected rename must retain the original profile");
  profiles.enable("renamed", false);
  require(!profiles.rows().front().enabled(), "disabling must retain the saved row");
  profiles.remove("renamed");
  require(profiles.rows().size() == 1 && profiles.rows().front().identity() == second, "removal must retain the relative order of surviving profiles");
  rejects(MachineError::unknown_machine, [&] {
    profiles.remove("missing");
  });
}

void versionsAndJsonRoundTripsPreserveEveryField() {
  SystemAllocator system;
  BudgetAllocator memory{system, MachineLimits::file_bytes};
  auto const *source = R"({"version":1,"local_label":"local","machines":[{"id":"m-000000000001","label":"box","destination":"dev@é'box","color":"#a0B1c2","enabled":false}]})";
  auto profiles = MachineProfileCodec::parse(memory, source);
  require(profiles.version() == MachineProfiles::plain_format_version, "profiles without setup metadata must stay readable by version-one clients");
  profiles.placeProgram("box", "/home/dev/.local/bin/telar");
  profiles.recordLogin("box", MachineAgent::codex, MachineLogin::done);
  require(profiles.version() == MachineProfiles::extended_format_version, "setup metadata must select version two");
  {
    const auto encoded = MachineProfileCodec::format(memory, profiles);
    const auto decoded = MachineProfileCodec::parse(memory, encoded);
    const auto &profile = decoded.rows().front();
    require(decoded.localLabel() == "local" && profile.label() == "box" && profile.destination() == "dev@é'box" && profile.color() == "#a0B1c2" && !profile.enabled(), "JSON round trips must retain local and remote identity fields");
    require(profile.program() == "/home/dev/.local/bin/telar" && profile.login(MachineAgent::codex) == MachineLogin::done, "JSON round trips must retain installed program paths and agent login metadata");
  }

  require(memory.liveBytes() == 0, "parsed profiles must own inline text and release every temporary allocation");
}

void strictJsonRejectsUnknownDuplicatedAndWronglyTypedFields() {
  SystemAllocator memory;
  const auto invalid = std::to_array<std::string_view>({
      R"({"version":1,"machines":[],"unknown":true})",
      R"({"version":1,"version":1,"machines":[]})",
      R"({"version":1,"machines":[{"id":"m-000000000001","label":"box","destination":"host","enabled":1}]})",
      R"({"version":1,"machines":[{"id":"m-000000000001","label":"box","destination":"host","logins":{"other":"done"}}]})",
      R"({"version":1,"machines":[{"id":"m-000000000001","label":"box","destination":"host","logins":{"codex":"unknown"}}]})",
  });
  for (const auto source : invalid) {
    rejects(MachineError::invalid_profiles, [&] {
      static_cast<void>(MachineProfileCodec::parse(memory, source));
    });
  }

  rejects(MachineError::incompatible_profiles, [&] {
    static_cast<void>(MachineProfileCodec::parse(memory, R"({"version":3,"machines":[]})"));
  });
  rejects(MachineError::invalid_profiles, [&] {
    static_cast<void>(MachineProfileCodec::parse(memory, R"({"version":3,"machines":[{"id":"broken","unknown":1}]})"));
  });
}

void capacityAndUniquenessHaveTheOriginalAdmissionOrder() {
  MachineProfiles profiles;
  for (std::size_t index = 0; index < MachineLimits::profiles; ++index) {
    const auto label = "box" + std::to_string(index);
    profiles.add(MachineProfile::create(MachineId::fromRaw(index + 1), {.label = label, .destination = label}));
  }

  rejects(MachineError::too_many, [&] {
    profiles.add(profiles.rows().front());
  });
  profiles.remove("box0");
  rejects(MachineError::duplicate_id, [&] {
    profiles.add(MachineProfile::create(MachineId::fromRaw(2), {.label = "different", .destination = "different"}));
  });
  rejects(MachineError::duplicate_destination, [&] {
    profiles.add(MachineProfile::create(MachineId::fromRaw(1), {.label = "different", .destination = "box1"}));
  });
  require(profiles.rows().size() == MachineLimits::profiles - 1, "rejected profile admissions must not consume capacity");
}

void remoteArgumentsRetainTheirValidationBoundaries() {
  MachineFieldRules::destination("alias;name'quote");
  MachineFieldRules::color("unknown-theme-role");
  MachineFieldRules::program("/home/dev/.local/+telar");
  rejects(MachineError::invalid_destination, [] {
    MachineFieldRules::destination("-oProxyCommand=bad");
  });
  rejects(MachineError::invalid_destination, [] {
    MachineFieldRules::destination("user@host name");
  });
  rejects(MachineError::invalid_destination, [] {
    MachineFieldRules::profileDestination(std::string_view{"host\x80"});
  });
  rejects(MachineError::invalid_program, [] {
    MachineFieldRules::program("/safe/../bad");
  });
  rejects(MachineError::invalid_program, [] {
    MachineFieldRules::program("/safe/name;command");
  });
  rejects(MachineError::invalid_color, [] {
    MachineFieldRules::color("#123");
  });
}

void allocationRejectionReleasesEveryTemporary() {
  SystemAllocator system;
  BudgetAllocator memory{system, 0};
  const auto source = std::string{R"({"version":1,"machines":[{"id":"m-000000000001","label":"box","destination":")"} + std::string(MachineLimits::destination_bytes, 'x') + R"("}]})";
  bool rejected = false;
  try {
    static_cast<void>(MachineProfileCodec::parse(memory, source));
  } catch (const std::bad_alloc &) {
    rejected = true;
  }

  require(rejected && memory.liveBytes() == 0 && memory.failures() != 0, "allocation rejection must stay observable and release every parser temporary");
}

}

int main() {
  try {
    identitiesKeepTheirStableRepresentationAndInjectedEntropy();
    profilesPreserveIdentityOrderAndRejectedEdits();
    versionsAndJsonRoundTripsPreserveEveryField();
    strictJsonRejectsUnknownDuplicatedAndWronglyTypedFields();
    capacityAndUniquenessHaveTheOriginalAdmissionOrder();
    remoteArgumentsRetainTheirValidationBoundaries();
    allocationRejectionReleasesEveryTemporary();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
