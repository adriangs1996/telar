#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include "client_peer.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <array>
#include <cstdint>
#include <atomic>
#include <concepts>
#include <condition_variable>
#include <optional>
#include <pthread.h>
#include <string_view>
#include "telar_base/memory/allocator.hpp"
#include <cassert>
#include <cstring>
#include <span>
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstddef>
#include "telar_base/program_identity.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <sys/types.h>
#include <limits.h>
#include <chrono>
#include <poll.h>
#include <sys/wait.h>
#include <charconv>
#include "telar_base/memory/fixed_text.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include "telar_platform/trace.hpp"
#include "../diagnostics/line.hpp"
#include "telar_base/diagnostics/config.hpp"
#include <bit>
#include <stdexcept>
#include <variant>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/serializers/telar_serializer.hpp"
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
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
#include "telar_config/graphics/limits.hpp"
#include <limits>
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <sys/mman.h>
#include "telar_base/text/utf8.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include <tuple>
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <memory>
#include <csignal>
#include <sys/uio.h>
#include <system_error>
#include "telar_base/diagnostics/limit_reach.hpp"
#include <filesystem>
#include <fstream>
#include <thread>



import telar.runtime.runtime.media_service;

using namespace telar;
using namespace telar::runtime;

static void testHeadFiles() {
  check(GitHead::parse(" ref: refs/heads/feature/topic\r\n") == "feature/topic");
  check(GitHead::parse("ref: refs/tags/release\n") == "refs/tags/release");
  check(GitHead::parse("0123456789abcdef\n") == "01234567");
  check(GitHead::parse(" \r\n").empty());

  std::array<char, 64> pattern;
  std::strcpy(pattern.data(), "/tmp/telar-head-test.XXXXXX");
  check(::mkdtemp(pattern.data()) != nullptr);
  const std::filesystem::path root{pattern.data()};
  std::filesystem::create_directory(root / ".git");
  std::filesystem::create_directory(root / "nested");
  std::ofstream{root / ".git/HEAD"} << "ref: refs/heads/main\n";
  GitHead reader;
  check(reader.read(root.string()) == "main");
  check(!reader.read((root / "nested").string()));
  std::filesystem::rename(root / ".git", root / "metadata");
  std::ofstream{root / ".git"} << " gitdir: metadata \r\n";
  check(reader.read(root.string()) == "main");
  std::ofstream{root / ".git"} << "gitdir: " << (root / "metadata").string() << '\n';
  check(reader.read(root.string()) == "main");

  std::filesystem::remove(root / "metadata/HEAD");
  check(::mkfifo((root / "metadata/HEAD").c_str(), 0600) == 0);
  check(!reader.read(root.string()));
  std::filesystem::remove(root / "metadata/HEAD");
  std::ofstream{root / "metadata/HEAD"} << std::string(8192, 'a');
  check(reader.read(root.string()) == "aaaaaaaa");
  std::filesystem::remove(root / ".git");
  check(::mkfifo((root / ".git").c_str(), 0600) == 0);
  check(!reader.read(root.string()));
  std::filesystem::remove_all(root);
}

static void testRepositoryFacts() {
  using namespace std::literals;
  const auto facts = GitRepositoryFacts::parse("global\0filter.trusted.clean\nrun\0local\0filter.local.required\ntrue\0worktree\0filter.local.process\nrun\0local\0remote.origin.promisor\nfalse\0"sv);
  check(facts && facts->driver_count == 1 && facts->drivers[0] == "local" && facts->may_fetch);
  check(!GitRepositoryFacts::parse("local\0filter.bad=name.clean\nrun\0"sv));
  check(!GitRepositoryFacts::parse("local\0unterminated"sv));
  check(GitRepositoryFacts::parse("local\0filter..clean\nrun\0"sv)->drivers[0].empty());
  check(!GitRepositoryFacts::parse("global\0remote.origin.promisor\ntrue\0"sv)->may_fetch);

  std::string listing;
  for (unsigned driver = 0; driver < 9; ++driver) {
    listing += "local"sv;
    listing += '\0';
    listing += "filter.driver" + std::to_string(driver) + ".required\ntrue";
    listing += '\0';
  }
  check(!GitRepositoryFacts::parse(listing));
}

class ControlledGitProbe {
public:
  using Request = WorkspaceGitRequest;
  using Result = WorkspaceGitResult;

  Result observe(const Request &request) noexcept {
    std::unique_lock lock{mutex};
    started = request.identity;
    ready.wait(lock, [&] { return released || stopped; });
    auto result = next;
    result.identity = request.identity;
    return result;
  }

  void stop() noexcept {
    const std::lock_guard lock{mutex};
    stopped = true;
    ready.notify_one();
  }

  void release() {
    const std::lock_guard lock{mutex};
    released = true;
    ready.notify_one();
  }

  std::mutex mutex;
  std::condition_variable ready;
  std::atomic<std::uint64_t> started{0};
  bool released = false;
  bool stopped = false;
  Result next;
};

using GitService = WorkspaceGitService<SystemAllocator, ControlledGitProbe &>;

static void collect(RuntimeModel<SystemAllocator> &model, GitService &service, GitService::Clock::time_point now) {
  pollfd completion{.fd = service.descriptor(), .events = POLLIN, .revents = 0};
  check(::poll(&completion, 1, 1000) == 1);
  for (unsigned attempt = 0; attempt < 1000; ++attempt) {
    service.collect(model, now);
    if (::poll(&completion, 1, 0) == 0) {
      return;
    }
    std::this_thread::yield();
  }
  check(false);
}

static void testObservationLifecycle() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  ControlledGitProbe probe;
  GitService service{limits, probe};
  auto first = makeOwned<Workspace<SystemAllocator>>(memory, memory, 7, "/first", "first");
  auto second = makeOwned<Workspace<SystemAllocator>>(memory, memory, 9, "/second", "second");
  auto &workspace = *first;
  model.workspaces.insert(7, std::move(first));
  model.workspaces.insert(9, std::move(second));
  auto now = GitService::Clock::time_point{std::chrono::seconds{100}};
  probe.next.present = true;
  probe.next.branch.assign("main");
  probe.next.dirty = true;
  probe.release();
  service.tick(model, now);
  collect(model, service, now);
  check(workspace.git_branch.view() == "main" && workspace.git_dirty && model.workspace_revision == 2);
  check(workspace.git_checked_at == now);

  service.tick(model, now);
  collect(model, service, now);
  check(probe.started == 9 && model.workspaces.find(9)->git_dirty && model.workspace_revision == 3);
  check(service.tick(model, now + std::chrono::seconds{1}) == std::chrono::seconds{4});
  model.workspaces.erase(9);
  ++model.workspace_revision;

  probe.next.branch.assign("changed");
  probe.next.dirty.reset();
  probe.next.timed_out = true;
  now += GitService::probe_interval;
  service.tick(model, now);
  collect(model, service, now);
  check(workspace.git_dirty && workspace.git_branch.view() == "changed" && workspace.git_timed_out);
  const auto changed_revision = model.workspace_revision;
  now += GitService::probe_interval;
  service.tick(model, now);
  collect(model, service, now);
  check(model.workspace_revision == changed_revision);

  ClientPeer client{memory, model, clients, ClientRole::control};
  limits.deliver(model, clients);
  limits.query(client.session(), QueryLimits{.request_id = 1});
  auto recorded = client.receive<LimitList>();
  check(recorded.entries.size() == 1 && recorded.entries[0].hits == 1);
  check(recorded.entries[0].reach.name == "gitstatus.status_timeout" && recorded.entries[0].reach.route.empty());

  probe.next.timed_out = false;
  probe.next.dirty = false;
  now += GitService::probe_interval;
  service.tick(model, now);
  collect(model, service, now);
  check(!workspace.git_dirty && !workspace.git_timed_out);
  probe.next.timed_out = true;
  now += GitService::probe_interval;
  service.tick(model, now);
  collect(model, service, now);
  limits.deliver(model, clients);
  limits.query(client.session(), QueryLimits{.request_id = 2});
  recorded = client.receive<LimitList>();
  check(recorded.entries.size() == 1 && recorded.entries[0].hits == 2);

  probe.next.present = false;
  probe.next.timed_out = false;
  now += GitService::probe_interval;
  service.tick(model, now);
  collect(model, service, now);
  check(workspace.git_branch.view().empty() && !workspace.git_dirty);

  {
    const std::lock_guard lock{probe.mutex};
    probe.released = false;
  }
  now += GitService::probe_interval;
  service.tick(model, now);
  model.workspaces.erase(7);
  const auto revision_before_completion = model.workspace_revision;
  probe.release();
  collect(model, service, now);
  check(model.workspace_revision == revision_before_completion);
}

void testWorkspaceGit() {
  testHeadFiles();
  testRepositoryFacts();
  testObservationLifecycle();
}
