module telar.runtime.platform.proc_file;
import telar.base.ds;

namespace telar::runtime {

  ProcDirectory::ProcDirectory(pid_t process) noexcept {
    ds::Array<char, sizeof("/proc/") + std::numeric_limits<pid_t>::digits10 + 1> path{};
    if (process > 0) {
      std::snprintf(path.dataMut(), path.size(), "/proc/%d", process);
      directory_.reset(::open(path.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    }
  }

  bool ProcDirectory::belongsTo(uid_t user) const noexcept {
    struct stat status{};
    return directory_ && ::fstat(directory_.get(), &status) == 0 && status.st_uid == user;
  }

  ds::Option<std::string_view> ProcDirectory::read(const char* name, std::span<char> buffer) const noexcept {
    FileDescriptor file{::openat(directory_.get(), name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)};
    if (!file) {
      return ds::none;
    }

    std::size_t used = 0;
    while (used < buffer.size()) {
      const auto count = ::read(file.get(), buffer.data() + used, buffer.size() - used);
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }
      if (count < 0) {
        return ds::none;
      }
      if (count == 0) {
        return std::string_view{buffer.data(), used};
      }
      used += static_cast<std::size_t>(count);
    }
    return ds::none;
  }

  ds::Option<std::string_view> ProcDirectory::link(const char* name, std::span<char> buffer) const noexcept {
    const auto count = ::readlinkat(directory_.get(), name, buffer.data(), buffer.size());
    if (count <= 0 || static_cast<std::size_t>(count) >= buffer.size()) {
      return ds::none;
    }
    return std::string_view{buffer.data(), static_cast<std::size_t>(count)};
  }

  ds::Option<ProcStat> ProcStat::parse(std::string_view input) noexcept {
    const auto begin = input.find('(');
    const auto end = input.rfind(')');
    if (begin == std::string_view::npos || end == std::string_view::npos || end <= begin || input.size() < end + 4) {
      return ds::none;
    }

    ProcStat result;
    result.name = input.substr(begin + 1, end - begin - 1);
    input.remove_prefix(end + 4);
    enum class Field : unsigned {
      parent = 4,
      group = 5,
      foreground = 8,
      started = 22,
    };
    for (unsigned field = static_cast<unsigned>(Field::parent); field <= static_cast<unsigned>(Field::started); ++field) {
      const auto separator = input.find(' ');
      const auto word = input.substr(0, separator);
      const auto selected = static_cast<Field>(field);
      if (selected == Field::parent || selected == Field::group || selected == Field::foreground || selected == Field::started) {
        const auto parsed = parseExact<std::int64_t>(word);
        if (!parsed) {
          return ds::none;
        }
        const auto value = *parsed;
        switch (selected) {
        case Field::parent:
          result.parent = static_cast<pid_t>(value);
          break;
        case Field::group:
          result.group = static_cast<pid_t>(value);
          break;
        case Field::foreground:
          result.foreground = static_cast<pid_t>(value);
          break;
        case Field::started:
          if (value < 0) {
            return ds::none;
          }
          result.started_ticks = static_cast<std::uint64_t>(value);
          break;
        }
      }
      if (separator == std::string_view::npos) {
        return field == static_cast<unsigned>(Field::started) ? ds::Option{result} : ds::none;
      }
      input.remove_prefix(separator + 1);
    }
    return result;
  }

}
