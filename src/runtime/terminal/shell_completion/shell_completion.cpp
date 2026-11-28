module telar.runtime.terminal.shell_completion;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.platform.process;
import telar.runtime.terminal.shell_completion.remote;
import telar.wire.vocabulary;
import telar.wire.editor;
import telar.runtime.terminal.shell_integration.words;
import telar.base.memory.allocators;
import telar.base.ds;
import telar.base.text.utf8;

namespace telar::runtime {

  namespace scripts {

#include "shell_completion_scripts.inc"

  }

  namespace {

    // Ends the answer zsh writes: its shell under the pty lives on until the pty closes.
    constexpr char answer_end = '\x1e';
    constexpr auto first_printable = static_cast<unsigned char>(' ');
    constexpr auto delete_character = static_cast<unsigned char>('\x7f');

    bool printable(std::string_view text) noexcept {
      const auto control = [](char character) {
        const auto byte = static_cast<unsigned char>(character);

        return byte < first_printable || byte == delete_character;
      };

      return inspectUtf8(text) == Utf8Validation::valid && std::ranges::none_of(text, control);
    }

    // Whether a shell may be given `line`. The shells' own completion evaluates parts of what it
    // reads: zsh expands a command substitution and a glob's qualifiers to find paths, and
    // bash-completion evaluates a word that starts with `'$` to unquote it. Without parentheses
    // or backquotes, quoted or not, none of them can run a command, and a line that starts with a
    // dash could be read as the shell's own option.
    bool completable(std::string_view line) noexcept {
      const auto start = line.find_first_not_of(" \t");

      return start != std::string_view::npos && line[start] != '-' && line.find_first_of("()`") == std::string_view::npos && printable(line);
    }

    std::string_view programOf(IntegratedShell shell) noexcept {
      switch (shell) {
      case IntegratedShell::zsh:
        return "zsh";
      case IntegratedShell::bash:
        return "bash";
      case IntegratedShell::fish:
        return "fish";
      case IntegratedShell::none:
        break;
      }

      return {};
    }

    // The word remote.sh reads for the entries of a directory.
    std::string_view listingQuestion(ShellQuestion question) noexcept {
      switch (question) {
      case ShellQuestion::paths:
        return "paths";
      case ShellQuestion::directories:
        return "directories";
      case ShellQuestion::executables:
        return "executables";
      case ShellQuestion::line:
      case ShellQuestion::provider:
        break;
      }

      return {};
    }

    // The word remote.sh reads for what a provider reads on the host; empty for one it cannot.
    std::string_view providerQuestion(CompletionProvider provider) noexcept {
      switch (provider) {
      case CompletionProvider::command:
        return "commands";
      case CompletionProvider::branch:
        return "branches";
      case CompletionProvider::reference:
        return "references";
      case CompletionProvider::remote:
        return "remotes";
      case CompletionProvider::stash:
        return "stashes";
      case CompletionProvider::process:
        return "processes";
      case CompletionProvider::make_target:
        return "makefile";
      case CompletionProvider::just_recipe:
        return "justfile";
      case CompletionProvider::package_script:
        return "package";
      case CompletionProvider::compose_service:
        return "compose";
      case CompletionProvider::ssh_host:
      case CompletionProvider::path:
      case CompletionProvider::directory:
      case CompletionProvider::executable:
      case CompletionProvider::shell:
        break;
      }

      return {};
    }

    // Whether the host answers a list a line each, which an answer cut at the bound keeps whole
    // lines of; a file cut there would read as another.
    bool listed(CompletionProvider provider) noexcept {
      return provider == CompletionProvider::command || provider == CompletionProvider::branch || provider == CompletionProvider::reference || provider == CompletionProvider::remote || provider == CompletionProvider::process;
    }

    // What a shell writes, kept until its answer ends: after the byte that starts it when it is
    // framed, up to the record separator that ends it, and at most `limit` bytes of either.
    class Answering {
    public:
      Answering(ConcurrentMemory& memory, bool framed, std::size_t limit)
          : written_(memory),
            started_(!framed),
            limit_(limit) {}

      // False once nothing more is read.
      bool take(std::span<const Byte> bytes) {
        return std::ranges::all_of(bytes, [this](Byte byte) {
          return step(static_cast<char>(byte));
        });
      }

      [[nodiscard]] bool started() const noexcept {
        return started_;
      }

      [[nodiscard]] bool ended() const noexcept {
        return ended_;
      }

      [[nodiscard]] bool full() const noexcept {
        return written_.size() == limit_;
      }

      [[nodiscard]] std::string_view text() const noexcept {
        return {written_.data(), written_.size()};
      }

    private:
      bool step(char character) {
        if (!started_) {
          started_ = character == remote_completion::answer_start;
          return ++skipped_ != limit_;
        }

        if (character == answer_end) {
          ended_ = true;
          return false;
        }

        if (full()) {
          return false;
        }

        written_.push(character);
        return true;
      }

      ds::Vec<char, ConcurrentMemory> written_;
      bool started_;
      bool ended_ = false;
      std::size_t skipped_ = 0;
      std::size_t limit_;
    };

    std::string_view trimmed(std::string_view text) {
      const auto start = text.find_first_not_of(" \t");
      if (start == std::string_view::npos) {
        return {};
      }

      return text.substr(start, text.find_last_not_of(" \t") - start + 1);
    }

  }

  ShellCompletionResult::ShellCompletionResult(tbc::mut_a<ConcurrentMemory> memory)
      : words(memory) {}

  ShellCompleter::ShellCompleter(tbc::mut_a<ConcurrentMemory> memory, tbc::mut_a<std::atomic<bool>> cancelled, const ShellCompletionOptions& options)
      : memory_(memory),
        cancelled_(cancelled),
        user_configuration_(options.user_configuration),
        time_(options.time),
        cache_directory_(memory, options.cache_directory),
        control_directory_(memory, options.control_directory),
        dump_(memory),
        locale_(memory),
        answers_(memory) {
    for (const auto* name : {"LANG", "LC_ALL", "LC_CTYPE"}) {
      // The runtime does not change its environment once it started.
      const char* value = std::getenv(name); // NOLINT(concurrency-mt-unsafe): read once, before the worker's thread starts
      if (value != nullptr) {
        locale_.push({.name = name, .value = ds::String<ConcurrentMemory>{memory, std::string_view{value}}});
      }
    }
  }

  tbc::val_a<ShellCompletionResult> ShellCompleter::observe(const Request& request) noexcept { // NOLINT(bugprone-exception-escape): a process without memory for a result ends, as noexcept states
    Result result{memory_};

    result.client = request.client;
    result.request = request.request;
    result.pane = request.pane;
    // A directory's entries are listed and a provider's words read, never evaluated: any
    // printable word begins them. Only a host `ssh` reached is asked for them; this host's are
    // the runtime's to read.
    const bool listing = request.question != ShellQuestion::line;
    if (listing ? request.control.view().empty() || !printable(request.line.view()) : !completable(request.line.view())) {
      return result;
    }

    const auto now = Clock::now();

    static_cast<void>(answers_.retain([now](const Answer& answer) {
      return now - answer.when <= kept;
    }));

    for (const auto& answer : answers_) {
      if (answer.shell == request.shell && answer.question == request.question && answer.provider == request.provider && answer.control.view() == request.control.view() && answer.line.view() == request.line.view() && answer.directory.view() == request.directory.view()) {
        for (const auto& word : answer.words) {
          result.words.push({.text = word.text.clone(), .description = word.description.clone()});
        }

        result.truncated = answer.truncated;
        return result;
      }
    }

    try {
      // A line whose shell was ended for a newer one has no answer to keep.
      if (run(request, result) || !cancelled_.load(std::memory_order_relaxed)) {
        remember(request, result);
      }
    } catch (...) { // NOLINT(bugprone-empty-catch): a shell that cannot run completes nothing, as a missing one does
      result.words.clear();
      result.truncated = false;
    }

    return result;
  }

  void ShellCompleter::stop() noexcept {
    cancelled_.store(true, std::memory_order_relaxed);
  }

  bool ShellCompleter::run(const Request& request, tbc::mut_a<Result> result) {
    const auto program = programOf(request.shell);
    ds::Array<char, PATH_MAX> shell{};
    const auto path = request.path.view().empty() ? std::string_view{"/usr/bin:/bin"} : request.path.view();

    if (!request.control.view().empty()) {
      return runRemote(request, path, result);
    }

    if (program.empty() || !request.directory.view().starts_with('/') || !findExecutable({.path = path, .program = program}, shell.viewMut())) {
      return false;
    }

    const std::string_view configuration = user_configuration_ ? "rc" : "";
    const auto line = request.line.view();
    ds::Array<std::string_view, 8> words{};
    std::size_t count = 0;
    const auto add = [&](std::string_view word) {
      words.atMut(count++) = word;
    };

    // Each script reads the line as its first argument.
    add(std::string_view{shell.data()});
    switch (request.shell) {
    case IntegratedShell::zsh:
      add("-f");
      add("-c");
      add(scripts::zsh);
      add("zsh");
      add(line);
      add(configuration);
      add(dump());
      break;
    case IntegratedShell::bash:
      add("--norc");
      add("--noprofile");
      add("-c");
      add(scripts::bash);
      add("bash");
      add(line);
      add(configuration);
      break;
    case IntegratedShell::fish:
      if (!user_configuration_) {
        add("--no-config");
      }

      add("-c");
      add(scripts::fish);
      // fish would read an argument that starts with a dash as its own option.
      add("--");
      add(line);
      add(configuration);
      break;
    case IntegratedShell::none:
      return false;
    }

    // A clean environment: the pane's PATH and the home, and nothing a terminal would set.
    ds::Vec<EnvironmentEntry, ConcurrentMemory> environment{memory_};

    environment.push({.name = "PATH", .value = path});
    environment.push({.name = "HOME", .value = request.home.view()});
    environment.push({.name = "TERM", .value = "dumb"});
    for (const auto& [name, value] : locale_) {
      environment.push({.name = name, .value = value.view()});
    }

    Command command{memory_, Launch{.cwd = request.directory.view(), .arguments = words.view().first(count), .environment_mode = EnvironmentMode::replace, .environment = environment.view()}, CommandPurpose::configured_helper};

    return collect(request, command, {.ends = request.shell == IntegratedShell::zsh}, {}, result);
  }

  bool ShellCompleter::runRemote(const Request& request, std::string_view path, tbc::mut_a<Result> result) {
    const bool listing = request.question != ShellQuestion::line;
    const bool provider = request.question == ShellQuestion::provider;
    const auto shell = listing ? IntegratedShell::none : request.shell;
    auto question = listing ? listingQuestion(request.question) : remote_completion::question(shell);

    if (provider) {
      question = providerQuestion(request.provider);
    }

    const auto directory = request.directory.view();
    const auto control = request.control.view();
    ds::Array<char, PATH_MAX> ssh{};
    // The socket is checked last, just before ssh opens it.
    if (question.empty() || (!directory.empty() && !directory.starts_with('/')) || !printable(directory) || !findExecutable({.path = path, .program = "ssh"}, ssh.viewMut()) || !remote_completion::acceptedControl(control, control_directory_.view())) {
      return false;
    }

    // Only the shared connection: no configuration of the user's, no connection of its own when
    // the master is gone (ProxyCommand false fails at once), no forwarding and no terminal. The
    // destination names nothing; the master knows its host.
    constexpr std::size_t most_words = 24;
    ds::Array<std::string_view, most_words> words{};
    std::size_t count = 0;

    for (const auto word : {std::string_view{ssh.data()}, std::string_view{"-F"}, std::string_view{"/dev/null"}, std::string_view{"-S"}, control, std::string_view{"-T"}, std::string_view{"-x"}, std::string_view{"-e"}, std::string_view{"none"}, std::string_view{"-o"}, std::string_view{"ControlMaster=no"}, std::string_view{"-o"}, std::string_view{"BatchMode=yes"}, std::string_view{"-o"}, std::string_view{"ProxyCommand=false"}, std::string_view{"-o"}, std::string_view{"ClearAllForwardings=yes"}, std::string_view{"--"}, std::string_view{"telar"}, remote_completion::command(shell), question}) {
      words.atMut(count++) = word;
    }

    if (!listing && user_configuration_) {
      words.atMut(count++) = "rc";
    }

    ds::Vec<EnvironmentEntry, ConcurrentMemory> environment{memory_};

    environment.push({.name = "PATH", .value = path});
    environment.push({.name = "HOME", .value = request.home.view()});
    environment.push({.name = "TERM", .value = "dumb"});
    for (const auto& [name, value] : locale_) {
      environment.push({.name = name, .value = value.view()});
    }

    // The data, a line each: the directory, then the line or the word.
    const ds::Array<std::string_view, 4> input{{directory, "\n", request.line.view(), "\n"}};
    Command command{memory_, Launch{.cwd = "/", .arguments = words.view().first(count), .environment_mode = EnvironmentMode::replace, .environment = environment.view()}, CommandPurpose::configured_helper};

    return collect(request, command, {.starts = true, .ends = shell == IntegratedShell::zsh, .cut = provider ? listed(request.provider) : listing}, input.view(), result);
  }

  bool ShellCompleter::collect(const Request& request, Command<ConcurrentMemory>& command, Framing framing, std::span<const std::string_view> input, tbc::mut_a<Result> result) {
    CommandOutput<ConcurrentMemory> output{memory_, maximum_output, &cancelled_};
    Answering answering{memory_, framing.starts, maximum_output};
    const auto consume = [&](std::span<const Byte> bytes) {
      return answering.take(bytes);
    };

    const auto ignore = [](std::span<const Byte>) {};

    try {
      if (input.empty()) {
        static_cast<void>(output.stream(command, Clock::now() + time_, consume));
      } else {
        static_cast<void>(output.streamWithInput(command, Clock::now() + time_, input, consume, ignore));
      }
    } catch (const RequestError&) {
      // Out of time or ended for a newer line: what it wrote by then may be cut anywhere.
      return false;
    }

    // zsh ends its answer; a shell that stopped before it, or wrote more than an answer holds,
    // answered nothing that can be trusted whole. A listing cut at the bound keeps its whole lines.
    const bool full = answering.full();
    if (!answering.started() || (framing.ends ? !answering.ended() : full && !framing.cut)) {
      return false;
    }

    auto answer = answering.text();

    if (full && !framing.ends) {
      answer = answer.substr(0, answer.rfind('\n') + 1);
      result.truncated = true;
    }

    read(request, answer, result);
    return true;
  }

  void ShellCompleter::read(const Request& request, std::string_view output, tbc::mut_a<Result> result) const {
    if (request.question == ShellQuestion::provider) {
      result.truncated = !hostWords(memory_, {.provider = request.provider, .prefix = request.line.view(), .shell = request.shell, .text = output}, result.words) || result.truncated;
      return;
    }

    while (!output.empty()) {
      const auto end = output.find('\n');
      const auto line = output.substr(0, end);

      output.remove_prefix(end == std::string_view::npos ? output.size() : end + 1);
      const auto tab = line.find('\t');
      const auto text = line.substr(0, tab);
      auto description = tab == std::string_view::npos ? std::string_view{} : trimmed(line.substr(tab + 1));

      // A word the wire cannot carry is left out, and the same word once.
      if (text.empty() || text.size() > maximum_word_bytes || !printable(text) || std::ranges::any_of(result.words, [text](const ShellWord& word) {
            return word.text.view() == text;
          })) {
        continue;
      }

      if (result.words.size() == maximum_words) {
        result.truncated = true;
        return;
      }

      description = printable(description) ? utf8Prefix(description, maximum_word_bytes) : std::string_view{};
      result.words.push({.text = ds::String<ConcurrentMemory>{memory_, text}, .description = ds::String<ConcurrentMemory>{memory_, description}});
    }
  }

  void ShellCompleter::remember(const Request& request, const Result& result) {
    if (answers_.size() == remembered) {
      static_cast<void>(answers_.remove(0));
    }

    Answer answer{
        .shell = request.shell,
        .question = request.question,
        .provider = request.provider,
        .control = ds::String<ConcurrentMemory>{memory_, request.control.view()},
        .line = ds::String<ConcurrentMemory>{memory_, request.line.view()},
        .directory = ds::String<ConcurrentMemory>{memory_, request.directory.view()},
        .when = Clock::now(),
        .words = ds::Vec<ShellWord, ConcurrentMemory>{memory_},
        .truncated = result.truncated,
    };

    for (const auto& word : result.words) {
      answer.words.push({.text = word.text.clone(), .description = word.description.clone()});
    }

    answers_.push(std::move(answer));
  }

  std::string_view ShellCompleter::dump() {
    if (dump_checked_) {
      return dump_.view();
    }

    dump_checked_ = true;
    if (!cache_directory_.view().starts_with('/')) {
      return {};
    }

    // zsh runs the dump as code: its directory must be the user's alone.
    constexpr mode_t group_or_others_write = 0022;
    constexpr std::string_view folder = "/shell-completion";
    const auto base = cache_directory_.view();
    ds::Array<char, PATH_MAX> directory{};

    if (base.size() + folder.size() >= directory.size()) {
      return {};
    }

    std::ranges::copy(folder, std::ranges::copy(base, directory.viewMut().begin()).out);
    static_cast<void>(::mkdir(directory.data(), S_IRWXU));
    struct stat status{};

    if (::lstat(directory.data(), &status) != 0 || !S_ISDIR(status.st_mode) || status.st_uid != ::geteuid() || (status.st_mode & group_or_others_write) != 0) {
      return {};
    }

    dump_.assign(std::string_view{directory.data()});
    dump_.append("/zcompdump");
    return dump_.view();
  }

  ShellCompletionService::ShellCompletionService(tbc::mut_a<ConcurrentMemory> memory, const ShellCompletionOptions& options)
      : enabled_(options.enabled),
        worker_(std::in_place, memory, cancelled_, options),
        waiting_(memory) {}

  bool ShellCompletionService::enabled() const noexcept {
    return enabled_;
  }

  ds::Option<ShellCompletionAsked> ShellCompletionService::request(const ShellCompletionRequest& request) {
    ds::Option<ShellCompletionAsked> dropped;

    // The line typed on from the one the pane's shell completes: that shell's answer is stale.
    // Another question of the same Tab is not.
    if (running_ && running_pane_ == request.pane && running_question_ == request.question && running_provider_ == request.provider) {
      cancelled_.store(true, std::memory_order_relaxed);
    }

    auto waiting = waiting_.viewMut();
    const auto same = std::ranges::find_if(waiting, [&request](const ShellCompletionRequest& asked) {
      return asked.pane == request.pane && asked.question == request.question && asked.provider == request.provider;
    });
    if (same != waiting.end()) {
      dropped = ShellCompletionAsked{.client = same->client, .request = same->request};
      *same = request;
    } else {
      if (waiting_.size() == waiting_requests) {
        const auto oldest = waiting_.remove(0);

        dropped = ShellCompletionAsked{.client = oldest.client, .request = oldest.request};
      }

      waiting_.push(request);
    }

    startNext();
    return dropped;
  }

  int ShellCompletionService::descriptor() const noexcept {
    return worker_.descriptor();
  }

  void ShellCompletionService::startNext() {
    if (running_ || waiting_.empty()) {
      return;
    }

    // The worker is idle: what cancelled its last shell is put back for the next.
    cancelled_.store(false, std::memory_order_relaxed);
    if (worker_.submit(waiting_[0])) {
      running_ = true;
      running_pane_ = waiting_[0].pane;
      running_question_ = waiting_[0].question;
      running_provider_ = waiting_[0].provider;
      static_cast<void>(waiting_.remove(0));
    }
  }

}
