module telar.testing;

import std;
import telar.sys.posix;

namespace telar::testing {

  namespace {

    // Constant-initialized, so a Case defined in any unit links in whatever the order of
    // dynamic initialization. Kept sorted by name.
    constinit Case* cases = nullptr;
    constinit const Mode* modes = nullptr;
    constinit const Case* current = nullptr;
    constinit std::atomic<bool> missed{false};

    // The longest line a report writes; a longer one is cut, never allocated.
    constexpr std::size_t report_capacity = 1024;

    class Report {
    public:
      Report& operator<<(std::string_view text) noexcept {
        const auto count = std::min(text.size(), bytes_.size() - size_);

        std::copy_n(text.data(), count, bytes_.data() + size_);
        size_ += count;

        return *this;
      }

      Report& operator<<(std::uint_least32_t value) noexcept {
        std::array<char, 16> digits{};
        const auto [end, error] = std::to_chars(digits.data(), digits.data() + digits.size(), value);

        static_cast<void>(error);

        return *this << std::string_view{digits.data(), static_cast<std::size_t>(end - digits.data())};
      }

      // One write per report, so reports from several threads do not interleave.
      void write(int descriptor) const noexcept {
        std::size_t written = 0;

        while (written < size_) {
          const auto count = ::write(descriptor, bytes_.data() + written, size_ - written);
          if (count <= 0) {
            return;
          }

          written += static_cast<std::size_t>(count);
        }
      }

    private:
      std::array<char, report_capacity> bytes_{};
      std::size_t size_ = 0;
    };

    void report(std::string_view verdict, std::string_view what, std::source_location location) noexcept {
      Report line;

      line << location.file_name() << ":" << location.line() << ": " << verdict;
      if (!what.empty()) {
        line << ": " << what;
      }

      if (current != nullptr) {
        line << " [" << current->name() << "]";
      }

      line << "\n";
      line.write(STDERR_FILENO);
    }

    void announce(std::string_view status, std::string_view name) noexcept {
      Report line;

      line << status << " " << name << "\n";
      line.write(STDOUT_FILENO);
    }

    // Runs one case and tells whether it passed: false on a missed expectation or an
    // exception, true when it passed or was skipped.
    bool execute(const Case& test) {
      current = &test;
      missed = false;
      announce("[ RUN      ]", test.name());
      try {
        test.run();
      } catch (const Skipped&) {
        current = nullptr;

        return true;
      } catch (const std::exception& error) {
        Report line;

        line << "unexpected exception: " << error.what() << " [" << test.name() << "]\n";
        line.write(STDERR_FILENO);
        missed = true;
      }

      current = nullptr;
      if (missed) {
        announce("[  FAILED  ]", test.name());

        return false;
      }

      announce("[       OK ]", test.name());

      return true;
    }

    // The case list in the format CMake's gtest_discover_tests reads: each suite on a line
    // ending in '.', each of its cases indented by two spaces. A name without '.' fails.
    int list() {
      std::string_view suite;

      for (const auto* test = cases; test != nullptr; test = test->next()) {
        const auto name = test->name();
        const auto dot = name.find('.');
        if (dot == std::string_view::npos || dot == 0 || dot + 1 == name.size()) {
          Report line;

          line << "case name is not <suite>.<case>: " << name << "\n";
          line.write(STDERR_FILENO);

          return 1;
        }

        if (test->next() != nullptr && test->next()->name() == name) {
          Report line;

          line << "case registered twice: " << name << "\n";
          line.write(STDERR_FILENO);

          return 1;
        }

        Report line;

        if (name.substr(0, dot) != suite) {
          suite = name.substr(0, dot);
          line << suite << ".\n";
        }

        line << "  " << name.substr(dot + 1) << "\n";
        line.write(STDOUT_FILENO);
      }

      return 0;
    }

    int runOne(std::string_view name) {
      for (const auto* test = cases; test != nullptr; test = test->next()) {
        if (test->name() == name) {
          return execute(*test) ? 0 : 1;
        }
      }

      Report line;

      line << "no case named " << name << "\n";
      line.write(STDERR_FILENO);

      return 1;
    }

    int runAll() {
      int failures = 0;

      for (const auto* test = cases; test != nullptr; test = test->next()) {
        if (!execute(*test)) {
          ++failures;
        }
      }

      return failures == 0 ? 0 : 1;
    }

  }

  Case::Case(std::string_view name, void (*run)()) noexcept
      : name_(name),
        run_(run) {
    Case** link = &cases;

    while (*link != nullptr && (*link)->name_ < name_) {
      link = &(*link)->next_;
    }

    next_ = *link;
    *link = this;
  }

  std::string_view Case::name() const noexcept {
    return name_;
  }

  void Case::run() const {
    run_();
  }

  const Case* Case::next() const noexcept {
    return next_;
  }

  Mode::Mode(std::string_view flag, int (*run)(int, char**)) noexcept
      : flag_(flag),
        run_(run),
        next_(modes) {
    modes = this;
  }

  std::string_view Mode::flag() const noexcept {
    return flag_;
  }

  int Mode::run(int argc, char** argv) const {
    return run_(argc, argv);
  }

  const Mode* Mode::next() const noexcept {
    return next_;
  }

  void skip(std::string_view reason) {
    Report line;

    line << "[  SKIPPED ] " << reason;
    if (current != nullptr) {
      line << " [" << current->name() << "]";
    }

    line << "\n";
    line.write(STDOUT_FILENO);

    throw Skipped{};
  }

  void fail(std::string_view what, std::source_location location) noexcept {
    report("check failed", what, location);
    std::abort();
  }

  void miss(std::string_view what, std::source_location location) noexcept {
    report("expectation failed", what, location);
    missed = true;
  }

  int run(int argc, char** argv) {
    if (argc >= 2) {
      const std::string_view first{argv[1]};

      for (const auto* mode = modes; mode != nullptr; mode = mode->next()) {
        if (mode->flag() == first) {
          return mode->run(argc, argv);
        }
      }
    }

    // CMake's gtest_discover_tests lists with --gtest_list_tests and runs one case with
    // --gtest_filter=<name>; the flags it adds next to them change nothing here.
    constexpr std::string_view filter = "--gtest_filter=";

    for (int index = 1; index < argc; ++index) {
      const std::string_view argument{argv[index]};
      if (argument == "--gtest_list_tests") {
        return list();
      }

      if (argument.starts_with(filter)) {
        return runOne(argument.substr(filter.size()));
      }
    }

    if (argc >= 2) {
      Report line;

      line << "usage: " << argv[0] << " [--gtest_list_tests | --gtest_filter=<suite>.<case>]\n";
      line.write(STDERR_FILENO);

      return 2;
    }

    return runAll();
  }

}
