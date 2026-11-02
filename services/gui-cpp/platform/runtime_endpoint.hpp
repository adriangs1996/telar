#pragma once

#include <string>

namespace telar::gui::platform::runtime_endpoint {
// The socket of the user's own runtime, which `telar server endpoint` starts in the background
// when none runs. telar runs through the user's login shell, so a runtime started from a
// Finder or login launch gets the PATH, EDITOR and SHELL a terminal would, and so do its panes.
// Blocks until telar answers or a deadline passes; throws when it fails.
std::string resolve();
std::string program();
}
