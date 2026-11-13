module;
#include <cstdint>

export module telar.gui.tests.activity_fixture;

import std;
export import telar.client.protocol;

export {
namespace telar::gui::test {

inline constexpr std::uint64_t task_worktree_id = 10;
inline constexpr std::uint64_t command_worktree_id = 11;

inline CoordinatorReference coordinatorReference(std::uint64_t pane, std::uint64_t generation = 1) {
  CoordinatorReference reference{.pane_id = pane, .pane_generation = generation};
  reference.session_id.front() = 1;

  return reference;
}

inline WorktreeListEntry worktreeEntry() {
  return {.worktree = task_worktree_id, .source = 1, .workspace = 2, .created_by = 1, .path = "/project/worktree", .branch = "worktree-fix", .title = "Fix the task"};
}

}
}
