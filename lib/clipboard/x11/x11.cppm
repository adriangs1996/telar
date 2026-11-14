module;
#include "../src/linux/backend.hpp"

export module telar.clipboard.x11;

import std;

// The X11 backend of the Linux reader. libxcb's headers stay in this module's units; the reader
// imports this declaration instead of including them.
export namespace telar::clipboard::linux_backend {
  std::expected<content, read_error> readX11(deadline expires, std::size_t maximum_bytes);
}
