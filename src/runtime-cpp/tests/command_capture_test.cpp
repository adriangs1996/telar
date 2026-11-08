#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include "telar_base/diagnostics/config.hpp"
#include <cstring>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <cassert>
#include <ghostty/vt.h>

import std;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.tests.check;
import telar.runtime.command_capture.tracker;

using namespace telar;
using namespace telar::runtime;

static std::span<const Byte> byteSpan(std::string_view text) {
  return {reinterpret_cast<const Byte *>(text.data()), text.size()};
}

struct CommandRecord {
  std::string command;
  std::string directory;
  std::string output;
  CapturedCommand metadata;
};

struct CaptureFixture {
  SystemAllocator memory;
  Terminal<SystemAllocator> terminal{memory, {20, 4, 8, 16}, TerminalPurpose::observation};
  CommandTracker<SystemAllocator> tracker{memory, terminal, "/initial", true};
  std::vector<CommandRecord> commands;

  void emit(const CapturedCommand &command) {
    auto metadata = command;
    metadata.command = {};
    metadata.directory = {};
    metadata.output = {};
    commands.push_back({std::string{command.command}, std::string{command.directory}, std::string{reinterpret_cast<const char *>(command.output.data()), command.output.size()}, metadata});
  }

  void input(std::string_view text, std::int64_t time = 100, std::optional<bool> foreground = true) {
    tracker.input({byteSpan(text), {time, time * 1'000'000}, foreground}, *this);
  }

  void output(std::string_view text, std::int64_t time = 110, std::optional<bool> foreground = true) {
    tracker.output({byteSpan(text), {time, time * 1'000'000}, foreground}, *this);
  }

  void finish(std::int64_t time = 120, int code = 0) {
    tracker.complete({{time, time * 1'000'000}, code}, *this);
  }
};

static void testInputBoundaries() {
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

static void testRenderedCommand() {
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

static void testWrappedAndUnicodeCommand() {
  CaptureFixture fixture;
  fixture.output("$ ");
  const std::string command = "printf 'á好🙂abcdefghijklmno'";
  fixture.input(command + "\r");
  fixture.output(command + "\r\n");
  fixture.finish();
  check(fixture.commands.size() == 1 && fixture.commands[0].command == command);
}

static void testRightPrompt() {
  CaptureFixture fixture;
  fixture.output("$ \x1b[1;15Hclock\x1b[1;3H");
  fixture.input("ls\r");
  fixture.output("ls\r\n");
  fixture.finish();
  check(fixture.commands.size() == 1 && fixture.commands[0].command == "ls");
}

static void testMovedEdit() {
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

static void testCompletionEvidence() {
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

static void testShellMarkers() {
  CaptureFixture fixture;
  fixture.output("\x1b]7;file://host/new%20path\x07\x1b]133;A\x07$ \x1b]133;B\x07");
  fixture.input("false\r", 100, std::nullopt);
  fixture.output("false\r\n\x1b]133;C\x07output\r\n\x1b]133;D;7;ignored\x1b\\", 130, std::nullopt);
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

static void testDiscardedEdits() {
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

static void testOutputTailBounds() {
  SystemAllocator memory;
  CommandOutputTail tail{memory, true};
  tail.append(byteSpan(std::string(60'000, 'a')));
  tail.append(byteSpan(std::string(40'000, 'b')));
  check(tail.bytes().size() == tail.capacity && tail.observed() == 100'000);
  check(tail.bytes().front() == 'a' && tail.bytes().back() == 'b');
  tail.append(byteSpan(std::string(80'000, 'c')));
  check(tail.bytes().size() == tail.capacity && tail.observed() == 180'000);
  check(std::ranges::all_of(tail.bytes(), [](Byte byte) { return byte == 'c'; }));
}

static void testCaptureBoundsAndResize() {
  CaptureFixture large;
  large.output("$ ");
  const std::string command = std::string(CommandSelection<SystemAllocator>::maximum_bytes - 1, 'a') + "🙂";
  large.input(command + "\r");
  large.output(command + "\r\n");
  large.finish();
  check(large.commands.size() == 1 && large.commands[0].metadata.truncated);
  check(large.commands[0].command == command.substr(0, CommandSelection<SystemAllocator>::maximum_bytes - 1));

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

static void testOscFragments() {
  struct Completions {
    std::vector<CommandCompletion> values;

    void complete(CommandCompletion completion) {
      values.push_back(completion);
    }
  };

  const std::string prompt = "ignored\x1b]7;kitty-shell-cwd://host/new%20directory\x1b\\\x1b]133;A\x07$ \x1b]133;B\x07";
  const std::string completion = "\x1b]133;C\x07output\x1b]133;D;+12;extra\x1b\\";
  for (std::size_t width = 1; width <= prompt.size(); ++width) {
    CommandZones zones{"/initial"};
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

void testCommandCapture() {
  testInputBoundaries();
  testRenderedCommand();
  testWrappedAndUnicodeCommand();
  testRightPrompt();
  testMovedEdit();
  testCompletionEvidence();
  testShellMarkers();
  testDiscardedEdits();
  testOutputTailBounds();
  testCaptureBoundsAndResize();
  testOscFragments();
}
