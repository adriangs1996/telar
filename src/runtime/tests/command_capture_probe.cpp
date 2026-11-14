// Runs command cycles as telar's zsh integration prints them, with marks signed by the pane's
// token, through the two places the runtime scans them, and times them.
// tools/bench_command_capture.py alternates two builds of it.
//
//   pane-<workload>      what a pane's read does in client_layouts: CommandZones finds the
//                        marks, the terminal is fed up to each one and CommandBlocks places it.
//   observer-<workload>  what PaneObserver does with the same bytes: CommandTracker reads the
//                        command back from its own terminal and reports it.
//
//   command-capture-probe --list
//   command-capture-probe --describe <case>
//   command-capture-probe <case> <iterations>
//
// Prints `<elapsed ns> <digest>`: the time spent in the cycles, and an FNV-1a digest of the
// marks, blocks and captured commands, which must match between builds. --describe prints how
// many of each one iteration produces, and the last command captured, to check that a
// workload reaches the scan.
#include <cstdio>
#include <cstdlib>

import std;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.config.core;
import telar.platform.events;
import telar.runtime.command_capture.tracker;
import telar.runtime.graphics.kitty;
import telar.runtime.graphics.pane_media;
import telar.runtime.shell_integration.token;
import telar.runtime.terminal.control;
import telar.runtime.terminal.text_reader;

using namespace telar;
using namespace telar::runtime;

namespace {
  constexpr std::string_view token_text = "0123456789abcdef0123456789abcdef";
  constexpr std::string_view forged_text = "00000000000000000000000000000000";

  struct Workload {
    std::string_view name;
    // What the user types, fed as pane input; empty when nothing is typed.
    std::string typed;
    // Bytes per input event; 0 sends the typed text at once.
    std::size_t typed_fragment;
    // What the pty prints for one cycle.
    std::string output;
    // Bytes per read of the pty; 0 reads the whole output at once.
    std::size_t fragment;
  };

  std::string repeat(std::string_view text, std::size_t count) {
    std::string result;

    result.reserve(text.size() * count);
    for (std::size_t index = 0; index < count; ++index) {
      result += text;
    }

    return result;
  }

  std::string mark(std::string_view body, std::string_view signer = token_text) {
    return "\x1b]133;" + std::string{body} + ";telar=" + std::string{signer} + "\a";
  }

  // What _telar_prompt prints after a command, and the prompt with its input mark.
  std::string prompt(int status, std::string_view signer = token_text) {
    return mark("D;" + std::to_string(status), signer) + mark("A", signer) + "\x1b]7;file://host/home/user/src/telar\a" + "user@host ~/src/telar % " + mark("B", signer);
  }

  std::string listing() {
    return repeat("-rw-r--r--  1 user  staff   4096 Nov 14 10:00 control.cpp\r\n", 40);
  }

  // The command echoed, the command mark, its output and the next prompt.
  std::string cycle(std::string_view command, std::string_view output, std::string_view signer = token_text) {
    return std::string{command} + "\r\n" + mark("C", signer) + std::string{output} + prompt(0, signer);
  }

  std::string pathReport() {
    std::string path = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

    for (int index = 0; index < 24; ++index) {
      path += ":/home/user/.local/tool-" + std::to_string(index) + "/bin";
    }

    return "\x1b]6973;telar=" + std::string{token_text} + ";path=" + path + "\a";
  }

  std::vector<Workload> workloads() {
    return {
        // A command with 40 lines of output, read at once.
        {"command-cycle", "ls -la\r", 0, cycle("ls -la", listing()), 0},
        // The same, in the reads of a slower producer.
        {"command-cycle-256-byte-reads", "ls -la\r", 0, cycle("ls -la", listing()), 256},
        // Typing: each key is one input event and its echo one read.
        {"typed-1-byte-echo", "git status --short\r", 1, cycle("git status --short", " M tracker.cppm\r\n"), 1},
        // A long-running command's output, with no mark: the scan over ordinary bytes.
        {"plain-output", "", 0, listing(), 0},
        // A prompt that also reports the PATH, as after a change of it.
        {"path-report", "cd\r", 0, "cd\r\n" + mark("C") + mark("D;0") + mark("A") + pathReport() + "user@host ~ % " + mark("B"), 0},
        // Marks a program printed with a signature that is not the pane's.
        {"forged-marks", "ls -la\r", 0, cycle("ls -la", listing(), forged_text), 0},
    };
  }

  struct Case {
    std::string name;
    bool pane = true;
    const Workload* workload = nullptr;
  };

  std::vector<Case> cases(const std::vector<Workload>& workloads) {
    std::vector<Case> result;

    for (const bool pane : {true, false}) {
      for (const auto& workload : workloads) {
        result.push_back({std::string{pane ? "pane-" : "observer-"} + std::string{workload.name}, pane, &workload});
      }
    }

    return result;
  }

  std::span<const Byte> bytesOf(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  struct Digest {
    std::uint64_t value = 0xcbf29ce484222325;

    void add(std::span<const Byte> bytes) noexcept {
      for (const auto byte : bytes) {
        value = (value ^ byte) * 0x100000001b3;
      }
    }

    template <typename Value>
    void add(const Value& field) noexcept {
      add(std::span{reinterpret_cast<const Byte*>(&field), sizeof(field)});
    }

    void add(std::string_view text) noexcept {
      add(text.size());
      add(bytesOf(text));
    }
  };

  struct Counts {
    std::uint64_t marks = 0;
    std::uint64_t completions = 0;
    std::uint64_t commands = 0;
    std::uint64_t blocks = 0;
    std::string last_command;
  };

  // The runtime server's allocator, as main.cpp builds it.
  struct ServerMemory {
    SystemAllocator system;
    BudgetAllocator<SystemAllocator> budget{system, std::size_t{256} * 1024 * 1024};
    SynchronizedAllocator<BudgetAllocator<SystemAllocator>> synchronized{budget};
    MemoryAdapter<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>> adapter{synchronized};
    ConcurrentMemory& memory = adapter;
  };

  // The marks of one read, as client_layouts' ShellCompletions keeps them.
  struct PaneCompletions {
    struct Mark {
      char action = 0;
      std::size_t end = 0;
      std::optional<int> status;
    };

    Digest& digest;
    Counts& counts;
    std::array<Mark, 16> kept{};
    std::size_t count = 0;

    void complete(CommandCompletion completion) noexcept {
      ++counts.completions;
      digest.add(completion.exit_code.value_or(-1));
      if (count != 0 && kept[count - 1].action == 'D') {
        kept[count - 1].status = completion.exit_code;
      }
    }

    void mark(CommandMark mark) noexcept {
      ++counts.marks;
      digest.add(mark.action);
      digest.add(mark.end);
      if (count < kept.size()) {
        kept[count++] = Mark{.action = mark.action, .end = mark.end, .status = std::nullopt};
      }
    }
  };

  class PaneProbe {
  public:
    PaneProbe(ConcurrentMemory& memory, TerminalSize size, ShellToken token)
        : media_(std::make_shared<PaneMedia<ConcurrentMemory>>(memory, budget_, GraphicsLimits{}, size, queue_)),
          terminal_(memory, size, TerminalPurpose::separate_media, queue_, GraphicsQueryResources{GraphicsLimits{}, budget_, &media_->queryUsage()}),
          zones_("/home/user/src/telar", token),
          blocks_(memory, terminal_) {
      terminal_.attachMedia(*media_);
    }

    void type(std::span<const Byte> bytes) {
      zones_.input(bytes);
    }

    // One read of the pty, as client_layouts' read() handles it.
    void read(std::span<const Byte> bytes, Digest& digest, Counts& counts) {
      PaneCompletions completions{digest, counts};
      std::size_t fed = 0;

      now_ += std::chrono::milliseconds{1};
      zones_.feed(bytes, ObservationTime{}, completions);
      for (const auto& kept : std::span{completions.kept}.first(completions.count)) {
        if (kept.end > fed) {
          terminal_.feed(bytes.subspan(fed, kept.end - fed), *media_);
          fed = kept.end;
        }

        if (kept.action == 'D') {
          blocks_.finished(kept.status, now_);
        } else {
          blocks_.mark(kept.action, now_);
        }
      }

      if (fed < bytes.size()) {
        terminal_.feed(bytes.subspan(fed), *media_);
      }

      settle();
      terminal_.followScrollback();
      blocks_.follow();
    }

    void finish(Digest& digest, Counts& counts) const {
      std::array<CommandBlock, CommandBlocks<ConcurrentMemory>::capacity> storage;
      const auto message = blocks_.message(1, storage);

      digest.add(blocks_.revision());
      for (const auto& block : message.blocks) {
        digest.add(block.row);
        digest.add(block.rows);
        digest.add(block.lines);
        digest.add(block.state);
        digest.add(block.status);
        digest.add(block.nest);
        digest.add(block.command);
        counts.last_command.assign(block.command);
      }

      counts.blocks = message.blocks.size();
    }

  private:
    // What the media worker and the reply delivery do between two reads, as in
    // terminal-media-feed-probe.
    void settle() {
      while (terminal_.hasPendingControl() || !media_->idle()) {
        if (!media_->seal()) {
          break;
        }

        media_->process();
        media_->complete();
        terminal_.resumeControl(*media_);
      }

      while (!terminal_.responses().empty()) {
        terminal_.consumeResponses(terminal_.responses().size(), *media_);
      }
    }

    MediaBudget budget_{GraphicsLimits::maximum_global_bytes};
    std::shared_ptr<PtyResponseQueue> queue_ = std::make_shared<PtyResponseQueue>();
    std::shared_ptr<PaneMedia<ConcurrentMemory>> media_;
    Terminal<ConcurrentMemory> terminal_;
    CommandZones zones_;
    CommandBlocks<ConcurrentMemory> blocks_;
    std::chrono::steady_clock::time_point now_{};
  };

  struct ObserverSink {
    Digest& digest;
    Counts& counts;

    void emit(const CapturedCommand& command) {
      ++counts.commands;
      counts.last_command.assign(command.command);
      digest.add(command.command);
      digest.add(command.directory);
      digest.add(command.exit_code.value_or(-1));
      digest.add(command.status);
      digest.add(command.truncated);
      digest.add(command.output);
      digest.add(command.output_observed);
    }
  };

  class ObserverProbe {
  public:
    ObserverProbe(ConcurrentMemory& memory, TerminalSize size, ShellToken token)
        : terminal_(memory, size, TerminalPurpose::observation),
          tracker_(memory, terminal_, "/home/user/src/telar", false, token) {}

    void type(std::span<const Byte> bytes, Digest& digest, Counts& counts) {
      ObserverSink sink{digest, counts};

      tracker_.input({bytes, tick(), true}, sink);
    }

    void read(std::span<const Byte> bytes, Digest& digest, Counts& counts) {
      ObserverSink sink{digest, counts};

      tracker_.output({bytes, tick(), true}, sink);
    }

    void finish(Digest& digest, Counts&) const {
      digest.add(tracker_.markersReady());
    }

  private:
    ObservationTime tick() noexcept {
      time_.milliseconds += 1;
      time_.nanoseconds += 1'000'000;
      return time_;
    }

    Terminal<ConcurrentMemory> terminal_;
    CommandTracker<ConcurrentMemory> tracker_;
    ObservationTime time_{1, 1'000'000};
  };

  template <typename Visit>
  void inFragments(std::string_view text, std::size_t fragment, Visit&& visit) {
    for (std::size_t offset = 0; offset < text.size();) {
      const auto count = std::min(fragment == 0 ? text.size() : fragment, text.size() - offset);

      visit(bytesOf(text.substr(offset, count)));
      offset += count;
    }
  }

  template <typename Probe>
  void run(Probe& probe, const Workload& workload, std::uint64_t iterations, Digest& digest, Counts& counts) {
    for (std::uint64_t iteration = 0; iteration < iterations; ++iteration) {
      inFragments(workload.typed, workload.typed_fragment, [&](std::span<const Byte> bytes) {
        if constexpr (std::is_same_v<Probe, PaneProbe>) {
          probe.type(bytes);
        } else {
          probe.type(bytes, digest, counts);
        }
      });

      inFragments(workload.output, workload.fragment, [&](std::span<const Byte> bytes) {
        probe.read(bytes, digest, counts);
      });
    }
  }

  // Sets the probe at a prompt, untimed, then times the cycles.
  template <typename Probe>
  std::int64_t measure(Probe& probe, const Workload& workload, std::uint64_t iterations, Digest& digest, Counts& counts) {
    const auto first = prompt(0);

    probe.read(bytesOf(first), digest, counts);

    const auto started = std::chrono::steady_clock::now();

    run(probe, workload, iterations, digest, counts);

    const auto elapsed = std::chrono::steady_clock::now() - started;

    probe.finish(digest, counts);
    return std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count();
  }
}

int main(int count, char** arguments) {
  const auto loads = workloads();
  const auto all = cases(loads);

  if (count == 2 && std::string_view{arguments[1]} == "--list") {
    for (const auto& entry : all) {
      std::printf("%s\n", entry.name.c_str());
    }

    return 0;
  }

  if (count != 3) {
    std::fprintf(stderr, "usage: %s --list | --describe <case> | <case> <iterations>\n", arguments[0]);
    return 2;
  }

  const bool describe = std::string_view{arguments[1]} == "--describe";
  const std::string_view name{arguments[describe ? 2 : 1]};
  const auto selected = std::ranges::find(all, name, &Case::name);
  const auto iterations = describe ? 1 : std::strtoull(arguments[2], nullptr, 10);
  if (selected == all.end() || iterations == 0) {
    std::fprintf(stderr, "unknown case or zero iterations\n");
    return 2;
  }

  try {
    ServerMemory memory;
    const TerminalSize size{120, 40, 9, 18};
    const auto token = *ShellToken::parse(token_text);
    Digest digest;
    Counts counts;
    std::int64_t elapsed = 0;

    if (selected->pane) {
      PaneProbe probe{memory.memory, size, token};

      elapsed = measure(probe, *selected->workload, iterations, digest, counts);
    } else {
      ObserverProbe probe{memory.memory, size, token};

      elapsed = measure(probe, *selected->workload, iterations, digest, counts);
    }

    if (describe) {
      std::printf("marks %llu completions %llu commands %llu blocks %llu last '%s'\n", static_cast<unsigned long long>(counts.marks), static_cast<unsigned long long>(counts.completions), static_cast<unsigned long long>(counts.commands), static_cast<unsigned long long>(counts.blocks), counts.last_command.c_str());
    } else {
      std::printf("%lld %016llx\n", static_cast<long long>(elapsed), static_cast<unsigned long long>(digest.value));
    }

    return 0;
  } catch (const TerminalError& error) {
    std::fprintf(stderr, "probe failed: %s:%u: %s (%d)\n", error.location().file_name(), error.location().line(), error.what(), static_cast<int>(error.result()));
    return 1;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "probe failed: %s\n", error.what());
    return 1;
  }
}
