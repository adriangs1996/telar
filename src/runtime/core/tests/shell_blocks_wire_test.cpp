#include <cstdio>
#include <cstdlib>
#include <unistd.h>

import std;
import telar.testing;
import telar.runtime.core.tests.protocol_peer;
import telar.runtime.core.tests.runtime_host;
import telar.wire.content;
import telar.wire.history;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

// Real shells, zsh, bash and fish, with telar's integration, in panes of a real runtime: the
// blocks and the history their clients hear of are the commands the shell ran.
namespace {

  using telar::testing::check;

  using namespace telar;

  constexpr TerminalSize size{100, 30, 8, 16};

  std::span<const Byte> bytes(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  // The shell named `name` on the PATH, or the test skips: not every machine has all three.
  std::string shellPath(std::string_view name) {
    const char* path = std::getenv("PATH");
    std::string_view rest = path == nullptr ? "/usr/bin:/bin" : path;

    while (!rest.empty()) {
      const auto end = std::min(rest.find(':'), rest.size());
      const auto candidate = std::filesystem::path{rest.substr(0, end)} / name;
      if (std::filesystem::exists(candidate)) {
        return candidate.string();
      }

      rest.remove_prefix(std::min(end + 1, rest.size()));
    }

    telar::testing::skip(std::format("{} is not installed", name));
    return {};
  }

  // A home of its own for the shell, with empty startup files: the user's own never run, and zsh
  // does not ask to write a .zshrc. The runtime and its shells inherit it.
  struct ShellHome {
    std::string path;

    ShellHome() {
      ds::Array<char, 32> directory{};

      std::strcpy(directory.dataMut(), "/tmp/telar-shell-XXXXXX");
      check(::mkdtemp(directory.dataMut()) != nullptr);
      path = directory.data();
      for (const auto* name : {".zshrc", ".zshenv", ".bashrc", ".bash_profile"}) {
        std::ofstream{path + "/" + name};
      }

      ::setenv("HOME", path.c_str(), 1);
      ::setenv("XDG_CONFIG_HOME", (path + "/.config").c_str(), 1);
      ::setenv("XDG_DATA_HOME", (path + "/.local/share").c_str(), 1);
      ::unsetenv("ZDOTDIR");
      ::unsetenv("PROMPT_COMMAND");
    }

    ~ShellHome() {
      std::error_code ignored;

      std::filesystem::remove_all(path, ignored);
    }

    ShellHome(const ShellHome&) = delete;
    ShellHome& operator=(const ShellHome&) = delete;
  };

  // One block as a client keeps it.
  struct Block {
    std::uint32_t row = 0;
    std::uint16_t rows = 0;
    CommandBlockState state{};
    std::int32_t status = 0;
    std::string command;
    bool restored = false;
  };

  // A pane running `shell` with telar's integration, and the client that opened it.
  struct ShellPane {
    ShellHome home;
    RuntimeHost host;
    ProtocolPeer peer;
    std::uint64_t pane = 0;
    std::uint32_t commands = 0;
    ShellPhase phase = ShellPhase::unknown;
    std::vector<Block> blocks;
    // The lines the shell's editor held when a command cleared them, as the client heard them.
    std::vector<std::string> typeahead;
    std::uint64_t request = 100;

    // `bare`: telar's editor stands in for the shell's prompt, as the window's native prompt does.
    // `rc` is the shell's startup file. `session`: the runtime keeps its session, so it comes
    // back when the runtime restarts. `output`: the history keeps what each command printed.
    explicit ShellPane(std::string_view shell, bool bare = true, std::string_view rc = {}, bool session = false, bool output = false)
        : host(RuntimeHostOptions{.session = session, .shell_integration = true, .capture_output = output}),
          peer(host.socket()) {
      const auto path = shellPath(shell);

      if (shell == "fish") {
        std::filesystem::create_directories(home.path + "/.config/fish");
      }

      std::ofstream{home.path + (shell == "zsh" ? "/.zshrc" : shell == "bash" ? "/.bashrc"
                                                                              : "/.config/fish/config.fish")}
          << rc;
      const ds::Array<std::string_view, 2> arguments{path, "-i"};

      peer.deadline(std::chrono::seconds{20});
      peer.send(ConfigureShellPrompt{.bare = bare});
      pane = peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = home.path, .arguments = arguments}}).pane_id;
    }

    // Restarts the runtime, which restores the session, and shows the pane again.
    void restart() {
      host.stop();
      host.start();
      peer.reconnect(host.socket());
      peer.deadline(std::chrono::seconds{20});
      blocks.clear();
      commands = 0;
      phase = ShellPhase::unknown;
      peer.send(ConfigureShellPrompt{.bare = true});
      peer.send(OpenPane{.request_id = ++request, .target = {.kind = PaneTarget::Kind::pane, .id = pane}, .size = size});
    }

    // Waits for the shell's prompt after it finished `count` commands, keeping the blocks heard
    // on the way.
    void prompt(std::uint32_t count) {
      while (!(phase == ShellPhase::prompt && commands >= count)) {
        hear(peer.receiveAny<PaneShell, PaneBlocks, PaneTypeahead>());
      }
    }

    template <typename... Messages>
    void hear(const std::variant<Messages...>& message) {
      std::visit([&](const auto& value) {
        hear(value);
      },
          message);
    }

    void hear(const PaneShell& shell) {
      if (shell.pane_id == pane) {
        commands = shell.commands;
        phase = shell.phase;
      }
    }

    void hear(const PaneBlocks& message) {
      keep(message);
    }

    void hear(const PaneTypeahead& message) {
      if (message.pane_id == pane) {
        typeahead.emplace_back(message.text);
      }
    }

    void hear(const PaneText& /*text*/) {}

    void hear(const RequestCompleted& /*completed*/) {}

    // Runs `text` from telar's editor, as the native prompt does, and waits for the prompt after it.
    void run(std::string_view text) {
      const auto next = commands + 1;

      peer.send(PaneCommand{.pane_id = pane, .text = bytes(text)});
      prompt(next);
    }

    // The commands the history recorded, newest first, once it holds `count`.
    // What the history kept of the output of the newest command, once it has some.
    std::string output() {
      for (;;) {
        peer.send(QueryHistory{.request_id = ++request, .limit = 1});
        std::uint64_t id = 0;

        while (id == 0) {
          const auto message = peer.receiveAny<HistoryResults, PaneShell, PaneBlocks, PaneTypeahead>();
          if (const auto* results = std::get_if<HistoryResults>(&message); results != nullptr && results->request_id == request) {
            id = results->entries.empty() ? std::uint64_t{1} << 63U : results->entries.front().id;
          }
        }

        if (id != std::uint64_t{1} << 63U) {
          peer.send(ReadHistoryOutput{.request_id = ++request, .id = id});
          for (;;) {
            const auto message = peer.receiveAny<HistoryOutput, PaneShell, PaneBlocks, PaneTypeahead>();
            if (const auto* output = std::get_if<HistoryOutput>(&message); output != nullptr && output->request_id == request) {
              if (!output->content.empty()) {
                return std::string{reinterpret_cast<const char*>(output->content.data()), output->content.size()};
              }

              break;
            }
          }
        }

        std::this_thread::sleep_for(std::chrono::milliseconds{50});
      }
    }

    std::vector<std::string> history(std::size_t count) {
      for (;;) {
        peer.send(QueryHistory{.request_id = ++request, .limit = 20});
        for (;;) {
          const auto message = peer.receiveAny<HistoryResults, PaneShell, PaneBlocks, PaneTypeahead>();
          if (const auto* results = std::get_if<HistoryResults>(&message); results != nullptr && results->request_id == request) {
            if (results->entries.size() >= count) {
              std::vector<std::string> commands;

              for (const auto& entry : results->entries) {
                commands.emplace_back(entry.command);
              }

              return commands;
            }

            break;
          }

          if (!std::holds_alternative<HistoryResults>(message)) {
            std::visit(
                [&](const auto& value) {
                  if constexpr (!std::is_same_v<std::remove_cvref_t<decltype(value)>, HistoryResults>) {
                    hear(value);
                  }
                },
                message
            );
          }
        }

        std::this_thread::sleep_for(std::chrono::milliseconds{20});
      }
    }

    // Keys that reach the shell itself, as keys typed while telar's editor is not up do. What the
    // runtime says until they are typed is kept: the shell may reach its prompt first, and the
    // runtime says so only once.
    void type(std::string_view text) {
      peer.send(SendPaneText{.request_id = ++request, .pane_id = pane, .mode = PaneTextMode::raw, .text = text});
      for (;;) {
        const auto message = peer.receiveAny<RequestCompleted, PaneShell, PaneBlocks, PaneTypeahead>();
        if (const auto* completed = std::get_if<RequestCompleted>(&message); completed != nullptr && completed->request_id == request) {
          return;
        }

        hear(message);
      }
    }

    // Waits for the blocks to satisfy `wanted`.
    template <typename Wanted>
    void blocksUntil(Wanted wanted) {
      while (!wanted(blocks)) {
        hear(peer.receiveAny<PaneShell, PaneBlocks, PaneTypeahead>());
      }
    }

    // The pane's screen once it shows `marker`, keeping what else the runtime said meanwhile.
    std::string screen(std::string_view marker) {
      for (;;) {
        peer.send(ReadPane{.request_id = ++request, .pane_id = pane, .rows = 200});
        for (;;) {
          const auto message = peer.receiveAny<PaneText, PaneShell, PaneBlocks, PaneTypeahead>();
          if (const auto* text = std::get_if<PaneText>(&message); text != nullptr && text->request_id == request) {
            if (text->text.contains(marker)) {
              return std::string{text->text};
            }

            break;
          }

          hear(message);
        }

        std::this_thread::sleep_for(std::chrono::milliseconds{10});
      }
    }

    void keep(const PaneBlocks& message) {
      if (message.pane_id != pane) {
        return;
      }

      blocks.clear();
      for (const auto& block : message.blocks) {
        blocks.push_back({.row = block.row, .rows = block.rows, .state = block.state, .status = block.status, .command = std::string{block.command}, .restored = block.restored});
      }
    }
  };

  // Commands one read holds whole, a fast script's say, each keep their block and their status:
  // here six, whose 24 marks the shell prints at once.
  void realShellKeepsEveryMarkOfOneRead() {
    ShellPane shell{"zsh"};

    shell.prompt(0);
    shell.run(R"(s=; for i in {1..6}; do s+=$'\e]133;A;telar='$_telar_token$'\a$ \e]133;B;telar='$_telar_token$'\afake'$i$'\r\n\e]133;C;telar='$_telar_token$'\a\e]133;D;'$i';telar='$_telar_token$'\a'; done; print -rn -- $s)");
    shell.blocksUntil([](const std::vector<Block>& blocks) {
      return std::ranges::count_if(blocks, [](const Block& block) {
        return block.command.starts_with("fake") && block.state != CommandBlockState::running;
      }) == 6;
    });

    for (int index = 1; index <= 6; ++index) {
      const auto found = std::ranges::find(shell.blocks, std::format("fake{}", index), &Block::command);

      check(found != shell.blocks.end() && found->state == CommandBlockState::failed && found->status == index, std::format("fake{} has no block of its own, or another's status", index));
    }
  }

  // The version of the bash at `path` as its major times 100 plus its minor, 402 for 4.2:
  // macOS still ships 3.2.
  int bashVersion(const std::string& path) {
    check(!path.contains('\''), path);
    FILE* pipe = ::popen(std::format("'{}' -c 'echo $((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1]))'", path).c_str(), "r");
    int version = 0;

    check(pipe != nullptr, path);
    if (pipe != nullptr) {
      ds::Array<char, 16> digits{};
      const auto count = std::fread(digits.dataMut(), 1, digits.size(), pipe);

      ::pclose(pipe);
      std::from_chars(digits.data(), digits.data() + count, version);
    }

    check(version != 0, std::format("{} told no version", path));
    return version;
  }

  // Keys typed before the shell's first prompt reach its line editor, which telar's editor hides.
  // The command telar's editor runs runs alone, and the client hears of the line it cleared. A
  // line editor that cannot read its line, bash's before 4.0, clears it unreported.
  void typeaheadBeforeTheFirstPromptIsReported(std::string_view name, bool reported = true) {
    ShellPane shell{name};

    shell.type("echo typed");
    shell.prompt(0);
    shell.run("echo real");
    shell.blocksUntil([](const std::vector<Block>& blocks) {
      return !blocks.empty() && blocks.back().state != CommandBlockState::running;
    });

    while (reported && shell.typeahead.empty()) {
      shell.hear(shell.peer.receiveAny<PaneShell, PaneBlocks, PaneTypeahead>());
    }

    // The shell reports the line before the command runs: by the screen of its output, a report
    // would have been heard.
    const auto screen = shell.screen("real");
    const auto expected = reported ? std::vector<std::string>{"echo typed"} : std::vector<std::string>{};

    check(shell.blocks.back().command == "echo real", std::format("{} ran '{}'", name, shell.blocks.back().command));
    check(shell.blocks.back().state == CommandBlockState::succeeded, std::format("{} failed the command", name));
    check(!screen.contains("typedecho") && !screen.contains("typed echo"), std::format("{} ran the keys typed ahead: {}", name, screen));
    check(shell.typeahead == expected, std::format("{} reported {}", name, shell.typeahead));
  }

  void zshReportsTypeahead() {
    typeaheadBeforeTheFirstPromptIsReported("zsh");
  }

  void bashReportsTypeahead() {
    typeaheadBeforeTheFirstPromptIsReported("bash", bashVersion(shellPath("bash")) >= 400);
  }

  void fishReportsTypeahead() {
    typeaheadBeforeTheFirstPromptIsReported("fish");
  }

  // Keys typed after a command ends, while a slow precmd runs and telar's editor waits for the
  // prompt, reach the line editor too: they are reported, not run before the next command.
  void typeaheadDuringASlowPromptIsReported() {
    ShellPane shell{"zsh", true, "_slow() { [[ -e $HOME/slow ]] && sleep 1; true }\nprecmd_functions+=(_slow)\n"};

    shell.prompt(0);
    shell.run("touch $HOME/slow");
    shell.peer.send(PaneCommand{.pane_id = shell.pane, .text = bytes("true")});
    shell.type("ls -l; x%y");
    shell.prompt(2);
    shell.run("echo real");
    while (shell.typeahead.empty()) {
      shell.hear(shell.peer.receiveAny<PaneShell, PaneBlocks, PaneTypeahead>());
    }

    check(shell.typeahead == std::vector<std::string>{"ls -l; x%y"}, shell.typeahead.front());
    shell.blocksUntil([](const std::vector<Block>& blocks) {
      return !blocks.empty() && blocks.back().command == "echo real" && blocks.back().state == CommandBlockState::succeeded;
    });
  }

  const telar::testing::Case case_zsh_typeahead{"shell_blocks.zsh_reports_typeahead", zshReportsTypeahead};
  const telar::testing::Case case_bash_typeahead{"shell_blocks.bash_reports_typeahead", bashReportsTypeahead};
  const telar::testing::Case case_fish_typeahead{"shell_blocks.fish_reports_typeahead", fishReportsTypeahead};
  const telar::testing::Case case_slow_prompt_typeahead{"shell_blocks.typeahead_during_a_slow_prompt_is_reported", typeaheadDuringASlowPromptIsReported};

  // A command of several lines, run from telar's editor in a shell without bracketed paste (bash
  // 3.2, or readline or zsh with it off), runs as the one line the history records: one block, one
  // command, every line's output.
  void linesWithoutBracketedPasteRunAsOne(std::string_view name, std::string_view rc) {
    ShellPane shell{name, true, rc};

    shell.prompt(0);
    shell.run("true");
    shell.run("echo one\necho two");
    shell.run("true");
    shell.blocksUntil([](const std::vector<Block>& blocks) {
      return blocks.size() >= 3 && blocks.back().command == "true" && blocks.back().state == CommandBlockState::succeeded;
    });

    const auto screen = shell.screen("two");
    const auto history = shell.history(3);

    check(shell.commands == 3, std::format("{} counted {} commands of 3", name, shell.commands));
    check(shell.blocks.size() == 3 && shell.blocks[1].command == "echo one", std::format("{} left {} blocks of 3", name, shell.blocks.size()));
    check(screen.contains("one\n") && screen.contains("two\n"), screen);
    check(history.size() == 3 && std::ranges::count(history, "echo one\necho two") == 1, std::format("{} recorded {} commands of 3", name, history.size()));
  }

  void bashLinesWithoutBracketedPaste() {
    linesWithoutBracketedPasteRunAsOne("bash", "bind 'set enable-bracketed-paste off'\n");
  }

  void zshLinesWithoutBracketedPaste() {
    linesWithoutBracketedPasteRunAsOne("zsh", "unset zle_bracketed_paste\n");
  }

  const telar::testing::Case case_bash_lines{"shell_blocks.bash_lines_without_bracketed_paste_run_as_one", bashLinesWithoutBracketedPaste};
  const telar::testing::Case case_zsh_lines{"shell_blocks.zsh_lines_without_bracketed_paste_run_as_one", zshLinesWithoutBracketedPaste};

  // A background job prints while the shell waits at its prompt: its output is a block of its
  // own, between the command that started the job and the next one.
  void backgroundOutputIsABlockOfItsOwn() {
    ShellPane shell{"zsh"};

    shell.prompt(0);
    shell.run("(sleep 0.3; echo late) &");
    shell.blocksUntil([](const std::vector<Block>& blocks) {
      return !blocks.empty() && blocks.back().state == CommandBlockState::background;
    });
    shell.run("echo next");
    shell.blocksUntil([](const std::vector<Block>& blocks) {
      return blocks.size() == 3 && blocks.back().command == "echo next" && blocks.back().state == CommandBlockState::succeeded;
    });

    const auto& job = shell.blocks[1];

    check(job.state == CommandBlockState::background && job.rows == 0 && job.command.empty());
    check(shell.blocks[0].row < job.row && job.row < shell.blocks[2].row, std::format("rows {} {} {}", shell.blocks[0].row, job.row, shell.blocks[2].row));
  }

  const telar::testing::Case case_background_output{"shell_blocks.background_output_is_a_block_of_its_own", backgroundOutputIsABlockOfItsOwn};

  // The screen's row whose line holds `text` first; the screen holds fewer rows than it keeps, so
  // its lines are its rows from the top.
  std::uint32_t rowOf(std::string_view screen, std::string_view text) {
    std::uint32_t row = 0;

    for (const auto line : std::views::split(screen, '\n')) {
      if (std::string_view{line}.contains(text)) {
        return row;
      }

      ++row;
    }

    check(false, std::format("{:?} is not on the screen", text));
    return row;
  }

  // The block whose rows hold `row`: the last one that starts on it or above it.
  const Block& holding(const std::vector<Block>& blocks, std::uint32_t row) {
    const Block* found = nullptr;

    for (const auto& block : blocks) {
      if (block.row <= row) {
        found = &block;
      }
    }

    check(found != nullptr, std::format("no block holds row {}", row));
    return *found;
  }

  // Runs `command` and waits for its block to end.
  void ran(ShellPane& shell, std::string_view command) {
    shell.run(command);
    shell.blocksUntil([command](const std::vector<Block>& blocks) {
      return std::ranges::any_of(blocks, [command](const Block& block) {
        return block.command == command && block.state != CommandBlockState::running;
      });
    });
  }

  // `text`, which the shell printed after the prompt appeared, is on the screen in a background
  // block: not the block of the command before it, nor of the next one, `next`.
  void checkInABackgroundBlock(ShellPane& shell, std::string_view name, std::string_view text, std::string_view next) {
    const auto screen = shell.screen(text);
    const auto row = rowOf(screen, text);
    const auto& block = holding(shell.blocks, row);
    const auto after = std::ranges::find(shell.blocks, next, &Block::command);

    check(block.state == CommandBlockState::background, std::format("{}: {:?} on row {} is in the block of {:?}", name, text, row, block.command));
    check(after != shell.blocks.end() && after->row > row, std::format("{}: the next command's block does not start below {:?}", name, text));
  }

  // A background job prints after the prompt appeared, while the shell waits at it: what it
  // printed is a block of its own whether or not the shell reports the job and draws its prompt
  // again (zsh's NOTIFY), and telar's editor runs the next command below it.
  void jobOutputAfterThePromptIsABlockOfItsOwn(std::string_view name, std::string_view shell_name, std::string_view rc) {
    ShellPane shell{shell_name, true, rc};

    shell.prompt(0);
    // The line holds the word in capitals: only the job's output is the word itself.
    ran(shell, "sh -c 'sleep 0.3; echo LATE | tr A-Z a-z' &");
    shell.screen("late");
    // The shell's report of the job, where it makes one, comes once the job is gone.
    std::this_thread::sleep_for(std::chrono::milliseconds{300});
    ran(shell, "echo next");
    checkInABackgroundBlock(shell, name, "late", "echo next");
  }

  void bashJobOutputAfterThePrompt() {
    // The flush key draws readline's prompt below the job's output through `bind -x`, which bash
    // has from 4.0: before, the output stays in the prompt's rows (telar.bash says so).
    if (bashVersion(shellPath("bash")) < 400) {
      telar::testing::skip("bash before 4.0 cannot draw its prompt again from a key");
    }

    jobOutputAfterThePromptIsABlockOfItsOwn("bash", "bash", {});
  }

  void zshJobOutputAfterThePrompt() {
    jobOutputAfterThePromptIsABlockOfItsOwn("zsh", "zsh", {});
  }

  void zshNonotifyJobOutputAfterThePrompt() {
    jobOutputAfterThePromptIsABlockOfItsOwn("zsh NO_NOTIFY", "zsh", "setopt no_notify\n");
  }

  void fishJobOutputAfterThePrompt() {
    jobOutputAfterThePromptIsABlockOfItsOwn("fish", "fish", {});
  }

  // A job ends while the shell waits at its prompt, and the shell reports it once the next
  // command ended (bash, zsh with NO_NOTIFY) or at once (fish): the report is a block of its own,
  // not the command's that ran meanwhile nor the next prompt's.
  void jobReportIsABlockOfItsOwn(std::string_view name, std::string_view shell_name, std::string_view rc, std::string_view report) {
    ShellPane shell{shell_name, true, rc};

    shell.prompt(0);
    ran(shell, "sleep 0.2 &");
    std::this_thread::sleep_for(std::chrono::milliseconds{600});
    ran(shell, "true");
    ran(shell, "echo next");
    checkInABackgroundBlock(shell, name, report, "echo next");
  }

  void bashJobReport() {
    jobReportIsABlockOfItsOwn("bash", "bash", {}, "Done");
  }

  void zshNonotifyJobReport() {
    jobReportIsABlockOfItsOwn("zsh NO_NOTIFY", "zsh", "setopt no_notify\n", "done");
  }

  void fishJobReport() {
    jobReportIsABlockOfItsOwn("fish", "fish", {}, "has ended");
  }

  // A job ends while a command runs in the foreground, and the shell reports it as that command
  // ends, before its prompt: the report is not the command's output.
  void jobEndingDuringACommandIsReportedApart(std::string_view name, std::string_view shell_name, std::string_view rc, std::string_view report) {
    ShellPane shell{shell_name, true, rc};

    shell.prompt(0);
    ran(shell, "sleep 0.2 &");
    ran(shell, "sleep 1");
    ran(shell, "echo next");
    checkInABackgroundBlock(shell, name, report, "echo next");
  }

  void bashJobEndingDuringACommand() {
    // The count of jobs that ended is read through `${…@P}`, which bash has from 4.4: before, the
    // shell vouches for none and the report stays in the command's block.
    if (bashVersion(shellPath("bash")) < 404) {
      telar::testing::skip("bash before 4.4 cannot count the jobs that ended during a command");
    }

    jobEndingDuringACommandIsReportedApart("bash", "bash", {}, "Done");
  }

  void zshNonotifyJobEndingDuringACommand() {
    jobEndingDuringACommandIsReportedApart("zsh NO_NOTIFY", "zsh", "setopt no_notify\n", "done");
  }

  const telar::testing::Case case_bash_job_output{"shell_blocks.bash_job_output_after_the_prompt_is_a_block_of_its_own", bashJobOutputAfterThePrompt};
  const telar::testing::Case case_zsh_job_output{"shell_blocks.zsh_job_output_after_the_prompt_is_a_block_of_its_own", zshJobOutputAfterThePrompt};
  const telar::testing::Case case_zsh_nonotify_job_output{"shell_blocks.zsh_nonotify_job_output_after_the_prompt_is_a_block_of_its_own", zshNonotifyJobOutputAfterThePrompt};
  const telar::testing::Case case_fish_job_output{"shell_blocks.fish_job_output_after_the_prompt_is_a_block_of_its_own", fishJobOutputAfterThePrompt};
  const telar::testing::Case case_bash_job_report{"shell_blocks.bash_job_report_is_a_block_of_its_own", bashJobReport};
  const telar::testing::Case case_zsh_nonotify_job_report{"shell_blocks.zsh_nonotify_job_report_is_a_block_of_its_own", zshNonotifyJobReport};
  const telar::testing::Case case_fish_job_report{"shell_blocks.fish_job_report_is_a_block_of_its_own", fishJobReport};
  const telar::testing::Case case_bash_job_during_command{"shell_blocks.bash_job_ending_during_a_command_is_reported_apart", bashJobEndingDuringACommand};
  const telar::testing::Case case_zsh_nonotify_job_during_command{"shell_blocks.zsh_nonotify_job_ending_during_a_command_is_reported_apart", zshNonotifyJobEndingDuringACommand};

  // The history keeps what a command printed, and nothing zsh prints once it ended: the
  // PROMPT_SP mark, which zsh draws before its prompt, is the shell's.
  void zshKeepsOnlyWhatTheCommandPrinted() {
    ShellPane shell{"zsh", true, {}, false, true};

    shell.prompt(0);
    shell.run("printf 'x\\n'");
    const auto output = shell.output();

    check(output == "x\r\n", std::format("the output kept is {:?}", output));
  }

  const telar::testing::Case case_zsh_output{"shell_blocks.zsh_keeps_only_what_the_command_printed", zshKeepsOnlyWhatTheCommandPrinted};

  // Ctrl-L clears the screen and the line editor draws its prompt again without the shell's
  // precmd. The next command's block starts on that prompt: its prompt and command take the rows a
  // command as wide took at the prompt before, not the rows from the prompt before the clear.
  // With the shell's own prompt, which the clear moves into the scrollback; telar's draws nothing
  // there, so its row stays on top. That prompt is the machine's, as wide as its user, host and
  // directory make it, and may take more than a row.
  void ctrlLStartsTheNextBlockOnTheNewPrompt(std::string_view name) {
    ShellPane shell{name, false};
    // Two commands as wide, so each takes the rows the other does.
    const auto finished = [](std::string_view command) {
      return [command](const std::vector<Block>& blocks) {
        return !blocks.empty() && blocks.back().command == command && blocks.back().state == CommandBlockState::succeeded;
      };
    };

    shell.prompt(0);
    shell.run("seq 1 12");
    shell.run("echo before");
    shell.blocksUntil(finished("echo before"));
    const auto before = shell.blocks.back().rows;

    shell.type("\x0c");
    shell.run("echo after_");
    shell.blocksUntil(finished("echo after_"));

    const auto rows = shell.blocks.back().rows;
    const auto screen = shell.screen("after_");

    check(before != 0 && rows == before, std::format("{}: the block after Ctrl-L takes {} rows, a command as wide before it {}: {}", name, rows, before, screen));
    for (std::size_t index = 1; index < shell.blocks.size(); ++index) {
      check(shell.blocks[index - 1].row + shell.blocks[index - 1].rows <= shell.blocks[index].row, std::format("{}: blocks out of order", name));
    }
  }

  void zshCtrlL() {
    ctrlLStartsTheNextBlockOnTheNewPrompt("zsh");
  }

  void bashCtrlL() {
    ctrlLStartsTheNextBlockOnTheNewPrompt("bash");
  }

  void fishCtrlL() {
    ctrlLStartsTheNextBlockOnTheNewPrompt("fish");
  }

  // `clear` erases the screen and the scrollback: the blocks drawn there go with them, and the
  // command after it has its own block.
  void clearTakesTheBlocksItErased(std::string_view name) {
    ShellPane shell{name};

    shell.prompt(0);
    shell.run("echo before");
    shell.run("clear");
    shell.run("echo after");
    shell.blocksUntil([](const std::vector<Block>& blocks) {
      return !blocks.empty() && blocks.back().command == "echo after" && blocks.back().state == CommandBlockState::succeeded;
    });

    check(std::ranges::none_of(shell.blocks, [](const Block& block) {
      return block.command == "echo before";
    }),
        std::format("{}: a block of erased rows was kept", name));
    check(shell.blocks.back().rows == 1, std::format("{}: the block after clear takes {} rows", name, shell.blocks.back().rows));
  }

  void zshClear() {
    clearTakesTheBlocksItErased("zsh");
  }

  void bashClear() {
    clearTakesTheBlocksItErased("bash");
  }

  void fishClear() {
    clearTakesTheBlocksItErased("fish");
  }

  const telar::testing::Case case_zsh_ctrl_l{"shell_blocks.zsh_ctrl_l_starts_the_next_block_on_the_new_prompt", zshCtrlL};
  const telar::testing::Case case_bash_ctrl_l{"shell_blocks.bash_ctrl_l_starts_the_next_block_on_the_new_prompt", bashCtrlL};
  const telar::testing::Case case_fish_ctrl_l{"shell_blocks.fish_ctrl_l_starts_the_next_block_on_the_new_prompt", fishCtrlL};
  const telar::testing::Case case_zsh_clear{"shell_blocks.zsh_clear_takes_the_blocks_it_erased", zshClear};
  const telar::testing::Case case_bash_clear{"shell_blocks.bash_clear_takes_the_blocks_it_erased", bashClear};
  const telar::testing::Case case_fish_clear{"shell_blocks.fish_clear_takes_the_blocks_it_erased", fishClear};

  // The blocks of a pane's shell come back with the session when the runtime restarts, as a list
  // before the new shell's: no rows, since the scrollback does not come back, and a command the
  // history would not keep, a secret's, redacted.
  void blocksReturnWithTheSession() {
    ShellPane shell{"zsh", true, {}, true};

    shell.prompt(0);
    shell.run("echo kept");
    shell.run("echo token=" + std::string(12, 'x'));
    shell.blocksUntil([](const std::vector<Block>& blocks) {
      return blocks.size() == 2 && blocks.back().state == CommandBlockState::succeeded;
    });

    shell.restart();
    shell.prompt(0);
    shell.run("echo again");
    shell.blocksUntil([](const std::vector<Block>& blocks) {
      return blocks.size() == 3 && blocks.back().command == "echo again" && blocks.back().state == CommandBlockState::succeeded;
    });

    check(shell.blocks[0].restored && shell.blocks[0].command == "echo kept" && shell.blocks[0].state == CommandBlockState::succeeded && shell.blocks[0].rows == 0, shell.blocks[0].command);
    check(shell.blocks[1].restored && shell.blocks[1].command == "[REDACTED]", std::format("the redacted command came back as '{}'", shell.blocks[1].command));
    check(!shell.blocks[2].restored && shell.blocks[2].rows != 0);
  }

  const telar::testing::Case case_blocks_return{"shell_blocks.blocks_return_with_the_session", blocksReturnWithTheSession};

  // zsh asks to correct a mistyped command after the command's C mark; answered with e(dit), the
  // line goes back to its line editor: no block runs, and the shell is at its prompt again.
  void correctionEditedLeavesNoRunningBlock() {
    ShellPane shell{"zsh", true, "setopt correct\n"};

    shell.prompt(0);
    shell.run("true");
    shell.peer.send(PaneCommand{.pane_id = shell.pane, .text = bytes("lss")});
    shell.screen("[nyae]?");
    shell.blocksUntil([](const std::vector<Block>& blocks) {
      return !blocks.empty() && blocks.back().command == "lss" && blocks.back().state == CommandBlockState::running;
    });

    shell.type("e");
    shell.blocksUntil([](const std::vector<Block>& blocks) {
      return !blocks.empty() && blocks.back().command == "true";
    });
    shell.prompt(1);
    check(shell.commands == 1, "the command taken back was counted as finished");
  }

  const telar::testing::Case case_correction_edited{"shell_blocks.correction_edited_leaves_no_running_block", correctionEditedLeavesNoRunningBlock};
  const telar::testing::Case case_real_shell_keeps_every_mark{"shell_blocks.real_shell_keeps_every_mark_of_one_read", realShellKeepsEveryMarkOfOneRead};

}
