module telar.runtime.paths.text_search;

import std;
import telar.sys.posix;
import telar.platform.error;
import telar.platform.process;
import telar.platform.primitives;
import telar.runtime.transport.connection;
import telar.runtime.workspaces.git_status;
import telar.wire.editor;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    using Clock = std::chrono::steady_clock;

    constexpr auto search_time = std::chrono::seconds{10};
    // A line is its path, two numbers, what separates them and its text.
    constexpr std::size_t line_capacity = TextMatch::maximum_path_bytes + TextMatch::maximum_text_bytes + 64;

    ds::Option<std::uint32_t> number(std::string_view digits) noexcept {
      std::uint32_t value = 0;
      const auto* end = digits.data() + digits.size();
      const auto parsed = std::from_chars(digits.data(), end, value);

      return parsed.ec == std::errc{} && parsed.ptr == end && !digits.empty() ? ds::Option<std::uint32_t>{value} : ds::none;
    }

    // The text of a match, cut to what a list shows at a character's edge and without the
    // blanks its line starts with.
    std::string_view shown(std::string_view text) noexcept {
      constexpr unsigned continuation_mask = 0xc0;
      constexpr unsigned continuation = 0x80;

      text.remove_prefix(std::min(text.find_first_not_of(" \t"), text.size()));
      if (text.size() <= TextMatch::maximum_text_bytes) {
        return text;
      }

      auto size = TextMatch::maximum_text_bytes;
      while (size > 0 && (static_cast<unsigned char>(text[size]) & continuation_mask) == continuation) {
        --size;
      }

      return text.substr(0, size);
    }

  }

  ds::Option<FileTextLine> FileTextLine::parse(std::string_view written) noexcept {
    const auto path_end = written.find('\0');
    if (path_end == std::string_view::npos || path_end == 0 || path_end > TextMatch::maximum_path_bytes) {
      return ds::none;
    }

    auto rest = written.substr(path_end + 1);
    // git ends each field with a NUL; ripgrep writes the numbers as `line:column:`.
    const char separator = rest.find('\0') == std::string_view::npos ? ':' : '\0';
    const auto line_end = rest.find(separator);
    const auto column_end = line_end == std::string_view::npos ? line_end : rest.find(separator, line_end + 1);
    if (column_end == std::string_view::npos) {
      return ds::none;
    }

    const auto line = number(rest.substr(0, line_end));
    const auto column = number(rest.substr(line_end + 1, column_end - line_end - 1));
    if (!line || !column) {
      return ds::none;
    }

    auto path = written.substr(0, path_end);

    // ripgrep names a file from the directory it was given.
    if (path.starts_with("./")) {
      path.remove_prefix(2);
    }

    return FileTextLine{.path = path, .line = *line, .column = *column, .text = shown(rest.substr(column_end + 1))};
  }

  FileTextSearch::FileTextSearch(ConcurrentMemory& memory)
      : memory_(memory),
        line_(memory),
        text_(memory),
        found_(memory) {}

  void FileTextSearch::keep(const FileTextLine& line) {
    found_.push({
        .path = static_cast<std::uint32_t>(text_.size()),
        .path_size = static_cast<std::uint16_t>(line.path.size()),
        .text_size = static_cast<std::uint16_t>(line.text.size()),
        .line = line.line,
        .column = line.column,
    });
    text_.extend(std::span<const char>{line.path});
    text_.extend(std::span<const char>{line.text});
  }

  bool FileTextSearch::feed(std::span<const Byte> bytes, std::size_t limit) {
    for (const auto byte : bytes) {
      const auto character = static_cast<char>(byte);
      if (character != '\n') {
        // A line longer than any match is passed over whole.
        if (line_.size() < line_capacity) {
          line_.push(character);
        } else {
          oversized_ = true;
        }

        continue;
      }

      const auto parsed = oversized_ ? ds::none : FileTextLine::parse(std::string_view{line_.data(), line_.size()});

      line_.clear();
      oversized_ = false;
      if (!parsed) {
        continue;
      }

      if (found_.size() == limit) {
        truncated_ = true;
        return false;
      }

      keep(*parsed);
    }

    return true;
  }

  void FileTextSearch::find(const FindText& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply) {
    if (!request.root.starts_with('/')) {
      throw RequestError{FailureCode::invalid_request, "A text search needs an absolute directory"};
    }

    line_.clear();
    oversized_ = false;
    text_.clear();
    found_.clear();
    truncated_ = false;

    const auto deadline = Clock::now() + search_time;
    const auto consume = [&](std::span<const Byte> bytes) {
      return feed(bytes, request.limit);
    };
    ds::Array<char, PATH_MAX> program{};
    const char* path = std::getenv("PATH"); // NOLINT(concurrency-mt-unsafe): the runtime does not change its environment once it started

    try {
      if (path != nullptr && findExecutable({.path = path, .program = "rg"}, std::span<char, PATH_MAX>{program.viewMut()})) {
        // Its own configuration file is left out: the search is the same for every user.
        const ds::Array<std::string_view, 12> arguments{
            program.data(),
            "--no-config",
            "--null",
            "--line-number",
            "--column",
            "--no-heading",
            "--color=never",
            "--fixed-strings",
            "--smart-case",
            "--max-columns=480",
            "--max-columns-preview",
            "-e",
        };
        ds::Array<std::string_view, 14> all{};

        std::ranges::copy(arguments, all.viewMut().begin());
        all.atMut(arguments.size()) = request.query;
        // The directory is named: without one, ripgrep reads its standard input when that is a pipe.
        all.atMut(arguments.size() + 1) = "./";

        Command command{memory_, Launch{.cwd = request.root, .arguments = all.view()}, CommandPurpose::administration};
        CommandOutput<ConcurrentMemory> output{memory_, line_capacity, &cancelled};

        static_cast<void>(output.stream(command, deadline, consume));
      } else {
        GitRepository git{memory_, request.root, deadline, cancelled};

        static_cast<void>(git.stream({"grep", "-n", "--column", "-I", "-F", "-z", "--no-color", "-e", request.query}, consume, deadline));
      }
    } catch (const SystemError&) {
      throw RequestError{FailureCode::invalid_request, "Searching text needs ripgrep, or git in a repository"};
    } catch (const RequestError&) {
      // Out of time, or ended for a newer search: what it found by then is what there is.
      if (found_.empty()) {
        throw;
      }

      truncated_ = true;
    }

    ds::Array<TextMatch, FindText::maximum_limit> matches{};
    const std::string_view text{text_.data(), text_.size()};

    for (std::size_t index = 0; index < found_.size(); ++index) {
      const auto& found = found_[index];

      matches.atMut(index) = {.path = text.substr(found.path, found.path_size), .line = found.line, .column = found.column, .text = text.substr(std::size_t{found.path} + found.path_size, found.text_size)};
    }

    reply.send(TextResults{.request_id = request.request_id, .root = request.root, .truncated = truncated_, .matches = matches.view().first(found_.size())});
  }

}
