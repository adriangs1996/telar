// Feeds a separate_media terminal with a PaneMedia attached, as a pane in client_layouts
// does, and times the feed together with the media pump. tools/bench_terminal_media_feed.py
// alternates two builds of it.
//
//   terminal-media-feed-probe --list
//   terminal-media-feed-probe <case> <iterations>
//
// Prints `<elapsed ns> <digest>`: the time spent feeding and pumping, and an FNV-1a digest of
// the replies, which must match between builds.
#include <cstdio>
#include <cstdlib>

import std;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.config.core;
import telar.runtime.terminal.kitty;
import telar.runtime.graphics.pane_media;
import telar.runtime.terminal.control;
import telar.runtime.terminal.text_reader;

using namespace telar;
using namespace telar::runtime;

namespace {
  struct Workload {
    std::string_view name;
    std::string input;
    // Bytes per feed call; 0 feeds the whole input at once.
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

  std::vector<Workload> workloads() {
    return {
        {"ordinary", repeat("ordinary text ", 256), 0},
        {"ordinary-lines", repeat("control.cpp:123: regular compiler output\r\n", 96), 0},
        {"ordinary-styled", repeat("\x1b[1;32mcompiled\x1b[0m object.o\r\n", 96), 0},
        {"mixed", repeat(repeat("ordinary text ", 8) + "\x1b[6n", 4), 0},
        {"cursor", "\x1b[6n", 0},
        {"graphics-query", "\x1b_Ga=q,i=9,s=1,v=1;AAAAAA==\x1b\\", 0},
        // Many small feeds: the fixed cost of each call dominates.
        {"ordinary-16-byte-feeds", repeat("ordinary text ", 64), 16},
        {"ordinary-1-byte-feeds", repeat("ordinary text ", 8), 1},
        {"cursor-1-byte-feeds", "\x1b[6n", 1},
    };
  }

  struct Probe {
    SystemAllocator system;
    BudgetAllocator<SystemAllocator> budgeted{system, 64 * 1024 * 1024};
    SynchronizedAllocator<BudgetAllocator<SystemAllocator>> synchronized{budgeted};
    MemoryAdapter<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>> memory{synchronized};
    MediaBudget budget{GraphicsLimits::maximum_global_bytes};
    std::shared_ptr<PtyResponseQueue> queue = std::make_shared<PtyResponseQueue>();
    std::shared_ptr<PaneMedia> media;
    Terminal terminal;
    std::uint64_t digest = 0xcbf29ce484222325;

    explicit Probe(TerminalSize size)
        : media(std::make_shared<PaneMedia>(memory, budget, GraphicsLimits{}, size, queue)),
          terminal(memory, size, TerminalPurpose::separate_media, queue, GraphicsQueryResources{GraphicsLimits{}, budget, &media->queryUsage()}) {
      terminal.attachMedia(*media);
    }

    // What the runtime's media worker and its reply delivery do between two reads of the pty.
    void settle() {
      while (terminal.hasPendingControl() || !media->idle()) {
        if (!media->seal()) {
          break;
        }

        media->process();
        media->complete();
        terminal.resumeControl(*media);
      }

      while (!terminal.responses().empty()) {
        const auto replies = terminal.responses();

        for (const auto byte : replies) {
          digest = (digest ^ byte) * 0x100000001b3;
        }

        terminal.consumeResponses(replies.size(), *media);
      }
    }

    void feed(std::span<const Byte> bytes, std::size_t fragment) {
      for (std::size_t offset = 0; offset < bytes.size();) {
        const auto count = std::min(fragment == 0 ? bytes.size() : fragment, bytes.size() - offset);

        terminal.feed(bytes.subspan(offset, count), *media);
        settle();
        offset += count;
      }
    }
  };
}

int main(int count, char** arguments) {
  const auto cases = workloads();

  if (count == 2 && std::string_view{arguments[1]} == "--list") {
    for (const auto& workload : cases) {
      std::printf("%.*s\n", static_cast<int>(workload.name.size()), workload.name.data());
    }

    return 0;
  }

  if (count != 3) {
    std::fprintf(stderr, "usage: %s --list | <case> <iterations>\n", arguments[0]);
    return 2;
  }

  const std::string_view name{arguments[1]};
  const auto workload = std::ranges::find(cases, name, &Workload::name);
  const auto iterations = std::strtoull(arguments[2], nullptr, 10);
  if (workload == cases.end() || iterations == 0) {
    std::fprintf(stderr, "unknown case or zero iterations\n");
    return 2;
  }

  try {
    Probe probe{TerminalSize{80, 24, 9, 18}};
    const std::span bytes{reinterpret_cast<const Byte*>(workload->input.data()), workload->input.size()};
    const auto started = std::chrono::steady_clock::now();

    for (std::uint64_t iteration = 0; iteration < iterations; ++iteration) {
      probe.feed(bytes, workload->fragment);
    }

    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();

    std::printf("%lld %016llx\n", static_cast<long long>(elapsed), static_cast<unsigned long long>(probe.digest));
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "probe failed: %s\n", error.what());
    return 1;
  }
}
