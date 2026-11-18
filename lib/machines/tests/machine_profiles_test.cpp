#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include <array>
#include <cstddef>
#include <cstring>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

import telar.testing;
import telar.machines;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::runtime::machines;

  template <typename Operation>
  void rejects(MachineError expected, Operation operation) {
    try {
      operation();
    } catch (const MachineFailure& failure) {
      check(failure.code() == expected, "machine operation must retain the original error category");

      return;
    }

    throw std::runtime_error{"Machine operation unexpectedly succeeded"};
  }

  void identitiesKeepTheirStableRepresentation() {
    const auto identity = MachineId::parse("m-0123456789ab");

    check(identity.format().view() == "m-0123456789ab", "machine identities must retain all twelve lowercase hexadecimal digits");
    rejects(MachineError::invalid_id, [] {
      static_cast<void>(MachineId::parse("m-000000000000"));
    });

    rejects(MachineError::invalid_id, [] {
      static_cast<void>(MachineId::parse("m-0123456789AB"));
    });
  }

  void profilesPreserveIdentityOrderAndRejectedEdits() {
    MachineProfiles profiles;

    profiles.relabelLocal("local");
    const auto first = MachineId::fromRaw(1);
    const auto second = MachineId::fromRaw(2);

    profiles.add(MachineProfile::create(first, {.label = "one", .destination = "user@one"}));
    profiles.add(MachineProfile::create(second, {.label = "two", .destination = "user@two"}));
    profiles.rename("one", "renamed");
    check(profiles.rows().front().identity() == first && profiles.find("renamed") == 0, "renaming must preserve the connection identity and row position");
    rejects(MachineError::duplicate_label, [&] {
      profiles.rename("renamed", "two");
    });

    rejects(MachineError::duplicate_label, [&] {
      profiles.rename("renamed", "local");
    });

    rejects(MachineError::invalid_label, [&] {
      profiles.rename("renamed", "bad name");
    });

    check(profiles.rows().front().label() == "renamed", "a rejected rename must retain the original profile");
    profiles.enable("renamed", false);
    check(!profiles.rows().front().enabled(), "disabling must retain the saved row");
    profiles.remove("renamed");
    check(profiles.rows().size() == 1 && profiles.rows().front().identity() == second, "removal must retain the relative order of surviving profiles");
    rejects(MachineError::unknown_machine, [&] {
      profiles.remove("missing");
    });
  }

  void versionsAndJsonRoundTripsPreserveEveryField() {
    SystemAllocator system;
    BudgetAllocator budget{system, MachineLimits::file_bytes};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    auto const* source = R"({"version":1,"local_label":"local","machines":[{"id":"m-000000000001","label":"box","destination":"dev@é'box","color":"#a0B1c2","enabled":false}]})";
    auto profiles = MachineProfileCodec::parse(memory, source);

    check(profiles.version() == MachineProfiles::plain_format_version, "profiles without setup metadata must stay readable by version-one clients");
    profiles.placeProgram("box", "/home/dev/.local/bin/telar");
    profiles.recordLogin("box", MachineAgent::codex, MachineLogin::done);
    check(profiles.version() == MachineProfiles::extended_format_version, "setup metadata must select version two");
    {
      const auto encoded = MachineProfileCodec::format(memory, profiles);
      const auto decoded = MachineProfileCodec::parse(memory, encoded);
      const auto& profile = decoded.rows().front();

      check(decoded.localLabel() == "local" && profile.label() == "box" && profile.destination() == "dev@é'box" && profile.color() == "#a0B1c2" && !profile.enabled(), "JSON round trips must retain local and remote identity fields");
      check(profile.program() == "/home/dev/.local/bin/telar" && profile.login(MachineAgent::codex) == MachineLogin::done, "JSON round trips must retain installed program paths and agent login metadata");
    }

    check(budget.liveBytes() == 0, "parsed profiles must own inline text and release every temporary allocation");
  }

  void strictJsonRejectsUnknownDuplicatedAndWronglyTypedFields() {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::Memory& memory = adapter;
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

  // Files written before logins were named store each login as its ordinal: one in range loads
  // as that login, one past the names is refused rather than kept for format() to trip on.
  void loginOrdinalsLoadWithinTheirNames() {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::Memory& memory = adapter;
    const auto profiles = MachineProfileCodec::parse(memory, R"({"version":2,"machines":[{"id":"m-000000000001","label":"box","destination":"host","logins":{"codex":1}}]})");

    check(profiles.rows().front().login(MachineAgent::codex) == MachineLogin::done, "an in-range login ordinal must load as that login");
    rejects(MachineError::invalid_profiles, [&] {
      static_cast<void>(MachineProfileCodec::parse(memory, R"({"version":2,"machines":[{"id":"m-000000000001","label":"box","destination":"host","logins":{"codex":3}}]})"));
    });
  }

  // Only the versions this build writes load: an older one is incompatible, and the version may
  // be written as a string.
  void onlyKnownVersionsLoad() {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::Memory& memory = adapter;

    rejects(MachineError::incompatible_profiles, [&] {
      static_cast<void>(MachineProfileCodec::parse(memory, R"({"version":0,"machines":[]})"));
    });

    const auto profiles = MachineProfileCodec::parse(memory, R"({"version":"2","machines":[{"id":"m-000000000001","label":"box","destination":"host"}]})");

    check(profiles.rows().size() == 1 && profiles.rows().front().label() == "box", "a string version must load like the number");
  }

  // A hand-edited file is admitted row by row like `machine add`: rows that share an identity,
  // a destination or the local label, or more rows than fit, are refused.
  void filesRefuseDuplicateRows() {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::Memory& memory = adapter;

    rejects(MachineError::duplicate_id, [&] {
      static_cast<void>(MachineProfileCodec::parse(memory, R"({"version":1,"machines":[{"id":"m-000000000001","label":"one","destination":"one"},{"id":"m-000000000001","label":"two","destination":"two"}]})"));
    });

    rejects(MachineError::duplicate_destination, [&] {
      static_cast<void>(MachineProfileCodec::parse(memory, R"({"version":1,"machines":[{"id":"m-000000000001","label":"one","destination":"host"},{"id":"m-000000000002","label":"two","destination":"host"}]})"));
    });

    rejects(MachineError::duplicate_label, [&] {
      static_cast<void>(MachineProfileCodec::parse(memory, R"({"version":1,"local_label":"here","machines":[{"id":"m-000000000001","label":"here","destination":"host"}]})"));
    });

    std::string rows;

    for (std::size_t index = 0; index <= MachineLimits::profiles; ++index) {
      const auto number = std::to_string(index + 1);

      rows += (index == 0 ? "" : ",") + std::string{R"({"id":"m-)"} + std::string(12 - number.size(), '0') + number + R"(","label":"box)" + number + R"(","destination":"box)" + number + R"("})";
    }

    rejects(MachineError::too_many, [&] {
      static_cast<void>(MachineProfileCodec::parse(memory, R"({"version":1,"machines":[)" + rows + "]}"));
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

    check(profiles.rows().size() == MachineLimits::profiles - 1, "rejected profile admissions must not consume capacity");
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
    BudgetAllocator budget{system, 0};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    const auto source = std::string{R"({"version":1,"machines":[{"id":"m-000000000001","label":"box","destination":")"} + std::string(MachineLimits::destination_bytes, 'x') + R"("}]})";
    bool rejected = false;

    try {
      static_cast<void>(MachineProfileCodec::parse(memory, source));
    } catch (const std::bad_alloc&) {
      rejected = true;
    }

    check(rejected && budget.liveBytes() == 0 && budget.failures() != 0, "allocation rejection must stay observable and release every parser temporary");
  }

  const telar::testing::Case case_identities_keep_their_stable_representation{"machine_profiles.identities_keep_their_stable_representation", identitiesKeepTheirStableRepresentation};
  const telar::testing::Case case_profiles_preserve_identity_order_and_rejected_edits{"machine_profiles.profiles_preserve_identity_order_and_rejected_edits", profilesPreserveIdentityOrderAndRejectedEdits};
  const telar::testing::Case case_versions_and_json_round_trips_preserve_every_field{"machine_profiles.versions_and_json_round_trips_preserve_every_field", versionsAndJsonRoundTripsPreserveEveryField};
  const telar::testing::Case case_strict_json_rejects_unknown_duplicated_and_wrongly_typed_fields{"machine_profiles.strict_json_rejects_unknown_duplicated_and_wrongly_typed_fields", strictJsonRejectsUnknownDuplicatedAndWronglyTypedFields};
  const telar::testing::Case case_login_ordinals_load_within_their_names{"machine_profiles.login_ordinals_load_within_their_names", loginOrdinalsLoadWithinTheirNames};
  const telar::testing::Case case_only_known_versions_load{"machine_profiles.only_known_versions_load", onlyKnownVersionsLoad};
  const telar::testing::Case case_files_refuse_duplicate_rows{"machine_profiles.files_refuse_duplicate_rows", filesRefuseDuplicateRows};
  const telar::testing::Case case_capacity_and_uniqueness_have_the_original_admission_order{"machine_profiles.capacity_and_uniqueness_have_the_original_admission_order", capacityAndUniquenessHaveTheOriginalAdmissionOrder};
  const telar::testing::Case case_remote_arguments_retain_their_validation_boundaries{"machine_profiles.remote_arguments_retain_their_validation_boundaries", remoteArgumentsRetainTheirValidationBoundaries};
  const telar::testing::Case case_allocation_rejection_releases_every_temporary{"machine_profiles.allocation_rejection_releases_every_temporary", allocationRejectionReleasesEveryTemporary};

}
