#pragma once

#include "session_channel.hpp"
#include "telar_base/text/json.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <cmath>
#include <fcntl.h>
#include <sys/stat.h>

namespace telar::runtime::cli::sessions {

template <Allocator Memory>
void recipeVersion(Memory &memory, JsonValue version) {
  String<Memory> decoded{AllocatorRef<char, Memory>{memory}};
  auto encoded = version.encoded();
  if (encoded.starts_with('"')) {
    version.string(decoded);
    encoded = decoded;
  } else if (encoded.empty() || (encoded.front() != '-' && (encoded.front() < '0' || encoded.front() > '9'))) {
    throw Failure{"UnexpectedToken"};
  }
  if (encoded.empty() || encoded.front() == '_' || encoded.back() == '_' || encoded.find_first_of(" \t\r\n") != std::string_view::npos) {
    throw Failure{"InvalidCharacter"};
  }
  std::string number;
  for (const auto byte : encoded) {
    if (byte != '_') {
      number += byte;
    }
  }
  char *end{};
  const auto value = std::strtold(number.c_str(), &end);
  if (end != number.data() + number.size()) {
    throw Failure{"InvalidCharacter"};
  }
  if (!std::isfinite(value) || std::round(value) != value) {
    throw Failure{"InvalidNumber"};
  }
  if (value < 0 || value > std::numeric_limits<std::uint8_t>::max()) {
    throw Failure{"Overflow"};
  }
  if (value != 1) {
    throw Failure{"InvalidProjectRecipe"};
  }
}

inline FileDescriptor setupDirectory(std::string_view cwd) {
  if (!cwd.starts_with('/')) {
    throw Failure{"AbsoluteFilePathRequired"};
  }
  std::string path{cwd};
  path += "/.telar";
  FileDescriptor current{::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  if (!current) {
    throw Failure{"AccessDenied"};
  }
  std::string_view remaining = path;
  while (!remaining.empty()) {
    const auto slash = remaining.find('/');
    const auto component = remaining.substr(0, slash);
    remaining.remove_prefix(slash == std::string_view::npos ? remaining.size() : slash + 1);
    if (component.empty()) {
      continue;
    }
    if (component == "." || component == "..") {
      throw Failure{"InvalidFilePath"};
    }
    const std::string name{component};
    FileDescriptor next{::openat(current.get(), name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
    if (!next) {
      if (errno == ENOENT) {
        return FileDescriptor{};
      }
      if (errno == ENOTDIR) {
        throw Failure{"NotDir"};
      }
      if (errno == ELOOP) {
        throw Failure{"SymLinkLoop"};
      }
      throw Failure{"AccessDenied"};
    }
    current = std::move(next);
  }
  struct stat status{};
  if (::fstat(current.get(), &status) != 0 || status.st_uid != ::getuid() || (status.st_mode & 0022) != 0) {
    throw Failure{"UnsafeTransferDirectory"};
  }
  return current;
}

// Open every component without following symlinks. A recipe from a checkout is
// executable input and requires the explicit setup flag before it is parsed.
template <Allocator Memory>
std::optional<std::uint64_t> worktreeSetup(Memory &memory, Channel<Memory> &session, const std::string &cwd, bool authorized) {
  constexpr std::size_t recipe_bytes = 32 * 1024;
  constexpr std::size_t max_arguments = 64;
  auto parent = setupDirectory(cwd);
  if (!parent) {
    return std::nullopt;
  }

  FileDescriptor file{::openat(parent.get(), "setup.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)};
  if (file.get() < 0) {
    if (errno == ENOENT) {
      return std::nullopt;
    }
    throw Failure{"UnsafeTransferFile"};
  }

  struct stat status{};
  if (::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode) || status.st_uid != ::getuid() || status.st_nlink != 1) {
    throw Failure{"UnsafeTransferFile"};
  }
  if (!authorized) {
    throw Failure{"ProjectSetupRequiresExplicitSetupFlag"};
  }
  if (status.st_size > static_cast<off_t>(recipe_bytes)) {
    throw Failure{"InvalidProjectRecipe"};
  }

  std::string bytes;
  std::array<char, recipe_bytes + 1> buffer;
  for (;;) {
    const auto count = ::read(file.get(), buffer.data(), buffer.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count < 0) {
      throw Failure{"InvalidProjectRecipe"};
    }
    if (count == 0) {
      break;
    }
    if (static_cast<std::size_t>(count) > recipe_bytes - bytes.size()) {
      throw Failure{"InvalidProjectRecipe"};
    }
    bytes.append(buffer.data(), static_cast<std::size_t>(count));
  }

  Vector<String<Memory>, Memory> arguments{AllocatorRef<String<Memory>, Memory>{memory}};
  try {
    const auto recipe = JsonValue::parse(bytes);
    if (!recipe.encoded().starts_with('{')) {
      throw Failure{"UnexpectedToken"};
    }
    std::optional<JsonValue> version, argv;
    recipe.eachMember([&](JsonValue key, JsonValue value) {
      String<Memory> name{AllocatorRef<char, Memory>{memory}};
      key.string(name);
      if (name == "version") {
        if (version) {
          throw Failure{"DuplicateField"};
        }
        version = value;
      } else if (name == "argv") {
        if (argv) {
          throw Failure{"DuplicateField"};
        }
        argv = value;
      } else {
        throw Failure{"UnknownField"};
      }
    });
    if (!version || !argv) {
      throw Failure{"MissingField"};
    }
    recipeVersion(memory, *version);
    if (!argv->encoded().starts_with('[')) {
      throw Failure{"UnexpectedToken"};
    }
    argv->eachElement([&](JsonValue value) {
      if (arguments.size() == max_arguments) {
        throw Failure{"InvalidProjectRecipe"};
      }
      String<Memory> argument{AllocatorRef<char, Memory>{memory}};
      if (!value.encoded().starts_with('"')) {
        throw Failure{"UnexpectedToken"};
      }
      value.string(argument);
      arguments.push_back(std::move(argument));
    });
    if (arguments.empty()) {
      throw Failure{"InvalidProjectRecipe"};
    }
  } catch (const Failure &) {
    throw;
  } catch (const std::exception &) {
    throw Failure{"SyntaxError"};
  }

  std::array<std::string_view, max_arguments> argv;
  for (std::size_t index = 0; index < arguments.size(); ++index) {
    argv[index] = arguments[index];
  }
  std::uint64_t id{};
  while (id == 0) {
    ::arc4random_buf(&id, sizeof(id));
  }
  ExecutionRequest request{.action = ExecutionAction::start, .execution_id = id, .cwd = cwd, .arguments = std::span{argv}.first(arguments.size())};
  std::fprintf(stderr, "telar project: setup execution %llu; each explicit invocation repeats the recipe\n", static_cast<unsigned long long>(id));
  auto reply = session.template exchange<ExecutionReply>(request);
  request.action = ExecutionAction::status;
  request.arguments = {};
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{default_wait_seconds};
  for (;;) {
    if (request.stdout_offset != reply.stdout_offset || request.stderr_offset != reply.stderr_offset) {
      throw Failure{"SetupOutputRetentionExceeded"};
    }
    std::fwrite(reply.stdout_bytes.data(), 1, reply.stdout_bytes.size(), stderr);
    std::fwrite(reply.stderr_bytes.data(), 1, reply.stderr_bytes.size(), stderr);
    request.stdout_offset += reply.stdout_bytes.size();
    request.stderr_offset += reply.stderr_bytes.size();
    if ((reply.state == ExecutionState::exited || reply.state == ExecutionState::failed) && request.stdout_offset == reply.stdout_total && request.stderr_offset == reply.stderr_total) {
      if (reply.state != ExecutionState::exited || reply.exit_code != 0) {
        throw Failure{"ProjectSetupFailed"};
      }
      return id;
    }

    if (std::chrono::steady_clock::now() >= deadline) {
      throw Failure{"SetupWaitTimedOutExecutionContinues"};
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{10});
    reply = session.template exchange<ExecutionReply>(request);
  }
}

}
