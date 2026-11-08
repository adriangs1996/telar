#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "config_bootstrap.hpp"
#include <cstdint>
#include <limits>
#include <span>
#include <stdexcept>
#include <string_view>
#include "telar_base/text/utf8.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cinttypes>
#include <cstdio>
#include "telar_base/memory/allocator.hpp"
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <chrono>
#include <cstring>
#include <cmath>
#include <initializer_list>
#include <optional>
#include <string>
#include <cstddef>
#include <concepts>
#include "telar_client/serializers/telar_messages.hpp"
#include <bit>
#include <utility>
#include "telar_base/memory/fixed_text.hpp"
#include <limits.h>
#include <sys/stat.h>
#include <exception>
#include <charconv>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <unistd.h>
#include <filesystem>
#include <format>
#include <ghostty/vt/unicode.h>
#include "telar_config/terminal/control/policy.hpp"
#include <arpa/inet.h>
#include "telar_config/graphics/limits.hpp"
#include <cstdlib>
#include "graphics/png_decoder.hpp"
#include <sqlite3.h>
#include <atomic>
#include <memory>
#include <condition_variable>
#include <mutex>
#include <type_traits>
#include <cassert>
#include "telar_client/codecs/telar_wire.hpp"
#include <poll.h>
#include <sys/uio.h>
#include <sys/types.h>
#include <climits>
#include "telar_platform/trace.hpp"
#include <csignal>
#include <thread>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include "telar_platform/random_bytes.hpp"
#include <dirent.h>
#include "telar_platform/open_directory.h"
#include <openssl/sha.h>
#include <pthread.h>
#include <brotli/decode.h>
#include <zlib.h>
#include <zstd.h>
#if (defined(__APPLE__))
#include <CoreFoundation/CoreFoundation.h>
#endif
#if (defined(__APPLE__))
#include <Security/Security.h>
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <openssl/err.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/pem.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/x509.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#include <sys/un.h>
#include "telar_base/program_identity.hpp"
#include <bitset>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include "telar_base/text/base64.hpp"
#include <variant>
#include <netdb.h>
#include <brotli/encode.h>
#include <nghttp2/nghttp2.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <openssl/crypto.h>
#include <ctime>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__))
#endif
#include <spawn.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include "diagnostics/timing.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_base/diagnostics/limit_reach.hpp"
#include <unordered_set>
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include "diagnostics/line.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include "telar_base/memory/allocation_statistics.hpp"
#endif
#if (TELAR_DIAGNOSTICS) && (defined(__APPLE__))
#include <mach/mach.h>
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include "telar_client/codecs/telar_codec.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include "telar_client/serializers/telar_serializer.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include "terminal/ghostty_allocator.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include "terminal/ghostty_handle.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include "graphics/kitty_framing.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include "graphics/media_budget.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include "graphics/kitty_control.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include "graphics/child_file.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include "telar_platform/graphics/child_shared_memory.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include "terminal/control/classification.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include "terminal/control/parser.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include "terminal/pty_response_queue.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include "graphics/temporary_path.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include "telar_platform/mapped_region.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include <sys/mman.h>
#endif
#if (TELAR_DIAGNOSTICS)
#include "telar_client/serializers/telar_frame.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include "cell_layout.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include <tuple>
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include "terminal/control/engine.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include "terminal/graphics_cursor.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include <system_error>
#endif
#include <sys/file.h>
#include <new>
#include <termios.h>
#include "terminal/control/clipboard.hpp"
#include <ifaddrs.h>
#include <net/if.h>
#if (defined(__APPLE__))
#include <libproc.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#include <pcap/pcap.h>
#include <unordered_map>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <net/if_utun.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <netinet6/in6_var.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <sys/ioctl.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <sys/kern_control.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <sys/sys_domain.h>
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#include <linux/if_ether.h>
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#include <linux/if_tun.h>
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#include <sys/ioctl.h>
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <sys/ioctl.h>
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <sys/sockio.h>
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <net/if_dl.h>
#endif
#if (defined(__APPLE__))
#include <net/route.h>
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <netinet/in_pcb.h>
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <netinet/tcp_fsm.h>
#endif
#if (defined(__APPLE__))
#include <netinet/tcp_var.h>
#endif
#if (defined(__APPLE__))
#include <sys/socketvar.h>
#endif
#if (defined(__APPLE__))
#include <sys/sysctl.h>
#endif
#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#include "traffic_api.hpp"
#include "plugin_bootstrap.hpp"



import telar.runtime.cli.server;
import telar.runtime.plugins.run_worker;

auto main(int argc, char **argv) -> int {
  using namespace telar;
  using namespace telar::runtime;

  std::span<char *> args(argv, argc);

  try {
    SystemAllocator system;
    constexpr std::size_t memory_budget = std::size_t{2} * 1024 * 1024 * 1024;
    BudgetAllocator budget{system, memory_budget};

    if (argc >= 2 && std::string_view{args.subspan<1>().front()} == "traffic") {
      cli::runTraffic(budget, args.subspan<2>());
      return 0;
    }

    if (argc >= 2 && std::string_view{argv[1]} == "plugin-worker") {
      cli::runPluginWorker(budget, cli::PluginWorkerOptions::parse(args.subspan<2>()));
      return 0;
    }

    if (argc >= 3 && std::string_view{argv[1]} == "tap-worker") {
      bool traffic = false;
      const char *trace_path = nullptr;
      for (int index = 3; index < argc; ++index) {
        const std::string_view option{argv[index]};
        if (option == "--traffic" && !traffic) { traffic = true; }
        else if (option == "--trace" && trace_path == nullptr && index + 1 < argc) { trace_path = argv[++index]; }
        else { throw std::invalid_argument{"Expected tap-worker ENTRY [--traffic] [--trace PATH]"}; }
      }

#if TELAR_DEBUG
      trace::Session tracing{budget, trace_path};
#else
      if (trace_path != nullptr) {
        throw std::invalid_argument{"Tracing is available in Debug builds only"};
      }
#endif
      plugins::runWorker(budget, argv[2], traffic);
      return 0;
    }

    SynchronizedAllocator memory{budget};
    const auto options = cli::ServerOptions::parse({argv + 1, static_cast<std::size_t>(argc - 1)});
    cli::runServer(memory, options);
    return 0;
  } catch (const std::invalid_argument &error) {
    std::fprintf(stderr, "telar runtime: %s\n", error.what());
    return 1;
  } catch (const SystemError &error) {
    std::fprintf(stderr, "telar runtime: %s: %s\n", error.what(), std::strerror(error.code()));
  } catch (const TerminalError &error) {
    std::fprintf(stderr, "%s:%u: %s (%d)\n", error.location().file_name(), error.location().line(), error.what(), static_cast<int>(error.result()));
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar runtime: %s\n", error.what());
  }

  return 1;
}
