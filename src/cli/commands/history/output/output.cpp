module telar.cli.commands.history.output;

import std;
import telar.sys.posix;
import telar.cli.console.command_limit;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::runtime::cli::history {

  namespace {

    constexpr std::int64_t milliseconds_per_second = 1000;
    constexpr std::int64_t nanoseconds_per_millisecond = 1000000;
    constexpr int tm_year_base = 1900;

    enum class Field : std::uint8_t {
      id,
      time,
      timestamp,
      duration,
      exit,
      status,
      author,
      provider,
      cwd,
      workspace,
      command,
    };

    constexpr ds::Array<std::string_view, 11> field_names{"id", "time", "timestamp", "duration", "exit", "status", "author", "provider", "cwd", "workspace", "command"};

    ds::Option<Field> fieldNamed(std::string_view name) noexcept {
      for (std::size_t index = 0; index < field_names.size(); ++index) {
        if (field_names[index] == name) {
          return static_cast<Field>(index);
        }
      }

      return ds::none;
    }

    std::string_view statusName(HistoryStatus status) noexcept {
      switch (status) {
      case HistoryStatus::completed:
        return "completed";
      case HistoryStatus::interrupted:
        return "interrupted";
      case HistoryStatus::running:
        return "running";
      }

      return "unknown";
    }

    std::string_view originName(HistoryOrigin origin) noexcept {
      switch (origin) {
      case HistoryOrigin::pane:
        return "pane";
      case HistoryOrigin::hook:
        return "hook";
      case HistoryOrigin::plugin:
        return "plugin";
      }

      return "unknown";
    }

    std::int64_t durationMilliseconds(const HistoryEntry& entry) noexcept {
      return std::max<std::int64_t>(0, entry.duration_ns / nanoseconds_per_millisecond);
    }

    std::int64_t startSeconds(const HistoryEntry& entry) noexcept {
      return std::max<std::int64_t>(0, entry.started_at_ms / milliseconds_per_second);
    }

    void printTime(DescriptorWriter& output, const HistoryEntry& entry) {
      const auto seconds = static_cast<std::time_t>(startSeconds(entry));
      std::tm utc{};

      ::gmtime_r(&seconds, &utc);
      output.print("{:04}-{:02}-{:02} {:02}:{:02}:{:02}Z", utc.tm_year + tm_year_base, utc.tm_mon + 1, utc.tm_mday, utc.tm_hour, utc.tm_min, utc.tm_sec);
    }

    // RUN, INT, the exit code, or ? when it is unknown.
    void printStatus(DescriptorWriter& output, const HistoryEntry& entry) {
      if (entry.status == HistoryStatus::running) {
        output.print("RUN");
      } else if (entry.status == HistoryStatus::interrupted) {
        output.print("INT");
      } else if (entry.exit_code) {
        output.print("{}", *entry.exit_code);
      } else {
        output.print("?");
      }
    }

    void printField(DescriptorWriter& output, const HistoryEntry& entry, Field field) {
      switch (field) {
      case Field::id:
        output.print("{}", entry.id);
        return;
      case Field::time:
        printTime(output, entry);
        return;
      case Field::timestamp:
        output.print("{}", entry.started_at_ms);
        return;
      case Field::duration:
        output.print("{}", durationMilliseconds(entry));
        return;
      case Field::exit:
        if (entry.exit_code) {
          output.print("{}", *entry.exit_code);
        }

        return;
      case Field::status:
        printStatus(output, entry);
        return;
      case Field::author:
        output.print("{}", entry.author == HistoryAuthor::agent ? "agent" : "human");
        return;
      case Field::provider:
        output.print("{}", EscapedField{entry.provider});
        return;
      case Field::cwd:
        output.print("{}", EscapedField{entry.cwd});
        return;
      case Field::workspace:
        output.print("{}", EscapedField{entry.workspace_path});
        return;
      case Field::command:
        output.print("{}", EscapedField{entry.command});
        return;
      }
    }

    // What a template's `\t`, `\n` or `\\` stands for; none for another escape, which stays as written.
    ds::Option<std::string_view> escapeOf(char letter) noexcept {
      switch (letter) {
      case 't':
        return "\t";
      case 'n':
        return "\n";
      case '\\':
        return "\\";
      default:
        return ds::none;
      }
    }

    // Walks a template: `literal` for each run of text, `field` for each placeholder.
    template <typename Literal, typename Placeholder>
    void walkTemplate(std::string_view text, Literal literal, Placeholder placeholder) {
      while (!text.empty()) {
        const auto special = text.find_first_of("{\\");

        literal(text.substr(0, special));
        if (special == std::string_view::npos) {
          return;
        }

        if (text[special] == '\\') {
          const auto next = special + 1 < text.size() ? text[special + 1] : '\\';

          literal(escapeOf(next).valueOr(text.substr(special, 2)));
          text.remove_prefix(std::min(special + 2, text.size()));
          continue;
        }

        const auto close = text.find('}', special);
        const auto field = close == std::string_view::npos ? ds::none : fieldNamed(text.substr(special + 1, close - special - 1));
        if (!field) {
          throw std::invalid_argument{"UnknownHistoryField"};
        }

        placeholder(*field);
        text.remove_prefix(close + 1);
      }
    }

    void printJson(DescriptorWriter& output, const HistoryEntry& entry) {
      output.print(R"({{"id":{},"pane_id":{},"started_at_ms":{},"duration_ms":{},"exit_code":{},"status":{},"author":{},"origin":{},"provider":{},"cwd":{},"workspace":{},"command":{},"command_truncated":{}}})", entry.id, entry.pane_id, entry.started_at_ms, durationMilliseconds(entry), orNull(entry.exit_code), quoteJson(statusName(entry.status)), quoteJson(entry.author == HistoryAuthor::agent ? "agent" : "human"), quoteJson(originName(entry.origin)), quoteJson(entry.provider), quoteJson(entry.cwd), quoteJson(entry.workspace_path), quoteJson(entry.command), entry.command_truncated ? "true" : "false");
      output.print("\n");
    }

    void printText(DescriptorWriter& output, const HistoryEntry& entry) {
      output.print("#{}  ", entry.id);
      printTime(output, entry);
      output.print("  ");
      printStatus(output, entry);
      output.print("  {}ms  {}  ", durationMilliseconds(entry), EscapedField{entry.cwd});
      if (entry.author == HistoryAuthor::agent && !entry.provider.empty()) {
        output.print("\x1b[2m[{}]\x1b[22m ", EscapedField{entry.provider});
      }

      output.print("{}\n", EscapedField{entry.command});
    }

    // zsh's extended format, its newlines as a backslash that ends the line and the bytes it treats
    // specially metafied, as zsh reads them back: Meta (0x83) and the byte with bit 5 flipped.
    void printZsh(DescriptorWriter& output, const HistoryEntry& entry) {
      constexpr unsigned char first_meta = 0x83;
      constexpr unsigned char last_meta = 0xa2;
      constexpr unsigned char meta_bit = 0x20;

      output.print(": {}:{};", startSeconds(entry), durationMilliseconds(entry) / milliseconds_per_second);
      for (const auto byte : entry.command) {
        const auto value = static_cast<unsigned char>(byte);

        if (byte == '\n') {
          output.print("\\\n");
        } else if (value >= first_meta && value <= last_meta) {
          output.print("{}{}", static_cast<char>(first_meta), static_cast<char>(value ^ meta_bit));
        } else {
          output.print("{}", byte);
        }
      }

      output.print("\n");
    }

    // bash with HISTTIMEFORMAT: the time as a comment, then the command's lines as they are.
    void printBash(DescriptorWriter& output, const HistoryEntry& entry) {
      output.print("#{}\n{}\n", startSeconds(entry), entry.command);
    }

    void printFish(DescriptorWriter& output, const HistoryEntry& entry) {
      output.print("- cmd: ");
      for (const auto byte : entry.command) {
        if (byte == '\n') {
          output.print("\\n");
        } else if (byte == '\\') {
          output.print("\\\\");
        } else {
          output.print("{}", byte);
        }
      }

      output.print("\n  when: {}\n", startSeconds(entry));
    }

  }

  void checkTemplate(std::string_view text) {
    walkTemplate(text, [](std::string_view) {}, [](Field) {});
  }

  void printEntry(DescriptorWriter& output, const HistoryEntry& entry, EntryStyle style, std::string_view format) {
    switch (style) {
    case EntryStyle::text:
      printText(output, entry);
      return;
    case EntryStyle::json:
      printJson(output, entry);
      return;
    case EntryStyle::format:
      walkTemplate(
          format,
          [&](std::string_view text) {
            output.print("{}", text);
          },
          [&](Field field) {
            printField(output, entry, field);
          }
      );
      output.print("\n");
      return;
    case EntryStyle::zsh:
      printZsh(output, entry);
      return;
    case EntryStyle::bash:
      printBash(output, entry);
      return;
    case EntryStyle::fish:
      printFish(output, entry);
      return;
    }
  }

}
