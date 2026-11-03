#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/erasing_allocator.hpp"
#include "telar_base/program_identity.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/pty_process.hpp"
#include <array>
#include <limits.h>
#include <string_view>

extern char **environ;

namespace telar::runtime {

enum class CommandPurpose {
  terminal,
  administration,
  configured_helper
};

template <Allocator Memory>
class Command {
public:
  explicit Command(Memory &memory, const Launch &launch, CommandPurpose purpose = CommandPurpose::terminal)
      : executable_(AllocatorRef<char, Memory>{memory}),
        cwd_(launch.cwd, AllocatorRef<char, Memory>{memory}),
        arguments_(AllocatorRef<String<Memory>, Memory>{memory}),
        environment_memory_(memory),
        environment_(AllocatorRef<String<SensitiveMemory>, SensitiveMemory>{environment_memory_}),
        argument_pointers_(AllocatorRef<char *, Memory>{memory}),
        environment_pointers_(AllocatorRef<char *, Memory>{memory}),
        memory_(memory),
        restorable_(launch.environment_mode == EnvironmentMode::inherit_runtime) {
    if (cwd_.empty()) {
      std::array<char, PATH_MAX> current{};
      if (::getcwd(current.data(), current.size()) == nullptr) {
        throw SystemError{"resolve working directory"};
      }

      cwd_.assign(current.data());
    }

    for (const auto argument : launch.arguments) {
      arguments_.emplace_back(argument, AllocatorRef<char, Memory>{memory});
    }

    if (arguments_.empty()) {
      const char *shell = std::getenv("SHELL");
      arguments_.emplace_back(shell != nullptr ? shell : "/bin/sh", AllocatorRef<char, Memory>{memory});
    }

    if (launch.environment_mode == EnvironmentMode::inherit_runtime) {
      for (char **entry = environ; *entry != nullptr; ++entry) {
        environment_.emplace_back(*entry, AllocatorRef<char, SensitiveMemory>{environment_memory_});
      }
    }

    for (const auto &entry : launch.environment) {
      setEnvironment(entry.name, entry.value);
    }

    std::erase_if(environment_, [purpose](const auto &entry) {
      if (purpose == CommandPurpose::configured_helper) {
        return false;
      }

      const auto name = std::string_view{entry}.substr(0, entry.find('='));
      if (purpose == CommandPurpose::administration) {
        return name == "TELAR_PANE_ID" || name == "TELAR_PANE_GENERATION" || name == "TELAR_WORKSPACE_ID" || name == "TELAR_TAB_ID" || name == "SSH_AUTH_SOCK";
      }

      return name == "GHOSTTY_RESOURCES_DIR" || name == "TELAR_SOCKET" || name == "TERM_PROGRAM_VERSION";
    });

    if (purpose == CommandPurpose::terminal) {
      setEnvironment("TERM_PROGRAM", control::program_name);
      setEnvironment("TERM_PROGRAM_VERSION", control::program_version);
      setEnvironment("TELAR_TERM_PROGRAM", "telar");
      setEnvironment("TERM", "xterm-256color");
      setEnvironment("COLORTERM", "truecolor");
    }
    resolveExecutable();
  }

  Command(const Command &) = delete;
  Command &operator=(const Command &) = delete;

  void removeEnvironmentPrefix(std::string_view prefix) {
    std::erase_if(environment_, [prefix](const auto &entry) { return entry.starts_with(prefix); });
  }

  void setEnvironment(std::string_view name, std::string_view value) {
    String<SensitiveMemory> entry{name, AllocatorRef<char, SensitiveMemory>{environment_memory_}};
    entry.push_back('=');
    entry.append(value);

    for (auto &existing : environment_) {
      const auto separator = existing.find('=');
      if (std::string_view{existing}.substr(0, separator) == name) {
        eraseSensitive(existing.data(), existing.size());
        existing = std::move(entry);
        return;
      }
    }

    environment_.push_back(std::move(entry));
  }

  SpawnSpec specification(TerminalSize size) {
    argument_pointers_.clear();
    environment_pointers_.clear();

    for (auto &argument : arguments_) {
      argument_pointers_.push_back(argument.data());
    }

    for (auto &entry : environment_) {
      environment_pointers_.push_back(entry.data());
    }

    argument_pointers_.push_back(nullptr);
    environment_pointers_.push_back(nullptr);
    return SpawnSpec{
        .executable = executable_.c_str(),
        .cwd = cwd_.c_str(),
        .arguments = argument_pointers_.data(),
        .environment = environment_pointers_.data(),
        .size = size,
    };
  }

  std::string_view cwd() const noexcept {
    return cwd_;
  }

  std::span<const String<Memory>> arguments() const noexcept {
    return arguments_;
  }

  bool restorable() const noexcept {
    return restorable_;
  }

private:
  void resolveExecutable() {
    const auto &program = arguments_.front();
    if (program.find('/') != String<Memory>::npos) {
      executable_ = program;
      return;
    }

    std::string_view path = "/usr/bin:/bin";
    for (const auto &entry : environment_) {
      if (std::string_view{entry}.starts_with("PATH=")) {
        path = std::string_view{entry}.substr(5);
        break;
      }
    }

    while (true) {
      const auto separator = path.find(':');
      const auto directory = path.substr(0, separator);
      executable_.clear();
      if (directory.empty() || directory.front() != '/') {
        executable_.append(cwd());
        executable_.push_back('/');
      }
      executable_.append(directory);
      executable_.push_back('/');
      executable_.append(program);

      if (::access(executable_.c_str(), X_OK) == 0) {
        return;
      }

      if (separator == std::string_view::npos) {
        throw SystemError{"resolve pane executable", ENOENT};
      }

      path.remove_prefix(separator + 1);
    }
  }

  using SensitiveMemory = ErasingAllocator<Memory>;
  String<Memory> executable_;
  String<Memory> cwd_;
  Vector<String<Memory>, Memory> arguments_;
  SensitiveMemory environment_memory_;
  Vector<String<SensitiveMemory>, SensitiveMemory> environment_;
  Vector<char *, Memory> argument_pointers_;
  Vector<char *, Memory> environment_pointers_;
  Memory &memory_;
  bool restorable_;
};

template <Allocator Memory>
Command(Memory &memory, const Launch &launch, CommandPurpose purpose = CommandPurpose::terminal) -> Command<Memory>;

}
