module telar.wire.worktrees;

import std;
import telar.wire.vocabulary;

namespace telar {

  void RegisterWorktree::validate() const {
    if (path.empty() || path.front() != '/') {
      throw EncodingError{"Invalid worktree path"};
    }
  }

}
