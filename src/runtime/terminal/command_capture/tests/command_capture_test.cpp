#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/diagnostics/config.hpp"
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <ghostty/vt.h>
#include <sys/mman.h>

import std;
import telar.base.memory.allocators;

import telar.runtime.terminal.control;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.terminal.command_capture.tracker;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.runtime.history.command;
import telar.runtime.terminal.shell_integration.token;
import telar.runtime.terminal.text_reader;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::span<const Byte> byteSpan(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  struct CommandRecord {
    std::string command;
    std::string directory;
    std::string output;
    CapturedCommand metadata;
  };

  struct CaptureFixture {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, {20, 4, 8, 16}, TerminalPurpose::observation};
    CommandTracker tracker{memory, terminal, "/initial", true};
    std::vector<CommandRecord> commands;

    void emit(const CapturedCommand& command) {
      auto metadata = command;

      metadata.command = {};
      metadata.directory = {};
      metadata.output = {};
      commands.push_back({std::string{command.command}, std::string{command.directory}, std::string{reinterpret_cast<const char*>(command.output.data()), command.output.size()}, metadata});
    }

    void input(std::string_view text, std::int64_t time = 100, ds::Option<bool> foreground = true) {
      tracker.input({byteSpan(text), {time, time * 1'000'000}, foreground}, *this);
    }

    void output(std::string_view text, std::int64_t time = 110, ds::Option<bool> foreground = true) {
      tracker.output({byteSpan(text), {time, time * 1'000'000}, foreground}, *this);
    }

    void finish(std::int64_t time = 120, int code = 0) {
      tracker.complete({{time, time * 1'000'000}, code}, *this);
    }
  };

  // The marks the pane's shell signs end the command's output, but what is stored holds none of
  // them, nor the token they carry, however the bytes arrive.
  void testOutputDropsIntegrationMarks() {
    for (const std::size_t piece : {std::size_t{1}, std::size_t{5}, std::size_t{4096}}) {
      telar::testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      const auto token = ShellToken::generate();
      const auto signature = ";telar=" + std::string{token.text()};
      Terminal terminal{memory, {20, 4, 8, 16}, TerminalPurpose::observation};
      CommandTracker tracker{memory, terminal, "/initial", true, token};
      std::vector<std::string> outputs;

      struct Sink {
        std::vector<std::string>& outputs;

        void emit(const CapturedCommand& command) {
          outputs.emplace_back(reinterpret_cast<const char*>(command.output.data()), command.output.size());
        }
      } sink{outputs};

      const auto output = [&](std::string_view text) {
        for (std::size_t offset = 0; offset < text.size(); offset += piece) {
          tracker.output({byteSpan(text.substr(offset, piece)), {110, 110'000'000}, true}, sink);
        }
      };

      output("\x1b]133;A" + signature + "\x07$ \x1b]133;B" + signature + "\x07");
      tracker.input({byteSpan("ls\r"), {100, 100'000'000}, true}, sink);
      output("ls\r\n\x1b]133;C" + signature + "\x07"
                                              "file\r\n\x1b]133;D;0" +
             signature + "\x07\x1b]133;A" + signature + "\x07$ ");
      check(outputs.size() == 1, "the signed D mark ends the command");
      check(!outputs.front().contains("telar="), "the stored output never holds the token");
      // The line editor's echo of the line comes before the C mark: it is the shell's.
      check(outputs.front() == "file\r\n", "the stored output is what the command printed, from its start to its end");
    }
  }

  // The shell's signed report that a command's output ended (zsh's, at the front of what it
  // prints before its prompt) ends the stored output there; one another program forges does not.
  void testOutputEndsWhereTheShellSaysSo() {
    for (const bool signed_report : {true, false}) {
      telar::testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      const auto token = ShellToken::generate();
      const auto signature = ";telar=" + std::string{token.text()};
      const auto report = signed_report ? "telar=" + std::string{token.text()} : "telar=" + std::string(ShellToken::length, '0');
      Terminal terminal{memory, {20, 4, 8, 16}, TerminalPurpose::observation};
      CommandTracker tracker{memory, terminal, "/initial", true, token};
      std::vector<std::string> outputs;

      struct Sink {
        std::vector<std::string>& outputs;

        void emit(const CapturedCommand& command) {
          outputs.emplace_back(reinterpret_cast<const char*>(command.output.data()), command.output.size());
        }
      } sink{outputs};

      const auto output = [&](std::string_view text) {
        tracker.output({byteSpan(text), {110, 110'000'000}, true}, sink);
      };

      output("\x1b]133;A" + signature + "\x07$ \x1b]133;B" + signature + "\x07");
      tracker.input({byteSpan("ls\r"), {100, 100'000'000}, true}, sink);
      output("ls\r\n\x1b]133;C" + signature + "\x07"
                                              "file\r\n\x1b]6973;" +
             report + ";ended\x07%   \r \r\x1b]133;D;0" + signature + "\x07\x1b]133;A" + signature + "\x07$ ");
      check(outputs.size() == 1, "the D mark ends the command");
      check(signed_report ? outputs.front() == "file\r\n" : outputs.front().starts_with("file\r\n%"), signed_report ? "what the shell prints once the command ended is not its output" : "a forged report ends nothing");
    }
  }

  // What a command printed after `prompt`, fed in chunks of `piece` bytes, as the history stores it.
  std::string capturedTail(std::string_view printed, std::size_t piece) {
    CaptureFixture fixture;

    fixture.output("$ ");
    fixture.input("run\r");
    fixture.output("run\r\n");
    for (std::size_t offset = 0; offset < printed.size(); offset += piece) {
      fixture.output(printed.substr(offset, piece));
    }

    fixture.finish();
    check(fixture.commands.size() == 1, std::to_string(fixture.commands.size()) + " commands for " + std::to_string(printed.size()) + " bytes in " + std::to_string(piece));
    return fixture.commands.empty() ? std::string{} : fixture.commands[0].output;
  }

  // However the output arrives, the stored tail is the last 64 KiB of it, all of them.
  void testOutputTailKeepsTheLast64KiB() {
    constexpr std::size_t kept = std::size_t{64} * 1024;
    std::string printed;

    for (std::size_t line = 0; printed.size() < 3 * kept; ++line) {
      printed += "line " + std::to_string(line) + "\r\n";
    }

    for (const std::size_t piece : {std::size_t{1000}, std::size_t{5000}, std::size_t{40000}, std::size_t{200000}}) {
      check(capturedTail(printed, piece) == printed.substr(printed.size() - kept), "the tail is exactly the last 64 KiB");
    }
  }

  // `count` bytes of lines of `fill`, as a command prints them.
  std::string lines(char fill, std::size_t count) {
    std::string text;

    while (text.size() < count) {
      text += std::string(78, fill) + "\r\n";
    }

    text.resize(count);
    return text;
  }

  // A tail that would start inside a character, or inside an escape sequence, starts after it.
  void testOutputTailStartsAtABoundary() {
    constexpr std::size_t kept = std::size_t{64} * 1024;
    // Lines of two-byte characters, with the cut on the second byte of one.
    std::string accents;

    while (accents.size() < 2 * kept) {
      accents += std::string{"\xc3\xa9"} + (accents.size() % 160 == 158 ? "\r\n" : "");
    }

    while (static_cast<unsigned char>(accents[accents.size() - kept]) != 0xa9) {
      accents += "y";
    }

    check(capturedTail(accents, 4096) == accents.substr(accents.size() - kept + 1), "a split character is left out whole");

    // A color sequence with the cut in its parameters.
    const auto after_color = lines('b', kept - 5);
    const auto colored = lines('a', 2000) + "\x1b[38;5;196m" + after_color;
    check(capturedTail(colored, 3000) == after_color, "a split escape sequence is left out whole");

    // A hyperlink whose cut falls in its URL: the tail starts after the sequence's terminator.
    const auto after_link = lines('d', kept - 100);
    const auto linked = lines('c', 500) + "\x1b]8;;https://example.com/" + std::string(300, 'p') + "\x1b\\" + after_link;
    check(capturedTail(linked, 7000) == after_link, "a split hyperlink is left out whole");
  }

  void testInputBoundaries() {
    CommandInputScanner scanner;

    check(!scanner.feed(byteSpan("abc\x7f\x08z")).submitted);
    check(scanner.typedText() == "az");
    check(scanner.feed(byteSpan("\r")).submitted);
    scanner.reset();
    for (const char character : std::string_view{"\x1b[200~line\nother\r\x1b[201~"}) {
      check(!scanner.feed(byteSpan(std::string_view{&character, 1})).submitted);
    }

    check(!scanner.typedText());
    check(scanner.feed(byteSpan("\r")).submitted);
    scanner.reset();
    check(scanner.feed(byteSpan("\x03")).cancelled);
    scanner.reset();
    check(!scanner.feed(byteSpan(std::string(256, 'a'))).submitted);
    check(!scanner.typedText());
  }

  void testRenderedCommand() {
    CaptureFixture fixture;

    check(!fixture.tracker.needsForegroundObservation());
    fixture.output("$ ");
    fixture.input("echo wrong");
    check(!fixture.tracker.needsForegroundObservation());
    fixture.input("\r");
    check(fixture.tracker.needsForegroundObservation());
    fixture.output("echo right\r\nresult\r\n");
    check(fixture.tracker.needsForegroundObservation());
    fixture.finish();
    check(!fixture.tracker.needsForegroundObservation());
    check(fixture.commands.size() == 1);
    check(fixture.commands[0].command == "echo right");
    check(fixture.commands[0].directory == "/initial");
    check(fixture.commands[0].metadata.duration_ns == 20'000'000);
    check(fixture.commands[0].output == "echo right\r\nresult\r\n");
  }

  void testWrappedAndUnicodeCommand() {
    CaptureFixture fixture;

    fixture.output("$ ");
    const std::string command = "printf 'á好🙂abcdefghijklmno'";

    fixture.input(command + "\r");
    fixture.output(command + "\r\n");
    fixture.finish();
    check(fixture.commands.size() == 1 && fixture.commands[0].command == command);
  }

  void testRightPrompt() {
    CaptureFixture fixture;

    fixture.output("$ \x1b[1;15Hclock\x1b[1;3H");
    fixture.input("ls\r");
    fixture.output("ls\r\n");
    fixture.finish();
    check(fixture.commands.size() == 1 && fixture.commands[0].command == "ls");
  }

  void testMovedEdit() {
    CaptureFixture fixture;

    fixture.input("ls");
    fixture.output("\r\n$ ls");
    fixture.input("\r");
    fixture.output("\r\n");
    fixture.finish();
    check(fixture.commands.size() == 1 && fixture.commands[0].command == "ls");

    CaptureFixture cleared;

    cleared.output("$ ");
    cleared.input("ls");
    cleared.output("ls");
    cleared.input("\x0c");
    cleared.output("\x1b[2J\x1b[3;1Hnew$ ls");
    cleared.input("\r");
    cleared.output("\r\n");
    cleared.finish();
    check(cleared.commands.size() == 1 && cleared.commands[0].command == "ls");
  }

  void testCompletionEvidence() {
    CaptureFixture fixture;

    fixture.output("$ ");
    fixture.input("cmd\r");
    fixture.output("cmd\r\n", 110, false);
    check(fixture.commands.empty());
    fixture.output("$ ", 130, true);
    check(fixture.commands.size() == 1 && !fixture.commands[0].metadata.exit_code);
    check(fixture.commands[0].metadata.duration_ns == 30'000'000);

    CaptureFixture next_input;

    next_input.output("$ ");
    next_input.input("cmd\r");
    next_input.output("cmd\r\n$ ", 120);
    next_input.input("next", 900);
    check(next_input.commands.size() == 1 && next_input.commands[0].metadata.duration_ns == 20'000'000);
#if TELAR_DIAGNOSTICS
    const auto foreground = fixture.tracker.takeMetrics();

    check(foreground.submissions == 1 && foreground.captures == 1 && foreground.foreground_completions == 1);
    check(foreground.next_input_completions == 0 && foreground.auxiliary_completions == 0);
    const auto next = next_input.tracker.takeMetrics();

    check(next.submissions == 1 && next.captures == 1 && next.next_input_completions == 1);
    check(next.foreground_completions == 0 && next.auxiliary_completions == 0);
#endif
  }

  void testShellMarkers() {
    CaptureFixture fixture;

    fixture.output("\x1b]7;file://host/new%20path\x07\x1b]133;A\x07$ \x1b]133;B\x07");
    fixture.input("false\r", 100, ds::none);
    fixture.output("false\r\n\x1b]133;C\x07output\r\n\x1b]133;D;7;ignored\x1b\\", 130, ds::none);
    check(fixture.commands.size() == 1);
    check(fixture.commands[0].command == "false");
    check(fixture.commands[0].directory == "/new path");
    check(fixture.commands[0].metadata.exit_code == 7);
    check(fixture.commands[0].metadata.duration_ns == 30'000'000);
#if TELAR_DIAGNOSTICS
    const auto metrics = fixture.tracker.takeMetrics();

    check(metrics.prompt_markers == 1 && metrics.input_markers == 1 && metrics.output_markers == 1 && metrics.finished_markers == 1);
    check(metrics.osc_started == 5 && metrics.osc_finished == 5);
    check(metrics.submissions == 1 && metrics.captures == 1 && metrics.capture_failures == 0 && metrics.auxiliary_completions == 1);
    check(metrics.foreground_completions == 0 && metrics.next_input_completions == 0);
#endif
  }

  void testDiscardedEdits() {
    CaptureFixture cancelled;

    cancelled.output("$ ");
    cancelled.input("bad\x03");
    cancelled.output("bad\r\n");
    cancelled.finish();
    check(cancelled.commands.empty());

    CaptureFixture alternate;

    alternate.output("\x1b[?1049h");
    alternate.input("not shell\r");
    alternate.output("not shell\r\n");
    alternate.finish();
    check(alternate.commands.empty());

    CaptureFixture erased;

    erased.output("$ ");
    erased.input("lost\r");
    erased.output("\x1b[2J\x1b[3;1Hnot command\r\n");
    erased.finish();
    check(erased.commands.empty());
#if TELAR_DIAGNOSTICS
    check(cancelled.tracker.takeMetrics().submissions == 0);
    check(alternate.tracker.takeMetrics().submissions == 0);
    check(erased.tracker.takeMetrics().capture_failures == 1);
#endif
  }

  void testCaptureBoundsAndResize() {
    CaptureFixture large;

    large.output("$ ");
    const std::string command = std::string(CommandSelection::maximum_bytes - 1, 'a') + "🙂";

    large.input(command + "\r");
    large.output(command + "\r\n");
    large.finish();
    check(large.commands.size() == 1 && large.commands[0].metadata.truncated);
    check(large.commands[0].command == command.substr(0, CommandSelection::maximum_bytes - 1));

    CaptureFixture resized;

    resized.output("$ ");
    resized.input("echo abcdefghijklmnop");
    resized.output("echo abcdefghijklmnop");
    resized.terminal.resize({10, 4, 8, 16});
    resized.input("\r");
    resized.output("\r\n");
    resized.finish();
    check(resized.commands.size() == 1 && resized.commands[0].command == "echo abcdefghijklmnop");
  }

  void testOscFragments() {
    SystemAllocator zone_system;
    MemoryAdapter<SystemAllocator> zone_adapter{zone_system};
    ConcurrentMemory& zone_memory = zone_adapter;

    struct Completions {
      std::vector<CommandCompletion> values;

      void complete(CommandCompletion completion) {
        values.push_back(completion);
      }
    };

    const std::string prompt = "ignored\x1b]7;kitty-shell-cwd://host/new%20directory\x1b\\\x1b]133;A\x07$ \x1b]133;B\x07";
    const std::string completion = "\x1b]133;C\x07output\x1b]133;D;+12;extra\x1b\\";

    for (std::size_t width = 1; width <= prompt.size(); ++width) {
      CommandZones zones{zone_memory, "/initial"};
      Completions sink;

      for (std::size_t offset = 0; offset < prompt.size(); offset += width) {
        zones.feed(byteSpan(std::string_view{prompt}.substr(offset, width)), {100, 100}, sink);
      }

      check(zones.markersReady() && zones.editing() && zones.directory() == "/new directory");
      zones.input(byteSpan("command\r"));
      for (std::size_t offset = 0; offset < completion.size(); offset += width) {
        zones.feed(byteSpan(std::string_view{completion}.substr(offset, width)), {200, 200}, sink);
      }

      check(sink.values.size() == 1 && sink.values[0].exit_code == 12);
      check(sink.values[0].status == HistoryStatus::completed && sink.values[0].time.nanoseconds == 200);
#if TELAR_DIAGNOSTICS
      const auto metrics = zones.takeMetrics();

      check(metrics.osc_started == 5 && metrics.osc_finished == 5);
      check(metrics.prompt_markers == 1 && metrics.input_markers == 1 && metrics.output_markers == 1 && metrics.finished_markers == 1);
      check(zones.takeMetrics().osc_started == 0);
#endif
    }
  }

  // A pane with a token trusts only the marks its shell integration signed.
  void testSignedMarks() {
    SystemAllocator zone_system;
    MemoryAdapter<SystemAllocator> zone_adapter{zone_system};
    ConcurrentMemory& zone_memory = zone_adapter;

    struct Completions {
      std::vector<CommandCompletion> values;

      void complete(CommandCompletion completion) {
        values.push_back(completion);
      }
    };

    const auto token = ShellToken::generate();
    const auto signature = ";telar=" + std::string{token.text()};
    const auto forged = ";telar=" + std::string(ShellToken::length, '0');
    CommandZones zones{zone_memory, "/", token};
    Completions sink;

    zones.feed(byteSpan("\x1b]133;A\x07\x1b]133;B\x07"), {}, sink);
    zones.feed(byteSpan("\x1b]133;A" + forged + "\x07\x1b]133;B" + forged + "\x07"), {}, sink);
    check(!zones.markersReady() && !zones.editing());

    zones.feed(byteSpan("\x1b]133;A" + signature + "\x07\x1b]133;B" + signature + "\x07"), {}, sink);
    check(zones.markersReady() && zones.editing());
    zones.input(byteSpan("true\r"));
    zones.feed(byteSpan("\x1b]133;C" + signature + "\x07\x1b]133;D;9\x07\x1b]133;D;9" + forged + "\x07"), {}, sink);
    check(sink.values.empty());
    zones.feed(byteSpan("\x1b]133;D;4" + signature + "\x07"), {}, sink);
    check(sink.values.size() == 1 && sink.values[0].exit_code == 4);

    // The shell redraws its prompt after input already arrived, as zsh does after a paste.
    zones.feed(byteSpan("\x1b]133;A" + signature + "\x07\x1b]133;B" + signature + "\x07"), {}, sink);
    zones.input(byteSpan("\x1b[200~ls\x1b[201~\r"));
    zones.feed(byteSpan("\x1b]133;B" + signature + "\x07\x1b]133;C" + signature + "\x07\x1b]133;D;0" + signature + "\x07"), {}, sink);
    check(sink.values.size() == 2 && sink.values[1].exit_code == 0);
  }

  // `ssh` nests a remote shell: the pane's shell signs a one-time nonce, the remote shell
  // answers with it and its own token, and the pane's token signing a mark again ends it.
  void testNestedMarks() {
    SystemAllocator zone_system;
    MemoryAdapter<SystemAllocator> zone_adapter{zone_system};
    ConcurrentMemory& zone_memory = zone_adapter;

    struct Completions {
      std::vector<CommandCompletion> values;

      void complete(CommandCompletion completion) {
        values.push_back(completion);
      }
    };

    const auto token = ShellToken::generate();
    const auto nonce = ShellToken::generate();
    const auto remote = ShellToken::generate();
    const auto signature = ";telar=" + std::string{token.text()};
    const auto remote_signature = ";telar=" + std::string{remote.text()};
    const auto answer = "\x1b]6973;nest=" + std::string{nonce.text()} + ";token=" + std::string{remote.text()} + ";shell=fish\x07";
    CommandZones zones{zone_memory, "/", token};
    Completions sink;

    // An answer nobody asked for, or one to a nonce the pane's shell did not sign, is ignored.
    zones.feed(byteSpan(answer), {}, sink);
    zones.feed(byteSpan("\x1b]6973;telar=" + std::string(ShellToken::length, '0') + ";nest=" + std::string{nonce.text()} + "\x07" + answer), {}, sink);
    check(!zones.remote());

    zones.feed(byteSpan("\x1b]133;A" + signature + "\x07\x1b]133;B" + signature + "\x07"), {}, sink);
    zones.input(byteSpan("ssh host\r"));
    zones.feed(byteSpan("\x1b]133;C" + signature + "\x07\x1b]6973" + signature + ";nest=" + std::string{nonce.text()} + "\x07"), {}, sink);
    zones.feed(byteSpan("\x1b]133;A" + remote_signature + "\x07"), {}, sink);
    check(!zones.remote() && zones.running());
    zones.feed(byteSpan(answer), {}, sink);
    check(zones.remote() && zones.remoteShell() == IntegratedShell::fish);

    // The remote shell's marks count; its PATH is not this host's and is not taken.
    zones.feed(byteSpan("\x1b]133;A" + remote_signature + "\x07\x1b]133;B" + remote_signature + "\x07\x1b]6973" + remote_signature + ";path=/remote\x07"), {}, sink);
    check(zones.editing() && zones.path().empty());
    zones.input(byteSpan("false\r"));
    zones.feed(byteSpan("\x1b]133;C" + remote_signature + "\x07\x1b]133;D;1" + remote_signature + "\x07"), {}, sink);
    check(sink.values.size() == 1 && sink.values.back().exit_code == 1);

    // The nonce is spent: a second answer cannot replace the remote token.
    const auto other = ShellToken::generate();

    zones.feed(byteSpan("\x1b]6973;nest=" + std::string{nonce.text()} + ";token=" + std::string{other.text()} + "\x07"), {}, sink);
    zones.feed(byteSpan("\x1b]133;A;telar=" + std::string{other.text()} + "\x07\x1b]133;C" + remote_signature + "\x07"), {}, sink);
    check(zones.running());

    // ssh returned: the pane's shell marks again, and finishes the ssh command with its status.
    const auto remote_commands = sink.values.size();

    zones.feed(byteSpan("\x1b]133;D;5" + signature + "\x07\x1b]133;A" + signature + "\x07"), {}, sink);
    check(!zones.remote() && zones.remoteShell() == IntegratedShell::none);
    check(sink.values.size() == remote_commands + 1 && sink.values.back().exit_code == 5);
    zones.feed(byteSpan("\x1b]133;B" + remote_signature + "\x07"), {}, sink);
    check(!zones.editing());

    // A nonce the session never answered expires when the pane's shell prompts again.
    zones.feed(byteSpan("\x1b]6973" + signature + ";nest=" + std::string{nonce.text()} + "\x07\x1b]133;A" + signature + "\x07" + answer), {}, sink);
    check(!zones.remote());
  }

  // The socket of the connection a session shares comes only from the nonce the pane's own shell
  // signs, and only a path ssh.sh could have named; it is the pane's while the remote shell is.
  void testControlComesOnlyFromThePanesOwnNest() {
    SystemAllocator zone_system;
    MemoryAdapter<SystemAllocator> zone_adapter{zone_system};
    ConcurrentMemory& zone_memory = zone_adapter;

    struct Completions {
      void complete(CommandCompletion) {}
    };

    const auto token = ShellToken::generate();
    const auto remote = ShellToken::generate();
    const auto signature = ";telar=" + std::string{token.text()};
    Completions sink;
    // The pane's shell hands a nonce naming `control`; the remote shell answers it, naming `own`.
    const auto nest = [&](std::string_view control, std::string_view own = {}) {
      CommandZones zones{zone_memory, "/", token};
      const auto nonce = ShellToken::generate();
      const auto named = control.empty() ? std::string{} : ";control=" + std::string{control};
      const auto answered = own.empty() ? std::string{} : ";control=" + std::string{own};

      zones.feed(byteSpan("\x1b]6973" + signature + ";nest=" + std::string{nonce.text()} + named + "\x07"), {}, sink);
      check(zones.remoteControl().empty(), "the socket is the session's once its shell answers");
      zones.feed(byteSpan("\x1b]6973;nest=" + std::string{nonce.text()} + ";token=" + std::string{remote.text()} + ";shell=zsh" + answered + "\x07"), {}, sink);
      check(zones.remote());
      return std::string{zones.remoteControl()};
    };

    // A socket telar named for the session's host, by a digest of it.
    const auto socket = "/run/user/1000/telar/ssh/" + std::string(40, 'f');

    check(nest(socket) == socket);
    check(nest("/home/me/.ssh/cm-me@build-01:22") == "/home/me/.ssh/cm-me@build-01:22", "a ControlPath of the user's own");
    check(nest({}).empty(), "a session that shares nothing");
    check(nest({}, "/tmp/evil").empty(), "the remote shell cannot name a socket");
    for (const std::string_view refused : {"relative/socket", "/tmp/../run/socket", "/tmp/./socket", "/tmp//socket", "/tmp/socket/", "/tmp/a b", "/tmp/a%3bb", "/tmp/$(id)"}) {
      check(nest(refused).empty(), std::format("{} is refused", refused));
    }

    check(nest("/" + std::string(CommandZones::control_capacity, 'a')).empty(), "a path no socket address holds");

    // ssh returned: the pane's own shell has no shared connection.
    CommandZones zones{zone_memory, "/", token};
    const auto nonce = ShellToken::generate();

    zones.feed(byteSpan("\x1b]6973" + signature + ";nest=" + std::string{nonce.text()} + ";control=/run/telar/ssh/m\x07\x1b]6973;nest=" + std::string{nonce.text()} + ";token=" + std::string{remote.text()} + ";shell=bash\x07"), {}, sink);
    check(zones.remoteControl() == "/run/telar/ssh/m");
    zones.feed(byteSpan("\x1b]133;A" + signature + "\x07"), {}, sink);
    check(!zones.remote() && zones.remoteControl().empty());
  }

  // telar's private reports count only when the pane's shell signs them; without a token no mark
  // is signed, so nothing a program prints changes the PATH completion searches.
  void testPrivateReportWithoutToken() {
    SystemAllocator zone_system;
    MemoryAdapter<SystemAllocator> zone_adapter{zone_system};
    ConcurrentMemory& zone_memory = zone_adapter;

    struct Completions {
      void complete(CommandCompletion) {}
    };

    const auto token = ShellToken::generate();
    const auto report = "\x1b]6973;telar=" + std::string{token.text()} + ";path=/evil\x07";
    Completions sink;
    CommandZones signed_zones{zone_memory, "/", token};

    signed_zones.feed(byteSpan(report), {}, sink);
    check(signed_zones.path() == "/evil");

    CommandZones zones{zone_memory, "/"};

    zones.feed(byteSpan(report), {}, sink);
    zones.feed(byteSpan("\x1b]6973;telar=;path=/evil\x07"), {}, sink);
    check(zones.path().empty(), "an unsigned report changed the PATH");
    zones.feed(byteSpan("\x1b]6973;nest=" + std::string{token.text()} + ";token=" + std::string{token.text()} + ";shell=fish\x07"), {}, sink);
    check(!zones.remote());
  }

  // A pane keeps its newest 64 command blocks, the most the wire carries.
  void testBlockRingKeepsNewest() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{40, 12, 8, 16}};
    CommandBlocks blocks{memory, terminal};
    const auto now = std::chrono::steady_clock::now();
    const auto mark = [&](char action, std::string_view sequence) {
      terminal.feed(byteSpan(sequence));
      blocks.mark(action, now);
    };

    for (int index = 1; index <= 65; ++index) {
      mark('A', "\x1b]133;A\x07");
      mark('B', "$ \x1b]133;B\x07");
      terminal.feed(byteSpan(std::format("command{:02}\r\n", index)));
      mark('C', "\x1b]133;C\x07");
      terminal.feed(byteSpan("\x1b]133;D;0\x07"));
      blocks.finished(0, now);
      blocks.follow();
    }

    ds::Array<CommandBlock, PaneBlocks::capacity> storage;
    const auto shown = blocks.message(7, storage).blocks;

    check(shown.size() == PaneBlocks::capacity);
    check(shown.front().command.ends_with("command02"), "the oldest block was kept");
    check(shown.back().command.ends_with("command65"));
  }

  // What a pane's shell runs or last ran is kept apart from the blocks: how it ended, and still
  // there once the scrollback dropped the rows its block was anchored to.
  void testLatestCommand() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{40, 12, 8, 16}};
    CommandBlocks blocks{memory, terminal};
    const auto started = std::chrono::steady_clock::now();
    const auto run = [&](std::string_view command) {
      terminal.feed(byteSpan("\x1b]133;A\x07"));
      blocks.mark('A', started);
      terminal.feed(byteSpan("$ \x1b]133;B\x07"));
      blocks.mark('B', started);
      terminal.feed(byteSpan(command));
      terminal.feed(byteSpan("\r\n\x1b]133;C\x07"));
      blocks.mark('C', started);
    };

    check(!blocks.latest() && blocks.commandRevision() == 0, "a shell that ran nothing has no command");

    run("make test");
    check(blocks.latest().hasValue() && blocks.commandRevision() == 1);
    check(blocks.latest()->state == CommandBlockState::running && blocks.latest()->command.view().ends_with("make test") && !blocks.latest()->truncated);

    blocks.finished(3, started + std::chrono::milliseconds{2500});
    check(blocks.commandRevision() == 2 && blocks.latest()->state == CommandBlockState::failed && blocks.latest()->status == 3 && blocks.latest()->duration_ms == 2500);
    blocks.finished(0, started + std::chrono::seconds{9});
    check(blocks.commandRevision() == 2 && blocks.latest()->status == 3, "a command ends once");

    // A prompt with no D mark interrupts the command: it reported no status.
    run("sleep 100");
    check(blocks.commandRevision() == 3 && blocks.latest()->state == CommandBlockState::running);
    terminal.feed(byteSpan("^C\r\n\x1b]133;A\x07"));
    blocks.mark('A', started + std::chrono::seconds{1});
    check(blocks.commandRevision() == 4 && blocks.latest()->state == CommandBlockState::interrupted && blocks.latest()->command.view().ends_with("sleep 100"));

    // The scrollback drops every row: the blocks go with them, the last command stays.
    const std::size_t limit = 1;

    check(ghostty_terminal_set(terminal.handle(), GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit) == GHOSTTY_SUCCESS);
    for (std::size_t batch = 0; batch < 4000 && terminal.scrollbackTrimmed() == 0; ++batch) {
      terminal.feed(byteSpan("scrollback line\r\nscrollback line\r\nscrollback line\r\nscrollback line\r\n"));
      terminal.followScrollback();
    }

    for (std::size_t line = 0; line < 64; ++line) {
      terminal.feed(byteSpan("scrollback line\r\n"));
    }

    terminal.followScrollback();
    blocks.follow();
    ds::Array<CommandBlock, PaneBlocks::capacity> storage;

    check(terminal.scrollbackTrimmed() > 0 && blocks.message(7, storage).blocks.empty(), "the blocks were not dropped");
    check(blocks.commandRevision() == 4 && blocks.latest()->command.view().ends_with("sleep 100"), "the last command went with its block");
  }

  // A command the line editor took back before it ran, as zsh's spelling correction does when
  // the answer is e(dit), is not recorded: the history holds the command that ran after it.
  void testCommandTakenBackIsNotRecorded() {
    CaptureFixture fixture;

    fixture.output("\x1b]133;A\x07$ \x1b]133;B\x07");
    fixture.input("lss\r", 100, ds::none);
    fixture.output("lss\r\n\x1b]133;C\x07zsh: correct 'lss' to 'ls' [nyae]? ", 101, ds::none);
    fixture.input("e", 102, ds::none);
    fixture.output("e\r\n\x1b]133;B\x07\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07lss", 103, ds::none);
    fixture.tracker.submitCommand(byteSpan("ls"));
    fixture.input("\x15ls\r", 104, ds::none);
    fixture.output("\r\x1b[K$ \x1b]133;B\x07ls\r\n\x1b]133;C\x07"
                   "file\r\n\x1b]133;D;0\x07",
        105,
        ds::none);

    check(fixture.commands.size() == 1, std::format("{} commands recorded", fixture.commands.size()));
    check(fixture.commands[0].command == "ls", fixture.commands[0].command);
  }

  // Ctrl-C (status 130, SIGINT) and a pipeline cut short (141, SIGPIPE) interrupt a command; any
  // other status but zero fails it.
  void testSignalStatusInterrupts() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{40, 12, 8, 16}};
    CommandBlocks blocks{memory, terminal};
    const auto now = std::chrono::steady_clock::now();
    const auto run = [&](std::string_view command, int status) {
      terminal.feed(byteSpan("\x1b]133;A\x07"));
      blocks.mark('A', now);
      terminal.feed(byteSpan("$ \x1b]133;B\x07"));
      blocks.mark('B', now);
      terminal.feed(byteSpan(command));
      terminal.feed(byteSpan("\r\n\x1b]133;C\x07"));
      blocks.mark('C', now);
      blocks.finished(status, now);
      return blocks.latest()->state;
    };

    check(run("sleep 100", 130) == CommandBlockState::interrupted, "Ctrl-C failed the command");
    check(blocks.latest()->status == 130, "the status was lost");
    check(run("yes | head -1", 141) == CommandBlockState::interrupted, "a broken pipe failed the command");
    check(run("false", 1) == CommandBlockState::failed);
    check(run("kill -TERM $$", 143) == CommandBlockState::failed, "only SIGINT and SIGPIPE interrupt");

    ds::Array<CommandBlock, PaneBlocks::capacity> storage;
    const auto shown = blocks.message(7, storage).blocks;

    check(shown.size() == 4 && shown[0].state == CommandBlockState::interrupted && shown[1].state == CommandBlockState::interrupted && shown[2].state == CommandBlockState::failed);
  }

  // An OSC longer than the 16 KiB a pane keeps is dropped whole: its kept prefix is never read.
  void testOverlongOscIgnored() {
    SystemAllocator zone_system;
    BudgetAllocator zone_budget{zone_system, 1 << 20};
    SynchronizedAllocator zone_synchronized{zone_budget};
    MemoryAdapter zone_adapter{zone_synchronized};
    ConcurrentMemory& zone_memory = zone_adapter;

    struct Completions {
      void complete(CommandCompletion) {}
    };

    const auto token = ShellToken::generate();
    const auto names = "\x1b]6973;telar=" + std::string{token.text()} + ";names=";
    CommandZones zones{zone_memory, "/initial", token};
    Completions sink;

    zones.feed(byteSpan("\x1b]7;file://host/" + std::string(17 * 1024, 'a') + "\x1b\\"), {}, sink);
    check(zones.directory() == "/initial", "a prefix of an overlong directory report was taken");

    zones.feed(byteSpan(names + "ll gs\x07"), {}, sink);
    check(zones.names() != nullptr && *zones.names() == "ll gs");
    check(zone_budget.liveBytes() != 0, "the names live in the zones' allocator");

    // Names that did not fit are unknown, not the ones that did.
    zones.feed(byteSpan(names + std::string(17 * 1024, 'n') + "\x07"), {}, sink);
    check(zones.names() == nullptr, "a prefix of an overlong names report was taken");
    check(zone_budget.liveBytes() == 0, "names no one holds go back to the allocator");

    // The next report is read again.
    zones.feed(byteSpan("\x1b]7;file://host/next\x07"), {}, sink);
    check(zones.directory() == "/next");
  }

  // The line a shell's editor held, as its integration reports it: %-encoded and signed by the
  // pane's shell, or by the remote shell ssh reached. What is kept is text to show, at most the
  // capacity, cut on a character; a report no shell signed, or that is not UTF-8, changes nothing.
  void testTypeaheadReport() {
    SystemAllocator zone_system;
    MemoryAdapter<SystemAllocator> zone_adapter{zone_system};
    ConcurrentMemory& zone_memory = zone_adapter;

    struct Completions {
      void complete(CommandCompletion) {}
    };

    const auto token = ShellToken::generate();
    const auto report = [&](std::string_view signature, std::string_view line) {
      return "\x1b]6973;telar=" + std::string{signature} + ";typeahead=" + std::string{line} + "\x07";
    };

    // Every byte but a letter, a digit or '-' %-encoded: more than an integration encodes, which
    // the line decodes all the same.
    const auto encoded = [](std::string_view line) {
      std::string text;

      for (const char byte : line) {
        if ((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '-') {
          text += byte;
        } else {
          text += std::format("%{:02X}", static_cast<unsigned char>(byte));
        }
      }

      return text;
    };

    CommandZones zones{zone_memory, "/", token};
    Completions sink;

    check(zones.typeaheadSerial() == 0 && zones.typeahead().empty());
    zones.feed(byteSpan(report(token.text(), encoded("ls -l; x%y\nnext\t\x01"))), {}, sink);
    check(zones.typeaheadSerial() == 1 && zones.typeahead() == "ls -l; x%y\nnext\t ", std::string{zones.typeahead()});

    // Forged, malformed, or not UTF-8: the line stays.
    const auto forged = ShellToken::generate();

    zones.feed(byteSpan(report(forged.text(), "rm")), {}, sink);
    zones.feed(byteSpan(report(token.text(), "bad%2")), {}, sink);
    zones.feed(byteSpan(report(token.text(), "%FF%FE")), {}, sink);
    check(zones.typeaheadSerial() == 1 && zones.typeahead().starts_with("ls -l"), "a report that is not the shell's line replaced it");

    // A line longer than kept ends on a whole character.
    std::string long_line;

    for (std::size_t index = 0; index < CommandZones::typeahead_capacity / 2; ++index) {
      long_line += "%C3%A9";
    }

    zones.feed(byteSpan(report(token.text(), "x" + long_line)), {}, sink);
    check(zones.typeaheadSerial() == 2 && zones.typeahead().size() == CommandZones::typeahead_capacity - 1 && zones.typeahead().ends_with("\xc3\xa9"), std::format("{} bytes kept", zones.typeahead().size()));

    // The shell ssh reached signs its own.
    const auto nonce = ShellToken::generate();
    const auto remote = ShellToken::generate();

    zones.feed(byteSpan("\x1b]6973;telar=" + std::string{token.text()} + ";nest=" + std::string{nonce.text()} + "\x07"), {}, sink);
    zones.feed(byteSpan("\x1b]6973;nest=" + std::string{nonce.text()} + ";token=" + std::string{remote.text()} + ";shell=bash\x07"), {}, sink);
    check(zones.remote());
    zones.feed(byteSpan(report(remote.text(), "uptime")), {}, sink);
    check(zones.typeaheadSerial() == 3 && zones.typeahead() == "uptime", "the remote shell's line was not taken");
  }

  // A prompt while a command runs, with no D mark, ends that command as interrupted.
  void testPromptWhileRunningInterrupts() {
    SystemAllocator zone_system;
    MemoryAdapter<SystemAllocator> zone_adapter{zone_system};
    ConcurrentMemory& zone_memory = zone_adapter;

    struct Completions {
      std::vector<CommandCompletion> values;

      void complete(CommandCompletion completion) {
        values.push_back(completion);
      }
    };

    CommandZones zones{zone_memory, "/"};
    Completions sink;

    zones.feed(byteSpan("\x1b]133;A\x07$ \x1b]133;B\x07"), {}, sink);
    zones.input(byteSpan("sleep 100\r"));
    zones.feed(byteSpan("\x1b]133;C\x07"), {}, sink);
    check(zones.running() && sink.values.empty());

    zones.feed(byteSpan("^C\r\n\x1b]133;A\x07"), {300, 300}, sink);
    check(sink.values.size() == 1 && sink.values[0].status == HistoryStatus::interrupted && !sink.values[0].exit_code);
    check(!zones.running());
  }

  const telar::testing::Case case_output_drops_integration_marks{"command_capture.output_drops_integration_marks", testOutputDropsIntegrationMarks};
  const telar::testing::Case case_signed_marks{"command_capture.signed_marks", testSignedMarks};
  const telar::testing::Case case_nested_marks{"command_capture.nested_marks", testNestedMarks};
  const telar::testing::Case case_output_ends_where_the_shell_says_so{"command_capture.output_ends_where_the_shell_says_so", testOutputEndsWhereTheShellSaysSo};
  const telar::testing::Case case_output_tail_keeps_the_last_64_kib{"command_capture.output_tail_keeps_the_last_64_kib", testOutputTailKeepsTheLast64KiB};
  const telar::testing::Case case_output_tail_starts_at_a_boundary{"command_capture.output_tail_starts_at_a_boundary", testOutputTailStartsAtABoundary};
  const telar::testing::Case case_input_boundaries{"command_capture.input_boundaries", testInputBoundaries};
  const telar::testing::Case case_rendered_command{"command_capture.rendered_command", testRenderedCommand};
  const telar::testing::Case case_wrapped_and_unicode_command{"command_capture.wrapped_and_unicode_command", testWrappedAndUnicodeCommand};
  const telar::testing::Case case_right_prompt{"command_capture.right_prompt", testRightPrompt};
  const telar::testing::Case case_moved_edit{"command_capture.moved_edit", testMovedEdit};
  const telar::testing::Case case_completion_evidence{"command_capture.completion_evidence", testCompletionEvidence};
  const telar::testing::Case case_shell_markers{"command_capture.shell_markers", testShellMarkers};
  const telar::testing::Case case_discarded_edits{"command_capture.discarded_edits", testDiscardedEdits};
  const telar::testing::Case case_capture_bounds_and_resize{"command_capture.capture_bounds_and_resize", testCaptureBoundsAndResize};
  const telar::testing::Case case_osc_fragments{"command_capture.osc_fragments", testOscFragments};
  const telar::testing::Case case_control_from_own_nest{"command_capture.control_comes_only_from_the_panes_own_nest", testControlComesOnlyFromThePanesOwnNest};
  const telar::testing::Case case_private_report_without_token_ignored{"command_capture.private_report_without_token_ignored", testPrivateReportWithoutToken};
  const telar::testing::Case case_block_ring_keeps_newest{"command_capture.block_ring_keeps_newest", testBlockRingKeepsNewest};
  const telar::testing::Case case_latest_command{"command_capture.latest_command", testLatestCommand};
  const telar::testing::Case case_typeahead_report{"command_capture.typeahead_report", testTypeaheadReport};
  const telar::testing::Case case_command_taken_back{"command_capture.command_taken_back_is_not_recorded", testCommandTakenBackIsNotRecorded};
  const telar::testing::Case case_signal_status_interrupts{"command_capture.signal_status_interrupts", testSignalStatusInterrupts};
  const telar::testing::Case case_overlong_osc_ignored{"command_capture.overlong_osc_ignored", testOverlongOscIgnored};
  const telar::testing::Case case_prompt_while_running_interrupts{"command_capture.prompt_while_running_interrupts", testPromptWhileRunningInterrupts};

}
