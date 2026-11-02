#pragma once

#if defined(__APPLE__)
#include "macos/private_tunnel.hpp"
#else
#include "linux/private_tunnel.hpp"
#endif
