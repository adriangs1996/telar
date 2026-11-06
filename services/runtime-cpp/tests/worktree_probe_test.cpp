#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include <array>
#include <optional>
#include <string_view>
#include "telar_base/memory/allocator.hpp"
#include <cassert>
#include <cstdint>
#include <cstring>
#include <span>
#include "telar_client/serializers/telar_protocol.hpp"
#include <exception>
#include <cstddef>
#include "telar_base/program_identity.hpp"
#include <cerrno>
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <sys/types.h>
#include <limits.h>
#include <atomic>
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
#include <filesystem>
#include <fstream>



import telar.runtime.workspaces.git_probe;
import telar.runtime.worktrees.git_probe;

using namespace telar;
using namespace telar::runtime;

static void runGit(SystemAllocator &memory, const std::string &root, std::initializer_list<std::string_view> arguments) {
  std::array<std::string_view, 32> complete;
  std::size_t count = 0;
  for (const auto prefix : {"git", "-c", "user.name=Runtime Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"}) {
    complete[count++] = prefix;
  }
  for (const auto argument : arguments) {
    complete[count++] = argument;
  }
  Command command{memory, Launch{.cwd = root, .arguments = std::span{complete}.first(count)}, CommandPurpose::administration};
  CommandOutput output{memory, 4096};
  check(output.run(command, std::chrono::steady_clock::now() + std::chrono::seconds{5}) == 0);
}

void testWorktreeProbe() {
  SystemAllocator memory;
  std::array<char, 64> directory{};
  std::strcpy(directory.data(), "/tmp/telar-git-test.XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
  const std::string root{directory.data()};
  runGit(memory, root, {"init", "--quiet", "--initial-branch=main", "--template="});
  std::ofstream{root + "/file.txt"} << "initial\n";
  runGit(memory, root, {"add", "file.txt"});
  runGit(memory, root, {"commit", "--quiet", "-m", "Initial fixture"});
  runGit(memory, root, {"checkout", "--quiet", "-b", "feature"});
  std::ofstream{root + "/file.txt", std::ios::app} << "committed\n";
  runGit(memory, root, {"add", "file.txt"});
  runGit(memory, root, {"commit", "--quiet", "-m", "Changed fixture"});
  std::ofstream{root + "/file.txt", std::ios::app} << "uncommitted\n";
  std::ofstream{root + "/.gitattributes"} << "*.txt filter=unsafe\n";
  const std::string dangerous = "touch " + root + "/unexpected-execution; cat";
  runGit(memory, root, {"config", "filter.unsafe.clean", dangerous});
  runGit(memory, root, {"config", "core.fsmonitor", dangerous});
  runGit(memory, root, {"config", "diff.external", dangerous});
  WorktreeGitProbe probe{memory};
  WorktreeProbeRequest request{};
  request.identity = 7;
  request.path.assign(root);
  request.base.assign("main");
  const auto result = probe.observe(request);
  check(result.present && result.measured && result.dirty && result.identity == 7);
  check(result.branch.view() == "feature" && result.added == 2 && result.removed == 0 && result.files == 1 && result.ahead == 1);
  WorkspaceGitProbe workspace_probe{memory};
  WorkspaceGitRequest workspace_request{.identity = 9};
  workspace_request.path.assign(root);
  const auto workspace_result = workspace_probe.observe(workspace_request);
  check(workspace_result.identity == 9 && workspace_result.present && workspace_result.branch.view() == "feature");
  check(workspace_result.dirty == true && !workspace_result.timed_out);
  check(!std::filesystem::exists(root + "/unexpected-execution"));
  std::string commit;
  std::ifstream{root + "/.git/refs/heads/feature"} >> commit;
  std::ofstream{root + "/.git/HEAD"} << commit << '\n';
  const auto detached = probe.observe(request);
  check(detached.present && detached.measured && detached.branch.view() == commit.substr(0, 8));
  check(detached.added == result.added && detached.ahead == result.ahead && detached.timeout == GitProbeTimeout::none);
  std::ofstream{root + "/.git/HEAD"} << "ref: refs/heads/" << std::string(201, 'x') << '\n';
  const auto invalid_branch = probe.observe(request);
  check(invalid_branch.present && invalid_branch.branch.view().empty() && !invalid_branch.measured);
  std::filesystem::remove_all(root);
  check(!probe.observe(request).present);
}
