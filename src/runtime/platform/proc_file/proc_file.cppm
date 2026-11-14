module;
#include <cstdint>
#include <sys/types.h>

export module telar.runtime.platform.proc_file;

import std;
import telar.sys.posix;

import telar.base.text;
import telar.platform.primitives;

// Linux only (cmake/module_platforms.cmake).
// Interface: platform/linux/proc_file.cppm
export {
  namespace telar::runtime {

    class ProcDirectory {
    public:
      explicit ProcDirectory(pid_t process) noexcept;

      bool belongsTo(uid_t user) const noexcept;

      std::optional<std::string_view> read(const char* name, std::span<char> buffer) const noexcept;

      std::optional<std::string_view> link(const char* name, std::span<char> buffer) const noexcept;

    private:
      FileDescriptor directory_;
    };

    struct ProcStat {
      pid_t parent = 0;
      pid_t group = 0;
      pid_t foreground = 0;
      std::uint64_t started_ticks = 0;
      std::string_view name;

      static std::optional<ProcStat> parse(std::string_view input) noexcept;
    };

  }
}
