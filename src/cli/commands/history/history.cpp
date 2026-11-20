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
import telar.base.ds;

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

    auto parent = openParent(options.path);
    const auto slash = options.path.rfind('/');
    const auto name = options.path.substr(slash + 1);
    if (name.empty() || name == "." || name == "..") {
      throw std::runtime_error{"InvalidFilePath"};
    }

    if (options.action == Options::Action::get) {
      auto file = openRegular(parent.get(), name.data());
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
    FileDescriptor file{::openat(parent.get(), temporary.data(), combineFlags(O_CREAT, O_EXCL, O_WRONLY, O_CLOEXEC), private_file_mode)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
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
      FileDescriptor file{::openat(directory, log.name.data(), combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
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
      std::unique_ptr<DIR, decltype(&::closedir)> directory{::opendir(parent.data()), &::closedir}; // NOLINT(misc-const-correctness): an owning pointer, which tbc's deep const forbids marking const
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

  constexpr std::size_t max_histfile_bytes = std::size_t{32} * 1024 * 1024;
  constexpr std::size_t max_command_bytes = 65535;
  constexpr std::size_t max_batch_payload = 4 * max_command_bytes;
  constexpr std::size_t max_import_entries = 64;

  namespace {

    constexpr std::int64_t milliseconds_per_second = 1000;

    struct ImportedLine {
      std::int64_t started_at_ms;
      Text command;
    };

    class ImportParser {
    public:
      ImportParser(Memory& memory, HistoryOptions::ImportKind kind)
          : kind_(kind),
            command_(memory) {}

      ds::Option<ImportedLine> feed(std::string_view line) {
        while (line.ends_with('\r')) {
          line.remove_suffix(1);
        }

        switch (kind_) {
        case HistoryOptions::ImportKind::zsh:
          return zsh(line);
        case HistoryOptions::ImportKind::bash:
          return bash(line);
        case HistoryOptions::ImportKind::fish:
          return fish(line);
        case HistoryOptions::ImportKind::automatic:
          break;
        }

        throw std::runtime_error{"UnknownHistoryImportKind"};
      }

      ds::Option<ImportedLine> flush() {
        if (!active_ || bytes_ == 0) {
          return ds::none;
        }

        active_ = false;
        if (bytes_ > command_.size()) {
          ++skipped_;
          largest_skipped_ = std::max(largest_skipped_, bytes_);
          return ds::none;
        }

        return ImportedLine{.started_at_ms = time_, .command = command_.clone()};
      }

      [[nodiscard]] std::size_t skipped() const noexcept {
        return skipped_;
      }

      [[nodiscard]] std::size_t largestSkipped() const noexcept {
        return largest_skipped_;
      }

    private:
      // A command and when it started, as a history line gives them.
      struct TimedCommand {
        std::int64_t time;
        std::string_view command;
      };

      static std::int64_t timestamp(std::string_view text) {
        try {
          constexpr auto max_seconds = std::numeric_limits<std::int64_t>::max() / milliseconds_per_second;
          constexpr auto min_seconds = std::numeric_limits<std::int64_t>::min() / milliseconds_per_second;
          const auto seconds = parseInt<std::int64_t>(text);

          return seconds > max_seconds || seconds < min_seconds ? 0 : seconds * milliseconds_per_second;
        } catch (const std::invalid_argument&) {
          return 0;
        }
      }

      static bool integer(std::string_view text) {
        try {
          static_cast<void>(parseInt<std::int64_t>(text));
          return true;
        } catch (const std::invalid_argument&) {
          return false;
        }
      }

      // The command a zsh line holds, extended (`: start:elapsed;command`) or plain; none for an
      // empty or malformed line.
      static tbc::val_a<ds::Option<TimedCommand>> zshCommand(tbc::val_a<std::string_view> line) {
        if (!line.starts_with(": ")) {
          return line.empty() ? ds::none : ds::Option{TimedCommand{.time = 0, .command = line}};
        }

        const auto semicolon = line.find(';');
        const auto colon = line.find(':', 2);
        if (semicolon == std::string_view::npos || colon == std::string_view::npos || colon >= semicolon) {
          return ds::none;
        }

        return TimedCommand{.time = timestamp(line.substr(2, colon - 2)), .command = line.substr(semicolon + 1)};
      }

      void append(std::string_view bytes) {
        if (bytes.empty()) {
          return;
        }

        bytes_ += bytes.size();
        last_ = bytes.back();
        if (bytes_ <= max_command_bytes) {
          command_.append(bytes);
        }
      }

      void begin(std::int64_t time, std::string_view command) {
        time_ = time;
        bytes_ = 0;
        last_ = 0;
        active_ = true;
        command_.clear();
        append(command);
      }

      // Ends the pending command, which it returns, and begins this one.
      ds::Option<ImportedLine> restart(std::int64_t time, std::string_view command) {
        auto finished = flush();

        begin(time, command);
        return finished;
      }

      ds::Option<ImportedLine> zsh(std::string_view line) {
        if (active_ && bytes_ != 0 && last_ == '\\') {
          --bytes_;
          if (bytes_ < command_.size()) {
            command_.truncate(bytes_);
          }

          last_ = 0;
          append("\n");
          append(line);
          return line.ends_with('\\') ? ds::none : flush();
        }

        const auto command = zshCommand(line);
        if (!command) {
          return flush();
        }

        if (auto finished = restart(command->time, command->command); finished || last_ == '\\') {
          return finished;
        }

        return flush();
      }

      ds::Option<ImportedLine> plain(std::string_view line) {
        if (line.empty()) {
          return ds::none;
        }

        if (auto finished = restart(time_, line)) {
          return finished;
        }

        return flush();
      }

      ds::Option<ImportedLine> bash(std::string_view line) {
        if (line.size() > 1 && line.front() == '#' && integer(line.substr(1))) {
          auto finished = flush();

          time_ = timestamp(line.substr(1));
          return finished;
        }

        return plain(line);
      }

      ds::Option<ImportedLine> fish(std::string_view line) {
        constexpr std::string_view command_prefix = "- cmd: ";
        constexpr std::string_view time_prefix = "  when: ";

        if (line.starts_with(command_prefix)) {
          return restart(0, line.substr(command_prefix.size()));
        }

        if (line.starts_with(time_prefix)) {
          time_ = timestamp(line.substr(time_prefix.size()));
          return flush();
        }

        return ds::none;
      }

      HistoryOptions::ImportKind kind_;
      std::int64_t time_ = 0;
      Text command_;
      std::size_t bytes_ = 0;
      char last_ = 0;
      bool active_ = false;
      std::size_t skipped_ = 0;
      std::size_t largest_skipped_ = 0;
    };

    // The shell a history file named on the command line comes from, as its name suggests.
    HistoryOptions::ImportKind fileKind(std::string_view file) noexcept {
      if (file.ends_with("fish_history")) {
        return HistoryOptions::ImportKind::fish;
      }

      return file.contains("bash") ? HistoryOptions::ImportKind::bash : HistoryOptions::ImportKind::zsh;
    }

    tbc::val_a<std::pair<HistoryOptions::ImportKind, Text>> resolveImport(tbc::mut_a<Memory> memory, const HistoryOptions& options) {
      using Kind = HistoryOptions::ImportKind;

      if (options.import_file) {
        const auto file = *options.import_file;
        const auto kind = options.import_kind != Kind::automatic ? options.import_kind : fileKind(file);

        return {kind, Text{memory, file}};
      }

      const auto home = processHome();
      if (home.empty()) {
        throw std::runtime_error{"HistfileNotFound"};
      }

      constexpr ds::Array candidates{
          std::pair{Kind::zsh, "/.zsh_history"},
          std::pair{Kind::bash, "/.bash_history"},
          std::pair{Kind::fish, "/.local/share/fish/fish_history"},
      };

      for (const auto& [kind, suffix] : candidates) {
        if (options.import_kind != Kind::automatic && options.import_kind != kind) {
          continue;
        }

        auto path = ds::format(memory, "{}{}", home, suffix);
        if (::access(path.data(), F_OK) == 0) {
          return {kind, std::move(path)};
        }
      }

      throw std::runtime_error{"HistfileNotFound"};
    }

    tbc::val_a<std::pair<Text, bool>> newestLines(tbc::mut_a<Memory> memory, const Text& path) {
      FileDescriptor file{::open(path.data(), combineFlags(O_RDONLY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      struct stat inode{};
      if (!file || ::fstat(file.get(), &inode) != 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      const auto size = static_cast<std::uint64_t>(inode.st_size);
      const auto offset = size > max_histfile_bytes ? size - max_histfile_bytes : 0;
      Text text{memory};
      std::size_t used = 0;

      text.resizeForOverwrite(size - offset);
      while (used < text.size()) {
        const auto rest = text.viewMut().subspan(used);
        const auto count = ::pread(file.get(), rest.data(), rest.size(), static_cast<off_t>(offset + used));
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count < 0) {
          throw std::runtime_error{sys::errorName(sys::lastError())};
        }

        if (count == 0) {
          break;
        }

        used += static_cast<std::size_t>(count);
      }

      text.truncate(used);
      if (offset != 0) {
        reportCommandLimit({.name = "history.max_histfile_bytes", .noun = "bytes", .value = max_histfile_bytes, .requested = size});
        const auto newline = text.view().find('\n');

        text.remove(0, newline == std::string_view::npos ? text.size() : newline + 1);
      }

      return {std::move(text), offset != 0};
    }

    struct ImportSource {
      HistoryOptions::ImportKind kind;
      Text path;
      Text text;
      bool truncated;
    };

    tbc::val_a<ImportSource> loadImport(tbc::mut_a<Memory> memory, const HistoryOptions& options) {
      auto [kind, path] = resolveImport(memory, options);
      auto [text, truncated] = newestLines(memory, path);

      return {.kind = kind, .path = std::move(path), .text = std::move(text), .truncated = truncated};
    }

    int importHistory(Memory& memory, ControlSession& session, const ImportSource& input) {
      constexpr ds::Array kind_names{"auto", "zsh", "bash", "fish"};
      const auto source = ds::format(memory, "{}:{}", kind_names.at(static_cast<std::size_t>(input.kind)), input.path);
      ds::Vec<ImportedLine, Memory> batch{memory};

      batch.reserve(max_import_entries);
      std::size_t used = 0;
      std::uint64_t total = 0;
      auto flush = [&] {
        if (batch.empty()) {
          return;
        }

        ds::Array<ImportHistoryEntry, max_import_entries> entries;

        for (std::size_t index = 0; index < batch.size(); ++index) {
          entries.atMut(index) = {.started_at_ms = batch[index].started_at_ms, .command = batch[index].command.view()};
        }

        session.template exchange<RequestCompleted>(ImportHistory{.source = source.view(), .base_sequence = total, .entries = std::span{entries}.first(batch.size())});
        total += batch.size();
        batch.clear();
        used = 0;
      };

      const auto push = [&](ds::Option<ImportedLine> entry) {
        if (!entry || entry->command.empty()) {
          return;
        }

        if (batch.size() == max_import_entries || used + entry->command.size() > max_batch_payload) {
          flush();
        }

        used += entry->command.size();
        batch.push(std::move(entry.getMut()));
      };

      ImportParser parser{memory, input.kind};
      std::string_view remaining = input.text;

      for (;;) {
        const auto newline = remaining.find('\n');

        push(parser.feed(remaining.substr(0, newline)));
        if (newline == std::string_view::npos) {
          break;
        }

        remaining.remove_prefix(newline + 1);
      }

      push(parser.flush());
      flush();
      writeText(ds::format(memory, "imported {} commands from {}\n", total, input.path));
      if (parser.skipped() != 0) {
        const LimitReach reach{.name = "history.import_command_bytes", .noun = "bytes", .value = max_command_bytes, .requested = parser.largestSkipped()};

        reportCommandLimit(reach);
        try {
          session.send(ReportLimit{.reach = reach, .hits = 1});
        } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): the limit is already reported here; the runtime's copy is best effort.
        }
      }

      return input.truncated || parser.skipped() != 0 ? 1 : 0;
    }

    // An entry's state: running, interrupted, its exit code written into `code`, or unknown.
    tbc::val_a<std::string_view> statusText(const HistoryEntry& entry, tbc::val_a<std::span<char>> code) {
      if (entry.status == HistoryStatus::running) {
        return "RUN";
      }

      if (entry.status == HistoryStatus::interrupted) {
        return "INT";
      }

      if (!entry.exit_code) {
        return "?";
      }

      const auto written = std::format_to_n(code.data(), static_cast<std::ptrdiff_t>(code.size()), "{}", *entry.exit_code);

      return {code.data(), std::min(static_cast<std::size_t>(written.size), code.size())};
    }

    void print(Memory& memory, const HistoryResults& results) {
      constexpr std::size_t exit_code_bytes = 16;
      constexpr int tm_year_base = 1900;
      constexpr std::int64_t nanoseconds_per_millisecond = 1000000;
      Text output{memory};

      for (const auto& entry : results.entries) {
        const auto seconds = static_cast<std::time_t>(std::max<std::int64_t>(0, entry.started_at_ms / milliseconds_per_second));
        std::tm utc{};

        ::gmtime_r(&seconds, &utc);
        ds::Array<char, exit_code_bytes> code{};
        const auto status = statusText(entry, code.viewMut());

        ds::formatTo(output, "#{}  {:04}-{:02}-{:02} {:02}:{:02}:{:02}Z  {}  {}ms  {}  ", entry.id, utc.tm_year + tm_year_base, utc.tm_mon + 1, utc.tm_mday, utc.tm_hour, utc.tm_min, utc.tm_sec, status, std::max<std::int64_t>(0, entry.duration_ns / nanoseconds_per_millisecond), EscapedField{entry.cwd});
        if (entry.author == HistoryAuthor::agent && !entry.provider.empty()) {
          ds::formatTo(output, "\x1b[2m[{}]\x1b[22m ", EscapedField{entry.provider});
        }

        ds::formatTo(output, "{}\n", EscapedField{entry.command});
      }

      writeText(output);
    }

    tbc::val_a<HistoryScopeValue> scopeValue(tbc::ref_a<HistoryOptions> options, tbc::val_a<std::string_view> cwd) {
      switch (options.scope) {
      case HistoryScope::cwd:
        return cwd;
      case HistoryScope::workspace:
        return options.scope_value;
      case HistoryScope::pane:
        return options.pane_id;
      case HistoryScope::global:
        return std::monostate{};
      }

      throw std::runtime_error{"InvalidHistoryScope"};
    }

  }

  tbc::val_b<HistoryResults> query(tbc::mut_b<ControlSession> session, const HistoryOptions& options, const HistoryScopeValue& scope) {
    return session.template exchange<HistoryResults>(QueryHistory{
        .query = options.query,
        .scope = options.scope,
        .scope_value = scope,
        .failed_only = options.failed_only,
        .author = options.author,
        .limit = options.limit,
    });
  }

  namespace {

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

  }

  void prune(Memory& memory, const char* socket, ControlSession& session, const HistoryOptions& options, const HistoryScopeValue& scope) {
    if (options.action == HistoryOptions::Action::remove) {
      const auto result = session.template exchange<HistoryPruned>(DeleteHistory{.id = options.id});

      writeText(ds::format(memory, "removed {} entries\n", result.removed));
      return;
    }

    if (options.dry_run || !options.assume_yes) {
      auto preview = options;

      preview.author = HistoryAuthorFilter::all;
      preview.limit = HistoryOptions::max_results;
      const auto results = query(session, preview, scope);

      if (options.before_ms != 0) {
        writeText(ds::format(memory, "{} newest entries match the text/scope filters; --before applies on top and is not previewable\n", results.entries.size()));
      } else {
        writeText(ds::format(memory, "would remove {} entries (counting at most the newest {})\n", results.entries.size(), HistoryOptions::max_results));
      }

      if (options.dry_run) {
        return;
      }

      writeText("prune permanently? type yes to continue: ");
      if (!confirmPrune()) {
        writeText("aborted\n");
        return;
      }
    }

    constexpr unsigned timeout_seconds = 30;
    ControlSession removal{memory, socket};

    removal.receiveTimeout(timeout_seconds);
    const auto result = removal.template exchange<HistoryPruned>(PruneHistory{
        .scope = options.scope,
        .scope_value = scope,
        .before_ms = options.before_ms,
        .failed_only = options.failed_only,
        .match = options.query,
    });

    writeText(ds::format(memory, "removed {} entries\n", result.removed));
  }

  namespace {

    void show(Memory& memory, ControlSession& session, const HistoryOptions& options) {
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

    void stats(Memory& memory, ControlSession& session, const HistoryOptions& options, const HistoryScopeValue& scope) {
      constexpr std::int64_t milliseconds_per_day = 86400000;
      const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
      const auto result = session.template exchange<HistoryStatsResult>(HistoryStatsQuery{
          .scope = options.scope,
          .scope_value = scope,
          .since_ms = options.period_days == 0 ? 0 : now - (static_cast<std::int64_t>(options.period_days) * milliseconds_per_day),
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
        return "error: HistoryQueryFailed\n";
      }

      std::unreachable();
    }

  }

  int run(Memory& memory, const HistoryOptions& options) {
    try {
      ds::Option<ImportSource> input;

      if (options.action == HistoryOptions::Action::import) {
        input.emplace(loadImport(memory, options));
      }

      // A request carries a batch of imported commands with its source and other fields, which this leaves room for.
      constexpr std::size_t request_overhead_bytes = 2048;
      constexpr unsigned timeout_seconds = 30;
      ServerOptions server_options{};

      server_options.socket = options.socket.valueOr("");
      const RuntimePaths<Memory> paths{memory, server_options, process_environment};

      ensureRuntime(memory, paths);
      ControlSession session{memory, paths.socket.data(), max_payload_size, max_batch_payload + request_overhead_bytes};

      session.receiveTimeout(timeout_seconds);
      ds::Array<char, PATH_MAX> directory{};
      if (options.scope == HistoryScope::cwd && ::realpath(".", directory.dataMut()) == nullptr) {
        throw SystemError{"Resolve the working directory"};
      }

      const auto scope = scopeValue(options, std::string_view{directory.data()});

      switch (options.action) {
      case HistoryOptions::Action::import:
        return importHistory(memory, session, *input);
      case HistoryOptions::Action::remove:
      case HistoryOptions::Action::prune:
        prune(memory, paths.socket.data(), session, options, scope);
        break;
      case HistoryOptions::Action::show:
        show(memory, session, options);
        break;
      case HistoryOptions::Action::stats:
        stats(memory, session, options, scope);
        break;
      case HistoryOptions::Action::list:
      case HistoryOptions::Action::search:
        print(memory, query(session, options, scope));
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

namespace telar::runtime::cli::diagnostics {

}

namespace telar::runtime::cli::history {

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
    if (value == "auto") {
      return ImportKind::automatic;
    }

    if (value == "zsh") {
      return ImportKind::zsh;
    }

    if (value == "bash") {
      return ImportKind::bash;
    }

    if (value == "fish") {
      return ImportKind::fish;
    }

    throw std::invalid_argument{"UnknownHistoryImportKind"};
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
    constexpr std::int64_t max_month_day = 31;
    if (year < epoch_year || year > max_date_year || month < 1 || month > months_per_year || day < 1 || day > max_month_day) {
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
      } else {
        throw std::invalid_argument{"UnknownHistoryAction"};
      }
    }

    std::uint16_t periodDays(std::string_view value) {
      constexpr std::uint16_t days_per_week = 7;
      constexpr std::uint16_t days_per_month = 30;
      constexpr std::uint16_t days_per_year = 365;

      if (value == "today") {
        return 1;
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
      } else {
        return false;
      }

      return true;
    }

    void historyOption(tbc::mut_a<HistoryOptions> self, std::string_view arg, Cursor& cursor) {
      using Action = HistoryOptions::Action;

      if (scopeOption(self, arg, cursor) || (self.action == Action::prune && pruneOption(self, arg, cursor))) {
        return;
      }

      if (arg == "--file" && self.action == Action::import) {
        self.import_file = cursor.take("MissingHistoryFile");
      } else if (arg == "--period" && self.action == Action::stats) {
        self.period_days = periodDays(cursor.take("MissingHistoryPeriod"));
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
