// Outside the module, like the native backends: the header declares read in the global module.
import std;
import telar.clipboard;

namespace telar::clipboard {
  std::expected<Content, ReadError> read(std::size_t) {
    return std::unexpected(ReadError::backend_unavailable);
  }
}
