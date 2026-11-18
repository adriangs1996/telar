#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits.h>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

import telar.testing;
import telar.gui.features.machines;
import telar.client;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::machines;
  // The capacity the library compiles discovery for, as the CLI and the GUI use it.
  constexpr std::size_t path_capacity = PATH_MAX;
  using Discovery = MachineDiscovery<path_capacity>;

  template <typename Operation>
  void rejects(MachineError expected, Operation operation) {
    try {
      operation();
    } catch (const MachineFailure& failure) {
      check(failure.code() == expected, "remote validation must retain the original error category");

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
    check(discovery.home() == "/home/dev" && discovery.shell() == "/bin/zsh" && discovery.endpoint() == "/run/telar.sock", "discovery must own all paths after its input storage changes");
    check(discovery.compatible() && discovery.schema() == telar::handshake::schema_id, "discovery must preserve the complete current wire schema");
    const auto copy = discovery;

    check(copy.endpoint() == discovery.endpoint() && copy.endpoint().data() != discovery.endpoint().data(), "copying discovery must retain independent inline path storage");
    discovery = Discovery::parse("/new-home\n/bin/bash\n/run/other.sock\n12345678");
    check(copy.endpoint() == "/run/telar.sock" && discovery.endpoint() == "/run/other.sock", "replacing the source discovery must preserve the copied endpoint");
    auto changed = telar::handshake::schema_id;

    changed.front() = 'x';
    check(!discovery.compatible(changed), "another schema must remain incompatible");
  }

  void discoveryRejectsUnframedUnsafeAndOversizedReplies() {
    for (const auto* const source : {"", "/home\n/bin/sh\n/run/socket", "home\n/bin/sh\n/run/socket\n12345678", "/home\n/bin/sh\n/run:socket\n12345678", "/home\n/bin/sh\n/run/socket\n1234567_", "/home\n/bin/sh\n/run/socket\n12345678\nextra", "/home\r\n/bin/sh\n/run/socket\n12345678"}) {
      rejects(MachineError::discovery_unreadable, [&] {
        static_cast<void>(Discovery::parse(source));
      });
    }

    const auto boundary = "/" + std::string(path_capacity - 1, 'a');
    const auto valid = boundary + "\n/bin/sh\n/run/socket\n12345678";

    check(Discovery::parse(valid).home().size() == path_capacity, "an absolute path at the native limit must remain valid");
    rejects(MachineError::discovery_unreadable, [&] {
      static_cast<void>(Discovery::parse("/" + valid));
    });

    rejects(MachineError::discovery_unreadable, [&] {
      static_cast<void>(Discovery::parse(valid + std::string(Discovery::max_output_bytes, '\n')));
    });

    const auto spaced = Discovery::parse("/home/with space\n/bin/sh\n/run/socket\n12345678");

    check(spaced.home() == "/home/with space", "discovered paths must retain ordinary spaces without shell reinterpretation");
  }

  void remoteCommandsKeepValidatedProgramsSeparateFromShellSyntax() {
    check(MachineRemoteCommand::bridge().view() == "exec telar server bridge", "the default bridge must resolve telar through the remote PATH");
    check(MachineRemoteCommand::bridge("/opt/bin/telar").view() == "exec /opt/bin/telar server bridge", "the bridge must use the saved validated absolute program path");
    check(MachineRemoteCommand::discovery().view() == R"(/bin/sh -c 'printf "%s\n" "$HOME" "${SHELL:-/bin/sh}"; exec telar server endpoint')", "discovery must retain the original shell-independent home and shell report");
    for (const auto* const program : {"", "telar", "/a/../telar", "/a;exit", "/path/with space", "/path/'quote"}) {
      rejects(MachineError::invalid_program, [&] {
        static_cast<void>(MachineRemoteCommand::discovery(program));
      });
    }
  }

  void sshFailuresPreservePrecedenceAndRetryPolicy() {
    constexpr std::uint8_t ssh_failed = 255;
    constexpr std::uint8_t program_missing = 127;
    const auto failed = [](telar::ds::Option<std::uint8_t> status, std::string_view text) {
      return MachineConnectionPolicy::failure({.exit_status = status, .standard_error = text});
    };

    check(failed(telar::ds::none, "telar protocol mismatch") == MachineError::endpoint_unavailable, "a signaled process must remain a transient endpoint failure");
    check(failed(program_missing, "telar protocol mismatch") == MachineError::remote_runtime_incompatible, "a reported runtime mismatch must precede shell exit classification");
    check(failed(program_missing, "Host key verification failed") == MachineError::remote_program_missing, "shell command failure must precede SSH diagnostics");
    check(failed(ssh_failed, "Permission denied (publickey). Host key verification failed") == MachineError::host_key_rejected, "host key refusal must precede authentication refusal");
    check(failed(ssh_failed, "Permission denied (publickey).") == MachineError::authentication_failed, "an SSH credential refusal must remain permanent");
    check(failed(ssh_failed, "Connection refused") == MachineError::endpoint_unavailable, "an endpoint outage must remain retryable");
    check(MachineConnectionPolicy::permanent(MachineError::host_key_rejected) && !MachineConnectionPolicy::setupRepairs(MachineError::host_key_rejected), "setup must not claim to repair rejected host keys");
    check(MachineConnectionPolicy::permanent(MachineError::remote_program_missing) && MachineConnectionPolicy::setupRepairs(MachineError::remote_program_missing), "setup must repair a missing remote program");
    check(!MachineConnectionPolicy::permanent(MachineError::endpoint_unavailable) && !MachineConnectionPolicy::setupRepairs(MachineError::endpoint_unavailable), "transient endpoint failures must retry without setup");
  }

  const telar::testing::Case case_discovery_owns_paths_and_keeps_protocol_identity{"machine_remote.discovery_owns_paths_and_keeps_protocol_identity", discoveryOwnsPathsAndKeepsProtocolIdentity};
  const telar::testing::Case case_discovery_rejects_unframed_unsafe_and_oversized_replies{"machine_remote.discovery_rejects_unframed_unsafe_and_oversized_replies", discoveryRejectsUnframedUnsafeAndOversizedReplies};
  const telar::testing::Case case_remote_commands_keep_validated_programs_separate_from_shell_syntax{"machine_remote.remote_commands_keep_validated_programs_separate_from_shell_syntax", remoteCommandsKeepValidatedProgramsSeparateFromShellSyntax};
  const telar::testing::Case case_ssh_failures_preserve_precedence_and_retry_policy{"machine_remote.ssh_failures_preserve_precedence_and_retry_policy", sshFailuresPreservePrecedenceAndRetryPolicy};

}
