module telar.cli.commands.history;

import telar.tbc;
import telar.cli.session.control_session;
import telar.sys.posix;
import telar.base.diagnostics;
import telar.cli.session.server;
import telar.platform.fs;
import telar.platform.paths;
import telar.platform.error;
import telar.wire.runtime;
import telar.wire.history;
import telar.base.ds;
import telar.cli.commands.history.sources;
import telar.cli.commands.history.output;

namespace telar::runtime::cli::file_transfer {

  constexpr std::uint64_t max_bytes = std::uint64_t{128} * 1024 * 1024;

  namespace {

    constexpr int directory_flags = combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC);

    // The directory `component` names under `current`, made first when it is missing and `create` asks.
    FileDescriptor openComponent(int current, std::string_view component, bool create) {
      constexpr mode_t private_directory_mode = 0700;
      ds::Array<char, NAME_MAX + 1> name{};
      if (component.size() >= name.size()) {
        throw std::runtime_error{sys::errorName(ENAMETOOLONG)};
      }

      std::ranges::copy(component, name.dataMut());
      auto next = ::openat(current, name.data(), directory_flags); // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      if (next < 0 && sys::lastError() == ENOENT && create) {
        if (::mkdirat(current, name.data(), private_directory_mode) != 0 && sys::lastError() != EEXIST) {
          throw std::runtime_error{sys::errorName(sys::lastError())};
        }

        next = ::openat(current, name.data(), directory_flags); // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      }

      if (next < 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      return FileDescriptor{next};
    }

  }

  FileDescriptor openDirectory(std::string_view path, bool create) {
    constexpr mode_t group_or_other_write = 0022;

    if (!path.starts_with('/')) {
      throw std::runtime_error{"AbsoluteFilePathRequired"};
    }

    FileDescriptor current{::open("/", combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    if (!current) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    std::size_t start = 1;

    while (start < path.size()) {
      const auto end = path.find('/', start);
      const auto component = path.substr(start, end == std::string_view::npos ? path.size() - start : end - start);

      start = end == std::string_view::npos ? path.size() : end + 1;
      if (component.empty()) {
        continue;
      }

      if (component == "." || component == "..") {
        throw std::runtime_error{"InvalidFilePath"};
      }

      current = openComponent(current.get(), component, create);
    }

    struct stat inode{};
    if (::fstat(current.get(), &inode) != 0) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    if (inode.st_uid != ::getuid() || (inode.st_mode & group_or_other_write) != 0) {
      throw std::runtime_error{"UnsafeTransferDirectory"};
    }

    return current;
  }

  FileDescriptor openParent(std::string_view path) {
    const auto slash = path.rfind('/');
    if (slash == std::string_view::npos) {
      throw std::runtime_error{"InvalidFilePath"};
    }

    return openDirectory(path.substr(0, slash == 0 ? 1 : slash));
  }

  FileDescriptor openRegular(int parent, const char* name) {
    FileDescriptor file{::openat(parent, name, combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
    if (!file) {
      throw std::runtime_error{sys::lastError() == ENOENT ? sys::errorName(ENOENT) : "UnsafeTransferFile"};
    }

    struct stat inode{};
    if (::fstat(file.get(), &inode) != 0 || !S_ISREG(inode.st_mode) || inode.st_uid != ::getuid() || inode.st_nlink != 1) {
      throw std::runtime_error{"UnsafeTransferFile"};
    }

    return file;
  }

  namespace {

    void checkSize(std::uint64_t size) {
      if (size > max_bytes) {
        reportCommandLimit({.name = "file_transfer.max_bytes", .noun = "bytes", .value = max_bytes, .requested = size});
        throw std::runtime_error{"FileTransferLimit"};
      }
    }

  }

  std::uint64_t copy(CopyEnds ends) {
    ds::Array<Byte, copy_buffer_bytes> buffer{};
    std::uint64_t total = 0;

    for (;;) {
      const auto count = ::read(ends.input, buffer.dataMut(), buffer.size());
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count < 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      if (count == 0) {
        return total;
      }

      total += static_cast<std::uint64_t>(count);
      checkSize(total);
      writeBytes(ends.output, std::span{buffer}.first(static_cast<std::size_t>(count)));
    }
  }

  void publish(int parent, const char* temporary, const char* name) {
#if defined(__APPLE__) || defined(__linux__)
    const auto result = renameAt(parent, temporary, parent, name, RenameMode::create_only);
#else
    const auto result = ::linkat(parent, temporary, parent, name, 0);
    if (result == 0) {
      ::unlinkat(parent, temporary, 0);
    }
#endif
    if (result != 0) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }
  }

  void transfer(const Options& options) {
    if (options.action == Options::Action::put) {
      checkSize(options.bytes);
    }

    const auto parent = openParent(options.path);
    const auto slash = options.path.rfind('/');
    const auto name = options.path.substr(slash + 1);
    if (name.empty() || name == "." || name == "..") {
      throw std::runtime_error{"InvalidFilePath"};
    }

    if (options.action == Options::Action::get) {
      const auto file = openRegular(parent.get(), name.data());
      struct stat inode{};
      if (::fstat(file.get(), &inode) != 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      checkSize(static_cast<std::uint64_t>(inode.st_size));
      copy({.input = file.get(), .output = STDOUT_FILENO});
      return;
    }

    // Room for the name, 12 bytes of prefix and 32 hex digits, and for the reply, at most 50 bytes.
    constexpr std::size_t temporary_bytes = 64;
    constexpr std::size_t reply_bytes = 64;
    constexpr mode_t private_file_mode = 0600;
    ds::Array<char, temporary_bytes> temporary{};

    std::format_to_n(temporary.dataMut(), temporary.size() - 1, ".telar-file-{:016x}{:016x}", randomIdentity(), randomIdentity());
    const FileDescriptor file{::openat(parent.get(), temporary.data(), combineFlags(O_CREAT, O_EXCL, O_WRONLY, O_CLOEXEC), private_file_mode)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
    if (!file) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    try {
      const auto size = copy({.input = STDIN_FILENO, .output = file.get()});
      if (size != options.bytes) {
        throw std::runtime_error{"FileTransferInterrupted"};
      }

      if (::fsync(file.get()) != 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      publish(parent.get(), temporary.data(), name.data());
      ds::Array<char, reply_bytes> reply{};
      const auto written = std::format_to_n(reply.dataMut(), reply.size(), "{{\"bytes\":{},\"published\":true}}\n", size);

      writeText({reply.data(), static_cast<std::size_t>(written.out - reply.data())});
    } catch (...) {
      ::unlinkat(parent.get(), temporary.data(), 0);
      throw;
    }
  }

  int run(const Options& options) {
    try {
      transfer(options);
      return 0;
    } catch (const std::exception& error) {
      std::println(stderr, "telar file: {}", error.what());
      return 1;
    }
  }

}

namespace telar::runtime::cli::diagnostics {

  constexpr std::size_t max_files = 64;
  constexpr std::size_t max_directory_entries = std::size_t{64} * 1024;
  constexpr std::size_t max_tail_bytes = std::size_t{1024} * 1024;

  namespace {

    struct Log { // NOLINT(bugprone-exception-escape): its implicit move assignment, which sorting uses, moves a String, which allocates only between two allocators, and every log's name comes from the one memory
      Text name;
      DiagnosticsOptions::Component component;
      std::uint32_t pid;
    };

    tbc::val_a<ds::Option<Log>> parseLog(tbc::mut_a<Memory> memory, std::string_view name, std::string_view base) {
      if (!name.starts_with(base) || !name.ends_with(".log")) {
        return ds::none;
      }

      auto suffix = name.substr(base.size(), name.size() - base.size() - std::string_view{".log"}.size());
      auto component = DiagnosticsOptions::Component::all;

      if (suffix.starts_with(".runtime-")) {
        component = DiagnosticsOptions::Component::runtime;
        suffix.remove_prefix(std::string_view{".runtime-"}.size());
      } else if (suffix.starts_with(".client-")) {
        component = DiagnosticsOptions::Component::client;
        suffix.remove_prefix(std::string_view{".client-"}.size());
      } else {
        return ds::none;
      }

      const auto pid = maybeUnsigned<std::uint32_t>(suffix);
      if (pid && *pid != 0) {
        return Log{.name = Text{memory, name}, .component = component, .pid = *pid};
      }

      return ds::none;
    }

    std::string_view tail(std::string_view bytes, std::uint16_t lines) {
      if (bytes.empty()) {
        return bytes;
      }

      auto index = bytes.size() - (bytes.back() == '\n' ? 1 : 0);
      std::size_t found = 0;

      while (index != 0) {
        if (bytes[--index] == '\n' && ++found == lines) {
          return bytes.substr(index + 1);
        }
      }

      return bytes;
    }

    // The descriptor beneath a directory stream, which the *at calls take.
    int directoryDescriptor(DIR* directory) {
      const int descriptor = ::dirfd(directory);
      if (descriptor < 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      return descriptor;
    }

    tbc::val_a<ds::Vec<Log, Memory>> findLogs(tbc::mut_a<Memory> memory, DIR* directory, std::string_view base, const DiagnosticsOptions& options) {
      ds::Vec<Log, Memory> logs{memory};
      std::size_t visited = 0;
      std::size_t skipped = 0;

      while (const auto* entry = ::readdir(directory)) { // NOLINT(concurrency-mt-unsafe): readdir is unsafe only on a stream that another thread reads too, and this stream is the call's own
        const std::string_view name{std::data(entry->d_name)};
        if (name == "." || name == "..") {
          continue;
        }

        if (++visited > max_directory_entries) {
          reportCommandLimit({.name = "cli.diagnostic_directory_entries", .noun = "entries", .value = max_directory_entries});
          break;
        }

        if (entry->d_type != DT_REG) {
          continue;
        }

        auto log = parseLog(memory, name, base);
        if (!log || (options.component != DiagnosticsOptions::Component::all && options.component != log->component) || (options.pid && log->pid != *options.pid)) {
          continue;
        }

        if (logs.size() == max_files) {
          ++skipped;
          continue;
        }

        logs.push(std::move(log.getMut()));
      }

      if (options.component != DiagnosticsOptions::Component::client && !options.pid) {
        const int descriptor = directoryDescriptor(directory);

        for (const auto* const suffix : {".runtime.start.log", ".runtime.log"}) {
          auto name = ds::format(memory, "{}{}", base, suffix);
          struct stat state{};
          if (::fstatat(descriptor, name.data(), &state, 0) == 0) {
            logs.push({.name = std::move(name), .component = DiagnosticsOptions::Component::runtime, .pid = 0});
          }
        }
      }

      if (skipped != 0) {
        reportCommandLimit({.name = "cli.diagnostic_logs", .noun = "logs", .value = max_files, .requested = max_files + skipped});
      }

      if (logs.empty()) {
        throw std::runtime_error{"DiagnosticLogsNotFound"};
      }

      std::ranges::sort(logs.viewMut(), [](const auto& left, const auto& right) {
        return left.name < right.name;
      });

      return logs;
    }

    // The last max_tail_bytes of a log, from the start of a line, and whether the log holds more.
    struct LogTail {
      tbc::val_a<std::string_view> text;
      bool cut;
    };

    tbc::val_a<LogTail> readTail(int directory, const Log& log, tbc::val_a<std::span<char>> bytes) {
      const FileDescriptor file{::openat(directory, log.name.data(), combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      if (!file) {
        throw std::runtime_error{"CannotOpenDiagnosticLog"};
      }

      struct stat inode{};
      if (::fstat(file.get(), &inode) != 0 || !S_ISREG(inode.st_mode) || inode.st_uid != ::getuid()) {
        throw std::runtime_error{"UnsafeDiagnosticLog"};
      }

      const auto offset = std::max<off_t>(0, inode.st_size - static_cast<off_t>(max_tail_bytes));
      std::size_t count = 0;

      while (count < bytes.size()) {
        const auto rest = bytes.subspan(count);
        const auto read = ::pread(file.get(), rest.data(), rest.size(), offset + static_cast<off_t>(count));
        if (read < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (read < 0) {
          throw std::runtime_error{sys::errorName(sys::lastError())};
        }

        if (read == 0) {
          break;
        }

        count += static_cast<std::size_t>(read);
      }

      auto text = std::string_view{bytes.data(), count};
      if (offset != 0 && text.contains('\n')) {
        text.remove_prefix(text.find('\n') + 1);
      }

      return {.text = text, .cut = offset != 0};
    }

    // What the output shows of one log: its path, the lines it shows, and whether the log holds more.
    struct LogPart {
      std::string_view path;
      std::string_view text;
      bool truncated;
    };

    void appendJson(Text& output, const Log& log, LogPart part) {
      ds::formatTo(output, R"({{"path":{},"component":{},"pid":{},"truncated":{},"text":{}}})", quoteJson(part.path), quoteJson(log.component == DiagnosticsOptions::Component::runtime ? "runtime" : "client"), log.pid, jsonBoolean(part.truncated), quoteJson(part.text));
    }

    void appendPlain(Text& output, LogPart part) {
      ds::formatTo(output, "{}{}{}", part.path, part.truncated ? " (tail)\n" : "\n", part.text);
      if (part.text.empty() || part.text.back() != '\n') {
        output.push('\n');
      }
    }

    void readLogs(Memory& memory, std::string_view endpoint, const DiagnosticsOptions& options) {
      const auto slash = endpoint.rfind('/');
      if (slash == std::string_view::npos) {
        throw std::runtime_error{"InvalidSocketPath"};
      }

      const Text parent{memory, endpoint.substr(0, slash)};
      const auto base = endpoint.substr(slash + 1);
      std::unique_ptr<DIR, decltype(&::closedir)> directory{::opendir(parent.data()), &::closedir};
      if (!directory) {
        throw std::runtime_error{sys::lastError() == ENOENT ? "DiagnosticLogsNotFound" : sys::errorName(sys::lastError())};
      }

      const auto logs = findLogs(memory, directory.get(), base, options);
      const int descriptor = directoryDescriptor(directory.get());
      Text bytes{memory};
      Text output{memory, options.json ? "[" : ""};

      bytes.resizeForOverwrite(max_tail_bytes);
      for (const auto& log : logs) {
        const auto read = readTail(descriptor, log, bytes.viewMut());
        const auto selected = tail(read.text, options.lines);
        const auto path = ds::format(memory, "{}/{}", parent, log.name);
        const LogPart part{.path = path, .text = selected, .truncated = read.cut || selected.size() < read.text.size()};

        if (!options.json) {
          appendPlain(output, part);
          continue;
        }

        if (&log != logs.data()) {
          output.push(',');
        }

        appendJson(output, log, part);
      }

      if (options.json) {
        output.append("]\n");
      }

      writeText(output);
    }

    void printLimits(Memory& memory, const LimitList& list, bool json) {
      Text output{memory};

      if (json) {
        ds::formatTo(output, R"({{"runtime_evicted":{},"client_evicted":{},"refused_reports":{},"limits":[)", list.runtime_evicted, list.client_evicted, list.refused_reports);
      } else if (list.entries.empty()) {
        output.append("no limit reached\n");
      }

      for (const auto& entry : list.entries) {
        const auto* const origin = entry.origin == LimitOrigin::runtime ? "runtime" : "client";

        if (json) {
          if (&entry != list.entries.data()) {
            output.push(',');
          }

          ds::formatTo(output, R"({{"name":{},"noun":{},"value":{},"requested":{},"route":{},"origin":{},"hits":{},"last_ms":{}}})", quoteJson(entry.reach.name), quoteJson(entry.reach.noun), entry.reach.value, orNull(entry.reach.requested), quoteJson(entry.reach.route), quoteJson(origin), entry.hits, entry.last_ms);
        } else {
          constexpr std::int64_t seconds_per_day = std::int64_t{24} * 60 * 60;
          constexpr std::int64_t seconds_per_hour = std::int64_t{60} * 60;
          constexpr std::int64_t seconds_per_minute = 60;
          const auto seconds = std::max<std::int64_t>(0, entry.last_ms / 1000) % seconds_per_day;

          ds::formatTo(output, "{}  ({}{}{}, last {:02}:{:02}:{:02} UTC)\n", limitDescription(entry.reach, entry.hits), origin, entry.reach.route.empty() ? "" : ", ", entry.reach.route, seconds / seconds_per_hour, seconds / seconds_per_minute % seconds_per_minute, seconds % seconds_per_minute);
        }
      }

      if (json) {
        output.append("]}\n");
      } else if (list.runtime_evicted != 0 || list.client_evicted != 0 || list.refused_reports != 0) {
        ds::formatTo(output, "{} runtime and {} client limits replaced by newer ones; {} client reports refused\n", list.runtime_evicted, list.client_evicted, list.refused_reports);
      }

      writeText(output);
    }

  }

  int run(Memory& memory, const DiagnosticsOptions& options) {
    try {
      ServerOptions server_options{};

      server_options.socket = options.socket.valueOr("");
      const RuntimePaths<Memory> paths{memory, server_options, process_environment};

      if (options.action == DiagnosticsOptions::Action::logs) {
        readLogs(memory, paths.socket, options);
      } else {
        constexpr unsigned timeout_seconds = 30;
        ControlSession session{memory, paths.socket.data()};

        session.receiveTimeout(timeout_seconds);
        printLimits(memory, session.template exchange<LimitList>(QueryLimits{}), options.json);
      }

      return 0;
    } catch (const std::exception& error) {
      const std::string_view reason = commandErrorName(error);

      std::println(stderr, "telar diagnostics: {}", reason);
      if (reason == "DiagnosticLogsNotFound") {
        writeText("  the background runtime writes .runtime.log beside its socket once it starts;\n  per-process telemetry needs a build with -Ddiagnostics.\n", STDERR_FILENO);
        return 2;
      }

      return 1;
    }
  }

}

namespace telar::runtime::cli {

  void ensureRuntime(Memory& memory, const RuntimePaths<Memory>& paths, const ServerOptions& options) {
    ds::Option<RuntimeConnection> connection;
    if (connectExisting(connection, paths.socket.data())) {
      return;
    }

    if (startRuntime(memory, options, paths) != RuntimeStart::listening) {
      throw std::runtime_error{"RuntimeUnavailable"};
    }
  }

}

namespace telar::runtime::cli::history {

  namespace {

    constexpr std::size_t max_batch_payload = 4 * max_command_bytes;
    constexpr std::size_t max_import_entries = ImportHistory::maximum_entries;
    constexpr unsigned timeout_seconds = 30;
    constexpr std::int64_t milliseconds_per_second = 1000;
    // A request carries a batch of imported commands with its source and other fields, which this leaves room for.
    constexpr std::size_t request_overhead_bytes = 4096;

    using Kind = HistoryOptions::ImportKind;

    // The shell or tool a file named on the command line comes from, as its name and its first
    // bytes suggest.
    Kind fileKind(std::string_view file, const char* path) noexcept {
      auto name = file;

      name.remove_prefix(file.rfind('/') + 1);

      if (name.ends_with("fish_history")) {
        return Kind::fish;
      }

      if (name == "ConsoleHost_history.txt") {
        return Kind::powershell;
      }

      if (name.ends_with(".json") || name == "history_json") {
        return Kind::xonsh;
      }

      if (sqliteFile(path)) {
        if (file.contains("atuin")) {
          return Kind::atuin;
        }

        if (file.contains("mcfly") || file.contains("McFly")) {
          return Kind::mcfly;
        }

        return name.ends_with(".sqlite3") ? Kind::nushell : Kind::histdb;
      }

      if (file.contains("nushell")) {
        return Kind::nushell;
      }

      return file.contains("bash") ? Kind::bash : Kind::zsh;
    }

    // Where each shell and tool keeps its history when nothing moved it, in the order tried: below
    // the directory an environment variable names, or below the home without one.
    struct Candidate {
      Kind kind;
      const char* variable;
      const char* suffix;
    };

    constexpr ds::Array candidates{
        Candidate{.kind = Kind::zsh, .variable = nullptr, .suffix = "/.zsh_history"},
        Candidate{.kind = Kind::bash, .variable = nullptr, .suffix = "/.bash_history"},
        Candidate{.kind = Kind::fish, .variable = "XDG_DATA_HOME", .suffix = "/fish/fish_history"},
        Candidate{.kind = Kind::fish, .variable = nullptr, .suffix = "/.local/share/fish/fish_history"},
        Candidate{.kind = Kind::nushell, .variable = "XDG_CONFIG_HOME", .suffix = "/nushell/history.sqlite3"},
        Candidate{.kind = Kind::nushell, .variable = "XDG_CONFIG_HOME", .suffix = "/nushell/history.txt"},
        Candidate{.kind = Kind::nushell, .variable = nullptr, .suffix = "/.config/nushell/history.sqlite3"},
        Candidate{.kind = Kind::nushell, .variable = nullptr, .suffix = "/.config/nushell/history.txt"},
        Candidate{.kind = Kind::nushell, .variable = nullptr, .suffix = "/Library/Application Support/nushell/history.sqlite3"},
        Candidate{.kind = Kind::nushell, .variable = nullptr, .suffix = "/Library/Application Support/nushell/history.txt"},
        Candidate{.kind = Kind::xonsh, .variable = "XONSH_DATA_DIR", .suffix = "/history_json"},
        Candidate{.kind = Kind::xonsh, .variable = "XDG_DATA_HOME", .suffix = "/xonsh/history_json"},
        Candidate{.kind = Kind::xonsh, .variable = nullptr, .suffix = "/.local/share/xonsh/history_json"},
        Candidate{.kind = Kind::powershell, .variable = nullptr, .suffix = "/.local/share/powershell/PSReadLine/ConsoleHost_history.txt"},
        Candidate{.kind = Kind::atuin, .variable = "XDG_DATA_HOME", .suffix = "/atuin/history.db"},
        Candidate{.kind = Kind::atuin, .variable = nullptr, .suffix = "/.local/share/atuin/history.db"},
        Candidate{.kind = Kind::mcfly, .variable = "XDG_DATA_HOME", .suffix = "/mcfly/history.db"},
        Candidate{.kind = Kind::mcfly, .variable = nullptr, .suffix = "/.local/share/mcfly/history.db"},
        Candidate{.kind = Kind::mcfly, .variable = nullptr, .suffix = "/.mcfly/history.db"},
        Candidate{.kind = Kind::mcfly, .variable = nullptr, .suffix = "/Library/Application Support/McFly/history.db"},
        Candidate{.kind = Kind::histdb, .variable = "HISTDB_FILE", .suffix = ""},
        Candidate{.kind = Kind::histdb, .variable = nullptr, .suffix = "/.histdb/zsh-history.db"},
    };

    // The import's source, by its real path: `./h`, `/home/me/h` and a link to it are one file,
    // and one source, so importing it again by another name adds only what it did not have.
    struct ImportPlan {
      Kind kind;
      Text path;
    };

    tbc::val_a<ds::Option<Text>> realPath(tbc::mut_a<Memory> memory, const char* path) {
      ds::Array<char, PATH_MAX> resolved{};
      if (::realpath(path, resolved.dataMut()) == nullptr) {
        return ds::none;
      }

      return Text{memory, std::string_view{resolved.data()}};
    }

    tbc::val_a<ImportPlan> planImport(tbc::mut_a<Memory> memory, const HistoryOptions& options) {
      if (options.import_file) {
        const auto file = *options.import_file;
        auto path = realPath(memory, file.data());
        if (!path) {
          throw std::runtime_error{sys::errorName(sys::lastError())};
        }

        const auto kind = options.import_kind != Kind::automatic ? options.import_kind : fileKind(path->view(), path->data());

        return {.kind = kind, .path = std::move(path.getMut())};
      }

      const auto home = processHome();

      for (const auto& candidate : candidates) {
        // Without a kind, only the shells' own histfiles are looked for, as before any tool's.
        const bool shell = candidate.kind == Kind::zsh || candidate.kind == Kind::bash || candidate.kind == Kind::fish;
        if (options.import_kind == Kind::automatic ? !shell : options.import_kind != candidate.kind) {
          continue;
        }

        const std::string_view base = candidate.variable == nullptr ? home : process_environment.lookup(candidate.variable);
        if (base.empty()) {
          continue;
        }

        const auto named = ds::format(memory, "{}{}", base, candidate.suffix);
        if (::access(named.data(), F_OK) != 0) {
          continue;
        }

        if (auto path = realPath(memory, named.data())) {
          return {.kind = candidate.kind, .path = std::move(path.getMut())};
        }
      }

      throw std::runtime_error{"HistfileNotFound"};
    }

    ImportFormat importFormat(Kind kind, const Text& path) {
      switch (kind) {
      case Kind::zsh:
        return ImportFormat::zsh;
      case Kind::bash:
        return ImportFormat::bash;
      case Kind::fish:
        return ImportFormat::fish;
      case Kind::nushell:
        return sqliteFile(path.data()) ? ImportFormat::nushell_sqlite : ImportFormat::nushell;
      case Kind::xonsh:
        return ImportFormat::xonsh;
      case Kind::powershell:
        return ImportFormat::powershell;
      case Kind::atuin:
        return ImportFormat::atuin;
      case Kind::mcfly:
        return ImportFormat::mcfly;
      case Kind::histdb:
        return ImportFormat::histdb;
      case Kind::automatic:
        break;
      }

      throw std::runtime_error{"UnknownHistoryImportKind"};
    }

    // The length of the valid UTF-8 character at `index`, or 0 for a byte that starts none: the
    // range a lead byte allows its first continuation rules out overlong forms, surrogates and
    // code points past U+10FFFF.
    std::size_t characterLength(std::string_view text, std::size_t index) noexcept {
      constexpr unsigned char continuation_low = 0x80;
      constexpr unsigned char continuation_high = 0xbf;

      struct Lead {
        unsigned char first;
        unsigned char last;
        std::size_t length;
        unsigned char low;
        unsigned char high;
      };

      constexpr ds::Array leads{
          Lead{.first = 0x01, .last = 0x7f, .length = 1, .low = 0, .high = 0},
          Lead{.first = 0xc2, .last = 0xdf, .length = 2, .low = continuation_low, .high = continuation_high},
          Lead{.first = 0xe0, .last = 0xe0, .length = 3, .low = 0xa0, .high = continuation_high},
          Lead{.first = 0xe1, .last = 0xec, .length = 3, .low = continuation_low, .high = continuation_high},
          Lead{.first = 0xed, .last = 0xed, .length = 3, .low = continuation_low, .high = 0x9f},
          Lead{.first = 0xee, .last = 0xef, .length = 3, .low = continuation_low, .high = continuation_high},
          Lead{.first = 0xf0, .last = 0xf0, .length = 4, .low = 0x90, .high = continuation_high},
          Lead{.first = 0xf1, .last = 0xf3, .length = 4, .low = continuation_low, .high = continuation_high},
          Lead{.first = 0xf4, .last = 0xf4, .length = 4, .low = continuation_low, .high = 0x8f},
      };

      const auto byte = static_cast<unsigned char>(text[index]);
      const auto* const lead = std::ranges::find_if(leads, [byte](const Lead& candidate) {
        return byte >= candidate.first && byte <= candidate.last;
      });
      if (lead == leads.end() || index + lead->length > text.size()) {
        return 0;
      }

      for (std::size_t offset = 1; offset < lead->length; ++offset) {
        const auto next = static_cast<unsigned char>(text[index + offset]);
        const auto low = offset == 1 ? lead->low : continuation_low;
        const auto high = offset == 1 ? lead->high : continuation_high;

        if (next < low || next > high) {
          return 0;
        }
      }

      return lead->length;
    }

    // The text with every byte that starts no valid UTF-8 character, and NUL, as U+FFFD: what a
    // histfile holds is whatever its shell wrote, the history keeps text.
    void appendRepaired(Text& output, std::string_view text) {
      constexpr std::string_view replacement = "\xef\xbf\xbd";
      std::size_t index = 0;
      std::size_t valid = 0;

      while (index < text.size()) {
        const auto length = characterLength(text, index);
        if (length != 0) {
          index += length;
          continue;
        }

        output.append(text.substr(valid, index - valid));
        output.append(replacement);
        ++index;
        valid = index;
      }

      output.append(text.substr(valid));
    }

    // FNV-1a over the bytes, seeded with the time: what tells the runs of one command apart.
    std::uint64_t runKey(std::int64_t time, std::string_view command) noexcept {
      constexpr std::uint64_t prime = 0x100000001b3;
      constexpr std::uint64_t offset_basis = 0xcbf29ce484222325;
      auto hash = offset_basis ^ static_cast<std::uint64_t>(time);

      for (const auto byte : command) {
        hash = (hash ^ static_cast<unsigned char>(byte)) * prime;
      }

      return hash;
    }

    // Sends a source's commands to the runtime in batches, each once the runtime has written the
    // last: an import that fails stops there and says so, and one large file never fills the
    // runtime's queue. Each entry is known by what it ran and when; the later runs of one command
    // at one time, as a histfile without times holds, take a millisecond more each, so the same
    // file imported again lands on the entries it already made.
    class Importer final : public ImportSink {
    public:
      Importer(Memory& memory, ControlSession& session, std::string_view source)
          : session_(session),
            source_(source),
            commands_(memory),
            repaired_(memory),
            runs_(memory) {
        commands_.reserve(max_batch_payload);
      }

      void command(std::int64_t started_at_ms, std::string_view command, const ImportedRun& known) override {
        repaired_.clear();
        appendRepaired(repaired_, command);
        if (repaired_.size() > max_command_bytes) {
          skipped(repaired_.size());
          return;
        }

        // A directory past what the wire carries is left out rather than cut into another one.
        const auto command_bytes = repaired_.size();

        appendRepaired(repaired_, known.cwd);
        const auto cwd_bytes = repaired_.size() - command_bytes <= ImportHistoryEntry::maximum_cwd_bytes ? repaired_.size() - command_bytes : 0;

        repaired_.truncate(command_bytes + cwd_bytes);

        const auto key = runKey(started_at_ms, repaired_.view().substr(0, command_bytes));
        auto* runs = runs_.findMut(key);
        std::int64_t run = 0;

        if (runs == nullptr) {
          runs_.insert(key, 1);
        } else {
          run = (*runs)++;
        }

        if (count_ == max_import_entries || commands_.size() + repaired_.size() > max_batch_payload) {
          flush();
        }

        offsets_.atMut(count_) = {.started_at_ms = started_at_ms + run, .offset = commands_.size(), .size = command_bytes, .cwd_size = cwd_bytes, .exit_code = known.exit_code, .duration_ns = std::max<std::int64_t>(0, known.duration_ns)};
        commands_.append(repaired_.view());
        ++count_;
      }

      void skipped(std::size_t bytes) override {
        ++skipped_;
        largest_skipped_ = std::max(largest_skipped_, bytes);
      }

      void flush() {
        if (count_ == 0) {
          return;
        }

        ds::Array<ImportHistoryEntry, max_import_entries> entries;

        for (std::size_t index = 0; index < count_; ++index) {
          const auto& entry = offsets_[index];

          entries.atMut(index) = {
              .started_at_ms = entry.started_at_ms,
              .command = commands_.view().substr(entry.offset, entry.size),
              .cwd = commands_.view().substr(entry.offset + entry.size, entry.cwd_size),
              .exit_code = entry.exit_code,
              .duration_ns = entry.duration_ns,
          };
        }

        session_.template exchange<RequestCompleted>(ImportHistory{.source = source_, .base_sequence = imported_, .entries = std::span{entries}.first(count_)});
        imported_ += count_;
        count_ = 0;
        commands_.clear();
      }

      [[nodiscard]] std::uint64_t imported() const noexcept {
        return imported_;
      }

      [[nodiscard]] std::size_t skippedCount() const noexcept {
        return skipped_;
      }

      [[nodiscard]] std::size_t largestSkipped() const noexcept {
        return largest_skipped_;
      }

    private:
      // An entry of the batch: its command and then its directory in commands_.
      struct Pending {
        std::int64_t started_at_ms;
        std::size_t offset;
        std::size_t size;
        std::size_t cwd_size;
        ds::Option<std::int32_t> exit_code;
        std::int64_t duration_ns;
      };

      ControlSession& session_;
      std::string_view source_;
      Text commands_;
      Text repaired_;
      ds::Map<std::uint64_t, std::int64_t, Memory> runs_;
      ds::Array<Pending, max_import_entries> offsets_{};
      std::size_t count_ = 0;
      std::uint64_t imported_ = 0;
      std::size_t skipped_ = 0;
      std::size_t largest_skipped_ = 0;
    };

    int importHistory(Memory& memory, const char* socket, const ImportPlan& plan) {
      const auto format = importFormat(plan.kind, plan.path);
      const auto source = ds::format(memory, "{}:{}", formatName(format), plan.path);
      if (source.size() > ImportHistory::maximum_source_bytes) {
        throw std::runtime_error{"HistfilePathTooLong"};
      }

      ControlSession session{memory, socket, max_payload_size, max_batch_payload + request_overhead_bytes};

      session.receiveTimeout(timeout_seconds);
      Importer importer{memory, session, source.view()};
      bool truncated = false;

      switch (format) {
      case ImportFormat::xonsh:
        readXonsh(memory, plan.path.data(), importer);
        break;
      case ImportFormat::atuin:
      case ImportFormat::mcfly:
      case ImportFormat::histdb:
      case ImportFormat::nushell_sqlite:
        readDatabase(format, plan.path.data(), importer);
        break;
      case ImportFormat::zsh:
      case ImportFormat::bash:
      case ImportFormat::fish:
      case ImportFormat::nushell:
      case ImportFormat::powershell: {
        const auto file = readHistfile(memory, plan.path.data());

        truncated = file.truncated;
        parseHistfile(memory, format, file.text.view(), file.truncated, importer);
        break;
      }
      }

      importer.flush();
      const auto skipped = importer.skippedCount();
      const auto largest = importer.largestSkipped();

      writeText(ds::format(memory, "imported {} commands from {}\n", importer.imported(), plan.path));
      if (skipped != 0) {
        const LimitReach reach{.name = "history.import_command_bytes", .noun = "bytes", .value = max_command_bytes, .requested = largest};

        reportCommandLimit(reach);
        try {
          session.send(ReportLimit{.reach = reach, .hits = 1});
        } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): the limit is already reported here; the runtime's copy is best effort.
        }
      }

      return truncated || skipped != 0 ? 1 : 0;
    }

    // The query a list, a search, a preview or an export pages through, from the options.
    tbc::val_a<QueryHistory> historyQuery(tbc::ref_a<HistoryOptions> options, tbc::ref_a<HistoryScopeValue> scope) {
      return QueryHistory{
          .query = options.query,
          .scope = options.scope,
          .scope_value = scope,
          .failed_only = options.failed_only,
          .author = options.author,
          .match = options.match,
          .distinct = options.distinct,
          .limit = options.limit,
          .offset = options.offset,
          .sort = options.sort,
          .since_ms = options.since_ms,
          .until_ms = options.until_ms,
          .exit_code = options.exit_code,
          .min_duration_ms = options.min_duration_ms,
          .host = options.host,
          .branch = options.branch,
          .shell = options.shell,
      };
    }

    // One page of a query, on a connection of its own: the runtime ends a control connection
    // once it answers a history query. `consume` reads the results while they are valid.
    template <typename Consume>
    void page(Memory& memory, const char* socket, const QueryHistory& request, Consume consume) {
      ControlSession session{memory, socket};

      session.receiveTimeout(timeout_seconds);
      consume(session.template exchange<HistoryResults>(request));
    }

    // Where a run stands in a listing by time, newest first: the place a page continues past.
    struct RunMark {
      std::int64_t started_at_ms = 0;
      std::uint64_t id = 0;

      static RunMark of(const HistoryEntry& entry) noexcept {
        return {.started_at_ms = entry.started_at_ms, .id = entry.id};
      }

      // Whether `entry` lists after this run, as an older one.
      [[nodiscard]] bool before(const HistoryEntry& entry) const noexcept {
        return entry.started_at_ms < started_at_ms || (entry.started_at_ms == started_at_ms && entry.id < id);
      }
    };

    // Asks for the runs past `mark`, or from the newest when it names none.
    void continuePast(QueryHistory& request, RunMark mark) noexcept {
      request.after_started_ms = mark.started_at_ms;
      request.after_id = mark.id;
    }

    // Every page the query matches, newest first, over one snapshot, each continuing past the
    // last run the one before it held: what the runtime records meanwhile neither shifts nor
    // joins the pages, and what it deletes skips nothing. `visit` reads a page that holds an
    // entry and returns whether to read on; the request keeps the snapshot.
    template <typename Visit>
    void eachPage(Memory& memory, const char* socket, QueryHistory& request, Visit visit) {
      request.limit = HistoryOptions::max_results;
      request.offset = 0;
      request.sort = HistorySort::time;
      continuePast(request, {});
      for (;;) {
        bool more = false;

        page(memory, socket, request, [&](const HistoryResults& results) {
          request.snapshot_id = results.snapshot_id;
          if (results.entries.empty()) {
            return;
          }

          more = visit(results) && results.has_more;
          continuePast(request, RunMark::of(results.entries.back()));
        });

        if (!more) {
          return;
        }
      }
    }

    // Every entry the query matches, newest first, as eachPage reads them. `visit` returns
    // whether to read on.
    template <typename Visit>
    void eachEntry(Memory& memory, const char* socket, QueryHistory request, Visit visit) {
      eachPage(memory, socket, request, [&](const HistoryResults& results) {
        return std::ranges::all_of(results.entries, std::ref(visit));
      });
    }

    EntryStyle entryStyle(HistoryOptions::Output output) noexcept {
      switch (output) {
      case HistoryOptions::Output::text:
        return EntryStyle::text;
      case HistoryOptions::Output::json:
        return EntryStyle::json;
      case HistoryOptions::Output::format:
        return EntryStyle::format;
      case HistoryOptions::Output::zsh:
        return EntryStyle::zsh;
      case HistoryOptions::Output::bash:
        return EntryStyle::bash;
      case HistoryOptions::Output::fish:
        return EntryStyle::fish;
      }

      return EntryStyle::text;
    }

    // The entry `--after` names, as a mark to continue past.
    RunMark entryMark(Memory& memory, const char* socket, std::uint64_t id) {
      ds::Option<RunMark> mark;

      page(memory, socket, QueryHistory{.limit = 1, .entry_id = id}, [&](const HistoryResults& results) {
        if (!results.entries.empty()) {
          mark = RunMark::of(results.entries.front());
        }
      });

      if (!mark) {
        throw std::runtime_error{"HistoryEntryNotFound"};
      }

      return *mark;
    }

    void list(Memory& memory, const char* socket, const HistoryOptions& options, const HistoryScopeValue& scope) {
      DescriptorWriter output{STDOUT_FILENO};
      auto request = historyQuery(options, scope);

      if (options.after_id != 0) {
        request.sort = HistorySort::time;
        continuePast(request, entryMark(memory, socket, options.after_id));
      }

      page(memory, socket, request, [&](const HistoryResults& results) {
        for (const auto& entry : results.entries) {
          printEntry(output, entry, entryStyle(options.output), options.format);
        }
      });

      output.flush();
    }

    // Prints every entry the filters match, oldest first, as a shell reads its histfile, holding
    // one page at a time. A first walk, newest first, marks where each page of one snapshot
    // ends; the pages are then read again from the oldest, each down to its mark and printed
    // reversed. Every page continues past a run rather than skipping a count of them, so what is
    // deleted meanwhile neither skips nor repeats an entry, and the snapshot keeps out what is
    // recorded.
    void exportHistory(Memory& memory, const char* socket, const HistoryOptions& options, const HistoryScopeValue& scope) {
      auto request = historyQuery(options, scope);
      ds::Vec<RunMark, Memory> marks{memory};
      DescriptorWriter output{STDOUT_FILENO};

      marks.push({});
      eachPage(memory, socket, request, [&](const HistoryResults& results) {
        marks.push(RunMark::of(results.entries.back()));
        return true;
      });

      // The page past the second-to-last mark, down to the last. One a deletion shrank ends at
      // an older entry or at the end of the listing; one the reply's size cut short (the runs
      // it holds grew since) is split at the run it reached, and its older part printed first.
      while (marks.size() > 1) {
        const auto until = marks.back();

        continuePast(request, marks[marks.size() - 2]);
        page(memory, socket, request, [&](const HistoryResults& results) {
          const auto entries = results.entries;
          std::size_t count = 0;

          while (count < entries.size() && !until.before(entries[count])) {
            ++count;
          }

          const bool reached = count < entries.size() || !results.has_more || count == 0 || entries[count - 1].id == until.id;

          marks.truncate(marks.size() - 1);
          if (!reached) {
            marks.push(RunMark::of(entries[count - 1]));
            marks.push(until);
            return;
          }

          for (const auto& entry : std::views::reverse(entries.first(count))) {
            printEntry(output, entry, entryStyle(options.output), options.format);
          }
        });
      }

      output.flush();
    }

    bool confirmPrune() {
      constexpr std::size_t confirmation_bytes = 16;
      ds::Array<char, confirmation_bytes> typed{};

      for (std::size_t index = 0; index < confirmation_bytes; ++index) {
        char byte = 0;
        const auto count = ::read(STDIN_FILENO, &byte, 1);
        if (count != 1) {
          return false;
        }

        if (byte == '\n') {
          const std::string_view line{typed.data(), index};
          const auto start = line.find_first_not_of(" \r");
          const auto end = line.find_last_not_of(" \r");

          return start != std::string_view::npos && line.substr(start, end - start + 1) == "yes";
        }

        typed.atMut(index) = byte;
      }

      return false;
    }

    // Shows how many entries a prune removes, asks, and tells whether to go on.
    bool previewPrune(Memory& memory, const HistoryOptions& options, std::uint64_t count) {
      writeText(ds::format(memory, "would remove {} entries\n", count));
      if (options.dry_run) {
        return false;
      }

      if (options.assume_yes) {
        return true;
      }

      writeText("prune permanently? type yes to continue: ");
      if (!confirmPrune()) {
        writeText("aborted\n");
        return false;
      }

      return true;
    }

    void prune(Memory& memory, const char* socket, const HistoryOptions& options, const HistoryScopeValue& scope) {
      PruneHistory request{
          .scope = options.scope,
          .scope_value = scope,
          .before_ms = options.before_ms,
          .failed_only = options.failed_only,
          .match = options.query,
          .keep_runs = options.keep_runs,
          .dry_run = true,
      };

      const auto send = [&] {
        ControlSession session{memory, socket};

        session.receiveTimeout(timeout_seconds);
        return session.template exchange<HistoryPruned>(request).removed;
      };

      // The preview is the prune's own selection, counted by the runtime, so it is exactly what goes.
      if ((options.dry_run || !options.assume_yes) && !previewPrune(memory, options, send())) {
        return;
      }

      request.dry_run = false;
      writeText(ds::format(memory, "removed {} entries\n", send()));
    }

    // Passes the entries the prune's filters match through the history's filters as the runtime
    // has them today: what they would refuse is removed and what they would keep redacted is
    // redacted, what a filter added later still kept from before it.
    void pruneFiltered(Memory& memory, const char* socket, const HistoryOptions& options, const HistoryScopeValue& scope) {
      RewriteHistory request{
          .scope = options.scope,
          .scope_value = scope,
          .before_ms = options.before_ms,
          .failed_only = options.failed_only,
          .match = options.query,
          .dry_run = true,
      };

      const auto rewrite = [&] {
        ControlSession session{memory, socket};

        session.receiveTimeout(timeout_seconds);
        return session.template exchange<HistoryRewritten>(request);
      };

      if (options.dry_run || !options.assume_yes) {
        const auto preview = rewrite();

        writeText(ds::format(memory, "would remove {} entries and redact {}\n", preview.removed, preview.redacted));
        if (options.dry_run) {
          return;
        }

        writeText("prune permanently? type yes to continue: ");
        if (!confirmPrune()) {
          writeText("aborted\n");
          return;
        }
      }

      request.dry_run = false;
      const auto result = rewrite();

      writeText(ds::format(memory, "removed {} entries and redacted {}\n", result.removed, result.redacted));
    }

    void show(Memory& memory, const char* socket, const HistoryOptions& options) {
      ControlSession session{memory, socket};

      session.receiveTimeout(timeout_seconds);
      const auto output = session.template exchange<HistoryOutput>(ReadHistoryOutput{.id = options.id});
      if (output.observed_bytes == 0) {
        writeText(ds::format(memory, "telar history: no output captured for entry {} (runtime.history.output = \"bounded\" enables capture)\n", output.id), STDERR_FILENO);
        return;
      }

      writeBytes(STDOUT_FILENO, output.content);
      if (output.truncated) {
        writeText(ds::format(memory, "telar history: output truncated ({} bytes observed)\n", output.observed_bytes), STDERR_FILENO);
      }
    }

    // When the period starts: local midnight for today, else that many days back from now.
    std::int64_t periodStart(const HistoryOptions& options) {
      constexpr std::int64_t milliseconds_per_day = 86400000;
      const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();

      if (options.period_today) {
        const auto seconds = static_cast<std::time_t>(now / milliseconds_per_second);
        std::tm local{};

        ::localtime_r(&seconds, &local);
        local.tm_hour = 0;
        local.tm_min = 0;
        local.tm_sec = 0;
        local.tm_isdst = -1;
        return static_cast<std::int64_t>(std::mktime(&local)) * milliseconds_per_second;
      }

      return options.period_days == 0 ? 0 : now - (static_cast<std::int64_t>(options.period_days) * milliseconds_per_day);
    }

    // Counts the runs of `size` commands one after another, as `git add` then `git commit`: the
    // period's entries arrive newest first, and the newest `size` of them, oldest first, make each
    // sequence. The most distinct sequences kept is bounded; past it the new ones are not counted.
    void ngramStats(Memory& memory, const char* socket, const HistoryOptions& options, const HistoryScopeValue& scope, std::int64_t since) {
      constexpr std::size_t maximum_sequences = 100000;
      constexpr std::size_t shown = 10;
      constexpr std::string_view separator = " ; ";

      struct Sequence { // NOLINT(bugprone-exception-escape): its implicit move assignment, which sorting uses, moves a Text between two of the one memory, which allocates nothing
        std::uint64_t count;
        Text text;
      };

      ds::Map<std::uint64_t, std::size_t, Memory> indexes{memory};
      ds::Vec<Sequence, Memory> sequences{memory};
      ds::Vec<Text, Memory> window{memory};
      Text joined{memory};
      std::size_t seen = 0;
      std::uint64_t total = 0;
      bool limited = false;
      auto request = historyQuery(options, scope);

      request.query = {};
      request.failed_only = false;
      request.author = HistoryAuthorFilter::all;
      request.match = HistoryMatch::substring;
      request.distinct = false;
      eachEntry(memory, socket, request, [&](const HistoryEntry& entry) {
        if (since != 0 && entry.started_at_ms < since) {
          return false;
        }

        // The last `size` commands read, in a ring: the one just read is the oldest of them, and
        // the ones before it in the ring follow it in time.
        const auto slot = seen % options.ngram_size;

        if (window.size() < options.ngram_size) {
          window.push(Text{memory, entry.command});
        } else {
          window.atMut(slot).assign(entry.command);
        }

        ++seen;
        if (seen < options.ngram_size) {
          return true;
        }

        joined.clear();
        for (std::size_t step = 0; step < options.ngram_size; ++step) {
          if (step != 0) {
            joined.append(separator);
          }

          joined.append(window[(slot + options.ngram_size - step) % options.ngram_size].view());
        }

        ++total;
        const auto key = runKey(0, joined.view());
        if (const auto* index = indexes.find(key)) {
          ++sequences.atMut(*index).count;
        } else if (sequences.size() < maximum_sequences) {
          indexes.insert(key, sequences.size());
          sequences.push({.count = 1, .text = joined.clone()});
        } else {
          limited = true;
        }

        return true;
      });

      if (limited) {
        reportCommandLimit({.name = "history.stats_sequences", .noun = "sequences", .value = maximum_sequences});
      }

      std::ranges::stable_sort(sequences.viewMut(), std::greater{}, &Sequence::count);
      auto output = ds::format(memory, "commands: {}\nunique:   {}\n", total, sequences.size());

      if (!sequences.empty()) {
        output.append("top:\n");
      }

      for (const auto& sequence : std::span{sequences}.first(std::min(shown, sequences.size()))) {
        ds::formatTo(output, "  {:>7}  {}\n", sequence.count, EscapedField{sequence.text});
      }

      writeText(output);
    }

    void stats(Memory& memory, const char* socket, const HistoryOptions& options, const HistoryScopeValue& scope) {
      const auto since = periodStart(options);

      if (options.ngram_size > 1) {
        ngramStats(memory, socket, options, scope, since);
        return;
      }

      ControlSession session{memory, socket};

      session.receiveTimeout(timeout_seconds);
      const auto result = session.template exchange<HistoryStatsResult>(HistoryStatsQuery{
          .scope = options.scope,
          .scope_value = scope,
          .since_ms = since,
      });

      auto output = ds::format(memory, "commands: {}\nunique:   {}\n", result.total, result.unique);

      if (!result.top.empty()) {
        output.append("top:\n");
      }

      for (const auto& entry : result.top) {
        ds::formatTo(output, "  {:>7}  {}\n", entry.count, EscapedField{entry.command});
      }

      writeText(output);
    }

    // The error name a failed history command ends with.
    std::string_view failureLine(HistoryOptions::Action action) noexcept {
      switch (action) {
      case HistoryOptions::Action::import:
        return "error: HistoryImportFailed\n";
      case HistoryOptions::Action::remove:
      case HistoryOptions::Action::prune:
        return "error: HistoryPruneFailed\n";
      case HistoryOptions::Action::show:
      case HistoryOptions::Action::stats:
      case HistoryOptions::Action::list:
      case HistoryOptions::Action::search:
      case HistoryOptions::Action::export_history:
        return "error: HistoryQueryFailed\n";
      }

      std::unreachable();
    }

    // A workspace named relative to where the command runs, as the store keys directories: its
    // real path when it exists, else the path joined to the working directory.
    tbc::val_a<std::string_view> workspacePath(tbc::val_a<std::string_view> path, std::string_view working, tbc::mut_a<ds::Array<char, PATH_MAX>> buffer) {
      if (path.starts_with('/')) {
        return path;
      }

      if (::realpath(path.data(), buffer.dataMut()) != nullptr) {
        return std::string_view{buffer.data()};
      }

      while (path.starts_with("./")) {
        path.remove_prefix(2);
      }

      const auto written = std::format_to_n(buffer.dataMut(), buffer.size() - 1, "{}/{}", working, path);
      if (static_cast<std::size_t>(written.size) >= buffer.size()) {
        throw std::invalid_argument{"InvalidWorkspacePath"};
      }

      const auto size = static_cast<std::size_t>(written.size);

      buffer.atMut(size) = '\0';
      return std::string_view{buffer.data(), size};
    }

  }

  int run(Memory& memory, const HistoryOptions& options) {
    try {
      ds::Option<ImportPlan> plan;

      if (options.action == HistoryOptions::Action::import) {
        plan.emplace(planImport(memory, options));
      }

      ServerOptions server_options{};

      server_options.socket = options.socket.valueOr("");
      const RuntimePaths<Memory> paths{memory, server_options, process_environment};

      ensureRuntime(memory, paths);
      ds::Array<char, PATH_MAX> directory{};
      ds::Array<char, PATH_MAX> workspace{};

      if ((options.scope == HistoryScope::cwd || options.scope == HistoryScope::workspace) && ::realpath(".", directory.dataMut()) == nullptr) {
        throw SystemError{"Resolve the working directory"};
      }

      HistoryScopeValue scope = std::monostate{};

      switch (options.scope) {
      case HistoryScope::cwd:
        scope = std::string_view{directory.data()};
        break;
      case HistoryScope::workspace:
        scope = workspacePath(options.scope_value, std::string_view{directory.data()}, workspace);
        break;
      case HistoryScope::pane:
        scope = options.pane_id;
        break;
      case HistoryScope::global:
        break;
      }

      const auto* const socket = paths.socket.data();

      switch (options.action) {
      case HistoryOptions::Action::import:
        return importHistory(memory, socket, *plan);
      case HistoryOptions::Action::remove: {
        ControlSession session{memory, socket};

        session.receiveTimeout(timeout_seconds);
        const auto result = session.template exchange<HistoryPruned>(DeleteHistory{.id = options.id});

        writeText(ds::format(memory, "removed {} entries\n", result.removed));
        break;
      }
      case HistoryOptions::Action::prune:
        if (options.prune_filters) {
          pruneFiltered(memory, socket, options, scope);
        } else {
          prune(memory, socket, options, scope);
        }

        break;
      case HistoryOptions::Action::show:
        show(memory, socket, options);
        break;
      case HistoryOptions::Action::stats:
        stats(memory, socket, options, scope);
        break;
      case HistoryOptions::Action::list:
      case HistoryOptions::Action::search:
        list(memory, socket, options, scope);
        break;
      case HistoryOptions::Action::export_history:
        exportHistory(memory, socket, options, scope);
        break;
      }

      return 0;
    } catch (const ControlFailure& error) {
      const auto* const context = options.action == HistoryOptions::Action::import ? "telar history import: " : "telar history: ";

      const std::string_view message = error.message().empty() ? std::string_view{error.what()} : error.message();

      std::println(stderr, "{}{}", context, message);
      writeText(failureLine(options.action), STDERR_FILENO);
      return 1;
    } catch (const std::exception& error) {
      std::println(stderr, "error: {}", error.what());
      return 1;
    }
  }

}

namespace telar::runtime::cli {

  namespace {

    DiagnosticsOptions::Component componentNamed(std::string_view value) {
      if (value == "all") {
        return DiagnosticsOptions::Component::all;
      }

      if (value == "runtime") {
        return DiagnosticsOptions::Component::runtime;
      }

      if (value == "client") {
        return DiagnosticsOptions::Component::client;
      }

      throw std::invalid_argument{"InvalidComponent"};
    }

    // Reads an option only `logs` takes; whether `arg` names one.
    bool logsOption(tbc::mut_a<DiagnosticsOptions> self, std::string_view arg, Cursor& cursor) {
      if (arg == "--component") {
        self.component = componentNamed(cursor.take("MissingComponent"));
        return true;
      }

      if (arg == "--pid" && !self.pid) {
        self.pid = number<std::uint32_t>(cursor.take("MissingPid"), "InvalidPid");
        if (*self.pid == 0) {
          throw std::invalid_argument{"InvalidPid"};
        }

        return true;
      }

      if (arg == "--lines") {
        self.lines = number<std::uint16_t>(cursor.take("MissingLineCount"), "InvalidLineCount");
        if (self.lines == 0 || self.lines > DiagnosticsOptions::max_lines) {
          throw std::invalid_argument{"InvalidLineCount"};
        }

        return true;
      }

      return false;
    }

  }

  DiagnosticsOptions DiagnosticsOptions::parse(Arguments words) {
    if (words.empty() || (std::string_view{words.front()} != "logs" && std::string_view{words.front()} != "limits")) {
      throw std::invalid_argument{"UnknownDiagnosticsAction"};
    }

    DiagnosticsOptions self{.action = std::string_view{words.front()} == "logs" ? Action::logs : Action::limits};
    Cursor cursor{words.subspan(1)};

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (self.action == Action::logs && logsOption(self, arg, cursor)) {
        continue;
      }

      if (arg == "--json" && !self.json) {
        self.json = true;
      } else if (arg == "--socket" && !self.socket) {
        self.socket = cursor.take("MissingSocketPath");
      } else {
        throw std::invalid_argument{"UnknownDiagnosticsOption"};
      }
    }

    return self;
  }

  void HistoryOptions::setScope(HistoryScope value, tbc::val_a<std::string_view> path) {
    if (scope != HistoryScope::global) {
      throw std::invalid_argument{"ConflictingHistoryScopes"};
    }

    scope = value;
    scope_value = path;
  }

  auto HistoryOptions::importKind(std::string_view value) -> ImportKind {
    using Named = std::pair<std::string_view, ImportKind>;
    constexpr ds::Array kinds{
        Named{"auto", ImportKind::automatic},
        Named{"zsh", ImportKind::zsh},
        Named{"bash", ImportKind::bash},
        Named{"fish", ImportKind::fish},
        Named{"nushell", ImportKind::nushell},
        Named{"xonsh", ImportKind::xonsh},
        Named{"powershell", ImportKind::powershell},
        Named{"atuin", ImportKind::atuin},
        Named{"mcfly", ImportKind::mcfly},
        Named{"histdb", ImportKind::histdb},
    };

    for (const auto& [name, kind] : kinds) {
      if (name == value) {
        return kind;
      }
    }

    throw std::invalid_argument{"UnknownHistoryImportKind"};
  }

  std::int64_t HistoryOptions::parseTime(std::string_view text, std::int64_t now_ms) {
    constexpr std::int64_t second_ms = 1000;
    constexpr std::int64_t minute_ms = 60 * second_ms;
    constexpr std::int64_t hour_ms = 60 * minute_ms;
    constexpr std::int64_t day_ms = 24 * hour_ms;
    constexpr std::int64_t week_ms = 7 * day_ms;

    if (text == "today" || text == "yesterday") {
      // Midnight where the user is, as `today` means to them.
      const auto seconds = static_cast<std::time_t>(now_ms / second_ms);
      std::tm local{};

      ::localtime_r(&seconds, &local);
      local.tm_hour = 0;
      local.tm_min = 0;
      local.tm_sec = 0;
      local.tm_isdst = -1;
      if (text == "yesterday") {
        --local.tm_mday;
      }

      return static_cast<std::int64_t>(std::mktime(&local)) * second_ms;
    }

    struct Unit {
      std::string_view suffix;
      std::int64_t milliseconds;
    };

    constexpr ds::Array<Unit, 5> units{
        {
            {.suffix = "w", .milliseconds = week_ms},
            {.suffix = "d", .milliseconds = day_ms},
            {.suffix = "h", .milliseconds = hour_ms},
            {.suffix = "m", .milliseconds = minute_ms},
            {.suffix = "s", .milliseconds = second_ms},
        },
    };

    auto age = text;

    age.remove_prefix(age.starts_with('-') ? 1 : 0);
    for (const auto& unit : units) {
      if (!age.ends_with(unit.suffix) || age.size() == unit.suffix.size()) {
        continue;
      }

      const auto count = parseInt<std::int64_t>(age.substr(0, age.size() - unit.suffix.size()));
      if (count < 0 || count > now_ms / unit.milliseconds) {
        throw std::invalid_argument{"InvalidHistoryTime"};
      }

      return now_ms - (count * unit.milliseconds);
    }

    return parseBefore(text);
  }

  std::uint64_t HistoryOptions::parseDuration(std::string_view text) {
    struct Unit {
      std::string_view suffix;
      std::uint64_t milliseconds;
    };

    constexpr ds::Array<Unit, 4> units{
        {
            {.suffix = "ms", .milliseconds = 1},
            {.suffix = "s", .milliseconds = 1'000},
            {.suffix = "m", .milliseconds = 60'000},
            {.suffix = "h", .milliseconds = 3'600'000},
        },
    };

    for (const auto& unit : units) {
      if (text.ends_with(unit.suffix) && text.size() > unit.suffix.size() && (unit.suffix != "s" || !text.ends_with("ms"))) {
        const auto count = parseInt<std::uint64_t>(text.substr(0, text.size() - unit.suffix.size()));
        if (count > std::numeric_limits<std::uint64_t>::max() / unit.milliseconds) {
          throw std::invalid_argument{"InvalidHistoryDuration"};
        }

        return count * unit.milliseconds;
      }
    }

    return parseInt<std::uint64_t>(text);
  }

  std::int64_t HistoryOptions::parseBefore(std::string_view text) {
    constexpr std::int64_t milliseconds_per_second = 1000;

    if (!text.contains('-')) {
      const auto seconds = parseInt<std::int64_t>(text);
      if (seconds <= 0 || seconds > std::numeric_limits<std::int64_t>::max() / milliseconds_per_second) {
        throw std::invalid_argument{"InvalidHistoryBefore"};
      }

      return seconds * milliseconds_per_second;
    }

    ds::Array<std::int64_t, 3> fields{};

    for (std::size_t at = 0; at < fields.size(); ++at) {
      const auto end = text.find('-');
      if ((at != fields.size() - 1 && end == std::string_view::npos) || (at == fields.size() - 1 && end != std::string_view::npos)) {
        throw std::invalid_argument{"InvalidHistoryBefore"};
      }

      fields.atMut(at) = parseInt<std::int64_t>(text.substr(0, end));
      if (end != std::string_view::npos) {
        text.remove_prefix(end + 1);
      }
    }

    const auto [year, month, day] = fields;
    constexpr std::int64_t epoch_year = 1970;
    constexpr std::int64_t max_date_year = 292000000;
    constexpr std::int64_t months_per_year = 12;
    if (year < epoch_year || year > max_date_year || month < 1 || month > months_per_year) {
      throw std::invalid_argument{"InvalidHistoryBefore"};
    }

    // A day the month does not have, as 2024-02-31, names no date rather than one in the next month.
    constexpr ds::Array<std::int64_t, 12> month_days{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    const bool leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    const auto last_day = month_days[static_cast<std::size_t>(month - 1)] + (month == 2 && leap ? 1 : 0);
    if (day < 1 || day > last_day) {
      throw std::invalid_argument{"InvalidHistoryBefore"};
    }

    const auto adjusted_year = month <= 2 ? year - 1 : year;
    constexpr std::int64_t years_per_era = 400;
    constexpr std::int64_t days_per_era = 146097;
    constexpr std::int64_t epoch_adjustment = 719468;
    constexpr std::int64_t milliseconds_per_day = 86400000;
    const auto era = adjusted_year / years_per_era;
    const auto year_of_era = adjusted_year - (era * years_per_era);
    const auto adjusted_month = (month + 9) % 12;
    const auto day_of_year = (((153 * adjusted_month) + 2) / 5) + day - 1;
    const auto day_of_era = (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100) + day_of_year;

    return ((era * days_per_era) + day_of_era - epoch_adjustment) * milliseconds_per_day;
  }

  namespace {

    // The action a history command names, with the arguments that follow it.
    void historyAction(tbc::mut_a<HistoryOptions> self, Arguments words, Cursor& cursor) {
      using Action = HistoryOptions::Action;
      const std::string_view action = words.front();

      if (action == "list") {
        self.action = Action::list;
      } else if (action == "stats") {
        self.action = Action::stats;
      } else if (action == "prune") {
        self.action = Action::prune;
      } else if (action == "search") {
        self.action = Action::search;
        self.query = cursor.take("MissingHistoryQuery");
      } else if (action == "show" || action == "delete") {
        self.action = action == "show" ? Action::show : Action::remove;
        self.id = parseInt<std::uint64_t>(cursor.take("MissingHistoryId"));
        if (self.id == 0) {
          throw std::invalid_argument{"InvalidHistoryId"};
        }
      } else if (action == "import") {
        self.action = Action::import;
        if (words.size() > 1 && !std::string_view{words[1]}.starts_with('-')) {
          self.import_kind = HistoryOptions::importKind(*cursor.next());
        }
      } else if (action == "export") {
        self.action = Action::export_history;
        self.output = HistoryOptions::Output::json;
      } else {
        throw std::invalid_argument{"UnknownHistoryAction"};
      }
    }

    std::uint16_t periodDays(std::string_view value) {
      constexpr std::uint16_t days_per_week = 7;
      constexpr std::uint16_t days_per_month = 30;
      constexpr std::uint16_t days_per_year = 365;

      if (value == "today") {
        return 0;
      }

      if (value == "week") {
        return days_per_week;
      }

      if (value == "month") {
        return days_per_month;
      }

      if (value == "year") {
        return days_per_year;
      }

      if (value == "all") {
        return 0;
      }

      throw std::invalid_argument{"InvalidHistoryPeriod"};
    }

    HistoryAuthorFilter authorNamed(std::string_view value) {
      if (value == "all") {
        return HistoryAuthorFilter::all;
      }

      if (value == "human") {
        return HistoryAuthorFilter::human;
      }

      if (value == "agent") {
        return HistoryAuthorFilter::agent;
      }

      throw std::invalid_argument{"InvalidHistoryAuthor"};
    }

    // Reads an option that narrows which entries the command reads; whether `arg` names one.
    bool scopeOption(tbc::mut_a<HistoryOptions> self, std::string_view arg, Cursor& cursor) {
      if (arg == "--cwd") {
        self.setScope(HistoryScope::cwd);
      } else if (arg == "--workspace") {
        self.setScope(HistoryScope::workspace, cursor.take("MissingWorkspacePath"));
      } else if (arg == "--pane") {
        self.pane_id = parseInt<std::uint64_t>(cursor.take("MissingPaneId"));
        if (self.pane_id == 0) {
          throw std::invalid_argument{"InvalidPaneId"};
        }

        self.setScope(HistoryScope::pane);
      } else if (arg == "--failed") {
        self.failed_only = true;
      } else if (arg == "--author") {
        self.author = authorNamed(cursor.take("MissingHistoryAuthor"));
      } else {
        return false;
      }

      return true;
    }

    // Reads an option only `prune` takes; whether `arg` names one.
    bool pruneOption(tbc::mut_a<HistoryOptions> self, std::string_view arg, Cursor& cursor) {
      if (arg == "--before") {
        self.before_ms = HistoryOptions::parseBefore(cursor.take("MissingHistoryBefore"));
      } else if (arg == "--dry-run") {
        self.dry_run = true;
      } else if (arg == "--yes") {
        self.assume_yes = true;
      } else if (arg == "--match") {
        self.query = cursor.take("MissingHistoryQuery");
      } else if (arg == "--filters") {
        self.prune_filters = true;
      } else if (arg == "--keep") {
        self.keep_runs = number<std::uint32_t>(cursor.take("MissingHistoryKeep"), "InvalidHistoryKeep");
        if (self.keep_runs == 0) {
          throw std::invalid_argument{"InvalidHistoryKeep"};
        }
      } else {
        return false;
      }

      return true;
    }

    // Reads an option only list and search take; whether `arg` names one.
    bool listOption(tbc::mut_a<HistoryOptions> self, std::string_view arg, Cursor& cursor) {
      using Output = HistoryOptions::Output;

      if (arg == "--offset") {
        self.offset = number<std::uint32_t>(cursor.take("MissingHistoryOffset"), "InvalidHistoryOffset");
      } else if (arg == "--after") {
        self.after_id = number<std::uint64_t>(cursor.take("MissingHistoryAfter"), "InvalidHistoryAfter");
        if (self.after_id == 0) {
          throw std::invalid_argument{"InvalidHistoryAfter"};
        }
      } else if (arg == "--fuzzy") {
        self.match = HistoryMatch::fuzzy;
      } else if (arg == "--distinct") {
        self.distinct = true;
      } else if (arg == "--json" && self.output == Output::text) {
        self.output = Output::json;
      } else if (arg == "--format" && self.output == Output::text) {
        self.format = cursor.take("MissingHistoryFormat");
        history::checkTemplate(self.format);
        self.output = Output::format;
      } else {
        return false;
      }

      return true;
    }

    // Reads an option that filters or orders what a listing or a search shows; whether `arg`
    // names one.
    bool filterOption(tbc::mut_a<HistoryOptions> self, std::string_view arg, Cursor& cursor) {
      const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();

      if (arg == "--since") {
        self.since_ms = HistoryOptions::parseTime(cursor.take("MissingHistorySince"), now);
      } else if (arg == "--until") {
        self.until_ms = HistoryOptions::parseTime(cursor.take("MissingHistoryUntil"), now);
      } else if (arg == "--exit") {
        const auto value = cursor.take("MissingHistoryExit");

        if (value == "failed") {
          self.failed_only = true;
        } else {
          self.exit_code = parseInt<std::int32_t>(value);
        }
      } else if (arg == "--min-duration") {
        self.min_duration_ms = HistoryOptions::parseDuration(cursor.take("MissingHistoryDuration"));
      } else if (arg == "--host") {
        self.host = cursor.take("MissingHistoryHost");
      } else if (arg == "--branch") {
        self.branch = cursor.take("MissingHistoryBranch");
      } else if (arg == "--shell") {
        self.shell = cursor.take("MissingHistoryShell");
        if (self.shell.empty() || self.shell.size() > max_history_shell_bytes) {
          throw std::invalid_argument{"InvalidHistoryShell"};
        }
      } else if (arg == "--sort") {
        const auto value = cursor.take("MissingHistorySort");
        if (value != "rank" && value != "time") {
          throw std::invalid_argument{"InvalidHistorySort"};
        }

        self.sort = value == "rank" ? HistorySort::rank : HistorySort::time;
      } else if (arg == "--mode") {
        constexpr ds::Array<std::pair<std::string_view, HistoryMatch>, 4> modes{{{"fuzzy", HistoryMatch::fuzzy}, {"substring", HistoryMatch::substring}, {"prefix", HistoryMatch::prefix}, {"regex", HistoryMatch::regex}}};
        const auto value = cursor.take("MissingHistoryMode");
        const auto* const found = std::ranges::find(modes, value, &std::pair<std::string_view, HistoryMatch>::first);
        if (found == modes.end()) {
          throw std::invalid_argument{"InvalidHistoryMode"};
        }

        self.match = found->second;
      } else {
        return false;
      }

      if (self.since_ms != 0 && self.until_ms != 0 && self.until_ms <= self.since_ms) {
        throw std::invalid_argument{"InvalidHistoryRange"};
      }

      return true;
    }

    // A cursor continues a listing by time, each command once or every run: a ranked one pages by
    // --offset alone.
    void checkPaging(const HistoryOptions& self) {
      const bool ranked = self.sort == HistorySort::rank || (self.sort == HistorySort::automatic && self.match == HistoryMatch::fuzzy && !self.query.empty());

      if (self.after_id != 0 && (self.offset != 0 || ranked)) {
        throw std::invalid_argument{"HistoryCursorNeedsTimeOrder"};
      }
    }

    HistoryOptions::Output exportFormat(std::string_view value) {
      using Output = HistoryOptions::Output;
      using Named = std::pair<std::string_view, Output>;
      constexpr ds::Array formats{
          Named{"json", Output::json},
          Named{"zsh", Output::zsh},
          Named{"bash", Output::bash},
          Named{"fish", Output::fish},
      };

      for (const auto& [name, format] : formats) {
        if (name == value) {
          return format;
        }
      }

      throw std::invalid_argument{"UnknownHistoryExportFormat"};
    }

    void historyOption(tbc::mut_a<HistoryOptions> self, std::string_view arg, Cursor& cursor) {
      using Action = HistoryOptions::Action;

      const bool listing = self.action == Action::list || self.action == Action::search;
      if (scopeOption(self, arg, cursor) || filterOption(self, arg, cursor) || (self.action == Action::prune && pruneOption(self, arg, cursor)) || (listing && listOption(self, arg, cursor))) {
        return;
      }

      if (arg == "--file" && self.action == Action::import) {
        self.import_file = cursor.take("MissingHistoryFile");
      } else if (arg == "--format" && self.action == Action::export_history) {
        self.output = exportFormat(cursor.take("MissingHistoryFormat"));
      } else if (arg == "--ngram-size" && self.action == Action::stats) {
        const auto size = number<std::uint16_t>(cursor.take("MissingHistoryNgramSize"), "InvalidHistoryNgramSize");
        if (size == 0 || size > HistoryOptions::max_ngram_size) {
          throw std::invalid_argument{"InvalidHistoryNgramSize"};
        }

        self.ngram_size = static_cast<std::uint8_t>(size);
      } else if (arg == "--period" && self.action == Action::stats) {
        const auto period = cursor.take("MissingHistoryPeriod");

        self.period_days = periodDays(period);
        self.period_today = period == "today";
      } else if (arg == "--limit") {
        self.limit = parseInt<std::uint16_t>(cursor.take("MissingHistoryLimit"));
        if (self.limit == 0 || self.limit > HistoryOptions::max_results) {
          throw std::invalid_argument{"InvalidHistoryLimit"};
        }
      } else if (arg == "--socket") {
        const auto value = cursor.take("MissingSocketPath");

        if (self.socket) {
          throw std::invalid_argument{"DuplicateSocketOption"};
        }

        self.socket = value;
      } else {
        throw std::invalid_argument{"UnknownHistoryOption"};
      }
    }

  }

  HistoryOptions HistoryOptions::parse(Arguments words) {
    if (words.empty()) {
      throw std::invalid_argument{"MissingHistoryAction"};
    }

    HistoryOptions self{.action = Action::list};
    Cursor cursor{words.subspan(1)};

    historyAction(self, words, cursor);
    while (const auto word = cursor.next()) {
      historyOption(self, *word, cursor);
    }

    checkPaging(self);
    if (self.keep_runs != 0 && self.prune_filters) {
      throw std::invalid_argument{"ConflictingHistoryPruneOptions"};
    }

    return self;
  }

}

namespace telar::runtime::cli::file_transfer {

  Options Options::parse(Arguments words) {
    if (words.size() != 2 && words.size() != 4) {
      throw std::invalid_argument{"InvalidFileArguments"};
    }

    if (!std::string_view{words[1]}.starts_with('/')) {
      throw std::invalid_argument{"AbsoluteFilePathRequired"};
    }

    const std::string_view action = words.front();
    if (action != "put" && action != "get") {
      throw std::invalid_argument{"UnknownFileAction"};
    }

    Options self{.action = action == "put" ? Action::put : Action::get, .path = words[1]};

    if (words.size() == 4) {
      if (self.action != Action::put || std::string_view{words[2]} != "--bytes") {
        throw std::invalid_argument{"InvalidFileArguments"};
      }

      self.bytes = parseUnsigned<std::uint64_t>(words[3]);
    } else if (self.action == Action::put) {
      throw std::invalid_argument{"MissingTransferByteCount"};
    }

    return self;
  }

}
