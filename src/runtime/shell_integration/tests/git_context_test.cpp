#include <cstdlib>

import std;
import telar.testing;
import telar.platform.fs;
import telar.runtime.shell_integration.git_context;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::string text(std::string_view value) {
    return std::string{value};
  }

  // A shell at a detached HEAD shows the commit it is on.
  void testDetachedHeadNamesCommit() {
    if (std::system("command -v git >/dev/null 2>&1") != 0) {
      telar::testing::skip("git is not installed");
    }

    TemporaryDirectory repository{"/tmp/telar-git-XXXXXX"};
    const auto run = [&](std::string_view command) {
      const auto line = "cd " + text(repository.path()) + " && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 " + text(command);

      check(std::system(line.c_str()) == 0);
    };

    run("git init -q -b trunk . && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m first && git checkout -q --detach && git rev-parse HEAD > head");
    std::string head;

    std::ifstream{text(repository.path()) + "/head"} >> head;
    ShellGitReader reader;
    ShellGitRequest request{.pane = 7, .generation = 1, .directory = {}};

    request.directory.assign(repository.path());
    const auto summary = reader.observe(request).summary;

    check(summary.repository && summary.detached);
    check(!summary.branch.view().empty() && head.starts_with(summary.branch.view()), "the detached HEAD is not named by its commit");
  }

  const telar::testing::Case case_detached_head_names_commit{"git_context.detached_head_names_commit", testDetachedHeadNamesCommit};

}
