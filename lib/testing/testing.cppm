export module telar.testing;

import std;

// A test program registers its cases and the child modes it can be started in, and
// lib/testing's main runs them. CTest runs every case as its own process, so a failed
// check ends that case and no other.
export namespace telar::testing {
  // A case of the program: `name` is "<suite>.<case>", and `run` passes by returning.
  // Define one at namespace scope; it links itself into the program's list.
  class Case {
  public:
    Case(std::string_view name, void (*run)()) noexcept;

    // From a literal without string_view's constructor from a pointer, which may throw:
    // a case is a static whose initializer runs before main can catch anything.
    template <std::size_t Size>
    Case(const char (&name)[Size], void (*run)()) noexcept
        : Case(std::string_view(name, Size - 1), run) {}

    Case(const Case&) = delete;
    Case& operator=(const Case&) = delete;

    [[nodiscard]] std::string_view name() const noexcept;
    void run() const;
    [[nodiscard]] const Case* next() const noexcept;

  private:
    std::string_view name_;
    void (*run_)();
    Case* next_ = nullptr;
  };

  // A way the program starts instead of running cases, for a child the tests spawn from
  // their own executable: main hands it the whole command line when argv[1] is `flag`.
  class Mode {
  public:
    Mode(std::string_view flag, int (*run)(int argc, char** argv)) noexcept;

    template <std::size_t Size>
    Mode(const char (&flag)[Size], int (*run)(int argc, char** argv)) noexcept
        : Mode(std::string_view(flag, Size - 1), run) {}

    Mode(const Mode&) = delete;
    Mode& operator=(const Mode&) = delete;

    [[nodiscard]] std::string_view flag() const noexcept;
    int run(int argc, char** argv) const;
    [[nodiscard]] const Mode* next() const noexcept;

  private:
    std::string_view flag_;
    int (*run_)(int, char**);
    const Mode* next_ = nullptr;
  };

  // A case that cannot run here, for want of a tool or a host, ends as skipped rather
  // than passed. Call it from the case's own thread, outside a catch (...).
  struct Skipped {};

  [[noreturn]] void skip(std::string_view reason);

  // Writes where a check failed and aborts the process: it allocates nothing and throws
  // nothing, so it holds in noexcept code, worker threads and forked children.
  [[noreturn]] void fail(std::string_view what, std::source_location location) noexcept;

  // Writes where an expectation failed and lets the case go on; the case fails when it
  // returns.
  void miss(std::string_view what, std::source_location location) noexcept;

  [[tbc::hot_path]] inline void check(bool condition, std::source_location location = std::source_location::current()) noexcept {
    if (!condition) [[unlikely]] {
      fail({}, location);
    }
  }

  [[tbc::hot_path]] inline void check(bool condition, std::string_view what, std::source_location location = std::source_location::current()) noexcept {
    if (!condition) [[unlikely]] {
      fail(what, location);
    }
  }

  [[tbc::hot_path]] inline bool expect(bool condition, std::string_view what = {}, std::source_location location = std::source_location::current()) noexcept {
    if (!condition) [[unlikely]] {
      miss(what, location);
    }

    return condition;
  }

  // The program's entry point, which lib/testing's main calls.
  int run(int argc, char** argv);
}
