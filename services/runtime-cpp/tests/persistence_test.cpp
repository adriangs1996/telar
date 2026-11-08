#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_base/memory/allocator.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <algorithm>
#include <array>
#include <fcntl.h>
#include <limits.h>
#include <string_view>
#include <sys/stat.h>
#include <cstdint>
#include "telar_platform/random_bytes.hpp"
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <unistd.h>
#endif
#include <span>
#include <unistd.h>
#include <cstdlib>
#include <sys/file.h>
#include "../diagnostics/line.hpp"
#include "telar_base/diagnostics/config.hpp"
#include <sys/types.h>
#include <chrono>
#include <bit>
#include <concepts>
#include <stdexcept>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <cassert>
#include <cstring>
#include "telar_client/codecs/telar_codec.hpp"
#include <cstddef>
#include "telar_client/serializers/telar_serializer.hpp"
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <optional>
#include "../graphics/kitty_framing.hpp"
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/trace.hpp"
#include <limits>
#include "telar_platform/mapped_region.hpp"
#include <sys/mman.h>
#include <atomic>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include <tuple>
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <memory>
#include "telar_base/program_identity.hpp"
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <system_error>
#include "telar_base/diagnostics/limit_reach.hpp"
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__))
#endif
#include <new>
#include "telar_config/terminal/control/policy.hpp"
#include <condition_variable>
#include <pthread.h>
#include <random>
#include <string>



import telar.runtime.persistence.session_store;
import telar.runtime.platform.request_worker;

using namespace telar;
using namespace telar::runtime;

static void testMonotonicIdentities(SystemAllocator &memory) {
  SlotStore<std::uint64_t, 32, SystemAllocator> store{memory};
  std::array<std::uint64_t, 32> identities{};
  std::uint64_t counter = 63;
  std::minstd_rand random{71};
  for (unsigned iteration = 0; iteration < 10000; ++iteration) {
    const auto slot = random() % identities.size();
    if (identities[slot] != 0) {
      store.erase(identities[slot]);
      check(store.find(identities[slot]) == nullptr);
    }

    identities[slot] = counter;
    store.insert(counter, makeOwned<std::uint64_t>(memory, counter));
    counter += 64;
    for (const auto identity : identities) {
      if (identity != 0) {
        check(store.find(identity) != nullptr && *store.find(identity) == identity);
      }
    }
  }

  check(store.nextCounter() == counter - 63);
  bool exhausted = false;
  try {
    store.insert(UINT64_MAX, makeOwned<std::uint64_t>(memory, UINT64_MAX));
  } catch (const std::bad_alloc &) {
    exhausted = true;
  }
  check(exhausted);
}

static void testIndependentHandles(SystemAllocator &memory) {
  SlotStore<std::uint64_t, 3, SystemAllocator> store{memory};
  constexpr std::uint64_t high_identity = UINT64_MAX - 1;
  const auto first = store.insert(high_identity, makeOwned<std::uint64_t>(memory, high_identity));
  check(*store.findHandle(first) == high_identity);
  check(store.find(high_identity) == store.findHandle(first));
  store.erase(high_identity);
  check(store.findHandle(first) == nullptr);

  const auto second = store.insert(1, makeOwned<std::uint64_t>(memory, 1));
  check(second != first);
  check(store.findHandle(first) == nullptr);
  check(*store.findHandle(second) == 1);
  check(store.findHandle(UINT64_MAX) == nullptr);
}

static void testExhaustedIdentities(SystemAllocator &memory) {
  SlotStore<std::uint64_t, 3, SystemAllocator> store{memory};
  store.advanceCounter(UINT64_MAX);
  check(store.nextId() == UINT64_MAX);
  store.insert(UINT64_MAX, makeOwned<std::uint64_t>(memory, UINT64_MAX));
  check(store.nextCounter() == 0 && *store.find(UINT64_MAX) == UINT64_MAX);
  store.erase(UINT64_MAX);
  store.advanceCounter(1);
  check(store.nextCounter() == 0 && store.size() == 0);

  bool exhausted = false;
  try {
    store.nextId();
  } catch (const std::bad_alloc &) {
    exhausted = true;
  }
  check(exhausted);
}

static std::span<const Byte> checkpointFixture(std::span<Byte> buffer) {
  checkpoint::Writer writer{buffer, checkpoint::Counters{70, 80, 300, 900}};
  writer.append(checkpoint::WorkspaceRecord{5, "/tmp", "Restored", 7, "Shells"});
  writer.append(checkpoint::TabRecord{5, 8, "Missing"});
  constexpr char arguments[] = "/bin/sh\0-c\0read value\0";
  writer.append(checkpoint::PaneRecord{257, 5, 7, "/tmp", 90, 30, 3, {arguments, sizeof(arguments) - 1}});
  writer.append(checkpoint::PaneRecord{1, 5, 7, "/tmp", 80, 24, 3, {arguments, sizeof(arguments) - 1}});
  writer.append(checkpoint::PaneRecord{258, 5, 8, "/telar-missing-checkpoint-directory", 80, 24, 3, {arguments, sizeof(arguments) - 1}});
  return writer.finish();
}

static void testCheckpointValidation() {
  std::array<Byte, 4096> buffer;
  const auto fixture = checkpointFixture(buffer);
  std::size_t count = 0;
  checkpoint::Reader reader{fixture};
  reader.read([&](const auto &) { ++count; });
  check(count == 5 && reader.counters.generation == 900);

  for (std::size_t length = 0; length < fixture.size(); ++length) {
    bool rejected = false;
    try {
      checkpoint::Reader truncated{fixture.first(length)};
      truncated.read([](const auto &) {});
    } catch (const EncodingError &) {
      rejected = true;
    }
    check(rejected);
  }

  buffer[fixture.size()] = 0;
  bool trailing_rejected = false;
  try {
    checkpoint::Reader trailing{std::span{buffer}.first(fixture.size() + 1)};
    trailing.read([](const auto &) {});
  } catch (const EncodingError &) {
    trailing_rejected = true;
  }
  check(trailing_rejected);

  for (std::size_t capacity = 43; capacity < fixture.size(); ++capacity) {
    checkpoint::Writer bounded{std::span{buffer}.first(capacity), {}};
    bounded.append(checkpoint::WorkspaceRecord{1, "/tmp", "Example", 1, ""});
    const auto encoded = bounded.finish();
    checkpoint::Reader valid{encoded};
    valid.read([](const auto &) {});
    check(encoded.size() <= capacity);
  }

  for (std::size_t capacity = 0; capacity < 43; ++capacity) {
    bool rejected = false;
    try {
      checkpoint::Writer tiny{std::span{buffer}.first(capacity), {}};
    } catch (const EncodingError &) {
      rejected = true;
    }
    check(rejected);
  }
}

static void testRestore(SystemAllocator &memory) {
  std::array<Byte, 4096> buffer;
  const auto fixture = checkpointFixture(buffer);
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-checkpoint-test.sock"}};
  ClientLayouts layouts{memory};
  checkpoint::Restore restore{memory, model, panes, layouts, false};
  restore.apply(fixture);
  check(model.panes.size() == 2);
  check(model.panes.find(1)->generation == 900);
  check(model.panes.find(257)->generation == 901);
  check(model.panes.find(257)->terminal.screen.cols == 90);
  check(model.panes.find(257)->launch.bytes() == model.panes.find(1)->launch.bytes());
  check(model.panes.nextId() == 300);
  check(model.workspaces.nextId() == 70);
  check(model.next_tab_id == 80);
  const auto *workspace = model.workspaces.find(5);
  check(workspace != nullptr && workspace->tabs.size() == 1);
  check(workspace->tabs.front().panes.size() == 2);
  check(workspace->tabs.front().panes[0] == 1);
}

static void testAtomicFile(SystemAllocator &memory) {
  std::array<char, 64> directory{};
  std::strcpy(directory.data(), "/tmp/telar-checkpoint-test-XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
  const auto path = std::string{directory.data()} + "/session.ckpt";
  checkpoint::FileStore file{memory, path};
  Vector<Byte, SystemAllocator> loaded{AllocatorRef<Byte, SystemAllocator>{memory}};
  check(!file.load(loaded));
  std::array<Byte, 4096> buffer;
  const auto fixture = checkpointFixture(buffer);
  {
    ObservationWorker<decltype(file) &> worker{std::in_place, file};
    check(worker.submit(fixture));
    worker.wait([](int error) { check(error == 0); });
  }

  check(file.load(loaded));
  check(std::ranges::equal(loaded, fixture));
  struct stat state{};
  check(::stat(path.c_str(), &state) == 0 && (state.st_mode & 0777) == 0600);
  file.quarantine();
  check(!file.load(loaded));
  check(::stat((path + ".corrupt").c_str(), &state) == 0);

  check(::mkdir(path.c_str(), 0700) == 0);
  check(file.observe(fixture) != 0);
  check(::stat(path.c_str(), &state) == 0 && S_ISDIR(state.st_mode));
  check(::rmdir(path.c_str()) == 0);
  check(::symlink((path + ".corrupt").c_str(), path.c_str()) == 0);
  bool rejected = false;
  try {
    file.load(loaded);
  } catch (const SystemError &) {
    rejected = true;
  }
  check(rejected);
  check(::unlink(path.c_str()) == 0);
  check(::unlink((path + ".corrupt").c_str()) == 0);
  check(::rmdir(directory.data()) == 0);
}

struct SnapshotAgents {
  const Agent *find(std::uint64_t, std::uint64_t) const noexcept {
    return nullptr;
  }

  std::uint64_t revision() const noexcept {
    return version;
  }

  std::uint64_t version = 0;
};

static void testSnapshotChanges(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<SystemAllocator> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-checkpoint-test.sock"}};
  ClientLayouts layouts{memory};
  SnapshotAgents agents;
  checkpoint::Snapshot<SystemAllocator, SnapshotAgents> snapshot;
  const auto expect = [&](bool changed) {
    check(snapshot.changed(model, layouts, agents) == changed);
    check(!snapshot.changed(model, layouts, agents));
  };
  expect(true);

  std::array<Byte, 4096> buffer;
  checkpoint::Restore restore{memory, model, panes, layouts, false};
  restore.apply(checkpointFixture(buffer));
  expect(true);
  auto *pane = model.panes.find(257);
  check(pane != nullptr);
  ++pane->cwd_revision;
  expect(true);
  pane->resize(TerminalSize{.cols = 91, .rows = 30, .cell_width_px = 0, .cell_height_px = 0});
  expect(true);
  pane->resize(TerminalSize{.cols = 91, .rows = 31, .cell_width_px = 0, .cell_height_px = 0});
  expect(true);

  constexpr std::array<Byte, 4> output{'t', 'e', 's', 't'};
  pane->terminal.feed(output);
  expect(false);
  pane->output_closed = true;
  expect(true);
  pane->exit_status = 0;
  expect(false);
  pane->output_closed = false;
  expect(false);
  pane->exit_status.reset();
  expect(true);
  pane->close_requested = true;
  expect(true);
  pane->close_requested = false;
  expect(true);
  ++agents.version;
  expect(true);
  ++model.workspace_revision;
  expect(true);

  model.panes.erase(1);
  expect(true);
  ++pane->cwd_revision;
  expect(true);
  const auto location = pane->location;
  model.panes.erase(257);
  expect(true);

  constexpr std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "read value"};
  Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
  const auto first = panes.launch(model, nullptr, command, location, TerminalSize{.cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0}).id;
  expect(true);
  model.panes.erase(first);
  const auto replacement = panes.launch(model, nullptr, command, location, TerminalSize{.cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0}).id;
  check(replacement != first);
  expect(true);
  model.panes.erase(replacement);
  expect(true);
}

static void testLargePaneIdentity(SystemAllocator &memory) {
  constexpr std::uint64_t identity = UINT64_MAX - 2;
  std::array<Byte, 4096> buffer;
  checkpoint::Writer writer{buffer, checkpoint::Counters{2, 2, identity + 1, 10}};
  writer.append(checkpoint::WorkspaceRecord{1, "/tmp", "Large identity", 1, ""});
  constexpr char arguments[] = "/bin/sh\0-c\0printf 'restored'; read value\0";
  writer.append(checkpoint::PaneRecord{identity, 1, 1, "/tmp", 80, 24, 3, {arguments, sizeof(arguments) - 1}});
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-checkpoint-test.sock"}};
  ClientLayouts layouts{memory};
  checkpoint::Restore restore{memory, model, panes, layouts, false};
  restore.apply(writer.finish());
  auto *pane = model.panes.find(identity);
  check(pane != nullptr && pane->id == identity);
  check(model.panes.nextId() == identity + 1);

  std::array<Event, decltype(poller)::event_capacity> ready{};
  const auto events = poller.wait(std::chrono::seconds{2}, ready);
  check(!events.empty());
  check(eventSource(events.front().token) == EventSource::pane);
  check(model.panes.findHandle(eventIdentity(events.front().token)) == pane);
  check(pane->read());
}

void testPersistence() {
  SystemAllocator memory;
  testMonotonicIdentities(memory);
  testIndependentHandles(memory);
  testExhaustedIdentities(memory);
  testCheckpointValidation();
  testRestore(memory);
  testLargePaneIdentity(memory);
  testSnapshotChanges(memory);
  testAtomicFile(memory);
}
