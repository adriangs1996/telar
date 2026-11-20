export module telar.runtime.host.proc_file;

import std;
import telar.sys.posix;

import telar.platform.primitives;
import telar.base.ds;

// Linux only (LINUX_SOURCES of runtime-platform).
// Interface: platform/linux/proc_file.cppm
export {
  namespace telar::runtime {

    class ProcDirectory {
    public:
      explicit ProcDirectory(pid_t process) noexcept;

      bool belongsTo(uid_t user) const noexcept;

      ds::Option<uid_t> owner() const noexcept;

      ds::Option<std::string_view> read(const char* name, std::span<char> buffer) const noexcept;

      ds::Option<std::string_view> link(const char* name, std::span<char> buffer) const noexcept;

    private:
      FileDescriptor directory_;
    };

    struct ProcStat {
      pid_t parent = 0;
      pid_t group = 0;
      pid_t foreground = 0;
      std::uint64_t started_ticks = 0;
      std::string_view name;
      // The state letter: R, S, D, Z, T, t, I, X.
      char state = '?';
      // User and system time, in clock ticks.
      std::uint64_t cpu_ticks = 0;
      std::int8_t nice = 0;
      std::uint32_t threads = 0;
      std::uint64_t resident_pages = 0;

      static ds::Option<ProcStat> parse(std::string_view input) noexcept;
    };

  }
}
