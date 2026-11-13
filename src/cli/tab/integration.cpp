module;
#include <cstddef>
#include <new>
#include <stdlib.h>

#include <cstdint>
#include <cstdlib>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <limits.h>
#include <unistd.h>
#include <cstdio>
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

module telar.cli.tab;

import std;

import telar.cli.integration.settings;
import telar.platform;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;


namespace telar::runtime::cli {

int runIntegration(BudgetAllocator<SystemAllocator> &memory, const IntegrationOptions &options) {
  const ExecutablePath executable;
  const ProcessEnvironment environment;
  if (options.provider == AgentProvider::pi || options.provider == AgentProvider::opencode) {
    return integration::runExtension(memory, options, environment, executable.view());
  }

  return integration::runSettings(memory, options, environment, executable.view());
}

}
