module;
#include <cstdlib>
#include <sys/un.h>
#include <unistd.h>

export module telar.platform.paths;

import std;

export import telar.base.memory;

import telar.platform.fs;

// Interface: telar_platform/process_environment.cppm
export {
  namespace telar::runtime {

    struct ProcessEnvironment {
      inline std::string_view lookup(const char* name) const noexcept {
        const auto* value = std::getenv(name);

        return value == nullptr ? std::string_view{} : std::string_view{value};
      }
    };

    // The process's environment, which is one per process: a value looked up in it borrows this object,
    // which outlives every caller.
    inline constexpr ProcessEnvironment process_environment{};

    template <typename Environment>
    concept EnvironmentLookup = requires(const Environment& environment, const char* name) {
      { environment.lookup(name) } -> std::same_as<std::string_view>;
    };

  }
}

// Interface: telar_platform/process_home.cppm
export {
  namespace telar::runtime {

    // HOME as this process started with it, read once: nothing in telar changes it.
    inline std::string_view processHome() noexcept {
      static const std::string_view home = [] {
        const char* value = std::getenv("HOME");

        return value == nullptr ? std::string_view{} : std::string_view{value};
      }();

      return home;
    }

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
      std::array<std::string_view, 64> engine_arguments;
      std::size_t engine_argument_count = 0;
      bool fresh = false;
      bool no_config = false;
      bool persist_session = true;
      bool resume_agents = true;

      inline static ServerOptions parse(std::span<char* const> arguments) {
        ServerOptions options;
        bool action_selected = false;

        if (!arguments.empty() && std::string_view{arguments.front()} == "server") {
          arguments = arguments.subspan(1);
        }

        for (std::size_t index = 0; index < arguments.size(); ++index) {
          const std::string_view argument = arguments[index];
          const auto value = [&]() -> std::string_view {
            if (++index == arguments.size()) {
              throw std::invalid_argument{"Missing server option value"};
            }

            return arguments[index];
          };

          if (argument == "stop" || argument == "endpoint" || argument == "bridge") {
            if (action_selected) {
              throw std::invalid_argument{"Duplicate server action"};
            }

            action_selected = true;
            options.action = argument == "stop" ? ServerAction::stop : argument == "endpoint" ? ServerAction::endpoint
                                                                                              : ServerAction::bridge;
          } else if (argument == "--help") {
            options.action = ServerAction::help;
          } else if (argument == "--socket") {
            setOnce(options.socket, value());
          } else if (argument == "--history") {
            setOnce(options.history, value());
          } else if (argument == "--session") {
            setOnce(options.session, value());
          } else if (argument == "--trace") {
            setOnce(options.trace, value());
          } else if (argument == "--config") {
            if (options.no_config) {
              throw std::invalid_argument{"Conflicting configuration options"};
            }

            setOnce(options.config, value());
          } else if (argument == "--profile") {
            setOnce(options.profile, value());
          } else if (argument == "--engine-arg") {
            if (options.engine_argument_count == options.engine_arguments.size()) {
              throw std::invalid_argument{"Too many engine arguments"};
            }

            options.engine_arguments[options.engine_argument_count++] = value();
          } else if (argument == "--no-session") {
            options.persist_session = false;
          } else if (argument == "--no-resume") {
            options.resume_agents = false;
          } else if (argument == "--no-config") {
            if (!options.config.empty()) {
              throw std::invalid_argument{"Conflicting configuration options"};
            }

            setFlag(options.no_config);
          } else if (argument == "--fresh") {
            setFlag(options.fresh);
          } else if (argument == "--background" || argument == "--daemonized") {
            if (options.mode != ServerMode::foreground) {
              throw std::invalid_argument{"Conflicting server modes"};
            }

            options.mode = argument == "--background" ? ServerMode::background : ServerMode::daemonized;
          } else {
            throw std::invalid_argument{"Unknown server option"};
          }
        }

        if (options.fresh && options.action != ServerAction::run) {
          throw std::invalid_argument{"Fresh session requires the run action"};
        }

        if (options.action == ServerAction::stop && options.mode != ServerMode::foreground) {
          throw std::invalid_argument{"Conflicting server action"};
        }

        if (options.no_config && !options.profile.empty()) {
          throw std::invalid_argument{"A profile requires configuration"};
        }

        return options;
      }

    private:
      inline static void setOnce(std::string_view& destination, std::string_view value) {
        if (!destination.empty() || value.empty()) {
          throw std::invalid_argument{"Duplicate or empty server option"};
        }

        destination = value;
      }

      inline static void setFlag(bool& flag) {
        if (flag) {
          throw std::invalid_argument{"Duplicate server option"};
        }

        flag = true;
      }
    };

  }
}

// Interface: telar_platform/tracing_build.cppm
export {
  namespace telar::runtime {

    // Only Debug builds record traces; asking another build for one fails instead of tracing nothing.
    inline void requireTracingBuild(bool requested) {
#if !TELAR_DEBUG
      if (requested) {
        throw std::invalid_argument{"Tracing is available in Debug builds only"};
      }
#else
      static_cast<void>(requested);
#endif
    }

  }
}

// Interface: telar_platform/runtime_paths.cppm
export {
  namespace telar::runtime::cli {

    template <EnvironmentLookup Environment>
    struct DefaultSocketEnvironment {
      const Environment& source;

      inline std::string_view lookup(const char* name) const noexcept {
        const std::string_view key{name};

        return key == "TELAR_SOCKET" || key == "TELAR_SOCKET_PATH" ? std::string_view{} : source.lookup(name);
      }
    };

    // An XDG base directory as the specification reads it: `variable` when it holds an absolute
    // path, else `fallback` under HOME when that is absolute. Empty when neither applies, since a
    // relative path in either is invalid.
    template <Allocator Memory, EnvironmentLookup Environment>
    inline String<Memory> xdgDirectory(Memory& memory, const Environment& environment, const char* variable, std::string_view fallback) {
      String<Memory> path{AllocatorRef<char, Memory>{memory}};

      if (const auto base = environment.lookup(variable); base.starts_with('/')) {
        path = base;
      } else if (const auto home = environment.lookup("HOME"); home.starts_with('/')) {
        path = home;
        path += fallback;
      }

      return path;
    }

    // Where a runtime's socket is, as every telar process finds it: the explicit path, else
    // TELAR_SOCKET, else TELAR_SOCKET_PATH, else the managed `runtime.sock` in XDG_RUNTIME_DIR/telar
    // or, without it, in TMPDIR/telar-<user> (/tmp without TMPDIR). Built in place; it throws unless
    // the result is an absolute path that fits sockaddr_un and names no directory.
    class SocketLocation {
    public:
      template <EnvironmentLookup Environment>
      [[nodiscard]] inline static SocketLocation resolve(std::string_view explicit_path, const Environment& environment, std::uint32_t user) {
        for (const auto candidate : {explicit_path, environment.lookup("TELAR_SOCKET"), environment.lookup("TELAR_SOCKET_PATH")}) {
          if (!candidate.empty()) {
            return explicitPath(candidate);
          }
        }

        SocketLocation location;

        if (const auto runtime_directory = environment.lookup("XDG_RUNTIME_DIR"); !runtime_directory.empty()) {
          location.managed(runtime_directory, "telar");
        } else {
          const auto temporary_directory = environment.lookup("TMPDIR");
          std::array<char, 32> name;
          constexpr std::string_view prefix = "telar-";

          std::ranges::copy(prefix, name.begin());
          const auto converted = std::to_chars(name.data() + prefix.size(), name.data() + name.size(), user);

          location.managed(temporary_directory.empty() ? "/tmp" : temporary_directory, {name.data(), converted.ptr});
        }

        location.validate();
        return location;
      }

      [[nodiscard]] inline static SocketLocation explicitPath(std::string_view path) {
        SocketLocation location;

        location.append(path);
        location.validate();
        return location;
      }

      [[nodiscard]] inline std::string_view path() const noexcept {
        return {bytes_.data(), length_};
      }

      // The directory a managed socket lives in, which its runtime creates; none for an explicit path.
      [[nodiscard]] inline std::optional<std::string_view> managedDirectory() const noexcept {
        return directory_ == 0 ? std::nullopt : std::optional{path().substr(0, directory_)};
      }

    private:
      inline void managed(std::string_view base, std::string_view name) {
        append(base);
        if (!base.ends_with('/')) {
          append("/");
        }

        append(name);
        directory_ = length_;
        append("/runtime.sock");
      }

      inline void append(std::string_view text) {
        if (text.size() >= bytes_.size() - length_) {
          throw std::invalid_argument{"Invalid absolute runtime socket path"};
        }

        std::ranges::copy(text, bytes_.data() + length_);
        length_ += text.size();
      }

      inline void validate() const {
        const auto socket = path();
        if (socket.empty() || socket.front() != '/' || socket.back() == '/' || socket.contains('\0')) {
          throw std::invalid_argument{"Invalid absolute runtime socket path"};
        }
      }

      std::array<char, sizeof(sockaddr_un::sun_path)> bytes_{};
      std::size_t length_ = 0;
      std::size_t directory_ = 0;
    };

    template <Allocator Memory>
    class RuntimePaths {
    public:
      template <EnvironmentLookup Environment>
      inline explicit RuntimePaths(Memory& memory, const ServerOptions& options, const Environment& environment)
          : socket(AllocatorRef<char, Memory>{memory}),
            history(AllocatorRef<char, Memory>{memory}),
            session(AllocatorRef<char, Memory>{memory}),
            data_home(AllocatorRef<char, Memory>{memory}) {
        resolveSocket(options.socket, environment);
      }

      template <EnvironmentLookup Environment>
      inline void resolveStorage(const ServerOptions& options, const Environment& environment) {
        data_home = environment.lookup("XDG_DATA_HOME");
        if (const auto home = environment.lookup("HOME"); data_home.empty() && !home.empty()) {
          data_home = home;
          data_home += "/.local/share";
        }

        history = options.history.empty() ? environment.lookup("TELAR_HISTORY") : options.history;
        if (history.empty()) {
          if (data_home.empty()) {
            throw std::invalid_argument{"Home directory unavailable"};
          }

          history = data_home;
          history += "/telar/history.db";
          history_managed = true;
        }

        if (options.persist_session) {
          if (!options.session.empty()) {
            session = options.session;
          } else {
            session.assign(std::string_view{history}.substr(0, history.find_last_of('/') + 1));
            session += "session.ckpt";
          }
        }
      }

      inline void prepareSocket() const {
        if (socket_managed) {
          createPrivateDirectory(std::string_view{socket}.substr(0, socket.rfind('/')));
        }
      }

      template <EnvironmentLookup Environment>
      inline bool isDefaultSocket(const Environment& environment) const {
        const RuntimePaths expected{socket.get_allocator().memory(), ServerOptions{}, DefaultSocketEnvironment<Environment>{environment}};

        return socket == expected.socket;
      }

      // telar's configuration directory: XDG_CONFIG_HOME/telar, else ~/.config/telar; empty without either.
      template <EnvironmentLookup Environment>
      [[nodiscard]] inline static String<Memory> configHome(Memory& memory, const Environment& environment) {
        auto path = xdgDirectory(memory, environment, "XDG_CONFIG_HOME", "/.config");
        if (!path.empty()) {
          path += "/telar";
        }

        return path;
      }

      // The configuration a process started without --config reads: TELAR_DEVELOPMENT_CONFIG, else
      // config.lua in the configuration directory; empty without either.
      template <EnvironmentLookup Environment>
      [[nodiscard]] inline static String<Memory> configFile(Memory& memory, const Environment& environment) {
        if (const auto development = environment.lookup("TELAR_DEVELOPMENT_CONFIG"); !development.empty()) {
          return String<Memory>{development, AllocatorRef<char, Memory>{memory}};
        }

        auto path = configHome(memory, environment);
        if (!path.empty()) {
          path += "/config.lua";
        }

        return path;
      }

      inline void prepareStorage() const {
        if (history_managed) {
          createPrivateDirectory(std::string_view{history}.substr(0, history.rfind('/')));
        }
      }

      String<Memory> socket;
      String<Memory> history;
      String<Memory> session;
      // XDG_DATA_HOME, or ~/.local/share; empty without either.
      String<Memory> data_home;
      bool socket_managed = false;
      bool history_managed = false;

    private:
      template <EnvironmentLookup Environment>
      inline void resolveSocket(std::string_view override, const Environment& environment) {
        const auto location = SocketLocation::resolve(override, environment, ::getuid());

        socket = location.path();
        socket_managed = location.managedDirectory().has_value();
      }
    };

    template <Allocator Memory, EnvironmentLookup Environment>
    RuntimePaths(Memory& memory, const ServerOptions& options, const Environment& environment) -> RuntimePaths<Memory>;

  }
}
