#pragma once

#if defined(__APPLE__)
#include "macos/system_certificates.hpp"
#else
#include "linux/system_certificates.hpp"
#endif
