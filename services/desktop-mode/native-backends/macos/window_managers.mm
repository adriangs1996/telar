#include "window_managers.hpp"
#include "../../trace.hpp"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <libproc.h>
#include <mutex>
#include <string_view>

namespace macos {
  namespace {
    using Clock = std::chrono::steady_clock;

    struct Known {
      std::string_view process;
      std::string_view name;
    };

    constexpr std::array known{
        Known{"AeroSpace", "AeroSpace"},
        Known{"yabai", "yabai"},
        Known{"Amethyst", "Amethyst"},
        Known{"KiwiDesk", "KiwiDesk"},
    };
    constexpr std::size_t process_limit = 8192;
    // The Spaces snapshot runs every frame while an operation is pending; the process list does
    // not need to.
    constexpr auto refresh_interval = std::chrono::seconds{2};

    std::vector<std::string> scan(std::array<pid_t, process_limit> &pids) {
      std::vector<std::string> found;
      const int bytes = proc_listallpids(pids.data(), static_cast<int>(sizeof(pids)));
      const auto count = bytes > 0 ? std::min<std::size_t>(bytes, process_limit) : 0;
      std::array<char, 2 * MAXCOMLEN + 1> name{};

      for (std::size_t index = 0; index < count; ++index) {
        if (proc_name(pids[index], name.data(), static_cast<std::uint32_t>(name.size())) <= 0) {
          continue;
        }

        for (const auto &manager : known) {
          if (manager.process == name.data() &&
              std::ranges::find(found, manager.name) == found.end()) {
            found.emplace_back(manager.name);
          }
        }
      }

      NSNumber *stage = CFBridgingRelease(
          CFPreferencesCopyAppValue(CFSTR("GloballyEnabled"), CFSTR("com.apple.WindowManager")));
      if ([stage isKindOfClass:NSNumber.class] && stage.boolValue) {
        found.emplace_back("Stage Manager");
      }

      return found;
    }
  } // namespace

  std::vector<std::string> windowManagers() {
    static std::mutex mutex;
    static std::array<pid_t, process_limit> pids;
    static std::vector<std::string> cached;
    static Clock::time_point checked;
    static bool ready = false;
    std::lock_guard lock(mutex);

    if (!ready || Clock::now() - checked >= refresh_interval) {
      TELAR_TRACE("native.window_managers.scan");
      cached = scan(pids);
      checked = Clock::now();
      ready = true;
    }

    return cached;
  }
} // namespace macos
