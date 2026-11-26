module telar.cli.commands.launch_commands;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.cli.commands.plugin;
import telar.cli.session.server;
import telar.cli.commands.machine;
import telar.cli.commands.window;
import telar.cli.commands.machine_gateway;
import telar.machines;
import telar.cli.console.output;
import telar.base.ds;

namespace telar::runtime::cli {
  namespace {
    constexpr std::size_t memory_budget = std::size_t{2} * 1024 * 1024 * 1024;

    // A window opened with --machine shows that machine first.
    int openMachineWindow(Memory& memory, std::span<char* const> command, bool gui, std::string_view label) {
      WindowOptions options;

      try {
        options = WindowOptions::parse(gui ? command.subspan(1) : command, gui);
      } catch (const std::invalid_argument& error) {
        const auto reference = helpReference(command);

        std::println(stderr, "telar: {}; see `{}`", error.what(), reference.cStr());
        return 1;
      }

      if (options.remote || options.machine) {
        std::println(stderr, "telar --machine: a window shows one machine first; drop --remote and the second --machine");
        return 1;
      }

      options.machine = label;
      return openWindow(memory, options);
    }

    bool checkMachineCommand(std::span<char* const> command, ds::Option<Family> family) {
      try {
        if (family == Family::machine) {
          static_cast<void>(MachineOptions::parse(command.subspan(1)));
        } else if (family == Family::cli) {
          static_cast<void>(parseCliInstall(command.subspan(1)));
        }
      } catch (const std::invalid_argument& error) {
        const auto reference = helpReference(command);

        std::println(stderr, "telar: {}; see `{}`", error.what(), reference.cStr());
        return false;
      }

      return true;
    }

    int forwardToMachine(Memory& memory, std::span<char* const> command, std::string_view label, Dispatch dispatch) {
      ds::Option<machines::MachineProfile> target;

      try {
        target = machine::resolve(memory, label);
      } catch (const std::exception& error) {
        const std::string_view reason = error.what();

        std::println(stderr, "telar --machine: {}: {}", label, reason == "UnknownMachine" ? "no saved machine or local label has that name; see `telar machine list`" : reason);
        return 1;
      }

      // The ports of a machine forwarded here are this machine's to list; the local one forwards none.
      if (!command.empty() && std::string_view{command.front()} == "ports") {
        return target ? port_sharing::list(memory, *target, command.subspan(1)) : 0;
      }

      return target ? machine::forward(memory, *target, command) : dispatch(command);
    }
  }

  int runMachineCommand(Memory& memory, std::span<char* const> words) {
    return runMachine(memory, MachineOptions::parse(words));
  }

  int runServerCommand(Memory& memory, std::span<char* const> words) {
    if (words.size() > 1 && gateway_commands::handles(words[1])) {
      return gateway_commands::run(memory, words.subspan(1));
    }

    runServer(memory, words);
    return 0;
  }

  int runSharePorts(Memory& memory, std::span<char* const> words) {
    return port_sharing::run(memory, words);
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
      std::println(stderr, "telar --machine: runs one telar command there; it cannot name another machine");
      return 1;
    }

    SystemAllocator system;
    BudgetAllocator budget{system, memory_budget};
    MemoryAdapter budget_memory{budget};
    Memory& memory = budget_memory;
    const auto family = parseFamily(first);
    // SSH uses no PTY, so the remote CLI cannot see whether this stdout is a terminal.
    if (family == Family::clipboard && (::isatty(STDOUT_FILENO) != 0)) {
      std::println(stderr, "telar clipboard: pipe clipboard content to a consumer or redirect stdout to a file");
      return 1;
    }

    if (command.empty() || (!family && first != "--version" && first != "-V" && first != "--skill" && first != "plugin-worker" && first != "ports") || family == Family::gui) {
      return openMachineWindow(memory, command, family == Family::gui, label);
    }

    if (!checkMachineCommand(command, family)) {
      return 1;
    }

    return forwardToMachine(memory, command, label, dispatch);
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
      arguments.push(tbc::raw(const_cast<char*>(word.data()))); // NOLINT(cppcoreguidelines-pro-type-const-cast): Dispatch takes argv's char*; a mutable borrow of each word would end the previous one's
    }

    return dispatch(arguments.view());
  }

}
