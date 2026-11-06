#include "clipboard.hpp"

namespace telar::clipboard {
  std::expected<content, read_error> read(std::size_t) {
    return std::unexpected(read_error::backend_unavailable);
  }
}
