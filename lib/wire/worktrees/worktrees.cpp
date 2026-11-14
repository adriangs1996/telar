module telar.wire.worktrees;

import std;
import telar.wire.vocabulary;

// The interface declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar {

  void RegisterWorktree::validate() const {
    if (path.empty() || path.front() != '/') {
      throw EncodingError{"Invalid worktree path"};
    }
  }

}
}
