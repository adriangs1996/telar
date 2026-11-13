// Source-extracted observeFrames oracle with actual frame types and Qt events.
// Preparation/presentation are simulated; native scene and acknowledgement tests
// remain required. Queued callbacks must retain their own immutable snapshots.
#include "application.hpp"
#include <QCoreApplication>
#include <QGuiApplication>
#include <QQuickWindow>
#include <charconv>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <deque>
#include <stdexcept>
#include <string_view>

namespace telar::gui::test {
struct FramePacing {
  using Frame = qt::Application::PresentedFrame;
};
}

using namespace telar::gui;
using PresentedFrame = test::FramePacing::Frame;

struct WindowImages {
  static void forWindow(QQuickWindow &) {}
};

static void require(bool value) {
  if (!value) {
    throw std::runtime_error("Frame snapshot oracle mismatch");
  }
}

static void fill(PresentedFrame &frame, std::uint64_t seed, std::size_t panes, bool history, bool links) {
  frame = {};
  frame.machine_view = 7;
  frame.preparation_ns = seed;
  frame.pane_count = panes;
  frame.tabs.machine_view = seed;
  frame.tabs.count = seed % frame.tabs.targets.size();
  for (std::size_t i = 0; i < frame.tabs.count; ++i) {
    frame.tabs.targets[i] = {.id = seed + i, .bounds = {float(i), float(seed % 31), 11, 17}};
  }

  for (std::size_t i = 0; i < panes; ++i) {
    auto &pane = frame.panes[i];
    pane.frame.pane = {.pane_id = i + 1, .frame_id = seed, .attached = true, .attachment_generation = seed / 13, .graphics_revision = seed * 2};
    pane.frame.revision = seed * 3 + i;
    if (links) {
      pane.frame.links.emplace();
      pane.frame.links->surface = {.content = {1, 2, 3, 4}, .cell = {5, 6}, .attachment_generation = seed, .scale = 2};
      pane.frame.links->cover = Rect{7, 8, 9, 10};
      auto link = std::make_shared<LinkHit>(LinkHit{.match = {.target = *LinkTarget::fromUri("https://snapshot.test"), .start = {}, .end = {}}});
      link->pane_id = seed + i;
      link->generation = seed;
      pane.frame.links->link = std::move(link);
    }
  }

  if (history) {
    frame.history.emplace();
    frame.history->choice = {.index = static_cast<std::size_t>(seed % 19), .revision = seed};
    frame.history->dialog_generation = seed / 3;
    frame.history->enter_runs = seed % 2;
    frame.history_surface = {.bounds = {1, 2, 3, 4}, .generation = seed, .revision = seed * 2, .row_height = 17, .cell_height = 13, .scale = 2, .delivered = true, .has_rows = true};
    frame.history_actions.generation = seed;
    auto &hover = frame.history_hover.emplace();
    hover.count = hover.targets.size();
    hover.generation = seed;
    for (std::size_t i = 0; i < hover.count; ++i) {
      hover.targets[i].identity.generation = seed + i;
      hover.targets[i].bounds = {float(i), 2, 3, 4};
    }
  }
}

static bool equal(const PresentedFrame &a, const PresentedFrame &b) {
  if (a.machine_view != b.machine_view || a.preparation_ns != b.preparation_ns || a.pane_count != b.pane_count || a.tabs.machine_view != b.tabs.machine_view || a.tabs.count != b.tabs.count || a.history.has_value() != b.history.has_value() || a.history_hover.has_value() != b.history_hover.has_value()) {
    return false;
  }

  for (std::size_t i = 0; i < a.tabs.count; ++i) {
    if (a.tabs.targets[i].id != b.tabs.targets[i].id || a.tabs.targets[i].bounds != b.tabs.targets[i].bounds) {
      return false;
    }
  }

  for (std::size_t i = 0; i < a.pane_count; ++i) {
    const auto &x = a.panes[i].frame;
    const auto &y = b.panes[i].frame;
    if (x.pane.pane_id != y.pane.pane_id || x.pane.frame_id != y.pane.frame_id || x.pane.attached != y.pane.attached || x.pane.attachment_generation != y.pane.attachment_generation || x.pane.graphics_revision != y.pane.graphics_revision || x.revision != y.revision || x.links.has_value() != y.links.has_value()) {
      return false;
    }

    if (x.links && (x.links->surface != y.links->surface || x.links->cover != y.links->cover || *x.links->link != *y.links->link)) {
      return false;
    }
  }

  if (a.history && (a.history->choice != b.history->choice || a.history->dialog_generation != b.history->dialog_generation || a.history->enter_runs != b.history->enter_runs || a.history_surface.bounds != b.history_surface.bounds || a.history_surface.revision != b.history_surface.revision || a.history_surface.generation != b.history_surface.generation || a.history_surface.row_height != b.history_surface.row_height || a.history_surface.cell_height != b.history_surface.cell_height || a.history_surface.scale != b.history_surface.scale || a.history_surface.delivered != b.history_surface.delivered || a.history_surface.has_rows != b.history_surface.has_rows || a.history_actions.generation != b.history_actions.generation)) {
    return false;
  }

  if (a.history_hover) {
    const auto &x = *a.history_hover;
    const auto &y = *b.history_hover;
    if (x.count != y.count || x.generation != y.generation) {
      return false;
    }

    for (std::size_t i = 0; i < x.count; ++i) {
      if (!(x.targets[i].identity == y.targets[i].identity) || x.targets[i].bounds != y.targets[i].bounds) {
        return false;
      }
    }
  }

  return true;
}

static SystemAllocator probe_memory;

class ProbeApplication : public QObject {
public:
  SystemAllocator &memory_ = probe_memory;
  QQuickWindow *window_ = nullptr;
  std::uint64_t window_generation_ = 1;
  std::uint64_t seed = 1;
  std::size_t panes = 1;
  bool history = false;
  bool links = false;
  bool verify = true;
  std::uint64_t digest = 0;
  std::size_t delivered = 0;
  std::weak_ptr<const LinkHit> observed_link;
  std::deque<std::unique_ptr<PresentedFrame>> expected;

  void prepareImagePlacements() {}

  void prepareFrame(PresentedFrame &frame) {
    fill(frame, seed, panes, history, links);
    observed_link = links && panes != 0 ? frame.panes[0].frame.links->link : std::shared_ptr<const LinkHit>{};
  }

  void prepareTerminalFrames(PresentedFrame &) {}

  void recordPreparedFrame(const PresentedFrame &) {}

  void observeFrames(QQuickWindow &window);

  void present(const PresentedFrame &frame) {
    if (verify) {
      require(!expected.empty());
      require(equal(frame, *expected.front()));
      expected.pop_front();
    }

    digest = digest * 131 + frame.preparation_ns + frame.pane_count;
    ++delivered;
  }

  void prepare(QQuickWindow &window) {
    window.beforeSynchronizing();
    window.afterSynchronizing();
  }

  void enqueue(QQuickWindow &window) {
    if (verify) {
      auto snapshot = std::make_unique<PresentedFrame>();
      fill(*snapshot, seed, panes, history, links);
      expected.push_back(std::move(snapshot));
    }

    window.frameSwapped();
  }

  void drain() {
    QCoreApplication::sendPostedEvents(this, QEvent::MetaCall);
  }
};

#include "observe_frames.inc"

static unsigned long long parameter(std::string_view text) {
  unsigned long long result = 0;
  const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
  require(parsed.ec == std::errc{} && parsed.ptr == text.data() + text.size());

  return result;
}

int execute(int argc, char **argv) {
  require(argc == 1 || argc == 5);
  QGuiApplication app(argc, argv);
  QQuickWindow window;
  ProbeApplication probe;
  probe.window_ = &window;
  probe.observeFrames(window);
  if (argc > 1) {
    probe.verify = false;
    const auto count = parameter(argv[1]);
    probe.panes = parameter(argv[2]);
    const auto backlog = parameter(argv[3]);
    probe.history = parameter(argv[4]);
    require(probe.panes <= PaneLayout::maximum_panes && backlog > 0 && count > 0);
    for (std::size_t i = 0; i < 1000; ++i) {
      probe.prepare(window);
      probe.enqueue(window);
      probe.drain();
    }

    const auto begin = std::chrono::steady_clock::now();
    for (std::size_t i = 0; i < count; ++i) {
      probe.seed = i + 1;
      probe.prepare(window);
      probe.enqueue(window);
      if ((i + 1) % backlog == 0) {
        probe.drain();
      }
    }

    probe.drain();
    const auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
    std::printf("{\"seconds\":%.9f,\"count\":%llu,\"digest\":%llu}\n", elapsed, count, static_cast<unsigned long long>(probe.digest));
    return 0;
  }

  for (std::size_t i = 0; i < 1024; ++i) {
    probe.seed = i + 1;
    probe.panes = i % 65;
    probe.history = i % 3 != 0;
    probe.links = i % 5 == 0;
    probe.prepare(window);
    probe.enqueue(window);
    if (i % 7 == 0) {
      probe.enqueue(window);
    }

    if (i % 31 == 0) {
      probe.drain();
    }
  }

  probe.seed = 7777;
  probe.panes = 64;
  probe.history = true;
  probe.links = true;
  probe.prepare(window);
  probe.drain();
  require(probe.expected.empty() && probe.delivered == 1171);
  probe.enqueue(window);
  const auto retained_link = probe.observed_link;
  probe.seed = 8888;
  probe.links = false;
  probe.history = false;
  probe.prepare(window);
  require(!retained_link.expired());
  probe.drain();
  require(retained_link.expired() && probe.delivered == 1172);
  probe.enqueue(window);
  ++probe.window_generation_;
  probe.drain();
  require(probe.expected.size() == 1 && probe.delivered == 1172);
  probe.expected.clear();
  probe.observeFrames(window);
  probe.seed = 9000;
  probe.prepare(window);
  probe.enqueue(window);
  probe.window_ = nullptr;
  probe.drain();
  require(probe.expected.size() == 1 && probe.delivered == 1172);
  probe.expected.clear();
  {
    auto owned = std::make_unique<ProbeApplication>();
    owned->window_ = &window;
    owned->observeFrames(window);
    owned->prepare(window);
    owned->enqueue(window);
  }

  QCoreApplication::sendPostedEvents(nullptr, QEvent::MetaCall);
  std::printf("{\"passed\":true,\"delivered\":%zu,\"digest\":%llu}\n", probe.delivered, static_cast<unsigned long long>(probe.digest));
  return 0;
}

int main(int argc, char **argv) {
  try {
    return execute(argc, argv);
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
