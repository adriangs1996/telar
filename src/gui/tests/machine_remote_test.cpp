#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <algorithm>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <span>
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include <cstring>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <charconv>
#include <concepts>
#include <system_error>
#include <exception>
#include <iostream>
#include <string>



import telar.gui.machines.discovery;
import telar.gui.machines.profile_store;
import telar.client;

namespace {

using namespace telar::gui;
using telar::gui::test::require;
constexpr std::size_t path_capacity = 64;
using Discovery = MachineDiscovery<path_capacity>;

template <typename Operation>
void rejects(MachineError expected, Operation operation) {
  try {
    operation();
  } catch (const MachineFailure &failure) {
    require(failure.code() == expected, "remote validation must retain the original error category");

    return;
  }

  throw std::runtime_error{"Remote operation unexpectedly succeeded"};
}

void discoveryOwnsPathsAndKeepsProtocolIdentity() {
  std::string source = "/home/dev\n/bin/zsh\n/run/telar.sock\n";
  for (const auto byte : telar::handshake::schema_id) {
    source.push_back(static_cast<char>(byte));
  }

  source.append("\n\n");
  auto discovery = Discovery::parse(source);
  source.assign(source.size(), 'x');
  require(discovery.home() == "/home/dev" && discovery.shell() == "/bin/zsh" && discovery.endpoint() == "/run/telar.sock", "discovery must own all paths after its input storage changes");
  require(discovery.compatible() && discovery.schema() == telar::handshake::schema_id, "discovery must preserve the complete current wire schema");
  const auto copy = discovery;
  require(copy.endpoint() == discovery.endpoint() && copy.endpoint().data() != discovery.endpoint().data(), "copying discovery must retain independent inline path storage");
  discovery = Discovery::parse("/new-home\n/bin/bash\n/run/other.sock\n12345678");
  require(copy.endpoint() == "/run/telar.sock" && discovery.endpoint() == "/run/other.sock", "replacing the source discovery must preserve the copied endpoint");
  auto changed = telar::handshake::schema_id;
  changed.front() = 'x';
  require(!discovery.compatible(changed), "another schema must remain incompatible");
}

void discoveryRejectsUnframedUnsafeAndOversizedReplies() {
  for (const auto *const source : {"", "/home\n/bin/sh\n/run/socket", "home\n/bin/sh\n/run/socket\n12345678", "/home\n/bin/sh\n/run:socket\n12345678", "/home\n/bin/sh\n/run/socket\n1234567_", "/home\n/bin/sh\n/run/socket\n12345678\nextra", "/home\r\n/bin/sh\n/run/socket\n12345678"}) {
    rejects(MachineError::discovery_unreadable, [&] {
      static_cast<void>(Discovery::parse(source));
    });
  }

  const auto boundary = "/" + std::string(path_capacity - 1, 'a');
  const auto valid = boundary + "\n/bin/sh\n/run/socket\n12345678";
  require(Discovery::parse(valid).home().size() == path_capacity, "an absolute path at the native limit must remain valid");
  rejects(MachineError::discovery_unreadable, [&] {
    static_cast<void>(Discovery::parse("/" + valid));
  });
  rejects(MachineError::discovery_unreadable, [&] {
    static_cast<void>(Discovery::parse(valid + std::string(Discovery::max_output_bytes, '\n')));
  });

  const auto spaced = Discovery::parse("/home/with space\n/bin/sh\n/run/socket\n12345678");
  require(spaced.home() == "/home/with space", "discovered paths must retain ordinary spaces without shell reinterpretation");
}

void remoteCommandsKeepValidatedProgramsSeparateFromShellSyntax() {
  require(MachineRemoteCommand::bridge().view() == "exec telar server bridge", "the default bridge must resolve telar through the remote PATH");
  require(MachineRemoteCommand::bridge("/opt/bin/telar").view() == "exec /opt/bin/telar server bridge", "the bridge must use the saved validated absolute program path");
  require(MachineRemoteCommand::discovery().view() == R"(/bin/sh -c 'printf "%s\n" "$HOME" "${SHELL:-/bin/sh}"; exec telar server endpoint')", "discovery must retain the original shell-independent home and shell report");
  for (const auto *const program : {"", "telar", "/a/../telar", "/a;exit", "/path/with space", "/path/'quote"}) {
    rejects(MachineError::invalid_program, [&] {
      static_cast<void>(MachineRemoteCommand::discovery(program));
    });
  }
}

void sshFailuresPreservePrecedenceAndRetryPolicy() {
  constexpr std::uint8_t ssh_failed = 255;
  constexpr std::uint8_t program_missing = 127;
  const auto failed = [](std::optional<std::uint8_t> status, std::string_view text) {
    return MachineConnectionPolicy::failure({.exit_status = status, .standard_error = text});
  };
  require(failed(std::nullopt, "telar protocol mismatch") == MachineError::endpoint_unavailable, "a signaled process must remain a transient endpoint failure");
  require(failed(program_missing, "telar protocol mismatch") == MachineError::remote_runtime_incompatible, "a reported runtime mismatch must precede shell exit classification");
  require(failed(program_missing, "Host key verification failed") == MachineError::remote_program_missing, "shell command failure must precede SSH diagnostics");
  require(failed(ssh_failed, "Permission denied (publickey). Host key verification failed") == MachineError::host_key_rejected, "host key refusal must precede authentication refusal");
  require(failed(ssh_failed, "Permission denied (publickey).") == MachineError::authentication_failed, "an SSH credential refusal must remain permanent");
  require(failed(ssh_failed, "Connection refused") == MachineError::endpoint_unavailable, "an endpoint outage must remain retryable");
  require(MachineConnectionPolicy::permanent(MachineError::host_key_rejected) && !MachineConnectionPolicy::setupRepairs(MachineError::host_key_rejected), "setup must not claim to repair rejected host keys");
  require(MachineConnectionPolicy::permanent(MachineError::remote_program_missing) && MachineConnectionPolicy::setupRepairs(MachineError::remote_program_missing), "setup must repair a missing remote program");
  require(!MachineConnectionPolicy::permanent(MachineError::endpoint_unavailable) && !MachineConnectionPolicy::setupRepairs(MachineError::endpoint_unavailable), "transient endpoint failures must retry without setup");
}

}

int main() {
  try {
    discoveryOwnsPathsAndKeepsProtocolIdentity();
    discoveryRejectsUnframedUnsafeAndOversizedReplies();
    remoteCommandsKeepValidatedProgramsSeparateFromShellSyntax();
    sshFailuresPreservePrecedenceAndRetryPolicy();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
