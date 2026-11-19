module;
#include "tbc/annotations.hpp"

export module telar.platform.paths;

import std;
import telar.tbc;

import telar.base.memory.allocators;

import telar.sys.socket;
import telar.base.ds;

// Interface: telar_platform/process_environment.cppm
export {
  namespace telar::runtime {

    // An environment that the functions below read through one virtual call, so that they need not
    // be templates over it. What a lookup returns borrows the environment.
    class EnvironmentSource {
    public:
      virtual std::string_view lookup(const char* name) const = 0;

    protected:
      ~EnvironmentSource() = default;
    };

    struct ProcessEnvironment final : EnvironmentSource {
      std::string_view lookup(const char* name) const noexcept override;
    };

    // The process's environment, which is one per process: a value looked up in it borrows this object,
    // which outlives every caller.
    inline constexpr ProcessEnvironment process_environment{};

    template <typename Environment>
    concept EnvironmentLookup = requires(const Environment& environment, const char* name) {
      { environment.lookup(name) } -> std::same_as<std::string_view>;
    };

    // Any lookup behind the virtual one, as Rust's `&dyn Environment`, for a function that reads it
    // without being a template over it.
    template <EnvironmentLookup Environment>
    class TBC_GENERIC EnvironmentOf final : public EnvironmentSource {
    public:
      explicit EnvironmentOf(tbc::view<const Environment&, tbc::lt::a> environment) noexcept
          : environment_(environment) {}

      std::string_view lookup(const char* name) const override {
        return environment_.lookup(name);
      }

    private:
      tbc::view<const Environment&, tbc::lt::a> environment_;
    };

  }
}

// Interface: telar_platform/process_home.cppm
export {
  namespace telar::runtime {

    // HOME as this process started with it, read once: nothing in telar changes it.
    std::string_view processHome() noexcept;

  }
}

// Interface: telar_platform/server_options.cppm
export {
  namespace telar::runtime::cli {

    enum class ServerAction {
      run,
      stop,
      endpoint,
      bridge,
      help,
    };
    enum class ServerMode {
      foreground,
      background,
      daemonized,
    };

    struct ServerOptions {
      ServerAction action = ServerAction::run;
      ServerMode mode = ServerMode::foreground;
      std::string_view socket;
      std::string_view history;
      std::string_view session;
      std::string_view trace;
      std::string_view config;
      std::string_view profile;
      ds::Array<std::string_view, 64> engine_arguments;
      std::size_t engine_argument_count = 0;
      bool fresh = false;
      bool no_config = false;
      bool persist_session = true;
      bool resume_agents = true;

      static ServerOptions parse(std::span<char* const> arguments);

    private:
      static void setOnce(std::string_view& destination, std::string_view value);
      static void setFlag(bool& flag);
    };

  }
}

// Interface: telar_platform/tracing_build.cppm
export {
  namespace telar::runtime {

    // Only Debug builds record traces; asking another build for one fails instead of tracing nothing.
    void requireTracingBuild(bool requested);

  }
}

// Interface: telar_platform/runtime_paths.cppm
export {
  namespace telar::runtime::cli {

    // An environment without the socket overrides, which finds the socket every process shares.
    class DefaultSocketEnvironment final : public EnvironmentSource {
    public:
      explicit DefaultSocketEnvironment(const EnvironmentSource& source) noexcept;

      std::string_view lookup(const char* name) const override;

    private:
      const EnvironmentSource& source_;
    };

    // An XDG base directory as the specification reads it: `variable` when it holds an absolute
    // path, else `fallback` under HOME when that is absolute. Empty when neither applies, since a
    // relative path in either is invalid.
    // The pieces of an XDG base directory, which borrow the environment and the fallback.
    struct XdgDirectory {
      tbc::view<std::string_view, tbc::lt::a> base;
      tbc::view<std::string_view, tbc::lt::a> suffix;
    };

    tbc::view<XdgDirectory, tbc::lt::a> findXdgDirectory(tbc::view<const EnvironmentSource&, tbc::lt::a> environment, const char* variable, tbc::view<std::string_view, tbc::lt::a> fallback);

    // Joins the pieces into a string of the caller's allocator; built in paths.cpp for the
    // allocators of telar.base.memory.allocators.
    template <Allocator Memory>
    tbc::view<ds::String<Memory>, tbc::lt::a> xdgDirectory(tbc::view<Memory&, tbc::lt::a> memory, const EnvironmentSource& environment, const char* variable, std::string_view fallback);

    extern template ds::String<Memory> xdgDirectory<Memory>(Memory& memory, const EnvironmentSource& environment, const char* variable, std::string_view fallback);
    extern template ds::String<ConcurrentMemory> xdgDirectory<ConcurrentMemory>(ConcurrentMemory& memory, const EnvironmentSource& environment, const char* variable, std::string_view fallback);
    extern template ds::String<SystemAllocator> xdgDirectory<SystemAllocator>(SystemAllocator& memory, const EnvironmentSource& environment, const char* variable, std::string_view fallback);
    extern template ds::String<BudgetAllocator<SystemAllocator>> xdgDirectory<BudgetAllocator<SystemAllocator>>(BudgetAllocator<SystemAllocator>& memory, const EnvironmentSource& environment, const char* variable, std::string_view fallback);

    // Where a runtime's socket is, as every telar process finds it: the explicit path, else
    // TELAR_SOCKET, else TELAR_SOCKET_PATH, else the managed `runtime.sock` in XDG_RUNTIME_DIR/telar
    // or, without it, in TMPDIR/telar-<user> (/tmp without TMPDIR). Built in place; it throws unless
    // the result is an absolute path that fits sockaddr_un and names no directory.
    class SocketLocation {
    public:
      [[nodiscard]] static SocketLocation resolve(std::string_view explicit_path, const EnvironmentSource& environment, std::uint32_t user);
      [[nodiscard]] static SocketLocation explicitPath(std::string_view path);

      [[nodiscard]] std::string_view path() const noexcept;

      // The directory a managed socket lives in, which its runtime creates; none for an explicit path.
      [[nodiscard]] ds::Option<std::string_view> managedDirectory() const noexcept;

    private:
      void managed(std::string_view base, std::string_view name);
      void append(std::string_view text);
      void validate() const;

      ds::Array<char, sizeof(sockaddr_un::sun_path)> bytes_{};
      std::size_t length_ = 0;
      std::size_t directory_ = 0;
    };

    template <Allocator Memory>
    class RuntimePaths {
    public:
      // Keeps nothing of the options or the environment: its paths are copies in `memory`.
      explicit RuntimePaths(tbc::view<Memory&, tbc::lt::a> memory, const ServerOptions& options, const EnvironmentSource& environment);

      void resolveStorage(const ServerOptions& options, const EnvironmentSource& environment);
      void prepareSocket() const;
      bool isDefaultSocket(const EnvironmentSource& environment) const;

      // telar's configuration directory: XDG_CONFIG_HOME/telar, else ~/.config/telar; empty without either.
      [[nodiscard]] static tbc::view<ds::String<Memory>, tbc::lt::a> configHome(tbc::view<Memory&, tbc::lt::a> memory, const EnvironmentSource& environment);

      // The configuration a process started without --config reads: TELAR_DEVELOPMENT_CONFIG, else
      // config.lua in the configuration directory; empty without either.
      [[nodiscard]] static tbc::view<ds::String<Memory>, tbc::lt::a> configFile(tbc::view<Memory&, tbc::lt::a> memory, const EnvironmentSource& environment);

      void prepareStorage() const;

      tbc::view<ds::String<Memory>, tbc::lt::a> socket;
      tbc::view<ds::String<Memory>, tbc::lt::a> history;
      tbc::view<ds::String<Memory>, tbc::lt::a> session;
      // XDG_DATA_HOME, or ~/.local/share; empty without either.
      tbc::view<ds::String<Memory>, tbc::lt::a> data_home;
      bool socket_managed = false;
      bool history_managed = false;

    private:
      void resolveSocket(std::string_view override, const EnvironmentSource& environment);
    };

  }
}

// The allocators the templates above are built for, in paths.cpp: the erased Memory family and the
// stacks of base allocators that callers build directly. Any other allocator goes behind a
// MemoryAdapter.
namespace telar::runtime::cli {

  extern template class RuntimePaths<Memory>;
  extern template class RuntimePaths<ConcurrentMemory>;
  extern template class RuntimePaths<SystemAllocator>;
  extern template class RuntimePaths<BudgetAllocator<SystemAllocator>>;
  extern template class RuntimePaths<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

}
