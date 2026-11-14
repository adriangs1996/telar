// Outside the module, like the native backends: the header declares read in the global module.
import std;
import telar.clipboard;

namespace telar::clipboard {
  std::expected<content, read_error> read(std::size_t) {
    return std::unexpected(read_error::backend_unavailable);
  }
}
