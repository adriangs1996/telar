module telar.cli.commands.history.sources;

import std;
import telar.tbc;
import telar.sys.posix;
import telar.platform.primitives;
import telar.cli.console.command_limit;
import telar.base.text.json;
import telar.base.ds;

namespace telar::runtime::cli::history {

  namespace {

    constexpr std::int64_t milliseconds_per_second = 1000;
    constexpr std::int64_t decimal = 10;

    // text.substr(offset, count) that cannot throw: an offset past the end gives an empty view.
    constexpr std::string_view slice(std::string_view text, std::size_t offset, std::size_t count = std::string_view::npos) noexcept {
      text.remove_prefix(std::min(offset, text.size()));
      text.remove_suffix(text.size() - std::min(count, text.size()));
      return text;
    }

    // A command a reader is assembling from the lines of one entry. Past max_command_bytes it
    // only counts what it is given, so the sink learns how long the command it skips was.
    class Pending {
    public:
      explicit Pending(Memory& memory)
          : text_(memory) {}

      void begin(std::int64_t time) {
        time_ = time;
        duration_ns_ = 0;
        bytes_ = 0;
        active_ = true;
        text_.clear();
      }

      void time(std::int64_t value) noexcept {
        time_ = value;
      }

      void duration(std::int64_t nanoseconds) noexcept {
        duration_ns_ = nanoseconds;
      }

      [[nodiscard]] bool active() const noexcept {
        return active_;
      }

      void append(std::string_view piece) {
        bytes_ += piece.size();
        if (bytes_ <= max_command_bytes) {
          text_.append(piece);
        }
      }

      void push(char byte) {
        append({&byte, 1});
      }

      void flush(ImportSink& sink) {
        if (!active_) {
          return;
        }

        active_ = false;
        if (bytes_ == 0) {
          return;
        }

        if (bytes_ > max_command_bytes) {
          sink.skipped(bytes_);
          return;
        }

        sink.command(time_, text_.view(), {.duration_ns = duration_ns_});
      }

    private:
      ds::String<Memory> text_;
      std::int64_t time_ = 0;
      std::int64_t duration_ns_ = 0;
      std::size_t bytes_ = 0;
      bool active_ = false;
    };

    // Calls `line` with each line of `text`, without its newline or the carriage returns before it.
    template <typename Line>
    void eachLine(std::string_view text, Line line) {
      while (!text.empty()) {
        const auto newline = text.find('\n');
        auto current = text.substr(0, newline);

        while (current.ends_with('\r')) {
          current.remove_suffix(1);
        }

        line(current);
        if (newline == std::string_view::npos) {
          return;
        }

        text.remove_prefix(newline + 1);
      }
    }

    ds::Option<std::int64_t> digits(std::string_view text) noexcept {
      constexpr std::size_t max_digits = 15;
      std::int64_t value = 0;

      if (text.empty() || text.size() > max_digits) {
        return ds::none;
      }

      for (const auto digit : text) {
        if (digit < '0' || digit > '9') {
          return ds::none;
        }

        value = (value * decimal) + (digit - '0');
      }

      return value;
    }

    ds::Option<std::int64_t> seconds(std::string_view text) noexcept {
      const auto value = digits(text);
      if (!value) {
        return ds::none;
      }

      return *value * milliseconds_per_second;
    }

    // zsh writes each byte it treats specially as Meta (0x83) and the byte with bit 5 flipped.
    void appendUnmetafied(Pending& pending, std::string_view bytes) {
      constexpr char meta = '\x83';
      constexpr unsigned char meta_bit = 0x20;

      while (!bytes.empty()) {
        const auto found = bytes.find(meta);

        pending.append(bytes.substr(0, found));
        if (found == std::string_view::npos || found + 1 == bytes.size()) {
          return;
        }

        pending.push(static_cast<char>(static_cast<unsigned char>(bytes[found + 1]) ^ meta_bit));
        bytes.remove_prefix(found + 2);
      }
    }

    // The start and the command of an extended zsh line, `: <start>:<elapsed>;<command>`.
    struct ZshHeader {
      std::int64_t time;
      std::int64_t elapsed_ns;
      std::string_view command;
    };

    ds::Option<ZshHeader> zshHeader(std::string_view line) noexcept {
      if (!line.starts_with(": ")) {
        return ds::none;
      }

      const auto colon = line.find(':', 2);
      const auto semicolon = line.find(';', 2);
      if (colon == std::string_view::npos || semicolon == std::string_view::npos || colon > semicolon) {
        return ds::none;
      }

      constexpr std::int64_t nanoseconds_per_second = 1000000000;
      const auto start = seconds(slice(line, 2, colon - 2));
      const auto elapsed = digits(slice(line, colon + 1, semicolon - colon - 1));
      if (!start || !elapsed) {
        return ds::none;
      }

      return ZshHeader{.time = *start, .elapsed_ns = *elapsed * nanoseconds_per_second, .command = slice(line, semicolon + 1)};
    }

    // zsh keeps a command's newlines as a backslash that ends the line. A line that does not
    // start an extended entry is a command of its own, even one like `: noop`. A file cut at its
    // start begins at the first line that is surely an entry's: an extended header, or the line
    // after the first one that ends no command.
    void parseZsh(Memory& memory, std::string_view text, bool truncated, ImportSink& sink) {
      Pending pending{memory};
      bool continued = false;
      bool skipping = truncated;

      eachLine(text, [&](std::string_view line) {
        if (skipping) {
          if (!zshHeader(line)) {
            skipping = line.ends_with('\\');
            return;
          }

          skipping = false;
        }

        if (continued) {
          continued = line.ends_with('\\');
          pending.push('\n');
          appendUnmetafied(pending, continued ? slice(line, 0, line.size() - 1) : line);
          if (!continued) {
            pending.flush(sink);
          }

          return;
        }

        if (line.empty()) {
          return;
        }

        const auto header = zshHeader(line);
        const auto body = header ? header->command : line;

        pending.begin(header ? header->time : 0);
        pending.duration(header ? header->elapsed_ns : 0);
        continued = body.ends_with('\\');
        appendUnmetafied(pending, continued ? body.substr(0, body.size() - 1) : body);
        if (!continued) {
          pending.flush(sink);
        }
      });

      pending.flush(sink);
    }

    // With HISTTIMEFORMAT, bash writes `#<epoch>` before each entry, and the lines up to the next
    // one are all that entry's, a multi-line command among them. Before the first such line, each
    // line is a command; a file cut at its start begins at its first timestamp when it has one.
    void parseBash(Memory& memory, std::string_view text, bool truncated, ImportSink& sink) {
      Pending pending{memory};
      bool timestamped = false;
      bool first_line = false;
      bool skipping = truncated && text.contains("\n#");

      eachLine(text, [&](std::string_view line) {
        const auto time = line.size() > 1 && line.front() == '#' ? seconds(slice(line, 1)) : ds::Option<std::int64_t>{};
        if (time) {
          pending.flush(sink);
          pending.begin(*time);
          timestamped = true;
          first_line = true;
          skipping = false;
          return;
        }

        if (skipping) {
          return;
        }

        if (timestamped) {
          if (!first_line) {
            pending.push('\n');
          }

          first_line = false;
          pending.append(line);
          return;
        }

        if (!line.empty()) {
          pending.begin(0);
          pending.append(line);
          pending.flush(sink);
        }
      });

      pending.flush(sink);
    }

    // fish writes a command's backslashes as `\\` and its newlines as `\n`.
    void appendFish(Pending& pending, std::string_view encoded) {
      while (!encoded.empty()) {
        const auto slash = encoded.find('\\');

        pending.append(slice(encoded, 0, slash));
        if (slash == std::string_view::npos) {
          return;
        }

        if (slash + 1 == encoded.size()) {
          pending.push('\\');
          return;
        }

        const auto next = encoded[slash + 1];
        if (next == 'n') {
          pending.push('\n');
        } else if (next == '\\') {
          pending.push('\\');
        } else {
          pending.append(slice(encoded, slash, 2));
        }

        encoded.remove_prefix(slash + 2);
      }
    }

    // `- cmd: <command>` opens an entry and `  when: <epoch>` dates it; what precedes the first
    // command of a cut file belongs to none.
    void parseFish(Memory& memory, std::string_view text, ImportSink& sink) {
      constexpr std::string_view command_prefix = "- cmd: ";
      constexpr std::string_view time_prefix = "  when: ";
      Pending pending{memory};

      eachLine(text, [&](std::string_view line) {
        if (line.starts_with(command_prefix)) {
          pending.flush(sink);
          pending.begin(0);
          appendFish(pending, slice(line, command_prefix.size()));
        } else if (line.starts_with(time_prefix) && pending.active()) {
          pending.time(seconds(slice(line, time_prefix.size())).valueOr(0));
        }
      });

      pending.flush(sink);
    }

    // reedline, nushell's line editor, writes a newline inside a command as `<\n>`.
    void parseNushell(Memory& memory, std::string_view text, ImportSink& sink) {
      constexpr std::string_view newline = "<\\n>";
      Pending pending{memory};

      eachLine(text, [&](std::string_view line) {
        if (line.empty()) {
          return;
        }

        pending.begin(0);
        while (!line.empty()) {
          const auto found = line.find(newline);

          pending.append(slice(line, 0, found));
          if (found == std::string_view::npos) {
            break;
          }

          pending.push('\n');
          line.remove_prefix(found + newline.size());
        }

        pending.flush(sink);
      });
    }

    // PSReadLine ends each line of a multi-line command but the last with a backtick. A cut file
    // begins after the first line that ends no command, which may be the tail of a cut one.
    void parsePowershell(Memory& memory, std::string_view text, bool truncated, ImportSink& sink) {
      Pending pending{memory};
      bool continued = false;
      bool skipping = truncated;

      eachLine(text, [&](std::string_view line) {
        if (skipping) {
          skipping = line.ends_with('`');
          return;
        }

        if (!continued) {
          if (line.empty()) {
            return;
          }

          pending.begin(0);
        } else {
          pending.push('\n');
        }

        continued = line.ends_with('`');
        pending.append(continued ? slice(line, 0, line.size() - 1) : line);
        if (!continued) {
          pending.flush(sink);
        }
      });

      pending.flush(sink);
    }

  }

  std::string_view formatName(ImportFormat format) noexcept {
    switch (format) {
    case ImportFormat::zsh:
      return "zsh";
    case ImportFormat::bash:
      return "bash";
    case ImportFormat::fish:
      return "fish";
    case ImportFormat::nushell:
    case ImportFormat::nushell_sqlite:
      return "nushell";
    case ImportFormat::xonsh:
      return "xonsh";
    case ImportFormat::powershell:
      return "powershell";
    case ImportFormat::atuin:
      return "atuin";
    case ImportFormat::mcfly:
      return "mcfly";
    case ImportFormat::histdb:
      return "histdb";
    }

    return "unknown";
  }

  void parseHistfile(Memory& memory, ImportFormat format, std::string_view text, bool truncated, ImportSink& sink) {
    switch (format) {
    case ImportFormat::zsh:
      parseZsh(memory, text, truncated, sink);
      return;
    case ImportFormat::bash:
      parseBash(memory, text, truncated, sink);
      return;
    case ImportFormat::fish:
      parseFish(memory, text, sink);
      return;
    case ImportFormat::nushell:
      parseNushell(memory, text, sink);
      return;
    case ImportFormat::powershell:
      parsePowershell(memory, text, truncated, sink);
      return;
    case ImportFormat::xonsh:
    case ImportFormat::atuin:
    case ImportFormat::mcfly:
    case ImportFormat::histdb:
    case ImportFormat::nushell_sqlite:
      break;
    }

    throw std::runtime_error{"UnknownHistoryImportKind"};
  }

  namespace {

    // An open regular file and its size; a file that is none, a FIFO or a device, is refused
    // before a byte of it is read.
    struct RegularFile {
      FileDescriptor descriptor;
      std::uint64_t size;
    };

    RegularFile openRegular(const char* path) {
      FileDescriptor file{::open(path, combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      struct stat inode{};
      if (!file || ::fstat(file.get(), &inode) != 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      if (!S_ISREG(inode.st_mode)) {
        throw std::runtime_error{"HistfileNotRegular"};
      }

      return {.descriptor = std::move(file), .size = static_cast<std::uint64_t>(inode.st_size)};
    }

  }

  tbc::val_a<Histfile> readHistfile(tbc::mut_a<Memory> memory, const char* path) {
    const auto file = openRegular(path);
    const auto offset = file.size > max_histfile_bytes ? file.size - max_histfile_bytes : 0;
    Histfile result{.text = ds::String<Memory>{memory}};
    std::size_t used = 0;

    result.text.resizeForOverwrite(static_cast<std::size_t>(file.size - offset));
    while (used < result.text.size()) {
      const auto rest = result.text.viewMut().subspan(used);
      const auto count = ::pread(file.descriptor.get(), rest.data(), rest.size(), static_cast<off_t>(offset + used));
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

    result.text.truncate(used);
    if (offset != 0) {
      reportCommandLimit({.name = "history.max_histfile_bytes", .noun = "bytes", .value = max_histfile_bytes, .requested = file.size});
      const auto newline = result.text.view().find('\n');

      result.text.remove(0, newline == std::string_view::npos ? result.text.size() : newline + 1);
      result.truncated = true;
    }

    return result;
  }

  namespace {

    // A JSON number of seconds, as xonsh dates a command, in milliseconds; 0 for anything else.
    std::int64_t jsonMilliseconds(std::string_view number) noexcept {
      const auto point = number.find('.');
      const auto whole = digits(slice(number, 0, point));
      if (!whole) {
        return 0;
      }

      std::int64_t fraction = 0;
      std::int64_t scale = milliseconds_per_second;

      if (point != std::string_view::npos) {
        for (const auto digit : slice(number, point + 1)) {
          if (digit < '0' || digit > '9' || scale == 1) {
            break;
          }

          scale /= decimal;
          fraction += (digit - '0') * scale;
        }
      }

      return (*whole * milliseconds_per_second) + fraction;
    }

    // When a xonsh command started and ended, in milliseconds: its `ts`, in seconds.
    std::pair<std::int64_t, std::int64_t> xonshTimes(const JsonValue& entry) {
      std::pair<std::int64_t, std::int64_t> times{};
      std::size_t index = 0;
      const auto found = entry.field("ts");

      if (!found) {
        return times;
      }

      found->eachElement([&](const JsonValue& time) {
        if (index == 0) {
          times.first = jsonMilliseconds(time.encoded());
        } else if (index == 1) {
          times.second = jsonMilliseconds(time.encoded());
        }

        ++index;
      });

      return times;
    }

    // A xonsh command's exit status, its `rtn`, when it fits a shell's.
    ds::Option<std::int32_t> xonshStatus(const JsonValue& entry) {
      const auto status = entry.field("rtn");
      if (!status) {
        return ds::none;
      }

      const auto encoded = status->encoded();
      const bool negative = encoded.starts_with('-');
      const auto value = digits(negative ? slice(encoded, 1) : encoded);
      if (!value || *value > std::numeric_limits<std::int32_t>::max()) {
        return ds::none;
      }

      return static_cast<std::int32_t>(negative ? -*value : *value);
    }

    // One xonsh session: `{"data": {"cmds": [{"inp": "ls\n", "ts": [start, end], ...}]}}`.
    void parseXonshSession(Memory& memory, std::string_view text, ImportSink& sink) {
      const auto root = JsonValue::parse(text);
      const auto data = root.field("data");
      const auto commands = data ? data->field("cmds") : ds::none;
      if (!commands) {
        return;
      }

      ds::String<Memory> input{memory};

      commands->eachElement([&](const JsonValue& entry) {
        const auto typed = entry.field("inp");
        if (!typed) {
          return;
        }

        constexpr std::int64_t nanoseconds_per_millisecond = 1000000;
        const auto times = xonshTimes(entry);
        const ImportedRun run{.exit_code = xonshStatus(entry), .duration_ns = std::max<std::int64_t>(0, times.second - times.first) * nanoseconds_per_millisecond};
        const auto started = times.first;

        input.clear();
        typed->string(input);
        auto command = input.view();

        while (command.ends_with('\n')) {
          command.remove_suffix(1);
        }

        if (command.size() > max_command_bytes) {
          sink.skipped(command.size());
        } else if (!command.empty()) {
          sink.command(started, command, run);
        }
      });
    }

    // When a session started, as its `data.ts` says, which orders the sessions of a directory.
    std::int64_t sessionStart(std::string_view text) {
      const auto data = JsonValue::parse(text).field("data");
      const auto times = data ? data->field("ts") : ds::none;
      std::int64_t started = 0;
      bool first = true;

      if (times) {
        times->eachElement([&](const JsonValue& time) {
          if (first) {
            started = jsonMilliseconds(time.encoded());
          }

          first = false;
        });
      }

      return started;
    }

  }

  void readXonsh(Memory& memory, const char* path, ImportSink& sink) {
    struct stat inode{};
    if (::lstat(path, &inode) != 0) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    if (!S_ISDIR(inode.st_mode)) {
      const auto file = readHistfile(memory, path);
      if (file.truncated) {
        throw std::runtime_error{"HistfileTooLarge"};
      }

      parseXonshSession(memory, file.text.view(), sink);
      return;
    }

    std::unique_ptr<DIR, decltype(&::closedir)> directory{::opendir(path), &::closedir};
    if (!directory) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    // Sessions are read oldest first: xonsh names each by its id, so their times order them.
    ds::Vec<ds::String<Memory>, Memory> names{memory};
    std::size_t visited = 0;

    while (const auto* entry = ::readdir(directory.get())) { // NOLINT(concurrency-mt-unsafe): this stream is the call's own
      const std::string_view name{std::data(entry->d_name)};
      if (!name.ends_with(".json") || entry->d_type != DT_REG) {
        continue;
      }

      if (++visited > max_session_files) {
        reportCommandLimit({.name = "history.import_session_files", .noun = "files", .value = max_session_files});
        break;
      }

      names.push(ds::format(memory, "{}/{}", path, name));
    }

    struct Session {
      std::size_t name;
      std::int64_t started;
    };

    ds::Vec<Session, Memory> sessions{memory};

    for (std::size_t index = 0; index < names.size(); ++index) {
      try {
        const auto file = readHistfile(memory, names[index].data());

        sessions.push({.name = index, .started = sessionStart(file.text.view())});
      } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a session xonsh cannot be read is skipped; the others still import
      }
    }

    std::ranges::stable_sort(sessions.viewMut(), {}, &Session::started);
    for (const auto& session : sessions) {
      try {
        const auto file = readHistfile(memory, names[session.name].data());

        parseXonshSession(memory, file.text.view(), sink);
      } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a session xonsh left half written is skipped; the others still import
      }
    }
  }

}
