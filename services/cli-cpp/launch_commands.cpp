module;
#include <utility>
#include <memory>
#include <mutex>
#include <stdlib.h>

#include <span>
#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <type_traits>
#include <cerrno>
#include <exception>
#include <cstdlib>
#include <limits.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#if (!(defined(__APPLE__)))
#include <unistd.h>
#endif
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include "help_texts.hpp"
#include <fcntl.h>
#include <filesystem>
#include <iostream>
#include <vector>
#include <chrono>
#include <cstdio>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <thread>
#include <cstddef>
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include <bit>
#include <new>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <sys/file.h>
#include <variant>
#include <sys/un.h>
#include <openssl/sha.h>
#include <map>
#include <set>
#include <cctype>
#include <functional>
#include <sys/socket.h>
#include <sys/time.h>
#include <sstream>
#include "machine_assets.hpp"
#include <fstream>
#include <csignal>
#include <dirent.h>
#include <pwd.h>

module telar.cli.window;

import telar.cli.plugin;
import telar.cli.server;
import telar.cli.machine;
import telar.cli.machine_ssh;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;


namespace telar::runtime::cli {
namespace {
constexpr std::size_t memory_budget = std::size_t{2} * 1024 * 1024 * 1024;
}

int runMachineCommand(BudgetAllocator<SystemAllocator> &memory, std::span<char *const> words) {
  return runMachine(memory, MachineOptions::parse(words));
}

int runCliCommand(std::span<char *const> words) {
  return runCliInstall(words);
}

int runWindowCommand(BudgetAllocator<SystemAllocator> &memory, std::span<char *const> words, bool gui) {
  const auto options = WindowOptions::parse(words, gui);
  if (options.login_shell) {
    relaunchLogin(words);
  }

  return openWindow(memory, options);
}

int dispatchMachine(std::span<char *const> words, Dispatch dispatch) {
  const std::string_view flag = words.front();
  const bool separate = flag == "--machine";
  if (separate && words.size() < 2) {
    throw std::invalid_argument{"MissingMachineLabel"};
  }

  const std::string label{separate ? std::string_view{words[1]} : flag.substr(std::string_view{"--machine="}.size())};
  if (label.empty()) {
    throw std::invalid_argument{"MissingMachineLabel"};
  }

  const auto command = words.subspan(separate ? 2 : 1);
  if (findHelp(command)) {
    return dispatch(command);
  }

  const std::string_view first = command.empty() ? "" : command.front();
  if (first == "--machine" || first.starts_with("--machine=") || first == "dispatch-argv") {
    std::fprintf(stderr, "telar --machine: runs one telar command there; it cannot name another machine\n");
    return 1;
  }

  SystemAllocator system;
  BudgetAllocator memory{system, memory_budget};
  const auto family = parseFamily(first);
  // SSH uses no PTY, so the remote CLI cannot see whether this stdout is a terminal.
  if (family == Family::clipboard && ::isatty(STDOUT_FILENO)) {
    std::fputs("telar clipboard: pipe clipboard content to a consumer or redirect stdout to a file\n", stderr);
    return 1;
  }
  if (command.empty() || (!family && first != "--version" && first != "-V" && first != "--skill" && first != "plugin-worker") || family == Family::gui) {
    WindowOptions options;
    try {
      options = WindowOptions::parse(family == Family::gui ? command.subspan(1) : command, family == Family::gui);
    } catch (const std::invalid_argument &error) {
      const auto reference = helpReference(command);
      std::fprintf(stderr, "telar: %s; see `%s`\n", error.what(), reference.c_str());
      return 1;
    }

    if (options.remote || options.machine) {
      std::fprintf(stderr, "telar --machine: a window shows one machine first; drop --remote and the second --machine\n");
      return 1;
    }

    options.machine = label;
    return openWindow(memory, options);
  }

  try {
    if (family == Family::machine) {
      static_cast<void>(MachineOptions::parse(command.subspan(1)));
    } else if (family == Family::cli) {
      static_cast<void>(parseCliInstall(command.subspan(1)));
    }
  } catch (const std::invalid_argument &error) {
    const auto reference = helpReference(command);
    std::fprintf(stderr, "telar: %s; see `%s`\n", error.what(), reference.c_str());
    return 1;
  }

  std::optional<machines::MachineProfile> target;
  try {
    target = machine::resolve(memory, label);
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar --machine: %s: %s\n", label.c_str(), std::string_view{error.what()} == "UnknownMachine" ? "no saved machine or local label has that name; see `telar machine list`" : error.what());
    return 1;
  }

  return target ? machine::forward(memory, *target, command) : dispatch(command);
}

int dispatchArguments(std::span<char *const> words, Dispatch dispatch) {
  std::vector<std::string> decoded;
  for (const std::string_view word : words) {
    decoded.push_back(machine::decode(word));
  }

  auto arguments = launch::pointers(decoded);
  arguments.pop_back();
  return dispatch(arguments);
}

}
