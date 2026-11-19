module telar.cli.history;

import telar.tbc;
import telar.cli.control_session;
import telar.sys.posix;
import telar.base.diagnostics;
import telar.cli.server;
import telar.platform.fs;
import telar.platform.paths;
import telar.platform.error;
import telar.wire.runtime;
import telar.base.ds;

namespace telar::runtime::cli::file_transfer {

  constexpr std::uint64_t max_bytes = 128 * 1024 * 1024;

  FileDescriptor openDirectory(std::string_view path, bool create) {
    if (!path.starts_with('/')) {
      throw std::runtime_error{"AbsoluteFilePathRequired"};
    }

    FileDescriptor current{::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
    if (!current) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    std::size_t start = 1;

    while (start < path.size()) {
      const auto end = path.find('/', start);
      const auto component = path.substr(start, end == path.npos ? path.size() - start : end - start);

      start = end == path.npos ? path.size() : end + 1;
      if (component.empty()) {
        continue;
      }

      if (component == "." || component == "..") {
        throw std::runtime_error{"InvalidFilePath"};
      }

      ds::Array<char, NAME_MAX + 1> name{};
      if (component.size() >= name.size()) {
        throw std::runtime_error{sys::errorName(ENAMETOOLONG)};
      }

      std::ranges::copy(component, name.dataMut());
      auto next = ::openat(current.get(), name.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (next < 0 && sys::lastError() == ENOENT && create) {
        if (::mkdirat(current.get(), name.data(), 0700) != 0 && sys::lastError() != EEXIST) {
          throw std::runtime_error{sys::errorName(sys::lastError())};
        }

        next = ::openat(current.get(), name.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      }

      if (next < 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      current.reset(next);
    }

    struct stat inode{};
    if (::fstat(current.get(), &inode) != 0) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    if (inode.st_uid != ::getuid() || (inode.st_mode & 0022) != 0) {
      throw std::runtime_error{"UnsafeTransferDirectory"};
    }

    return current;
  }

  FileDescriptor openParent(std::string_view path) {
    const auto slash = path.rfind('/');
    if (slash == path.npos) {
      throw std::runtime_error{"InvalidFilePath"};
    }

    return openDirectory(path.substr(0, slash == 0 ? 1 : slash));
  }

  FileDescriptor openRegular(int parent, const char* name) {
    FileDescriptor file{::openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
    if (!file) {
      throw std::runtime_error{sys::lastError() == ENOENT ? sys::errorName(ENOENT) : "UnsafeTransferFile"};
    }

    struct stat inode{};
    if (::fstat(file.get(), &inode) != 0 || !S_ISREG(inode.st_mode) || inode.st_uid != ::getuid() || inode.st_nlink != 1) {
      throw std::runtime_error{"UnsafeTransferFile"};
    }

    return file;
  }

  void checkSize(std::uint64_t size) {
    if (size > max_bytes) {
      reportCommandLimit({.name = "file_transfer.max_bytes", .noun = "bytes", .value = max_bytes, .requested = size});
      throw std::runtime_error{"FileTransferLimit"};
    }
  }

  std::uint64_t copy(int input, int output) {
    ds::Array<Byte, copy_buffer_bytes> buffer;
    std::uint64_t total = 0;

    for (;;) {
      const auto count = ::read(input, buffer.dataMut(), buffer.size());
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
      writeBytes(output, std::span{buffer}.first(static_cast<std::size_t>(count)));
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
      copy(file.get(), STDOUT_FILENO);
      return;
    }

    ds::Array<char, 64> temporary{};

    std::format_to_n(temporary.dataMut(), temporary.size() - 1, ".telar-file-{:016x}{:016x}", randomIdentity(), randomIdentity());
    FileDescriptor file{::openat(parent.get(), temporary.data(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600)};
    if (!file) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    try {
      const auto size = copy(STDIN_FILENO, file.get());
      if (size != options.bytes) {
        throw std::runtime_error{"FileTransferInterrupted"};
      }

      if (::fsync(file.get()) != 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      publish(parent.get(), temporary.data(), name.data());
      ds::Array<char, 64> reply;
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
      std::fprintf(stderr, "telar file: %s\n", error.what());
      return 1;
    }
  }

}

namespace telar::runtime::cli::diagnostics {

  constexpr std::size_t max_files = 64;
  constexpr std::size_t max_directory_entries = 64 * 1024;
  constexpr std::size_t max_tail_bytes = 1024 * 1024;

  struct Log {
    Text name;
    DiagnosticsOptions::Component component;
    std::uint32_t pid;
  };

  tbc::view<ds::Option<Log>, tbc::lt::a> parseLog(tbc::view<Memory&, tbc::lt::a> memory, std::string_view name, std::string_view base) {
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

  tbc::view<ds::Vec<Log, Memory>, tbc::lt::a> findLogs(tbc::view<Memory&, tbc::lt::a> memory, DIR* directory, std::string_view base, const DiagnosticsOptions& options) {
    ds::Vec<Log, Memory> logs{memory};
    std::size_t visited = 0;
    std::size_t skipped = 0;

    while (const auto* entry = ::readdir(directory)) {
      if (std::string_view{entry->d_name} == "." || std::string_view{entry->d_name} == "..") {
        continue;
      }

      if (++visited > max_directory_entries) {
        reportCommandLimit({.name = "cli.diagnostic_directory_entries", .noun = "entries", .value = max_directory_entries});
        break;
      }

      if (entry->d_type != DT_REG) {
        continue;
      }

      auto log = parseLog(memory, entry->d_name, base);
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
      for (const auto suffix : {".runtime.start.log", ".runtime.log"}) {
        auto name = ds::format(memory, "{}{}", base, suffix);
        struct stat state{};
        if (::fstatat(::dirfd(directory), name.data(), &state, 0) == 0) {
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

  void readLogs(Memory& memory, std::string_view endpoint, const DiagnosticsOptions& options) {
    const auto slash = endpoint.rfind('/');
    if (slash == endpoint.npos) {
      throw std::runtime_error{"InvalidSocketPath"};
    }

    const Text parent{memory, endpoint.substr(0, slash)};
    const auto base = endpoint.substr(slash + 1);
    std::unique_ptr<DIR, decltype(&::closedir)> directory{::opendir(parent.data()), &::closedir};
    if (!directory) {
      throw std::runtime_error{sys::lastError() == ENOENT ? "DiagnosticLogsNotFound" : sys::errorName(sys::lastError())};
    }

    const auto logs = findLogs(memory, directory.get(), base, options);
    Text bytes{memory};
    Text output{memory, options.json ? "[" : ""};

    bytes.resizeForOverwrite(max_tail_bytes);
    for (const auto& log : logs) {
      FileDescriptor file{::openat(::dirfd(directory.get()), log.name.data(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
      if (!file) {
        throw std::runtime_error{"CannotOpenDiagnosticLog"};
      }

      struct stat inode{};
      if (::fstat(file.get(), &inode) != 0 || !S_ISREG(inode.st_mode) || inode.st_uid != ::getuid()) {
        throw std::runtime_error{"UnsafeDiagnosticLog"};
      }

      const auto offset = std::max<off_t>(0, inode.st_size - max_tail_bytes);
      std::size_t count = 0;

      while (count < bytes.size()) {
        const auto read = ::pread(file.get(), bytes.dataMut() + count, bytes.size() - count, offset + count);
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

      auto text = bytes.view().substr(0, count);
      if (offset != 0 && text.find('\n') != text.npos) {
        text.remove_prefix(text.find('\n') + 1);
      }

      const auto selected = tail(text, options.lines);
      const bool truncated = offset != 0 || selected.size() < text.size();
      const auto path = ds::format(memory, "{}/{}", parent, log.name);

      if (options.json) {
        if (&log != logs.data()) {
          output.push(',');
        }

        ds::formatTo(output, "{{\"path\":{},\"component\":{},\"pid\":{},\"truncated\":{},\"text\":{}}}", quoteJson(path), quoteJson(log.component == DiagnosticsOptions::Component::runtime ? "runtime" : "client"), log.pid, jsonBoolean(truncated), quoteJson(selected));
      } else {
        ds::formatTo(output, "{}{}{}", path, truncated ? " (tail)\n" : "\n", selected);
        if (selected.empty() || selected.back() != '\n') {
          output.push('\n');
        }
      }
    }

    if (options.json) {
      output.append("]\n");
    }

    writeText(output);
  }

  void printLimits(Memory& memory, const LimitList& list, bool json) {
    Text output{memory};

    if (json) {
      ds::formatTo(output, "{{\"runtime_evicted\":{},\"client_evicted\":{},\"refused_reports\":{},\"limits\":[", list.runtime_evicted, list.client_evicted, list.refused_reports);
    } else if (list.entries.empty()) {
      output.append("no limit reached\n");
    }

    for (const auto& entry : list.entries) {
      const auto origin = entry.origin == LimitOrigin::runtime ? "runtime" : "client";

      if (json) {
        if (&entry != list.entries.data()) {
          output.push(',');
        }

        ds::formatTo(output, "{{\"name\":{},\"noun\":{},\"value\":{},\"requested\":{},\"route\":{},\"origin\":{},\"hits\":{},\"last_ms\":{}}}", quoteJson(entry.reach.name), quoteJson(entry.reach.noun), entry.reach.value, orNull(entry.reach.requested), quoteJson(entry.reach.route), quoteJson(origin), entry.hits, entry.last_ms);
      } else {
        constexpr std::int64_t seconds_per_day = 24 * 60 * 60;
        constexpr std::int64_t seconds_per_hour = 60 * 60;
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

  int run(Memory& memory, const DiagnosticsOptions& options) {
    try {
      ServerOptions server_options{};

      server_options.socket = options.socket.valueOr("");
      const RuntimePaths paths{memory, server_options, process_environment};

      if (options.action == DiagnosticsOptions::Action::logs) {
        readLogs(memory, paths.socket, options);
      } else {
        ControlSession session{memory, paths.socket.data()};

        session.receiveTimeout(30);
        printLimits(memory, session.template exchange<LimitList>(QueryLimits{}), options.json);
      }

      return 0;
    } catch (const std::exception& error) {
      const std::string_view reason = commandErrorName(error);

      std::fprintf(stderr, "telar diagnostics: %.*s\n", static_cast<int>(reason.size()), reason.data());
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

  constexpr std::size_t max_histfile_bytes = 32 * 1024 * 1024;
  constexpr std::size_t max_command_bytes = 65535;
  constexpr std::size_t max_batch_payload = 4 * max_command_bytes;
  constexpr std::size_t max_import_entries = 64;

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
      default:
        throw std::runtime_error{"UnknownHistoryImportKind"};
      }
    }

    ds::Option<ImportedLine> flush() {
      if (!active_ || bytes_ == 0) {
        return ds::none;
      }

      active_ = false;
      if (bytes_ > command_.size()) {
        ++skipped;
        largest_skipped = std::max(largest_skipped, bytes_);
        return ds::none;
      }

      return ImportedLine{.started_at_ms = time_, .command = command_.clone()};
    }

    std::size_t skipped = 0;
    std::size_t largest_skipped = 0;

  private:
    static std::int64_t timestamp(std::string_view text) {
      try {
        constexpr auto max_seconds = std::numeric_limits<std::int64_t>::max() / 1000;
        constexpr auto min_seconds = std::numeric_limits<std::int64_t>::min() / 1000;
        const auto seconds = parseInt<std::int64_t>(text);

        return seconds > max_seconds || seconds < min_seconds ? 0 : seconds * 1000;
      } catch (const std::invalid_argument&) {
        return 0;
      }
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

      auto finished = flush();

      if (line.starts_with(": ")) {
        const auto semicolon = line.find(';');
        const auto colon = line.find(':', 2);
        if (semicolon == line.npos || colon == line.npos || colon >= semicolon) {
          return finished;
        }

        begin(timestamp(line.substr(2, colon - 2)), line.substr(semicolon + 1));
      } else if (!line.empty()) {
        begin(0, line);
      } else {
        return finished;
      }

      if (last_ == '\\' || finished) {
        return finished;
      }

      return flush();
    }

    ds::Option<ImportedLine> plain(std::string_view line) {
      if (line.empty()) {
        return ds::none;
      }

      auto finished = flush();

      begin(time_, line);
      if (finished) {
        return finished;
      }

      return flush();
    }

    ds::Option<ImportedLine> bash(std::string_view line) {
      if (line.size() > 1 && line.front() == '#') {
        try {
          static_cast<void>(parseInt<std::int64_t>(line.substr(1)));
          auto finished = flush();

          time_ = timestamp(line.substr(1));
          return finished;
        } catch (const std::invalid_argument&) {
        }
      }

      return plain(line);
    }

    ds::Option<ImportedLine> fish(std::string_view line) {
      constexpr std::string_view command_prefix = "- cmd: ";
      constexpr std::string_view time_prefix = "  when: ";

      if (line.starts_with(command_prefix)) {
        auto finished = flush();

        begin(0, line.substr(command_prefix.size()));
        return finished;
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
  };

  tbc::view<std::pair<HistoryOptions::ImportKind, Text>, tbc::lt::a> resolveImport(tbc::view<Memory&, tbc::lt::a> memory, const HistoryOptions& options) {
    using Kind = HistoryOptions::ImportKind;

    if (options.import_file) {
      const auto file = *options.import_file;
      const auto kind = options.import_kind != Kind::automatic ? options.import_kind : file.ends_with("fish_history") ? Kind::fish
                                                                                   : file.contains("bash")            ? Kind::bash
                                                                                                                      : Kind::zsh;

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

  tbc::view<std::pair<Text, bool>, tbc::lt::a> newestLines(tbc::view<Memory&, tbc::lt::a> memory, const Text& path) {
    FileDescriptor file{::open(path.data(), O_RDONLY | O_CLOEXEC)};
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
      const auto count = ::pread(file.get(), text.dataMut() + used, text.size() - used, static_cast<off_t>(offset + used));
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

  tbc::view<ImportSource, tbc::lt::a> loadImport(tbc::view<Memory&, tbc::lt::a> memory, const HistoryOptions& options) {
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

    auto push = [&](ds::Option<ImportedLine> entry) {
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
      if (newline == remaining.npos) {
        break;
      }

      remaining.remove_prefix(newline + 1);
    }

    push(parser.flush());
    flush();
    writeText(ds::format(memory, "imported {} commands from {}\n", total, input.path));
    if (parser.skipped != 0) {
      const LimitReach reach{.name = "history.import_command_bytes", .noun = "bytes", .value = max_command_bytes, .requested = parser.largest_skipped};

      reportCommandLimit(reach);
      try {
        session.send(ReportLimit{.reach = reach, .hits = 1});
      } catch (const std::exception&) {
      }
    }

    return input.truncated || parser.skipped != 0 ? 1 : 0;
  }

  void print(Memory& memory, const HistoryResults& results) {
    Text output{memory};

    for (const auto& entry : results.entries) {
      const auto seconds = static_cast<std::time_t>(std::max<std::int64_t>(0, entry.started_at_ms / 1000));
      std::tm utc{};

      ::gmtime_r(&seconds, &utc);
      ds::Array<char, 16> code;
      std::string_view status = entry.status == HistoryStatus::running ? "RUN" : entry.status == HistoryStatus::interrupted ? "INT" : "?";
      if (entry.status != HistoryStatus::running && entry.status != HistoryStatus::interrupted && entry.exit_code) {
        status = {code.data(), std::format_to_n(code.dataMut(), code.size(), "{}", *entry.exit_code).out};
      }

      ds::formatTo(output, "#{}  {:04}-{:02}-{:02} {:02}:{:02}:{:02}Z  {}  {}ms  {}  ", entry.id, utc.tm_year + 1900, utc.tm_mon + 1, utc.tm_mday, utc.tm_hour, utc.tm_min, utc.tm_sec, status, std::max<std::int64_t>(0, entry.duration_ns / 1000000), EscapedField{entry.cwd});
      if (entry.author == HistoryAuthor::agent && !entry.provider.empty()) {
        ds::formatTo(output, "\x1b[2m[{}]\x1b[22m ", EscapedField{entry.provider});
      }

      ds::formatTo(output, "{}\n", EscapedField{entry.command});
    }

    writeText(output);
  }

  tbc::view<HistoryScopeValue, tbc::lt::a> scopeValue(tbc::view<const HistoryOptions&, tbc::lt::a> options, tbc::view<std::string_view, tbc::lt::a> cwd) {
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

  tbc::view<HistoryResults, tbc::lt::b> query(tbc::view<ControlSession&, tbc::lt::b> session, const HistoryOptions& options, const HistoryScopeValue& scope) {
    return session.template exchange<HistoryResults>(QueryHistory{
        .query = options.query,
        .scope = options.scope,
        .scope_value = scope,
        .failed_only = options.failed_only,
        .author = options.author,
        .limit = options.limit,
    });
  }

  bool confirmPrune() {
    constexpr std::size_t confirmation_bytes = 16;
    ds::Array<char, confirmation_bytes> typed;

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

        return start != line.npos && line.substr(start, end - start + 1) == "yes";
      }

      typed.atMut(index) = byte;
    }

    return false;
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

    ControlSession removal{memory, socket};

    removal.receiveTimeout(30);
    const auto result = removal.template exchange<HistoryPruned>(PruneHistory{
        .scope = options.scope,
        .scope_value = scope,
        .before_ms = options.before_ms,
        .failed_only = options.failed_only,
        .match = options.query,
    });

    writeText(ds::format(memory, "removed {} entries\n", result.removed));
  }

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
        .since_ms = options.period_days == 0 ? 0 : now - static_cast<std::int64_t>(options.period_days) * milliseconds_per_day,
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

  int run(Memory& memory, const HistoryOptions& options) {
    try {
      ds::Option<ImportSource> input;

      if (options.action == HistoryOptions::Action::import) {
        input = loadImport(memory, options);
      }

      ServerOptions server_options{};

      server_options.socket = options.socket.valueOr("");
      const RuntimePaths paths{memory, server_options, process_environment};

      ensureRuntime(memory, paths);
      ControlSession session{memory, paths.socket.data(), max_payload_size, max_batch_payload + 2048};

      session.receiveTimeout(30);
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
      const auto context = options.action == HistoryOptions::Action::import ? "telar history import: " : "telar history: ";

      const std::string_view message = error.message().empty() ? std::string_view{error.what()} : error.message();

      std::fprintf(stderr, "%s%.*s\n", context, static_cast<int>(message.size()), message.data());
      writeText(options.action == HistoryOptions::Action::import ? "error: HistoryImportFailed\n" : options.action == HistoryOptions::Action::remove || options.action == HistoryOptions::Action::prune ? "error: HistoryPruneFailed\n"
                                                                                                                                                                                                        : "error: HistoryQueryFailed\n",
          STDERR_FILENO);
      return 1;
    } catch (const std::exception& error) {
      std::fprintf(stderr, "error: %s\n", error.what());
      return 1;
    }
  }

}

namespace telar::runtime::cli::diagnostics {

}

namespace telar::runtime::cli::history {

}

namespace telar::runtime::cli {

  DiagnosticsOptions DiagnosticsOptions::parse(Arguments words) {
    if (words.empty() || (std::string_view{words.front()} != "logs" && std::string_view{words.front()} != "limits")) {
      throw std::invalid_argument{"UnknownDiagnosticsAction"};
    }

    DiagnosticsOptions self{.action = std::string_view{words.front()} == "logs" ? Action::logs : Action::limits};
    Cursor cursor{words.subspan(1)};

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--component" && self.action == Action::logs) {
        const auto value = cursor.take("MissingComponent");
        if (value != "all" && value != "runtime" && value != "client") {
          throw std::invalid_argument{"InvalidComponent"};
        }

        self.component = value == "all" ? Component::all : value == "runtime" ? Component::runtime
                                                                              : Component::client;
      } else if (arg == "--pid" && !self.pid && self.action == Action::logs) {
        self.pid = number<std::uint32_t>(cursor.take("MissingPid"), "InvalidPid");
        if (*self.pid == 0) {
          throw std::invalid_argument{"InvalidPid"};
        }
      } else if (arg == "--lines" && self.action == Action::logs) {
        self.lines = number<std::uint16_t>(cursor.take("MissingLineCount"), "InvalidLineCount");
        if (self.lines == 0 || self.lines > max_lines) {
          throw std::invalid_argument{"InvalidLineCount"};
        }
      } else if (arg == "--json" && !self.json) {
        self.json = true;
      } else if (arg == "--socket" && !self.socket) {
        self.socket = cursor.take("MissingSocketPath");
      } else {
        throw std::invalid_argument{"UnknownDiagnosticsOption"};
      }
    }

    return self;
  }

  void HistoryOptions::setScope(HistoryScope value, tbc::view<std::string_view, tbc::lt::a> path) {
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
      if ((at != fields.size() - 1 && end == text.npos) || (at == fields.size() - 1 && end != text.npos)) {
        throw std::invalid_argument{"InvalidHistoryBefore"};
      }

      fields.atMut(at) = parseInt<std::int64_t>(text.substr(0, end));
      if (end != text.npos) {
        text.remove_prefix(end + 1);
      }
    }

    const auto [year, month, day] = fields;
    constexpr std::int64_t epoch_year = 1970;
    constexpr std::int64_t max_date_year = 292000000;
    if (year < epoch_year || year > max_date_year || month < 1 || month > 12 || day < 1 || day > 31) {
      throw std::invalid_argument{"InvalidHistoryBefore"};
    }

    const auto adjusted_year = month <= 2 ? year - 1 : year;
    constexpr std::int64_t years_per_era = 400;
    constexpr std::int64_t days_per_era = 146097;
    constexpr std::int64_t epoch_adjustment = 719468;
    constexpr std::int64_t milliseconds_per_day = 86400000;
    const auto era = adjusted_year / years_per_era;
    const auto year_of_era = adjusted_year - era * years_per_era;
    const auto adjusted_month = (month + 9) % 12;
    const auto day_of_year = (153 * adjusted_month + 2) / 5 + day - 1;
    const auto day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;

    return (era * days_per_era + day_of_era - epoch_adjustment) * milliseconds_per_day;
  }

  HistoryOptions HistoryOptions::parse(Arguments words) {
    if (words.empty()) {
      throw std::invalid_argument{"MissingHistoryAction"};
    }

    const std::string_view action = words.front();
    HistoryOptions self{.action = Action::list};
    Cursor cursor{words.subspan(1)};

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
        self.import_kind = importKind(*cursor.next());
      }
    } else {
      throw std::invalid_argument{"UnknownHistoryAction"};
    }

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--file" && self.action == Action::import) {
        self.import_file = cursor.take("MissingHistoryFile");
      } else if (arg == "--cwd") {
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
      } else if (arg == "--period" && self.action == Action::stats) {
        const auto value = cursor.take("MissingHistoryPeriod");
        if (value == "today") {
          self.period_days = 1;
        } else if (value == "week") {
          self.period_days = 7;
        } else if (value == "month") {
          self.period_days = 30;
        } else if (value == "year") {
          self.period_days = 365;
        } else if (value == "all") {
          self.period_days = 0;
        } else {
          throw std::invalid_argument{"InvalidHistoryPeriod"};
        }
      } else if (arg == "--before" && self.action == Action::prune) {
        self.before_ms = parseBefore(cursor.take("MissingHistoryBefore"));
      } else if (arg == "--dry-run" && self.action == Action::prune) {
        self.dry_run = true;
      } else if (arg == "--yes" && self.action == Action::prune) {
        self.assume_yes = true;
      } else if (arg == "--match" && self.action == Action::prune) {
        self.query = cursor.take("MissingHistoryQuery");
      } else if (arg == "--author") {
        const auto value = cursor.take("MissingHistoryAuthor");
        if (value != "all" && value != "human" && value != "agent") {
          throw std::invalid_argument{"InvalidHistoryAuthor"};
        }

        self.author = value == "all" ? HistoryAuthorFilter::all : value == "human" ? HistoryAuthorFilter::human
                                                                                   : HistoryAuthorFilter::agent;
      } else if (arg == "--limit") {
        self.limit = parseInt<std::uint16_t>(cursor.take("MissingHistoryLimit"));
        if (self.limit == 0 || self.limit > max_results) {
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
