module telar.runtime.host.proc_file;

import telar.base.ds;
import telar.base.text;
import telar.tbc;

namespace telar::runtime {

  ProcDirectory::ProcDirectory(pid_t process) noexcept {
    ds::Array<char, sizeof("/proc/") + std::numeric_limits<pid_t>::digits10 + 1> path{};
    if (process > 0) {
      std::snprintf(path.dataMut(), path.size(), "/proc/%d", process);
      directory_.reset(::open(path.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    }
  }

  bool ProcDirectory::belongsTo(uid_t user) const noexcept {
    const auto found = owner();
    return found && *found == user;
  }

  ds::Option<uid_t> ProcDirectory::owner() const noexcept {
    struct stat status{};
    if (!directory_ || ::fstat(directory_.get(), &status) != 0) {
      return ds::none;
    }

    return status.st_uid;
  }

  tbc::val_a<ds::Option<std::string_view>> ProcDirectory::read(const char* name, tbc::val_a<std::span<char>> buffer) const noexcept {
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

  tbc::val_a<ds::Option<std::string_view>> ProcDirectory::link(const char* name, tbc::val_a<std::span<char>> buffer) const noexcept {
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
    result.state = input[end + 2];
    input.remove_prefix(end + 4);

    // Fields as proc(5) numbers them; the name is 2 and the state 3.
    enum class Field : unsigned {
      parent = 4,
      group = 5,
      foreground = 8,
      user_time = 14,
      system_time = 15,
      nice = 19,
      threads = 20,
      started = 22,
      resident = 24,
    };

    for (unsigned field = static_cast<unsigned>(Field::parent); field <= static_cast<unsigned>(Field::resident); ++field) {
      const auto separator = input.find(' ');
      const auto word = input.substr(0, separator);
      const auto selected = static_cast<Field>(field);

      const auto wanted = selected == Field::parent || selected == Field::group || selected == Field::foreground || selected == Field::user_time ||
                          selected == Field::system_time || selected == Field::nice || selected == Field::threads || selected == Field::started ||
                          selected == Field::resident;
      if (wanted) {
        const auto parsed = parseExact<std::int64_t>(word);
        if (!parsed) {
          return ds::none;
        }

        const auto value = *parsed;
        if (value < 0 && selected != Field::nice && selected != Field::foreground) {
          return ds::none;
        }

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
        case Field::user_time:
        case Field::system_time:
          result.cpu_ticks += static_cast<std::uint64_t>(value);
          break;
        case Field::nice:
          result.nice = static_cast<std::int8_t>(std::clamp<std::int64_t>(value, -20, 19));
          break;
        case Field::threads:
          result.threads = static_cast<std::uint32_t>(std::min<std::int64_t>(value, std::numeric_limits<std::uint32_t>::max()));
          break;
        case Field::started:
          result.started_ticks = static_cast<std::uint64_t>(value);
          break;
        case Field::resident:
          result.resident_pages = static_cast<std::uint64_t>(value);
          break;
        }
      }

      if (separator == std::string_view::npos) {
        return field >= static_cast<unsigned>(Field::started) ? ds::Option{result} : ds::none;
      }

      input.remove_prefix(separator + 1);
    }

    return result;
  }

}
