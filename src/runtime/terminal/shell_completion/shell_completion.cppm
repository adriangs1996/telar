export module telar.runtime.terminal.shell_completion;

import std;
import telar.sys.posix;
import telar.sys.socket;
import telar.tbc;

import telar.wire.vocabulary;
import telar.wire.editor;
import telar.platform.process;
import telar.runtime.terminal.shell_integration.words;
import telar.runtime.workers.request_worker;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// What the pane's own shell would complete at the end of a line, for a command no spec
// describes. The shell runs apart from the pane, in a process of its own that reads no
// configuration unless the user asks for it, with the pane's directory and PATH and nothing else
// of its environment; the line reaches it as an argument, never as code it runs or keys it reads.
// A pane `ssh` reached is asked on its host, through the connection its session shares, with a
// command of the runtime's own and the line on standard input.
export namespace telar::runtime {

  // What a request asks: the words the shell would complete at the end of the line, or, on a host
  // `ssh` reached, the entries of the one directory the line's word names, as typed: files, only
  // directories, or directories and the programs there; or the words a provider offers there,
  // which the line begins.
  enum class ShellQuestion : std::uint8_t {
    line,
    paths,
    directories,
    executables,
    provider,
  };

  struct ShellCompletionRequest {
    static constexpr std::size_t line_bytes = 256;
    static constexpr std::size_t path_bytes = 8192;
    static constexpr std::size_t control_bytes = sizeof(sockaddr_un::sun_path) - 1;

    std::uint64_t client = 0;
    std::uint64_t request = 0;
    std::uint64_t pane = 0;
    IntegratedShell shell = IntegratedShell::none;
    // The line from its start to the cursor.
    FixedText<line_bytes> line;
    FixedText<PATH_MAX> directory;
    FixedText<PATH_MAX> home;
    // This host's PATH, where the shell or, for a remote pane, ssh is found.
    FixedText<path_bytes> path;
    ShellQuestion question = ShellQuestion::line;
    // The socket of the ssh connection the pane's session shares: the question goes to that host,
    // where `shell` is the remote shell and `directory` its own, empty for the home it starts in.
    // Empty asks this host, and only for a line.
    FixedText<control_bytes> control;
    // For ShellQuestion::provider: the host's branches, targets, processes or commands, read in
    // `directory` as this host's own provider reads them here.
    CompletionProvider provider = CompletionProvider::shell;
  };

  using ShellWord = Word;

  // Built on the worker's thread and dropped on the runtime's, so its text lives in memory both
  // can reach, region `a`. Each word stands for the whole word the cursor ends, unquoted.
  struct ShellCompletionResult {
    explicit ShellCompletionResult(tbc::mut_a<ConcurrentMemory> memory);

    std::uint64_t client = 0;
    std::uint64_t request = 0;
    std::uint64_t pane = 0;
    tbc::val_a<ds::Vec<ShellWord, ConcurrentMemory>> words;
    bool truncated = false;
  };

  struct ShellCompletionOptions {
    static constexpr auto default_time = std::chrono::milliseconds{1500};

    // The user may turn the shell's completion off.
    bool enabled = true;
    // The shell reads the user's own configuration, .zshrc, .bashrc or config.fish, which only
    // the user may ask for: it runs whatever that configuration runs.
    bool user_configuration = false;
    // A directory only the user may write, where zsh keeps the dump that makes it start fast;
    // empty for none.
    std::string_view cache_directory;
    // The runtime's private directory for the sockets of the connections ssh shares, where a
    // request's socket is taken; outside it, only one in a directory nobody else may write.
    std::string_view control_directory;
    // How long a shell may take before it is ended and its line has no words.
    std::chrono::milliseconds time = default_time;
  };

  // Runs one shell at a time, on the worker's thread. The answers of the last few lines are kept
  // for a few seconds, by shell, line and directory.
  class ShellCompleter {
  public:
    using Request = ShellCompletionRequest;
    using Result = ShellCompletionResult;

    static constexpr std::size_t maximum_words = 256;
    static constexpr std::size_t maximum_word_bytes = 256;
    static constexpr std::size_t maximum_output = std::size_t{64} * 1024;
    static constexpr std::size_t remembered = 8;
    static constexpr auto kept = std::chrono::seconds{5};

    // `cancelled` ends the shell running when it turns true, as stopping does; the caller resets
    // it between requests.
    ShellCompleter(tbc::mut_a<ConcurrentMemory> memory, tbc::mut_a<std::atomic<bool>> cancelled, const ShellCompletionOptions& options);

    tbc::val_a<Result> observe(const Request& request) noexcept;

    void stop() noexcept;

  private:
    using Clock = std::chrono::steady_clock;

    struct Answer {
      IntegratedShell shell = IntegratedShell::none;
      ShellQuestion question = ShellQuestion::line;
      CompletionProvider provider = CompletionProvider::shell;
      tbc::val_a<ds::String<ConcurrentMemory>> control;
      tbc::val_a<ds::String<ConcurrentMemory>> line;
      tbc::val_a<ds::String<ConcurrentMemory>> directory;
      Clock::time_point when;
      tbc::val_a<ds::Vec<ShellWord, ConcurrentMemory>> words;
      bool truncated = false;
    };

    // How an answer is read: from a host, after the byte that `starts` it; from zsh, up to the
    // record separator that `ends` it; and whether one `cut` at the bound keeps its whole lines,
    // as a directory's entries do.
    struct Framing {
      bool starts = false;
      bool ends = false;
      bool cut = false;
    };

    // Runs the shell; false when it was cancelled, ran out of time or could not start.
    bool run(const Request& request, tbc::mut_a<Result> result);
    // Asks the host of the request's connection, through ssh.
    bool runRemote(const Request& request, std::string_view path, tbc::mut_a<Result> result);
    // Waits for the answer to the request, writing `input` to the command.
    bool collect(const Request& request, Command<ConcurrentMemory>& command, Framing framing, std::span<const std::string_view> input, tbc::mut_a<Result> result);
    // Reads what the shell wrote: a word a line, its description after a tab; or what the host
    // printed for a provider, as that provider reads it.
    void read(const Request& request, std::string_view output, tbc::mut_a<Result> result) const;
    void remember(const Request& request, const Result& result);
    // The zsh dump's file, in a directory made for it; empty when it cannot be one only the user
    // may write.
    std::string_view dump();

    tbc::mut_a<ConcurrentMemory> memory_;
    tbc::mut_a<std::atomic<bool>> cancelled_;
    bool user_configuration_;
    std::chrono::milliseconds time_;
    tbc::val_a<ds::String<ConcurrentMemory>> cache_directory_;
    tbc::val_a<ds::String<ConcurrentMemory>> control_directory_;
    tbc::val_a<ds::String<ConcurrentMemory>> dump_;
    bool dump_checked_ = false;

    // The runtime's locale, so a shell reads the names of files as the pane's does.
    struct LocaleVariable {
      std::string_view name;
      tbc::val_a<ds::String<ConcurrentMemory>> value;
    };

    tbc::val_a<ds::Vec<LocaleVariable, ConcurrentMemory>> locale_;
    tbc::val_a<ds::Vec<Answer, ConcurrentMemory>> answers_;
  };

  // Who asked: a request the service let go without answering, which the caller answers with no
  // words, or the one a result answers.
  struct ShellCompletionAsked {
    std::uint64_t client = 0;
    std::uint64_t request = 0;
  };

  // One shell at a time; a pane waits with its latest line only, for each question one Tab asks.
  // A newer line of the pane whose shell runs that question ends that shell, which answers with
  // no words: the person typed on.
  class ShellCompletionService {
  public:
    static constexpr std::size_t waiting_requests = 8;

    ShellCompletionService(tbc::mut_a<ConcurrentMemory> memory, const ShellCompletionOptions& options);

    ShellCompletionService(const ShellCompletionService&) = delete;
    ShellCompletionService& operator=(const ShellCompletionService&) = delete;
    ShellCompletionService(ShellCompletionService&&) = delete;
    ShellCompletionService& operator=(ShellCompletionService&&) = delete;
    ~ShellCompletionService() = default;

    [[nodiscard]] bool enabled() const noexcept;

    // The service keeps the request until its turn comes. A request it replaces or makes room
    // by letting go comes back, to be answered.
    [[nodiscard]] ds::Option<ShellCompletionAsked> request(const ShellCompletionRequest& request);

    // The consumer is the caller's type; the worker's collect is a template over it too.
    template <typename Consumer>
    [[tbc::generic]] inline void collect(Consumer&& consume) {
      worker_.collect([&](const ShellCompletionResult& result) {
        running_ = false;
        std::forward<Consumer>(consume)(result);
      });

      startNext();
    }

    [[nodiscard]] int descriptor() const noexcept;

  private:
    void startNext();

    bool enabled_;
    std::atomic<bool> cancelled_{false};
    tbc::val_a<ObservationWorker<ShellCompleter>> worker_;
    tbc::val_a<ds::Vec<ShellCompletionRequest, ConcurrentMemory>> waiting_;
    // The pane whose shell runs, and what it asks, while one does.
    bool running_ = false;
    std::uint64_t running_pane_ = 0;
    ShellQuestion running_question_ = ShellQuestion::line;
    CompletionProvider running_provider_ = CompletionProvider::shell;
  };

}
