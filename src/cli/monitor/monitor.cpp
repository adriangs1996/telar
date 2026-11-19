module telar.cli.monitor;

import std;
import telar.sys.posix;
import telar.sys.process;

import telar.cli.command_limit;
import telar.cli.control_session;
import telar.cli.output;
import telar.config.core;
import telar.platform.paths;
import telar.wire.monitor;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.text.json;
import telar.base.ds;

namespace telar::runtime::cli::monitor {
  namespace {

    constexpr ds::Array<std::string_view, 5> sort_names{"cpu", "memory", "threads", "pid", "name"};
    constexpr ds::Array<std::string_view, 3> scope_names{"all", "telar", "agents"};
    constexpr ds::Array<std::string_view, 6> signal_names{"TERM", "KILL", "STOP", "CONT", "HUP", "INT"};
    constexpr ds::Array<std::string_view, 4> tool_names{"stack", "files", "logs", "debug"};
    constexpr ds::Array<std::string_view, 6> state_names{"unknown", "running", "sleeping", "idle", "stopped", "zombie"};
    constexpr ds::Array<std::string_view, 6> state_letters{"?", "R", "S", "I", "T", "Z"};
    constexpr unsigned minimum_interval_ms = 100;
    constexpr unsigned maximum_interval_ms = 60'000;
    constexpr unsigned reply_timeout_seconds = 15;
    constexpr std::size_t microsecond_digits = 6;
    constexpr std::size_t command_column_bytes = 96;

    template <typename Enum, std::size_t Size>
    Enum pick(std::string_view word, const ds::Array<std::string_view, Size>& names, const char* error) {
      for (std::size_t index = 0; index < Size; ++index) {
        if (names[index] == word) {
          return static_cast<Enum>(index);
        }
      }

      usage(error);
    }

    template <typename Enum, std::size_t Size>
    std::string_view nameOf(Enum value, const ds::Array<std::string_view, Size>& names) noexcept {
      const auto index = static_cast<std::size_t>(value);

      return index < Size ? names[index] : names[0];
    }

    // A start as `process list` prints it: seconds, a dot and six digits of microseconds.
    void parseStarted(std::string_view text, ProcessInstance& process) {
      const auto dot = text.find('.');
      const auto fraction = dot == std::string_view::npos ? std::string_view{} : text.substr(dot + 1);
      if (fraction.size() > microsecond_digits) {
        usage("InvalidStarted");
      }

      process.started_seconds = number<std::uint64_t>(text.substr(0, dot), "InvalidStarted");
      process.started_microseconds = fraction.empty() ? 0 : number<std::uint64_t>(fraction, "InvalidStarted");
      for (auto digits = fraction.size(); digits < microsecond_digits; ++digits) {
        process.started_microseconds *= 10;
      }
    }

    bool listing(Command command) noexcept {
      return command == Command::process_list || command == Command::process_watch;
    }

    bool targeted(Command command) noexcept {
      return command == Command::process_get || command == Command::process_signal || command == Command::process_renice || command == Command::process_review;
    }

    std::string_view familyText(Command command) noexcept {
      return command == Command::monitor_host || command == Command::monitor_disks || command == Command::monitor_network ? "telar monitor" : "telar process";
    }

    // The program a row names: the agent it runs when telar knows it, else the process's own name.
    std::string_view program(const MonitorProcess& process) noexcept {
      if (process.agent != AgentProvider::unknown) {
        const auto name = describeProvider(process.agent).name;
        if (!name.empty()) {
          return name;
        }
      }

      return process.name;
    }

    void appendBytes(Text& output, std::uint64_t bytes) {
      constexpr ds::Array<char, 5> units{'B', 'K', 'M', 'G', 'T'};
      constexpr std::uint64_t step = 1024;
      std::size_t unit = 0;
      std::uint64_t tenths = bytes * 10;

      while (tenths >= step * 10 && unit + 1 < units.size()) {
        tenths /= step;
        ++unit;
      }

      if (unit == 0) {
        ds::formatTo(output, "{}B", bytes);
      } else {
        ds::formatTo(output, "{}.{}{}", tenths / 10, tenths % 10, units[unit]);
      }
    }

    void appendPermille(Text& output, std::uint32_t permille) {
      ds::formatTo(output, "{}.{}", permille / 10, permille % 10);
    }

    void appendStarted(Text& output, const ProcessInstance& process) {
      ds::formatTo(output, "{}.{:06}", process.started_seconds, process.started_microseconds);
    }

    // The process as a JSON object; `open` leaves the object open for more members.
    void appendProcessJson(Text& output, const MonitorProcess& process, bool open = false) {
      ds::formatTo(output, "{{\"pid\":{},\"started\":\"", process.instance.pid);
      appendStarted(output, process.instance);
      ds::formatTo(output, "\",\"parent\":{},\"user\":{},\"user_id\":{},\"name\":{},\"program\":{},\"command\":{},\"state\":{},\"measured\":{},", process.parent, quoteJson(process.user), process.user_id, quoteJson(process.name), quoteJson(program(process)), quoteJson(process.command), quoteJson(nameOf(process.state, state_names)), jsonBoolean(process.measured));
      if (process.measured) {
        ds::formatTo(output, "\"cpu_permille\":{},\"resident_bytes\":{},\"threads\":{},", process.cpu_permille, process.resident_bytes, process.threads);
      } else {
        output.append("\"cpu_permille\":null,\"resident_bytes\":null,\"threads\":null,");
      }

      ds::formatTo(output, "\"nice\":{},\"pane_id\":{},\"agent\":", process.nice, orNull(process.pane_id == 0 ? ds::Option<std::uint64_t>{} : ds::Option{process.pane_id}));
      if (process.agent == AgentProvider::unknown) {
        output.append("null");
      } else {
        ds::formatTo(output, "{}", quoteJson(program(process)));
      }

      ds::formatTo(output, ",\"depth\":{}", process.depth);
      if (!open) {
        output.push('}');
      }
    }

    void appendListJson(Text& output, const MonitorSnapshot& snapshot) {
      ds::formatTo(output, "{{\"matched\":{},\"processes\":[", snapshot.matched);
      for (const auto& process : snapshot.processes) {
        if (&process != snapshot.processes.data()) {
          output.push(',');
        }

        appendProcessJson(output, process);
      }

      output.append("]}");
    }

    void appendListText(Text& output, const MonitorSnapshot& snapshot) {
      ds::formatTo(output, "{:>7} {:<10} {:>6} {:>7} {:>4} S {:>5} {:<16} {}\n", "PID", "USER", "CPU%", "MEM", "THR", "PANE", "PROGRAM", "COMMAND");
      for (const auto& process : snapshot.processes) {
        Text cpu{output.memory()};
        Text memory{output.memory()};
        Text threads{output.memory()};
        Text pane{output.memory()};
        Text name{output.memory()};

        if (process.measured) {
          appendPermille(cpu, process.cpu_permille);
          appendBytes(memory, process.resident_bytes);
          ds::formatTo(threads, "{}", process.threads);
        } else {
          cpu.append("-");
          memory.append("-");
          threads.append("-");
        }

        if (process.pane_id == 0) {
          pane.append("-");
        } else {
          ds::formatTo(pane, "{}", process.pane_id);
        }

        for (std::uint8_t level = 0; level < process.depth; ++level) {
          name.append("  ");
        }

        name.append(program(process));

        const auto user = process.user.substr(0, 10);
        const auto command = process.command.substr(0, command_column_bytes);

        ds::formatTo(output, "{:>7} {:<10} {:>6} {:>7} {:>4} {} {:>5} {:<16} {}\n", process.instance.pid, user, cpu.view(), memory.view(), threads.view(), nameOf(process.state, state_letters), pane.view(), name.view(), command);
      }

      if (snapshot.matched > snapshot.processes.size()) {
        ds::formatTo(output, "{} of {} processes\n", snapshot.processes.size(), snapshot.matched);
      }
    }

    void appendDetailJson(Text& output, const MonitorDetail& detail) {
      appendProcessJson(output, detail.process, true);
      ds::formatTo(output, ",\"arguments\":{},\"directory\":{},\"ports\":[", quoteJson(detail.arguments), quoteJson(detail.directory));
      for (std::size_t index = 0; index < detail.ports.size(); ++index) {
        ds::formatTo(output, "{}{}", index == 0 ? "" : ",", detail.ports[index]);
      }

      output.append("],\"children\":[");
      for (std::size_t index = 0; index < detail.children.size(); ++index) {
        ds::formatTo(output, "{}{}", index == 0 ? "" : ",", detail.children[index]);
      }

      output.append("]}");
    }

    void appendDetailText(Text& output, const MonitorDetail& detail) {
      const auto& process = detail.process;

      ds::formatTo(output, "PID: {}\nStarted: ", process.instance.pid);
      appendStarted(output, process.instance);
      ds::formatTo(output, "\nProgram: {}\nName: {}\nUser: {} ({})\nState: {}\nParent: {}\nNice: {}\n", program(process), process.name, process.user, process.user_id, nameOf(process.state, state_names), process.parent, process.nice);
      if (process.measured) {
        output.append("CPU: ");
        appendPermille(output, process.cpu_permille);
        output.append("%\nMemory: ");
        appendBytes(output, process.resident_bytes);
        ds::formatTo(output, "\nThreads: {}\n", process.threads);
      } else {
        output.append("CPU, memory and threads: not readable by this user\n");
      }

      if (process.pane_id != 0) {
        ds::formatTo(output, "Pane: {}\n", process.pane_id);
      }

      ds::formatTo(output, "Directory: {}\nCommand: {}\nPorts:", detail.directory.empty() ? "-" : detail.directory, detail.arguments.empty() ? "-" : detail.arguments);
      for (const auto port : detail.ports) {
        ds::formatTo(output, " {}", port);
      }

      output.append("\nChildren:");
      for (const auto child : detail.children) {
        ds::formatTo(output, " {}", child);
      }

      output.push('\n');
    }

    void appendHost(Text& output, const MonitorSnapshot& snapshot, bool json) {
      if (json) {
        ds::formatTo(output, "{{\"cpu_permille\":{},\"cores\":[", snapshot.cpu_permille);
        for (std::size_t index = 0; index < snapshot.cores.size(); ++index) {
          ds::formatTo(output, "{}{}", index == 0 ? "" : ",", snapshot.cores[index]);
        }

        ds::formatTo(output, "],\"memory_total_bytes\":{},\"memory_used_bytes\":{},\"memory_available_bytes\":{},\"memory_cached_bytes\":{},\"swap_total_bytes\":{},\"swap_used_bytes\":{},\"process_count\":{},\"thread_count\":{}}}\n", snapshot.memory_total_bytes, snapshot.memory_used_bytes, snapshot.memory_available_bytes, snapshot.memory_cached_bytes, snapshot.swap_total_bytes, snapshot.swap_used_bytes, snapshot.process_count, snapshot.thread_count);
        return;
      }

      output.append("CPU: ");
      appendPermille(output, snapshot.cpu_permille);
      ds::formatTo(output, "% of {} cores\nCores:", snapshot.cores.size());
      for (const auto core : snapshot.cores) {
        output.push(' ');
        appendPermille(output, core);
      }

      output.append("\nMemory: ");
      appendBytes(output, snapshot.memory_used_bytes);
      output.append(" used of ");
      appendBytes(output, snapshot.memory_total_bytes);
      output.append(", ");
      appendBytes(output, snapshot.memory_available_bytes);
      output.append(" available, ");
      appendBytes(output, snapshot.memory_cached_bytes);
      output.append(" cached\nSwap: ");
      appendBytes(output, snapshot.swap_used_bytes);
      output.append(" used of ");
      appendBytes(output, snapshot.swap_total_bytes);
      ds::formatTo(output, "\nProcesses: {}\nThreads: {}\n", snapshot.process_count, snapshot.thread_count);
    }

    void appendDisks(Text& output, const MonitorSnapshot& snapshot, bool json) {
      if (json) {
        ds::formatTo(output, "{{\"read_per_second\":{},\"written_per_second\":{},\"disks\":[", snapshot.disk_read_per_second, snapshot.disk_written_per_second);
        for (const auto& disk : snapshot.disks) {
          ds::formatTo(output, "{}{{\"path\":{},\"device\":{},\"type\":{},\"total_bytes\":{},\"used_bytes\":{},\"available_bytes\":{}}}", &disk == snapshot.disks.data() ? "" : ",", quoteJson(disk.path), quoteJson(disk.device), quoteJson(disk.type), disk.total_bytes, disk.used_bytes, disk.available_bytes);
        }

        output.append("]}\n");
        return;
      }

      output.append("Read: ");
      appendBytes(output, snapshot.disk_read_per_second);
      output.append("/s\nWritten: ");
      appendBytes(output, snapshot.disk_written_per_second);
      ds::formatTo(output, "/s\n{:<28} {:<8} {:>8} {:>8} {:>8} {:>5}\n", "PATH", "TYPE", "USED", "TOTAL", "FREE", "USE%");
      for (const auto& disk : snapshot.disks) {
        Text used{output.memory()};
        Text total{output.memory()};
        Text available{output.memory()};

        appendBytes(used, disk.used_bytes);
        appendBytes(total, disk.total_bytes);
        appendBytes(available, disk.available_bytes);
        ds::formatTo(output, "{:<28} {:<8} {:>8} {:>8} {:>8} {:>4}%\n", disk.path, disk.type, used.view(), total.view(), available.view(), disk.total_bytes == 0 ? 0 : disk.used_bytes * 100 / disk.total_bytes);
      }
    }

    void appendNetwork(Text& output, const MonitorSnapshot& snapshot, bool json) {
      if (json) {
        output.append("{\"interfaces\":[");
        for (const auto& interface : snapshot.interfaces) {
          ds::formatTo(output, "{}{{\"name\":{},\"received_per_second\":{},\"sent_per_second\":{},\"received_bytes\":{},\"sent_bytes\":{}}}", &interface == snapshot.interfaces.data() ? "" : ",", quoteJson(interface.name), interface.received_per_second, interface.sent_per_second, interface.received_bytes, interface.sent_bytes);
        }

        output.append("]}\n");
        return;
      }

      ds::formatTo(output, "{:<12} {:>10} {:>10} {:>10} {:>10}\n", "INTERFACE", "RX/s", "TX/s", "RX", "TX");
      for (const auto& interface : snapshot.interfaces) {
        Text received{output.memory()};
        Text sent{output.memory()};
        Text received_total{output.memory()};
        Text sent_total{output.memory()};

        appendBytes(received, interface.received_per_second);
        appendBytes(sent, interface.sent_per_second);
        appendBytes(received_total, interface.received_bytes);
        appendBytes(sent_total, interface.sent_bytes);
        ds::formatTo(output, "{:<12} {:>10} {:>10} {:>10} {:>10}\n", interface.name, received.view(), sent.view(), received_total.view(), sent_total.view());
      }
    }

    QueryMonitor query(const Options& options, std::uint8_t sections) {
      return {
          .sections = sections,
          .sort = options.sort,
          .reverse = options.reverse,
          .scope = options.scope,
          .tree = options.tree,
          .filter = options.filter,
          .limit = listing(options.command) ? options.limit : std::uint16_t{0},
          .detail = options.command == Command::process_get || options.command == Command::process_review ? options.process : ProcessInstance{},
      };
    }

    int watch(Memory& memory, ControlSession& session, const Options& options) {
      for (std::uint64_t round = 0; !options.count || round < *options.count; ++round) {
        if (round != 0) {
          std::this_thread::sleep_for(std::chrono::milliseconds{options.interval_ms});
        }

        const auto snapshot = session.template exchange<MonitorSnapshot>(query(options, MonitorSections::processes));
        Text output{memory};

        if (options.json) {
          appendListJson(output, snapshot);
          output.push('\n');
        } else {
          if (round != 0) {
            output.push('\n');
          }

          appendListText(output, snapshot);
        }

        writeText(output);
      }

      return 0;
    }

    // The system tool that shows `tool` of a process here, and its arguments.
    ds::Array<std::string_view, 6> reviewCommand(ReviewTool tool, std::string_view pid, std::string_view predicate) noexcept {
#if defined(__APPLE__)
      switch (tool) {
      case ReviewTool::stack:
        return {"sample", pid};
      case ReviewTool::files:
        return {"lsof", "-p", pid};
      case ReviewTool::logs:
        return {"log", "stream", "--predicate", predicate};
      case ReviewTool::debug:
        return {"lldb", "-p", pid};
      }
#else
      switch (tool) {
      case ReviewTool::stack:
        return {"eu-stack", "-p", pid};
      case ReviewTool::files:
        return {"lsof", "-p", pid};
      case ReviewTool::logs:
        return {"journalctl", "-f", predicate};
      case ReviewTool::debug:
        return {"gdb", "-p", pid};
      }
#endif
      return {};
    }

    int review(Memory& memory, const Options& options) {
      Text pid{memory};
      Text predicate{memory};

      ds::formatTo(pid, "{}", options.process.pid);
#if defined(__APPLE__)
      ds::formatTo(predicate, "processID == {}", options.process.pid);
#else
      ds::formatTo(predicate, "_PID={}", options.process.pid);
#endif
      const auto words = reviewCommand(options.tool, pid.view(), predicate.view());
      const auto count = static_cast<std::size_t>(std::ranges::count_if(words, [](std::string_view word) {
        return !word.empty();
      }));

      if (options.print) {
        Text output{memory};

        for (std::size_t index = 0; index < count; ++index) {
          const auto word = words[index];
          const auto plain = word.find_first_of(" '\"$\\") == std::string_view::npos;

          ds::formatTo(output, "{}{}{}{}", index == 0 ? "" : " ", plain ? "" : "'", word, plain ? "" : "'");
        }

        output.push('\n');
        writeText(output);
        return 0;
      }

      // The words, each ended by a NUL, and argv pointing at them once they stop moving.
      Text storage{memory};
      ds::Array<std::size_t, 6> offsets{};
      ds::Array<char*, 7> argv{};

      for (std::size_t index = 0; index < count; ++index) {
        offsets.atMut(index) = storage.size();
        storage.append(words[index]);
        storage.push('\0');
      }

      for (std::size_t index = 0; index < count; ++index) {
        argv.atMut(index) = storage.viewMut().data() + offsets[index];
      }

      ::execvp(argv[0], argv.dataMut());
      std::fprintf(stderr, "telar process: %s is not available on this machine\n", argv[0]);
      return 1;
    }

  }

  Options Options::parse(Family family, Arguments words) {
    Cursor cursor{words};
    Options options;
    const auto verb = cursor.take("MissingCommand");

    if (family == Family::process) {
      constexpr ds::Array<std::string_view, 6> verbs{"list", "get", "watch", "signal", "renice", "review"};

      options.command = pick<Command>(verb, verbs, "UnknownCommand");
    } else {
      constexpr ds::Array<std::string_view, 3> verbs{"host", "disks", "network"};

      options.command = static_cast<Command>(static_cast<std::size_t>(pick<Command>(verb, verbs, "UnknownCommand")) + static_cast<std::size_t>(Command::monitor_host));
    }

    if (options.command == Command::process_watch) {
      options.limit = default_watch_limit;
    }

    std::size_t positional = 0;

    while (const auto word = cursor.next()) {
      const auto argument = *word;
      const auto list_option = listing(options.command);

      if (argument == "--socket") {
        options.socket = cursor.take("MissingSocket");
      } else if ((argument == "--json" && options.command != Command::process_watch) || (argument == "--jsonl" && options.command == Command::process_watch)) {
        options.json = true;
      } else if (list_option && argument == "--sort") {
        options.sort = pick<MonitorSort>(cursor.take("MissingSort"), sort_names, "InvalidSort");
      } else if (list_option && argument == "--reverse") {
        options.reverse = true;
      } else if (list_option && argument == "--scope") {
        options.scope = pick<MonitorScope>(cursor.take("MissingScope"), scope_names, "InvalidScope");
      } else if (list_option && argument == "--tree") {
        options.tree = true;
      } else if (list_option && argument == "--filter") {
        options.filter = cursor.take("MissingFilter");
        if (options.filter.size() > MonitorLimits::filter_bytes || std::ranges::any_of(options.filter, [](unsigned char byte) {
              return byte < 0x20 || byte == 0x7f;
            })) {
          usage("InvalidFilter");
        }
      } else if (list_option && argument == "--limit") {
        options.limit = number<std::uint16_t>(cursor.take("MissingLimit"), "InvalidLimit");
        if (options.limit == 0 || options.limit > MonitorLimits::maximum_processes) {
          usage("InvalidLimit");
        }
      } else if (options.command == Command::process_watch && argument == "--interval-ms") {
        options.interval_ms = number<unsigned>(cursor.take("MissingInterval"), "InvalidInterval");
        if (options.interval_ms < minimum_interval_ms || options.interval_ms > maximum_interval_ms) {
          usage("InvalidInterval");
        }
      } else if (options.command == Command::process_watch && argument == "--count") {
        options.count = positive(cursor.take("MissingCount"), "InvalidCount");
      } else if (targeted(options.command) && argument == "--started") {
        parseStarted(cursor.take("MissingStarted"), options.process);
      } else if (options.command == Command::process_review && argument == "--tool") {
        options.tool = pick<ReviewTool>(cursor.take("MissingTool"), tool_names, "InvalidTool");
      } else if (options.command == Command::process_review && argument == "--print") {
        options.print = true;
      } else if (argument.starts_with("--")) {
        usage("UnknownOption");
      } else if (targeted(options.command) && positional == 0) {
        options.process.pid = static_cast<std::int32_t>(std::min<std::uint64_t>(positive(argument, "InvalidPid"), std::numeric_limits<std::int32_t>::max()));
        ++positional;
      } else if (options.command == Command::process_signal && positional == 1) {
        options.signal = pick<ProcessSignal>(argument, signal_names, "InvalidSignal");
        ++positional;
      } else if (options.command == Command::process_renice && positional == 1) {
        options.nice = signedNumber<int>(argument, "InvalidNice");
        if (options.nice < -20 || options.nice > 20) {
          usage("InvalidNice");
        }

        ++positional;
      } else {
        usage("UnexpectedArgument");
      }
    }

    const auto required = options.command == Command::process_signal || options.command == Command::process_renice ? 2u : targeted(options.command) ? 1u
                                                                                                                                                    : 0u;
    if (positional < required) {
      usage(positional == 0 ? "MissingPid" : options.command == Command::process_signal ? "MissingSignal"
                                                                                        : "MissingNice");
    }

    return options;
  }

  int run(Memory& memory, const Options& options) {
    const auto family = familyText(options.command);

    try {
      ServerOptions server_options{};

      server_options.socket = options.socket.valueOr("");
      const RuntimePaths paths{memory, server_options, process_environment};
      ds::Option<ControlSession> session;

      session.emplace(memory, paths.socket.data());
      session.getMut().receiveTimeout(reply_timeout_seconds);

      Text output{memory};

      switch (options.command) {
      case Command::process_list: {
        const auto snapshot = session.getMut().template exchange<MonitorSnapshot>(query(options, MonitorSections::processes));
        if (options.json) {
          appendListJson(output, snapshot);
          output.push('\n');
        } else {
          appendListText(output, snapshot);
        }

        break;
      }
      case Command::process_watch:
        return watch(memory, session.getMut(), options);
      case Command::process_get: {
        const auto snapshot = session.getMut().template exchange<MonitorSnapshot>(query(options, 0));
        if (!snapshot.detail) {
          throw ControlFailure{FailureCode::process_not_found};
        }

        if (options.json) {
          appendDetailJson(output, *snapshot.detail);
          output.push('\n');
        } else {
          appendDetailText(output, *snapshot.detail);
        }

        break;
      }
      case Command::process_signal:
        session.getMut().template exchange<RequestCompleted>(RequestProcessSignal{.process = options.process, .signal = options.signal});
        if (options.json) {
          ds::formatTo(output, "{{\"pid\":{},\"signal\":{}}}\n", options.process.pid, quoteJson(nameOf(options.signal, signal_names)));
        } else {
          ds::formatTo(output, "Sent {} to {}\n", nameOf(options.signal, signal_names), options.process.pid);
        }

        break;
      case Command::process_renice:
        session.getMut().template exchange<RequestCompleted>(RequestProcessPriority{.process = options.process, .nice = options.nice});
        if (options.json) {
          ds::formatTo(output, "{{\"pid\":{},\"nice\":{}}}\n", options.process.pid, options.nice);
        } else {
          ds::formatTo(output, "Set the nice value of {} to {}\n", options.process.pid, options.nice);
        }

        break;
      case Command::process_review:
        // The tool runs only on the instance the caller named; the session closes before it does.
        session.getMut().template exchange<MonitorSnapshot>(query(options, 0));
        session.reset();
        return review(memory, options);
      case Command::monitor_host:
        appendHost(output, session.getMut().template exchange<MonitorSnapshot>(query(options, MonitorSections::host)), options.json);
        break;
      case Command::monitor_disks:
        appendDisks(output, session.getMut().template exchange<MonitorSnapshot>(query(options, MonitorSections::disks)), options.json);
        break;
      case Command::monitor_network:
        appendNetwork(output, session.getMut().template exchange<MonitorSnapshot>(query(options, MonitorSections::network)), options.json);
        break;
      }

      writeText(output);
      return 0;
    } catch (const std::exception& error) {
      return commandFailure(family.data(), error);
    }
  }

}
