#pragma once

#include <string>
#include <vector>

namespace macos {
  // Other programs that place windows on their own and would fight the desktop over them, by the
  // names users know them by. Stage Manager counts while it is on.
  std::vector<std::string> windowManagers();
} // namespace macos
