export module telar.runtime.files.touches;

import std;

import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

export namespace telar::runtime {

  // Something a pane did that may have touched files: a command its shell finished, or the line
  // an agent reports of the tool it runs (`» Edit src/main.cpp`).
  struct TouchNote {
    std::uint64_t pane = 0;
    TouchActor actor = TouchActor::user;
    AgentProvider provider = AgentProvider::unknown;
    // The command, or the agent's line with its mark.
    std::string_view text;
    // Where the pane was: what a relative path starts from, and what a touch stays below.
    std::string_view directory;
    std::uint64_t seconds = 0;
  };

  // Who touched which file of this machine, lately: the files the commands of the panes and the
  // tools of their agents named. A note costs the runtime a copy: what it names is looked up when
  // an explorer asks, on the files worker, and never by reading a directory.
  class TouchIndex {
  public:
    // The notes that wait for an explorer to ask, the touches kept, and how old one may be.
    static constexpr std::size_t pending_notes = 128;
    static constexpr std::size_t kept_touches = 512;
    static constexpr std::uint64_t kept_seconds = std::uint64_t{24} * 60 * 60;
    // The words of a command looked at for the files they name.
    static constexpr std::size_t command_words = 16;

    explicit TouchIndex(ConcurrentMemory& memory);

    // Keeps the note for the next answer. From any thread; a note that finds no room or no memory
    // is a touch not shown.
    void note(const TouchNote& note) noexcept;

    // Sends the FileTouches below `request.path`, the newest first. Throws RequestError for a
    // path that is not absolute.
    void answer(const QueryTouches& request, EncodedReply<ConcurrentMemory>& reply);

  private:
    struct Pending {
      explicit Pending(ConcurrentMemory& memory);

      std::uint64_t pane = 0;
      TouchActor actor = TouchActor::user;
      AgentProvider provider = AgentProvider::unknown;
      std::uint64_t seconds = 0;
      ds::String<ConcurrentMemory> text;
      ds::String<ConcurrentMemory> directory;
    };

    struct Touch {
      explicit Touch(ConcurrentMemory& memory);

      ds::String<ConcurrentMemory> path;
      FixedText<FileLimits::verb_bytes> verb;
      std::uint64_t pane = 0;
      TouchActor actor = TouchActor::user;
      AgentProvider provider = AgentProvider::unknown;
      std::uint64_t seconds = 0;
    };

    // Looks up what the notes that wait name, and keeps the files among it.
    void resolve();

    // A word of a note that may name a file, and the verb the note gives what it touches.
    struct Mention {
      std::string_view verb;
      std::string_view word;
    };

    // Keeps the file the mention names from the note's directory, if it is one below it.
    bool keep(const Pending& note, const Mention& mention);

    ConcurrentMemory& memory_;
    std::mutex mutex_;
    // Guarded by `mutex_`: the runtime's thread adds, the worker takes them all.
    ds::Vec<Pending, ConcurrentMemory> pending_;
    // The worker's own, the oldest first.
    ds::Vec<Touch, ConcurrentMemory> touches_;
    ds::String<ConcurrentMemory> path_;
  };

}
