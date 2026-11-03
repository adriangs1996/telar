#pragma once

#include "json_text.hpp"
#include "launch_process.hpp"
#include "machine_store.hpp"
#include "telar_client/machines/discovery.hpp"
#include "telar_client/machines/remote_command.hpp"
#include "telar_platform/runtime_paths.hpp"
#include <openssl/sha.h>

namespace telar::runtime::cli::machine {

inline constexpr std::size_t command_limit = 64 * 1024;
inline constexpr auto endpoint_timeout = std::chrono::seconds{30};
inline constexpr auto probe_timeout = std::chrono::seconds{60};
inline constexpr auto install_timeout = std::chrono::seconds{900};
inline constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
using Discovery = machines::MachineDiscovery<PATH_MAX>;

inline std::string encode(std::string_view argument) {
  std::string result{"a"};
  unsigned value = 0;
  unsigned bits = 0;
  for (const unsigned char byte : argument) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      result += alphabet[(value >> bits) & 63];
    }
  }

  if (bits != 0) {
    result += alphabet[(value << (6 - bits)) & 63];
  }

  return result;
}

inline std::string decode(std::string_view word) {
  if (word.empty() || word.front() != 'a') {
    throw CommandError{"InvalidDispatchArgument"};
  }

  word.remove_prefix(1);
  if (word.size() % 4 == 1) {
    throw CommandError{"InvalidDispatchArgument"};
  }

  std::string result;
  unsigned value = 0;
  unsigned bits = 0;
  for (const auto byte : word) {
    const auto digit = alphabet.find(byte);
    if (digit == std::string_view::npos) {
      throw CommandError{"InvalidDispatchArgument"};
    }

    value = (value << 6) | static_cast<unsigned>(digit);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      const auto decoded = static_cast<char>((value >> bits) & 255);
      if (decoded == '\0') {
        throw CommandError{"InvalidDispatchArgument"};
      }

      result += decoded;
    }
  }

  if (bits != 0 && (value & ((1u << bits) - 1)) != 0) {
    throw CommandError{"InvalidDispatchArgument"};
  }

  return result;
}

template <Allocator Memory>
std::vector<std::string> ssh(Memory &memory, std::string_view destination, std::string_view command) {
  MachineFieldRules::destination(destination);
  const RuntimePaths paths{memory, ServerOptions{}, ProcessEnvironment{}};
  paths.prepareSocket();
  const auto directory = std::string_view{paths.socket}.substr(0, paths.socket.rfind('/'));
  std::array<unsigned char, SHA256_DIGEST_LENGTH> digest;
  ::SHA256(reinterpret_cast<const unsigned char *>(destination.data()), destination.size(), digest.data());
  std::uint64_t hash = 0;
  constexpr unsigned bits_per_byte = 8;
  constexpr unsigned control_hash_shift = 16;
  for (std::size_t index = 0; index < sizeof(hash); ++index) {
    hash |= static_cast<std::uint64_t>(digest[index]) << (index * bits_per_byte);
  }

  std::array<char, 32> name;
  std::snprintf(name.data(), name.size(), "/ssh-%012llx", static_cast<unsigned long long>(hash >> control_hash_shift));
  return {"ssh", "-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "ForwardAgent=no", "-o", "ControlMaster=auto", "-o", "ControlPersist=600", "-o", "ControlPath=" + std::string{directory} + name.data(), "--", std::string{destination}, std::string{command}};
}

template <Allocator Memory>
int forward(Memory &memory, const MachineProfile &profile, std::span<char *const> words) {
  std::string command = std::string{profile.program().value_or("telar")} + " dispatch-argv";
  for (const std::string_view word : words) {
    const auto encoded = encode(word);
    if (command.size() + 1 + encoded.size() > command_limit) {
      throw CommandError{"MachineCommandTooLong"};
    }

    command += ' ';
    command += encoded;
  }

  return launch::inherit(ssh(memory, profile.destination(), command));
}

inline std::string_view trimmed(std::string_view text) {
  const auto start = text.find_first_not_of(" \t\r\n");
  if (start == std::string_view::npos) {
    return {};
  }

  return text.substr(start, text.find_last_not_of(" \t\r\n") + 1 - start);
}

inline MachineError sshFailure(const launch::Output &output) {
  if (output.err.contains("telar protocol mismatch")) {
    return MachineError::remote_runtime_incompatible;
  }

  if (output.status == 126 || output.status == 127) {
    return MachineError::remote_program_missing;
  }

  if (output.status == launch::ssh_failure) {
    if (output.err.contains("Host key verification failed") || output.err.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")) {
      return MachineError::host_key_rejected;
    }

    if (output.err.contains("Permission denied (") || output.err.contains("Too many authentication failures")) {
      return MachineError::authentication_failed;
    }
  }

  return MachineError::endpoint_unavailable;
}

template <Allocator Memory>
Discovery discover(Memory &memory, const MachineProfile &profile, std::string &detail) {
  launch::Output output;
  try {
    output = launch::capture(ssh(memory, profile.destination(), MachineRemoteCommand::discovery(profile.program()).view()), -1, endpoint_timeout);
  } catch (const std::exception &) {
    throw MachineFailure{MachineError::endpoint_unavailable};
  }

  constexpr std::size_t detail_limit = 1024;
  if (output.status != 0) {
    const auto failure = sshFailure(output);
    if (failure == MachineError::remote_program_missing) {
      detail = "telar is not on the PATH of non-interactive SSH sessions there: ";
    } else if (failure == MachineError::remote_runtime_incompatible) {
      detail = "the runtime there is another telar build; run `telar server stop` there: ";
    }

    if (failure == MachineError::host_key_rejected) {
      std::string_view lines{output.err};
      while (!lines.empty()) {
        const auto end = lines.find('\n');
        const auto line = lines.substr(0, end);
        if (line.contains("you have requested strict checking") || line.contains("Host key verification failed")) {
          detail += std::string{trimmed(line)} + " ";
        }

        if (end == std::string_view::npos) {
          break;
        }

        lines.remove_prefix(end + 1);
      }
    } else {
      detail += output.err;
    }

    detail.resize(std::min(detail.size(), detail_limit));
    throw MachineFailure{failure};
  }

  try {
    if (output.dropped != 0) {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    return Discovery::parse(output.out);
  } catch (const MachineFailure &) {
    detail = "`telar server endpoint` there printed something this telar cannot read; install the same telar build on both machines and keep shell startup files quiet";
    throw;
  }
}

template <Allocator Memory>
int check(Memory &memory, const MachineProfile &profile, bool json) {
  std::string detail;
  std::optional<Discovery> found;
  try {
    found = discover(memory, profile, detail);
  } catch (const MachineFailure &error) {
    if (json) {
      String<Memory> output{AllocatorRef<char, Memory>{memory}};
      output += "{\"label\":";
      appendJsonText(output, profile.label(), JsonEscapes::control);
      output += ",\"reachable\":false,\"error\":";
      appendJsonText(output, error.what(), JsonEscapes::control);
      output += ",\"detail\":";
      appendJsonText(output, trimmed(detail), JsonEscapes::control);
      output += "}\n";
      std::fwrite(output.data(), 1, output.size(), stdout);
    } else {
      std::fprintf(stderr, "telar machine: %.*s (%.*s) is not reachable: %s\n%.*s\n", static_cast<int>(profile.label().size()), profile.label().data(), static_cast<int>(profile.destination().size()), profile.destination().data(), error.what(), static_cast<int>(trimmed(detail).size()), trimmed(detail).data());
    }

    return 1;
  }

  const auto schema = std::string{found->schema().begin(), found->schema().end()};
  const auto local_schema = std::string{handshake::schema_id.begin(), handshake::schema_id.end()};
  if (json) {
    String<Memory> output{AllocatorRef<char, Memory>{memory}};
    output += "{\"label\":";
    appendJsonText(output, profile.label(), JsonEscapes::control);
    output += ",\"reachable\":true,\"schema\":\"" + schema + "\",\"local_schema\":\"" + local_schema + "\",\"compatible\":";
    output += found->compatible() ? "true" : "false";
    for (const auto &[name, value] : std::array<std::pair<std::string_view, std::string_view>, 3>{{{"home", found->home()}, {"shell", found->shell()}, {"socket", found->endpoint()}}}) {
      output += ",\"";
      output += name;
      output += "\":";
      appendJsonText(output, value, JsonEscapes::control);
    }

    output += "}\n";
    std::fwrite(output.data(), 1, output.size(), stdout);
  } else {
    std::printf("%.*s\t%.*s\treachable\n  home\t%.*s\n  shell\t%.*s\n  socket\t%.*s\n  schema\t%s (%s)\n", static_cast<int>(profile.label().size()), profile.label().data(), static_cast<int>(profile.destination().size()), profile.destination().data(), static_cast<int>(found->home().size()), found->home().data(), static_cast<int>(found->shell().size()), found->shell().data(), static_cast<int>(found->endpoint().size()), found->endpoint().data(), schema.c_str(), found->compatible() ? "matches this telar" : ("does not match this telar " + local_schema + "; update telar on one side").c_str());
  }

  return found->compatible() ? 0 : 1;
}

}
