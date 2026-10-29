#include "core/memory.hpp"
#include "machines/connection_policy.hpp"
#include "machines/discovery.hpp"
#include "machines/failure.hpp"
#include "machines/remote_command.hpp"
#include "platform/path_limits.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include <array>
#include <bit>
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
  discovery = 1,
  command,
  failure,
  policy,
};

void discoveryCase(SystemAllocator &memory) {
  const auto input = readText(memory);
  try {
    const auto discovery = MachineDiscovery<platform::PathLimits::path_bytes>::parse(input);
    write(std::uint8_t{1});
    writeText(discovery.home());
    writeText(discovery.shell());
    writeText(discovery.endpoint());
    const auto schema = std::bit_cast<std::array<char, telar::SchemaId{}.size()>>(discovery.schema());
    writeText({schema.data(), schema.size()});
    write(static_cast<std::uint8_t>(discovery.compatible()));
  } catch (const MachineFailure &failure) {
    write(std::uint8_t{0});
    writeText(failure.what());
  }
}

void commandCase(SystemAllocator &memory) {
  const auto discovery = read<std::uint8_t>() != 0;
  const auto has_program = read<std::uint8_t>() != 0;
  const auto program = readText(memory);
  const std::optional<std::string_view> selected = has_program ? std::optional<std::string_view>{program} : std::nullopt;
  try {
    const auto command = discovery ? MachineRemoteCommand::discovery(selected) : MachineRemoteCommand::bridge(selected);
    write(std::uint8_t{1});
    writeText(command.view());
  } catch (const MachineFailure &failure) {
    write(std::uint8_t{0});
    writeText(failure.what());
  }
}

void failureCase(SystemAllocator &memory) {
  const auto exited = read<std::uint8_t>() != 0;
  const auto status = read<std::uint8_t>();
  const auto text = readText(memory);
  const auto failure = MachineConnectionPolicy::failure({.exit_status = exited ? std::optional{status} : std::nullopt, .standard_error = text});
  writeText(MachineFailure::name(failure));
}

void policyCase(SystemAllocator &memory) {
  const auto name = readText(memory);
  for (std::uint8_t value = 0; value <= static_cast<std::uint8_t>(MachineError::invalid_runtime_directory); ++value) {
    const auto error = static_cast<MachineError>(value);
    if (name == MachineFailure::name(error)) {
      write(static_cast<std::uint8_t>(MachineConnectionPolicy::permanent(error)));
      write(static_cast<std::uint8_t>(MachineConnectionPolicy::setupRepairs(error)));

      return;
    }
  }

  write(std::uint8_t{0});
  write(std::uint8_t{0});
}

}

int main() {
  try {
    SystemAllocator memory;
    int operation = 0;
    while ((operation = std::getchar()) != EOF) {
      switch (static_cast<Operation>(operation)) {
      case Operation::discovery:
        discoveryCase(memory);
        break;
      case Operation::command:
        commandCase(memory);
        break;
      case Operation::failure:
        failureCase(memory);
        break;
      case Operation::policy:
        policyCase(memory);
        break;
      default:
        throw std::runtime_error{"Unknown machine-remote probe operation"};
      }
    }
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));

    return 1;
  }
}
