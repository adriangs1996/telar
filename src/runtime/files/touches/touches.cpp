module telar.runtime.files.touches;

import std;
import telar.sys.posix;
import telar.runtime.files.entry;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;
import telar.base.text.utf8;

namespace telar::runtime {

  namespace {

    // What an agent's line starts with before the name of its tool.
    constexpr std::string_view tool_mark = "» ";

    constexpr bool blank(char character) noexcept {
      return character == ' ' || character == '\t';
    }

    // The next word of a command, taken off its front: a run without blanks, or what a pair of
    // quotes holds. Empty once nothing is left.
    constexpr std::string_view takeWord(std::string_view& rest) noexcept {
      while (!rest.empty() && blank(rest.front())) {
        rest.remove_prefix(1);
      }

      if (rest.empty()) {
        return {};
      }

      const char quote = rest.front() == '\'' || rest.front() == '"' ? rest.front() : '\0';
      std::size_t end = 0;

      if (quote != '\0') {
        rest.remove_prefix(1);
        end = std::min(rest.find(quote), rest.size());
      } else {
        while (end < rest.size() && !blank(rest[end])) {
          ++end;
        }
      }

      const std::string_view word{rest.data(), end};

      rest.remove_prefix(std::min(rest.size(), end + (quote != '\0' ? 1 : 0)));
      return word;
    }

    // A verb a row shows: the name of a program or a tool, without where it is.
    constexpr std::string_view verbOf(std::string_view word) noexcept {
      word.remove_prefix(word.find_last_of('/') + 1);

      const bool plain = !word.empty() && std::ranges::all_of(word, [](char character) {
        return character > ' ' && character < '\x7f';
      });

      if (!plain) {
        return {};
      }

      word.remove_suffix(word.size() - std::min<std::size_t>(word.size(), FileLimits::verb_bytes));
      return word;
    }

    constexpr bool below(std::string_view path, std::string_view directory) noexcept {
      if (directory == "/") {
        return path.size() > 1 && path.starts_with('/');
      }

      return path.size() > directory.size() + 1 && path.starts_with(directory) && path[directory.size()] == '/';
    }

    // A path as a command spells it, and the directory it is read from.
    struct Spelled {
      std::string_view directory;
      std::string_view word;
    };

    // Writes in `path` the path `spelled` names, with its `.` and `..` taken out. False for one
    // that climbs past the root.
    bool absolute(ds::String<ConcurrentMemory>& path, const Spelled& spelled) {
      const auto directory = spelled.directory;
      auto candidate = spelled.word;

      path.clear();
      if (candidate.starts_with("~/")) {
        path.assign(accountHome());
        candidate.remove_prefix(1);
      } else if (!candidate.starts_with('/')) {
        path.assign(directory);
      }

      while (!candidate.empty()) {
        const auto end = std::min(candidate.find('/'), candidate.size());
        const std::string_view part{candidate.data(), end};

        candidate.remove_prefix(std::min(candidate.size(), end + 1));
        if (part.empty() || part == ".") {
          continue;
        }

        if (part == "..") {
          const auto slash = path.view().find_last_of('/');
          if (slash == std::string_view::npos) {
            return false;
          }

          path.truncate(slash);
          continue;
        }

        if (path.view() != "/") {
          path.append("/");
        }

        path.append(part);
      }

      return path.size() > 1 && path.size() <= FileLimits::path_bytes;
    }

    // Whether `path` is text a reply carries: UTF-8 with no control character in it.
    bool sendable(std::string_view path) noexcept {
      return inspectUtf8(path) == Utf8Validation::valid && std::ranges::none_of(path, [](char character) {
        return static_cast<unsigned char>(character) < ' ' || character == '\x7f';
      });
    }

  }

  TouchIndex::Pending::Pending(ConcurrentMemory& memory)
      : text(memory),
        directory(memory) {}

  TouchIndex::Touch::Touch(ConcurrentMemory& memory)
      : path(memory) {}

  TouchIndex::TouchIndex(ConcurrentMemory& memory)
      : memory_(memory),
        pending_(memory),
        touches_(memory),
        path_(memory) {}

  void TouchIndex::note(const TouchNote& note) noexcept {
    // A command as long as a path can be names no more files than its first words do.
    if (note.text.empty() || note.text.size() > FileLimits::path_bytes || !note.directory.starts_with('/') || note.directory.size() > FileLimits::path_bytes) {
      return;
    }

    try {
      const std::scoped_lock lock{mutex_};

      if (pending_.size() == pending_notes) {
        static_cast<void>(pending_.remove(0));
      }

      auto& kept = pending_.push(Pending{memory_});

      kept.pane = note.pane;
      kept.actor = note.actor;
      kept.provider = note.provider;
      kept.seconds = note.seconds;
      kept.text.assign(note.text);
      kept.directory.assign(note.directory);
    } catch (...) { // NOLINT(bugprone-empty-catch): a note that found no memory is a touch not shown
    }
  }

  bool TouchIndex::keep(const Pending& note, const Mention& mention) {
    const auto verb = mention.verb;
    const auto candidate = mention.word;

    if (candidate.empty() || candidate.starts_with('-') || !absolute(path_, {.directory = note.directory.view(), .word = candidate}) || !below(path_.view(), note.directory.view()) || !sendable(path_.view())) {
      return false;
    }

    struct stat status{};
    if (::lstat(path_.data(), &status) != 0 || kindOf(status.st_mode) != FileKind::file) {
      return false;
    }

    // A command the history records names no agent: it is by the one whose tools the pane last
    // reported, where one did.
    auto provider = note.provider;
    if (note.actor == TouchActor::agent && provider == AgentProvider::unknown) {
      for (const auto& touch : touches_) {
        if (touch.pane == note.pane && touch.provider != AgentProvider::unknown) {
          provider = touch.provider;
        }
      }
    }

    // One touch of a file by the same hand and verb: the last time it happened.
    touches_.retain([&](const Touch& touch) {
      return !(touch.pane == note.pane && touch.actor == note.actor && touch.provider == provider && touch.verb.view() == verb && touch.path.view() == path_.view());
    });

    if (touches_.size() == kept_touches) {
      static_cast<void>(touches_.remove(0));
    }

    auto& touch = touches_.push(Touch{memory_});

    touch.path.assign(path_.view());
    touch.verb.assign(verb);
    touch.pane = note.pane;
    touch.actor = note.actor;
    touch.provider = provider;
    touch.seconds = note.seconds;
    touch.size = static_cast<std::uint64_t>(std::max<std::int64_t>(0, status.st_size));
    return true;
  }

  void TouchIndex::resolve() {
    ds::Vec<Pending, ConcurrentMemory> notes{memory_};

    {
      const std::scoped_lock lock{mutex_};

      std::swap(notes, pending_);
    }

    for (const auto& note : notes) {
      auto rest = note.text.view();
      const bool tool = rest.starts_with(tool_mark);

      if (tool) {
        rest.remove_prefix(tool_mark.size());
      }

      const auto verb = verbOf(takeWord(rest));
      if (verb.empty()) {
        continue;
      }

      // A tool is given one path, which may hold blanks; a command, words.
      auto whole = rest;

      while (!whole.empty() && blank(whole.front())) {
        whole.remove_prefix(1);
      }

      if (tool && keep(note, {.verb = verb, .word = whole})) {
        continue;
      }

      for (std::size_t word = 0; word < command_words && !rest.empty(); ++word) {
        static_cast<void>(keep(note, {.verb = verb, .word = takeWord(rest)}));
      }
    }
  }

  void TouchIndex::answer(const QueryTouches& request, EncodedReply<ConcurrentMemory>& reply) {
    if (!request.path.starts_with('/')) {
      throw RequestError{FailureCode::invalid_request, "The touches of a directory need its absolute path"};
    }

    resolve();

    // What is older than a day is no longer what someone is working on.
    const auto now = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());

    touches_.retain([&](const Touch& touch) {
      return touch.seconds + kept_seconds >= now;
    });

    ds::Array<FileTouch, FileLimits::maximum_touches> listed{};
    std::size_t count = 0;
    bool truncated = false;

    for (const auto& touch : touches_ | std::views::reverse) {
      if (touch.path.view() != request.path && !below(touch.path.view(), request.path)) {
        continue;
      }

      if (count == listed.size()) {
        truncated = true;
        break;
      }

      listed.atMut(count++) = {.path = touch.path.view(), .actor = touch.actor, .provider = touch.provider, .pane_id = touch.pane, .verb = touch.verb.view(), .seconds = touch.seconds, .size = touch.size};
    }

    reply.send(FileTouches{.request_id = request.request_id, .path = request.path, .truncated = truncated, .touches = listed.view().first(count)});
  }

}
