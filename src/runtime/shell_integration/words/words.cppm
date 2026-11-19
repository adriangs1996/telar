module;
#include "tbc/annotations.hpp"

export module telar.runtime.shell_integration.words;

import std;
import telar.sys.posix;

import telar.git;
import telar.wire.vocabulary;
import telar.wire.editor;
import telar.runtime.platform.request_worker;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;
import telar.tbc;

// The values a completion spec leaves to the runtime, found where the shell runs: commands on
// its PATH, the repository's branches, the hosts in the SSH configuration and the targets of
// the makefile in its directory. Read on a worker, so a slow file system never stalls panes.
export namespace telar::runtime {

  struct WordRequest {
    std::uint64_t client = 0;
    std::uint64_t request = 0;
    CompletionProvider provider = CompletionProvider::command;
    FixedText<256> prefix;
    FixedText<PATH_MAX> directory;
    FixedText<PATH_MAX> home;
    FixedText<8192> path;
    // The shell whose builtins and keywords count as commands, and the aliases and functions
    // it reported; without them a missing command cannot be told from an unreported one.
    IntegratedShell shell = IntegratedShell::none;
    tbc::view<std::shared_ptr<const ds::String<ConcurrentMemory>>, tbc::lt::a> names;
    // Asks for the completion spec of the command `prefix` names instead of words, and the
    // digest of the spec the client already holds.
    bool spec = false;
    std::uint64_t known_digest = 0;
  };

  struct Word {
    tbc::view<ds::String<ConcurrentMemory>, tbc::lt::a> text;
    tbc::view<ds::String<ConcurrentMemory>, tbc::lt::a> description;

    bool operator==(const Word&) const = default;
    auto operator<=>(const Word&) const = default;
  };

  // Built on the worker's thread and dropped on the runtime's, so its text lives in memory both
  // can reach, region `a`.
  struct WordResult {
    explicit WordResult(tbc::view<ConcurrentMemory&, tbc::lt::a> memory);

    std::uint64_t client = 0;
    std::uint64_t request = 0;
    tbc::view<ds::Vec<Word, ConcurrentMemory>, tbc::lt::a> words;
    bool truncated = false;
    // For a spec request: the command, whether a spec describes it where the shell runs, and
    // the spec when the client does not hold it already.
    bool spec = false;
    tbc::view<ds::String<ConcurrentMemory>, tbc::lt::a> command;
    CommandSpecState spec_state = CommandSpecState::unavailable;
    std::uint64_t digest = 0;
    tbc::view<ds::String<ConcurrentMemory>, tbc::lt::a> source;
    // The words an alias stands for, when the command is one.
    tbc::view<ds::String<ConcurrentMemory>, tbc::lt::a> expansion;
  };

  // The completion specs telar ships, by the command they describe.
  std::span<const std::pair<std::string_view, std::string_view>> shippedSpecs() noexcept;

  class WordReader {
  public:
    using Request = WordRequest;
    using Result = WordResult;

    static constexpr std::size_t maximum_words = 256;
    static constexpr std::size_t maximum_file = 1 << 20;
    static constexpr std::size_t maximum_entries = 65536;

    // User specs come from `completions` in the configuration directory the runtime resolved.
    // What it reads and returns lives in `memory`, which must outlive the reader and its results.
    explicit WordReader(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, std::string_view configuration_directory = {});

    tbc::view<Result, tbc::lt::a> observe(const Request& request) noexcept;

    void stop() noexcept;

  private:
    // The spec of the command the request names, when the shell runs it: the user's own from
    // the completions directory when it compiles, else the one telar ships.
    void spec(const Request& request, tbc::view<Result&, tbc::lt::a> result);

    // The user's spec for `name`, from the completions directory beside the configuration;
    // empty when there is none or it does not compile.
    tbc::view<ds::String<ConcurrentMemory>, tbc::lt::a> userSpec(std::string_view name);

    tbc::view<ConcurrentMemory&, tbc::lt::a> memory_;
    tbc::view<ds::String<ConcurrentMemory>, tbc::lt::a> completions_;
    tbc::view<git::StatusReader, tbc::lt::a> git_;
    // Whether each user spec, by digest, compiled: a spec is compiled once, not per request.
    tbc::view<ds::Map<std::uint64_t, bool, ConcurrentMemory>, tbc::lt::a> compiled_;
  };

  // One query at a time; later ones wait in order, at most a few per client.
  class WordService {
  public:
    explicit WordService(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, std::string_view configuration_directory = {});

    // The service keeps the request, and the names it shares, until its turn comes.
    void request(tbc::holds<const WordRequest&, tbc::lt::a> request);

    // The consumer is the caller's type; the queue's collect is a template over it too.
    template <typename Consumer>
    TBC_GENERIC inline void collect(Consumer&& consume) {
      queue_.collect(worker_, std::forward<Consumer>(consume));
    }

    int descriptor() const noexcept;

  private:
    tbc::view<ObservationWorker<WordReader>, tbc::lt::a> worker_;
    tbc::view<SerialQueue<WordRequest>, tbc::lt::a> queue_;
  };

}
