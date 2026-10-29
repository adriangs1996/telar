#include "core/memory.hpp"
#include "machines/failure.hpp"
#include "machines/field_rules.hpp"
#include "machines/identity.hpp"
#include "machines/profile.hpp"
#include "machines/profile_codec.hpp"
#include "machines/profiles.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include <cstdint>
#include <cstdio>
#include <exception>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace {

using namespace telar::gui;
using namespace telar::gui::probe;

enum class Operation : std::uint8_t {
  validate = 1,
  codec,
  edit,
};
enum class Validation : std::uint8_t {
  identity,
  label,
  destination,
  profile_destination,
  color,
  program,
};
enum class Edit : std::uint8_t {
  reset,
  local_label,
  add,
  remove,
  rename,
  enable,
  program,
  login,
};

void validationCase(SystemAllocator &memory) {
  const auto kind = read<Validation>();
  const auto text = readText(memory);
  try {
    switch (kind) {
    case Validation::identity: {
      const auto identity = MachineId::parse(text);
      write(std::uint8_t{1});
      writeText(identity.format().view());

      return;
    }
    case Validation::label:
      MachineFieldRules::label(text);
      break;
    case Validation::destination:
      MachineFieldRules::destination(text);
      break;
    case Validation::profile_destination:
      MachineFieldRules::profileDestination(text);
      break;
    case Validation::color:
      MachineFieldRules::color(text);
      break;
    case Validation::program:
      MachineFieldRules::program(text);
      break;
    }

    write(std::uint8_t{1});
    writeText({});
  } catch (const MachineFailure &failure) {
    write(std::uint8_t{0});
    writeText(failure.what());
  }
}

void codecCase(SystemAllocator &memory) {
  const auto source = readText(memory);
  try {
    const auto profiles = MachineProfileCodec::parse(memory, source);
    const auto output = MachineProfileCodec::format(memory, profiles);
    write(std::uint8_t{1});
    writeText(output);
  } catch (const MachineFailure &failure) {
    write(std::uint8_t{0});
    writeText(failure.what());
  }
}

MachineProfile readProfile(SystemAllocator &memory) {
  const auto identity = readText(memory);
  const auto label = readText(memory);
  const auto destination = readText(memory);
  const auto has_color = read<std::uint8_t>() != 0;
  const auto color = readText(memory);
  const auto enabled = read<std::uint8_t>() != 0;
  const auto has_program = read<std::uint8_t>() != 0;
  const auto program = readText(memory);

  return MachineProfile::create(MachineId::parse(identity), {
                                                                .label = label,
                                                                .destination = destination,
                                                                .color = has_color ? std::optional<std::string_view>{color} : std::nullopt,
                                                                .enabled = enabled,
                                                                .program = has_program ? std::optional<std::string_view>{program} : std::nullopt,
                                                            });
}

void applyEdit(SystemAllocator &memory, MachineProfiles &profiles) {
  switch (read<Edit>()) {
  case Edit::reset:
    profiles = {};
    break;
  case Edit::local_label:
    profiles.relabelLocal(readText(memory));
    break;
  case Edit::add:
    profiles.add(readProfile(memory));
    break;
  case Edit::remove:
    profiles.remove(readText(memory));
    break;
  case Edit::rename: {
    const auto label = readText(memory);
    profiles.rename(label, readText(memory));
    break;
  }
  case Edit::enable: {
    const auto label = readText(memory);
    profiles.enable(label, read<std::uint8_t>() != 0);
    break;
  }
  case Edit::program: {
    const auto label = readText(memory);
    profiles.placeProgram(label, readText(memory));
    break;
  }
  case Edit::login: {
    const auto label = readText(memory);
    const auto agent = read<MachineAgent>();
    profiles.recordLogin(label, agent, read<MachineLogin>());
    break;
  }
  }
}

void editCase(SystemAllocator &memory, MachineProfiles &profiles) {
  try {
    applyEdit(memory, profiles);
    write(std::uint8_t{1});
    writeText({});
  } catch (const MachineFailure &failure) {
    write(std::uint8_t{0});
    writeText(failure.what());
  }

  writeText(MachineProfileCodec::format(memory, profiles));
}

}

int main() {
  try {
    SystemAllocator memory;
    MachineProfiles profiles;
    int operation = 0;
    while ((operation = std::getchar()) != EOF) {
      switch (static_cast<Operation>(operation)) {
      case Operation::validate:
        validationCase(memory);
        break;
      case Operation::codec:
        codecCase(memory);
        break;
      case Operation::edit:
        editCase(memory, profiles);
        break;
      default:
        throw std::runtime_error{"Unknown machine-profile probe operation"};
      }
    }
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));

    return 1;
  }
}
