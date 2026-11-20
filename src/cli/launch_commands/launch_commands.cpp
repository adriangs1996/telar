module telar.cli.launch_commands;

import std;
import telar.sys.posix;

import telar.cli.plugin;
import telar.cli.server;
import telar.cli.machine;
import telar.cli.window;
import telar.cli.machine_ssh;
import telar.machines;
import telar.cli.output;
import telar.base.ds;

namespace telar::runtime::cli {
  namespace {
    constexpr std::size_t memory_budget = std::size_t{2} * 1024 * 1024 * 1024;
  }

  int runMachineCommand(Memory& memory, std::span<char* const> words) {
    return runMachine(memory, MachineOptions::parse(words));
  }

  int runCliCommand(std::span<char* const> words) {
    return runCliInstall(words);
  }

  int runWindowCommand(Memory& memory, std::span<char* const> words, bool gui) {
    const auto options = WindowOptions::parse(words, gui);
    if (options.login_shell) {
      relaunchLogin(memory, words);
    }

    return openWindow(memory, options);
  }

  int dispatchMachine(std::span<char* const> words, Dispatch dispatch) {
    const std::string_view flag = words.front();
    const bool separate = flag == "--machine";
    if (separate && words.size() < 2) {
      throw std::invalid_argument{"MissingMachineLabel"};
    }

    // The label views the command line, which outlives the command.
    const std::string_view label = separate ? std::string_view{words[1]} : flag.substr(std::string_view{"--machine="}.size());
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
    BudgetAllocator budget{system, memory_budget};
    MemoryAdapter budget_memory{budget};
    Memory& memory = budget_memory;
    const auto family = parseFamily(first);
    // SSH uses no PTY, so the remote CLI cannot see whether this stdout is a terminal.
    if (family == Family::clipboard && (::isatty(STDOUT_FILENO) != 0)) {
      std::fputs("telar clipboard: pipe clipboard content to a consumer or redirect stdout to a file\n", stderr);
      return 1;
    }

    if (command.empty() || (!family && first != "--version" && first != "-V" && first != "--skill" && first != "plugin-worker") || family == Family::gui) {
      WindowOptions options;

      try {
        options = WindowOptions::parse(family == Family::gui ? command.subspan(1) : command, family == Family::gui);
      } catch (const std::invalid_argument& error) {
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
    } catch (const std::invalid_argument& error) {
      const auto reference = helpReference(command);

      std::fprintf(stderr, "telar: %s; see `%s`\n", error.what(), reference.c_str());
      return 1;
    }

    ds::Option<machines::MachineProfile> target;

    try {
      target = machine::resolve(memory, label);
    } catch (const std::exception& error) {
      std::fprintf(stderr, "telar --machine: %.*s: %s\n", static_cast<int>(label.size()), label.data(), std::string_view{error.what()} == "UnknownMachine" ? "no saved machine or local label has that name; see `telar machine list`" : error.what());
      return 1;
    }

    return target ? machine::forward(memory, *target, command) : dispatch(command);
  }

  int dispatchArguments(Memory& memory, std::span<char* const> words, Dispatch dispatch) {
    launch::Argv decoded{memory};
    ds::Vec<char*, Memory> arguments{memory};

    decoded.reserve(words.size());
    for (const std::string_view word : words) {
      decoded.push(machine::decode(memory, word));
    }

    // The pointers are taken once every word is in place, so none moves after; the commands
    // read their arguments and never write through them.
    arguments.reserve(decoded.size());
    for (const auto& word : decoded) {
      arguments.push(const_cast<char*>(word.data()));
    }

    return dispatch(arguments.view());
  }

}
