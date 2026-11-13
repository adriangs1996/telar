module;
#include <cstddef>
#include <new>
#include <stdlib.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#include "integration_assets.hpp"
#include <cstring>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif

module telar.cli.integration.settings;

import std;

import telar.platform.paths;
import telar.platform.process;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.platform.primitives;

namespace telar::runtime::cli {

  int runIntegration(BudgetAllocator<SystemAllocator>& memory, const IntegrationOptions& options) {
    const ExecutablePath executable;
    const ProcessEnvironment environment;

    if (options.provider == AgentProvider::pi || options.provider == AgentProvider::opencode) {
      return integration::runExtension(memory, options, environment, executable.view());
    }

    return integration::runSettings(memory, options, environment, executable.view());
  }

}
