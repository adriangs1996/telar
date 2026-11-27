#include <ghostty/vt.h>

import std;
import telar.base.memory.allocators;

import telar.runtime.terminal.control;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.terminal.command_capture.tracker;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.runtime.terminal.shell_integration.token;
import telar.runtime.terminal.text_reader;
import telar.base.ds;

// The blocks a pane's integrated shell leaves, given the bytes it printed: its signed marks read
// by the zones, placed on the terminal as the runtime places them.
namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::span<const Byte> byteSpan(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  // A shell session on a terminal: what the shell prints reaches the zones, the terminal and the
  // blocks in one pass, as a pane's reads do.
  struct ShellSession {
    struct Feed {
      Terminal& terminal;

      void operator()(std::span<const Byte> bytes) {
        terminal.feed(bytes);
      }
    };

    struct Sink {
      CommandBlockFeed<Feed>& blocks;
      std::vector<CommandCompletion>& completions;

      void complete(CommandCompletion completion) {
        completions.push_back(completion);
      }

      void mark(CommandMark mark) {
        blocks.mark(mark);
      }
    };

    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ShellToken token = ShellToken::generate();
    Terminal terminal;
    CommandBlocks blocks{memory, terminal};
    CommandZones zones{memory, "/home/user", token};
    std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now();
    ds::Array<CommandBlock, PaneBlocks::capacity> storage;
    // The commands the zones heard end, as the pane's shell state counts them.
    std::vector<CommandCompletion> completions;
    // The user this host's shell runs as and the branch its directory is in, as the runtime knows them.
    std::string user = "alice";
    std::string branch = "main";

    explicit ShellSession(TerminalSize size = {40, 12, 8, 16})
        : terminal(memory, size) {}

    // A mark the pane's shell signs.
    [[nodiscard]] std::string mark(std::string_view action) const {
      return std::format("\x1b]133;{};telar={}\x07", action, token.text());
    }

    [[nodiscard]] std::string finished(int status) const {
      return mark(std::format("D;{}", status));
    }

    // The end of the shell's report of its jobs, with the lines bash may have printed above its
    // end mark.
    [[nodiscard]] std::string reported(int above) const {
      return std::format("\x1b]6973;telar={};jobs={}\x07", token.text(), above);
    }

    // One read of what the shell printed.
    void print(std::string_view bytes) {
      Feed feed{terminal};
      std::size_t fed = 0;

      {
        CommandBlockFeed<Feed> marks{blocks, byteSpan(bytes), feed, fed, now, CommandPlace{.user = user, .branch = branch}};
        Sink sink{marks, completions};

        zones.feed(byteSpan(bytes), {}, sink);
      }

      feed(byteSpan(bytes).subspan(fed));
      blocks.follow();
    }

    // Keys that reach the shell's line editor.
    void type(std::string_view text) {
      zones.input(byteSpan(text));
    }

    // A prompt, a command typed at it and the start of its output, as the shell prints them.
    [[nodiscard]] std::string command(std::string_view text) const {
      return mark("A") + "$ " + mark("B") + std::string{text} + "\r\n" + mark("C");
    }

    std::span<const CommandBlock> shown() {
      return blocks.message(7, storage).blocks;
    }
  };

  // A read that holds many commands, a script's or a fast shell's, places every one of their
  // marks: each command has its block, ended with its own status.
  void blocksKeepEveryMarkOfOneRead() {
    ShellSession session{{40, 100, 8, 16}};
    std::string read;

    for (int index = 1; index <= 20; ++index) {
      read += session.command(std::format("step{}", index)) + "out\r\n" + session.finished(index);
    }

    session.print(read);
    const auto shown = session.shown();

    check(shown.size() == 20, std::format("{} blocks of 20 commands", shown.size()));
    for (std::size_t index = 0; index < shown.size(); ++index) {
      check(shown[index].command.ends_with(std::format("step{}", index + 1)), std::string{shown[index].command});
      check(shown[index].state == CommandBlockState::failed && shown[index].status == static_cast<int>(index) + 1, std::format("block {} ended with {}", index + 1, shown[index].status));
    }
  }

  // A command line wider than the pane wraps; the rows its block gives the prompt and the command
  // follow the reflow, so the boundary stays on the output's first line however the pane is
  // resized.
  void boundaryStaysOnTheOutputAfterAResize() {
    ShellSession session{{40, 12, 8, 16}};
    const std::string line(60, 'x');

    session.print(session.command("echo " + line) + "out\r\n" + session.finished(0));
    check(session.shown().size() == 1 && session.shown()[0].rows == 2, std::format("{} rows at 40 columns", session.shown()[0].rows));

    // "$ echo " and the 60 x take 67 columns: one row at 80, four at 20.
    session.terminal.resize({80, 12, 8, 16});
    session.blocks.follow(true);
    check(session.shown()[0].rows == 1, std::format("{} rows at 80 columns", session.shown()[0].rows));

    session.terminal.resize({20, 12, 8, 16});
    session.blocks.follow(true);
    check(session.shown()[0].rows == 4, std::format("{} rows at 20 columns", session.shown()[0].rows));
  }

  // Ctrl-L clears the screen and the line editor draws its prompt again, with a B mark but no A
  // (precmd does not run). The next command's block starts on that prompt, not on the one the
  // screen showed before.
  void ctrlLStartsTheBlockAtTheRedrawnPrompt() {
    ShellSession session;

    session.print(session.command("first") + "one\r\n" + session.finished(0));
    session.print(session.mark("A") + "$ " + session.mark("B"));
    std::uint32_t before = 0;

    {
      const auto shown = session.shown();

      check(shown.size() == 1);
      before = shown[0].row + shown[0].rows + 1;
    }

    // Ctrl-L, then the prompt drawn again on the cleared screen, then a command typed at it.
    session.print("\x1b[H\x1b[2J$ " + session.mark("B"));
    session.print("second\r\n" + session.mark("C") + "two\r\n" + session.finished(0));
    const auto shown = session.shown();

    check(shown.size() == 2 && shown.back().command.ends_with("second"), "Ctrl-L left a block of its own");
    check(shown.back().row > before, std::format("the block starts on row {}, where the prompt before Ctrl-L was ({})", shown.back().row, before));
    check(shown.back().rows == 1, std::format("the block takes {} rows for a one-row prompt", shown.back().rows));
    for (std::size_t index = 1; index < shown.size(); ++index) {
      check(shown[index - 1].row + shown[index - 1].rows <= shown[index].row, "blocks out of order");
    }
  }

  // `clear` erases the screen and the scrollback: the blocks drawn on them go, and the command
  // after it has the only block.
  void clearDropsTheBlocksItErased() {
    ShellSession session;

    session.print(session.command("first") + "one\r\n" + session.finished(0));
    session.print(session.command("clear") + "\x1b[H\x1b[2J\x1b[3J" + session.finished(0));
    session.print(session.command("after") + "three\r\n" + session.finished(0));
    const auto shown = session.shown();

    check(shown.size() == 1, std::format("{} blocks after clear", shown.size()));
    check(shown[0].command.ends_with("after") && shown[0].row == 0 && shown[0].rows == 1);
    check(session.blocks.latest()->command.view().ends_with("after"));
  }

  // A full reset (RIS, `reset`) erases everything the blocks were drawn on, as `clear` does.
  void resetDropsTheBlocks() {
    ShellSession session;

    session.print(session.command("first") + "one\r\n" + session.finished(0));
    session.print(session.command("second") + "two\r\n" + session.finished(0));
    session.print(session.command("reset") + "\x1b"
                                             "c" +
                  session.finished(0));
    session.print(session.command("after") + "three\r\n" + session.finished(0));
    const auto shown = session.shown();

    check(shown.size() == 1 && shown[0].command.ends_with("after"), std::format("{} blocks after a reset", shown.size()));
  }

  // A program that draws from the top of the screen over earlier rows, as `tput cup 0 0` or a
  // full-screen program without the alternate screen leaves it, puts the next prompt over blocks
  // drawn there: those blocks go, and the ones left stay in order.
  void promptOverEarlierBlocksDropsThem() {
    ShellSession session;

    session.print(session.command("first") + "one\r\n" + session.finished(0));
    session.print(session.command("second") + "two\r\n" + session.finished(0));
    session.print(session.command("tput cup 0 0") + "\x1b[H" + session.finished(0));
    session.print(session.command("after") + "three\r\n" + session.finished(0));
    const auto shown = session.shown();

    check(shown.size() == 1 && shown[0].command.ends_with("after") && shown[0].row == 0, std::format("{} blocks, the last at row {}", shown.size(), shown.back().row));
  }

  // zsh's spelling correction asks after the command's C mark; answered with e(dit), the line
  // goes back to the line editor and never runs. zsh runs precmd, whose integration says so
  // with an input mark before its D and A, as zsh 5.9 prints them. It leaves no block, no
  // running command and no end, and the command that runs next has its block on the prompt
  // drawn again.
  void correctionEditedLeavesNoBlock() {
    ShellSession session;

    session.print(session.mark("A") + "$ " + session.mark("B"));
    session.type("first\r");
    session.print("first\r\n" + session.mark("C") + "one\r\n" + session.finished(0) + session.mark("A") + "$ " + session.mark("B"));
    session.type("lss\r");
    session.print("lss\r\n" + session.mark("C") + "zsh: correct 'lss' to 'ls' [nyae]? ");
    check(session.shown().back().state == CommandBlockState::running && session.zones.running());

    session.print("e\r\n" + session.mark("B") + session.finished(0) + session.mark("A") + "$ " + session.mark("B") + "lss");
    {
      const auto shown = session.shown();

      check(shown.size() == 1 && shown[0].command.ends_with("first"), "the command taken back kept its block");
      check(!session.zones.running() && session.zones.editing(), "the shell is not back at its prompt");
      check(session.blocks.latest()->command.view().ends_with("first") && session.blocks.latest()->state == CommandBlockState::succeeded, "the pane says the command taken back runs");
    }

    session.type("\x15ls\r");
    session.print("\r\x1b[K$ " + session.mark("B") + "ls\r\n" + session.mark("C") + "file\r\n" + session.finished(0));
    const auto shown = session.shown();

    check(shown.size() == 2 && shown[1].command.ends_with("ls") && !shown[1].command.contains("lss") && shown[1].state == CommandBlockState::succeeded);
    check(shown[1].rows == 1, std::format("the block takes {} rows: it starts on the prompt the correction left", shown[1].rows));
    check(session.completions.size() == 2, std::format("{} commands ended; two ran", session.completions.size()));
  }

  const telar::testing::Case case_correction_edited{"command_blocks.correction_edited_leaves_no_block", correctionEditedLeavesNoBlock};
  const telar::testing::Case case_prompt_over_blocks{"command_blocks.prompt_over_earlier_blocks_drops_them", promptOverEarlierBlocksDropsThem};

  // A block says where and when its command started: the directory the shell last reported, the
  // host and user it ran as, the branch of that directory's repository and the wall clock.
  void blockSaysWhereItsCommandStarted() {
    ShellSession session;
    const auto before = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();

    session.print("\x1b]7;file://build-host/home/alice/my%20project\x07" + session.command("make") + "built\r\n" + session.finished(0));
    session.branch = "feature/x";
    session.print("\x1b]7;file://build-host/tmp\x07" + session.command("ls") + "file\r\n" + session.finished(0));
    const auto after = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    const auto shown = session.shown();

    check(shown.size() == 2);
    check(shown[0].directory == "/home/alice/my project" && shown[0].host == "build-host" && shown[0].user == "alice" && shown[0].branch == "main", std::string{shown[0].directory});
    check(shown[1].directory == "/tmp" && shown[1].branch == "feature/x");
    check(shown[0].started_ms >= before && shown[1].started_ms <= after && shown[0].started_ms <= shown[1].started_ms, "the start is not the wall clock's");
  }

  // Inside an ssh session a block is the remote shell's: its host, directory and user, and no
  // branch of this host's repository.
  void remoteBlockSaysWhereItsCommandStarted() {
    ShellSession session;
    const auto nonce = ShellToken::generate();
    const auto remote = ShellToken::generate();
    const auto signed_by = [](const ShellToken& token, std::string_view action) {
      return std::format("\x1b]133;{};telar={}\x07", action, token.text());
    };

    session.print(session.command("ssh box") + std::format("\x1b]6973;telar={};nest={}\x07", session.token.text(), nonce.text()));
    session.print(std::format("\x1b]6973;nest={};token={};shell=bash;user=root\x07", nonce.text(), remote.text()));
    session.print(signed_by(remote, "A") + "\x1b]7;file://box/srv/app\x07# " + signed_by(remote, "B") + "uptime\r\n" + signed_by(remote, "C") + "up\r\n" + signed_by(remote, "D;0"));
    const auto shown = session.shown();

    check(shown.size() == 2 && shown[1].nest == CommandBlockNest::inside);
    check(shown[1].host == "box" && shown[1].directory == "/srv/app" && shown[1].user == "root" && shown[1].branch.empty(), std::format("{}@{}:{} on {}", shown[1].user, shown[1].host, shown[1].directory, shown[1].branch));
    check(shown[0].user == "alice" && shown[0].branch == "main", "the ssh's own block is this host's");
  }

  // A directory a client could not show, not UTF-8 or holding a control byte, is left out.
  void undisplayableDirectoryIsLeftOut() {
    ShellSession session;

    session.print("\x1b]7;file://host/tmp/a%0Ab\x07" + session.command("ls") + "x\r\n" + session.finished(0));
    session.print("\x1b]7;file://host/tmp/%FF\x07" + session.command("ls") + "x\r\n" + session.finished(0));
    const auto shown = session.shown();

    check(shown.size() == 2 && shown[0].directory.empty() && shown[1].directory.empty());
  }

  // A background job prints while the shell waits at its prompt, then zsh reports the job and
  // draws the prompt again below, as zsh 5.9 prints them. Those rows are a block of their own:
  // the command before them did not print them, and the next one starts on the prompt below.
  void backgroundOutputIsABlockOfItsOwn() {
    ShellSession session{{80, 12, 8, 16}};

    session.print(session.command("(sleep 1; echo done) &") + "[1] 4242\r\n" + session.finished(0) + session.mark("A") + session.mark("B"));
    session.print("done\r\n\x1b[K\r\r\n[1]  + done       ( sleep 1; echo done; )\r\n\x1b[J" + session.mark("B"));
    session.print("ls\r\n" + session.mark("C") + "file\r\n" + session.finished(0));
    const auto shown = session.shown();

    check(shown.size() == 3, std::format("{} blocks", shown.size()));
    check(shown[1].state == CommandBlockState::background && shown[1].rows == 0 && shown[1].command.empty());
    check(shown[0].row + shown[0].rows < shown[1].row && shown[1].row < shown[2].row, std::format("rows {} {} {}", shown[0].row, shown[1].row, shown[2].row));
    // The job's output starts on the background block's row, below the first command's own.
    check(shown[1].row == 2 && shown[2].row == 5 && shown[2].command == "ls", std::format("background at {}, ls at {}", shown[1].row, shown[2].row));
  }

  // A prompt drawn again where it was, as a theme's async segment does with reset-prompt, leaves
  // no block: nothing came between.
  void promptRedrawnInPlaceLeavesNoBlock() {
    ShellSession session;

    session.print(session.command("true") + session.finished(0) + session.mark("A") + "$ " + session.mark("B"));
    session.print("\r\x1b[K$ " + session.mark("B"));
    session.print("\r\x1b[K$ " + session.mark("B") + "ls\r\n" + session.mark("C") + "file\r\n" + session.finished(0));
    const auto shown = session.shown();

    check(shown.size() == 2 && shown[1].command.ends_with("ls"), std::format("{} blocks", shown.size()));
  }

  // Blocks an earlier runtime kept come back before the new shell's, without rows: that
  // runtime's scrollback is gone. A command that still ran when it ended was interrupted.
  void restoredBlocksComeFirstWithoutRows() {
    ShellSession session;

    session.blocks.restore({.state = CommandBlockState::failed, .status = 2, .duration_ms = 40, .started_ms = 1000, .command = "make", .directory = "/src", .host = "box", .user = "alice", .branch = "main"});
    session.blocks.restore({.state = CommandBlockState::running, .started_ms = 2000, .command = "sleep 100", .directory = "/src"});
    session.print(session.command("ls") + "file\r\n" + session.finished(0));
    session.print(session.command("pwd") + "/src\r\n" + session.finished(0));
    const auto shown = session.shown();

    check(shown.size() == 4, std::format("{} blocks", shown.size()));
    check(shown[0].restored && shown[0].rows == 0 && shown[0].command == "make" && shown[0].state == CommandBlockState::failed && shown[0].status == 2 && shown[0].directory == "/src" && shown[0].branch == "main");
    check(shown[1].restored && shown[1].command == "sleep 100" && shown[1].state == CommandBlockState::interrupted);
    check(!shown[2].restored && shown[2].command.ends_with("ls") && shown[2].rows == 1 && !shown[3].restored && shown[2].row < shown[3].row);

    // They take no rows of this terminal: a clear does not drop them.
    session.print(session.command("clear") + "\x1b[H\x1b[2J\x1b[3J" + session.finished(0));
    session.print(session.command("after") + "x\r\n" + session.finished(0));
    check(session.shown().size() == 3 && session.shown()[0].restored && session.shown()[1].restored, "a clear dropped the restored blocks");
  }

  const telar::testing::Case case_restored_first{"command_blocks.restored_blocks_come_first_without_rows", restoredBlocksComeFirstWithoutRows};

  // bash reports a job that ended while it waited at its prompt between its end mark and the
  // next prompt, as telar's integration has it do: a block of its own, not the command's output
  // nor the next prompt's.
  void jobReportsAfterACommandAreABlockOfTheirOwn() {
    ShellSession session;

    session.print(session.command("true") + session.finished(0) + "[1]+  Done                    sleep 1\r\n" + session.reported(0) + session.mark("A") + "$ " + session.mark("B"));
    session.print("ls\r\n" + session.mark("C") + "file\r\n" + session.finished(0) + session.reported(0));
    const auto shown = session.shown();

    check(shown.size() == 3, std::format("{} blocks", shown.size()));
    check(shown[1].state == CommandBlockState::background && shown[1].row == 1 && shown[1].rows == 0, std::format("the report's block starts on row {}", shown[1].row));
    check(shown[2].command.ends_with("ls") && shown[2].row == 2, std::format("the next block starts on row {}", shown[2].row));
  }

  // zsh reports them after the command's output ended (its PROMPT_SP), before the precmd hooks;
  // what the hooks print is not the report.
  void zshJobReportsEndBeforeThePrecmdHooks() {
    ShellSession session;
    const auto ended = std::format("\x1b]6973;telar={};ended\x07", session.token.text());

    session.print(session.command("true") + ended + "%" + std::string(39, ' ') + "\r \r" + "[1]  + done       sleep 1\r\n" + session.reported(0) + "hook\r\n" + session.finished(0) + session.mark("A") + "$ " + session.mark("B"));
    session.print("ls\r\n" + session.mark("C") + "file\r\n");
    const auto shown = session.shown();

    check(shown.size() == 3 && shown[1].state == CommandBlockState::background && shown[1].row == 1, std::format("{} blocks", shown.size()));
    check(shown[2].row == 3, std::format("the hook's line stays before the report's block ends: ls starts on row {}", shown[2].row));
  }

  // A job that ended while the command ran is reported as bash waited for it, above its end mark:
  // the lines the integration counts, which read as bash's reports, are a block of their own.
  void reportsBashPrintedAsTheCommandEndedAreABlockOfTheirOwn() {
    ShellSession session;

    session.print(session.command("sleep 2") + "slept\r\n[1]+  Done                    sleep 1\r\n[2]   Exit 1                  false\r\n" + session.finished(0) + session.reported(3) + session.mark("A") + "$ " + session.mark("B"));
    const auto shown = session.shown();

    check(shown.size() == 2 && shown[1].state == CommandBlockState::background, std::format("{} blocks", shown.size()));
    check(shown[1].row == 2, std::format("the reports start on row {}, after the command's own line", shown[1].row));
  }

  // Lines that read as reports are the command's when the shell counts none: `jobs` prints them.
  void reportLikeOutputStaysTheCommands() {
    ShellSession session;
    const auto forged = std::format("\x1b]6973;telar={};jobs=1\x07", std::string(32, '0'));

    session.print(session.command("jobs") + "[1]+  Running                 sleep 100 &\r\n" + session.finished(0) + session.reported(0) + session.mark("A") + "$ " + session.mark("B"));
    session.print(session.command("jobs") + "[1]+  Running                 sleep 100 &\r\n" + session.finished(0) + forged + session.mark("A") + "$ " + session.mark("B"));
    const auto shown = session.shown();

    check(shown.size() == 2 && shown[0].command.ends_with("jobs") && shown[1].command.ends_with("jobs"), std::format("{} blocks", shown.size()));
  }

  const telar::testing::Case case_background_output{"command_blocks.background_output_is_a_block_of_its_own", backgroundOutputIsABlockOfItsOwn};
  const telar::testing::Case case_job_reports{"command_blocks.job_reports_after_a_command_are_a_block_of_their_own", jobReportsAfterACommandAreABlockOfTheirOwn};
  const telar::testing::Case case_zsh_job_reports{"command_blocks.zsh_job_reports_end_before_the_precmd_hooks", zshJobReportsEndBeforeThePrecmdHooks};
  const telar::testing::Case case_waited_reports{"command_blocks.reports_bash_printed_as_the_command_ended_are_a_block_of_their_own", reportsBashPrintedAsTheCommandEndedAreABlockOfTheirOwn};
  const telar::testing::Case case_report_like_output{"command_blocks.report_like_output_stays_the_commands", reportLikeOutputStaysTheCommands};
  const telar::testing::Case case_redrawn_in_place{"command_blocks.prompt_redrawn_in_place_leaves_no_block", promptRedrawnInPlaceLeavesNoBlock};
  const telar::testing::Case case_block_place{"command_blocks.block_says_where_its_command_started", blockSaysWhereItsCommandStarted};
  const telar::testing::Case case_remote_block_place{"command_blocks.remote_block_says_where_its_command_started", remoteBlockSaysWhereItsCommandStarted};
  const telar::testing::Case case_undisplayable_directory{"command_blocks.undisplayable_directory_is_left_out", undisplayableDirectoryIsLeftOut};
  const telar::testing::Case case_boundary_after_resize{"command_blocks.boundary_stays_on_the_output_after_a_resize", boundaryStaysOnTheOutputAfterAResize};
  const telar::testing::Case case_ctrl_l{"command_blocks.ctrl_l_starts_the_block_at_the_redrawn_prompt", ctrlLStartsTheBlockAtTheRedrawnPrompt};
  const telar::testing::Case case_clear{"command_blocks.clear_drops_the_blocks_it_erased", clearDropsTheBlocksItErased};
  const telar::testing::Case case_reset{"command_blocks.reset_drops_the_blocks", resetDropsTheBlocks};
  const telar::testing::Case case_keep_every_mark{"command_blocks.keep_every_mark_of_one_read", blocksKeepEveryMarkOfOneRead};

}
