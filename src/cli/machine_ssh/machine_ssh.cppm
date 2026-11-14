export module telar.cli.machine_ssh;

import std;
import telar.sys.posix;

export import telar.machines;

export import telar.base.text.json;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.base.text;
import telar.cli.command_limit;
import telar.cli.output;
import telar.cli.plugin;
import telar.cli.server;
import telar.client;
import telar.platform.daemon;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.paths;
import telar.platform.process;

// Interface: config_receive.cppm
export {
  namespace telar::runtime::cli::config_receive {

    inline constexpr std::size_t max_file_bytes = 1024 * 1024;
    inline constexpr std::size_t max_total_bytes = 16 * max_file_bytes;
    inline constexpr std::size_t max_files = 4096;

    // Directories that hold credentials, which no configuration sync reads or writes below.
    inline constexpr auto credential_directories = std::to_array<std::string_view>({".ssh", ".gnupg", ".aws", ".kube", ".docker", "keychains", "gcloud", ".password-store"});

    bool acceptable(std::string_view path);

    std::string line();

    int run();

  }
}

// Interface: launch_process.cppm
export {
  namespace telar::runtime::cli::launch {

    inline constexpr int ssh_failure = 255;
    inline constexpr std::size_t output_limit = 256 * 1024;

    std::vector<char*> pointers(const std::vector<std::string>& arguments);

    // Runs a program on this terminal: it keeps the standard streams and this process group, and
    // nothing else this process holds.
    int inherit(const std::vector<std::string>& arguments);

    struct Output {
      int status = ssh_failure;
      std::string out;
      std::string err;
      std::size_t dropped = 0;

      std::string_view errorLine() const;
    };

    // Runs a program with `input` on its standard input, keeping the tail of each output stream.
    // Input and output are polled together, so no size of either deadlocks against the child.
    template <Allocator Memory>
    Output capture(Memory& memory, const std::vector<std::string>& arguments, std::string_view input, std::chrono::seconds timeout);
    extern template Output capture<SystemAllocator>(SystemAllocator& memory, const std::vector<std::string>& arguments, std::string_view input, std::chrono::seconds timeout);
    extern template Output capture<Memory>(Memory& memory, const std::vector<std::string>& arguments, std::string_view input, std::chrono::seconds timeout);

    // As `capture`, with the contents of an open regular file as the input, or none for -1.
    template <Allocator Memory>
    Output captureFile(Memory& memory, const std::vector<std::string>& arguments, int file, std::chrono::seconds timeout);
    extern template Output captureFile<Memory>(Memory& memory, const std::vector<std::string>& arguments, int file, std::chrono::seconds timeout);

    std::string quote(std::string_view value);

  }
}

// Interface: machine_options.cppm
export {
  namespace telar::runtime::cli {

    struct MachineOptions {
      enum class Action {
        add,
        remove,
        rename,
        enable,
        disable,
        list,
        check,
        setup,
        receive_config,
      };
      Action action;
      std::string_view label;
      std::string_view value;
      std::optional<std::string_view> color;
      std::optional<std::string_view> new_label;
      std::optional<std::string_view> binary;
      bool disabled = false;
      bool check = false;
      bool json = false;
      bool setup = false;
      bool confirm = false;
      std::array<bool, 3> skip{};

      static MachineOptions parse(std::span<char* const> args);
    };

  }
}

// Interface: machine_store.cppm
export {
  namespace telar::runtime::cli::machine {

    using namespace machines;

    std::string profilesPath();

    template <Allocator Memory>
    MachineProfiles load(Memory& memory, const std::string& path);
    extern template MachineProfiles load<Memory>(Memory& memory, const std::string& path);

    std::string localLabel(const MachineProfiles& profiles);

    struct Random {
      void fill(std::span<std::uint8_t> bytes);
    };

    MachineProfile newProfile(const MachineProfiles& profiles, const MachineOptions& options);

    void change(MachineProfiles& profiles, const MachineOptions& options);

    const char* describe(std::string_view error);

    int report(const std::exception& error);

    template <Allocator Memory>
    int list(Memory& memory, const MachineProfiles& profiles, bool json);
    extern template int list<Memory>(Memory& memory, const MachineProfiles& profiles, bool json);

  }
}

// Interface: machine_ssh.cppm
export {
  namespace telar::runtime::cli::machine {

    inline constexpr std::size_t command_limit = 64 * 1024;
    inline constexpr auto probe_timeout = std::chrono::seconds{60};
    inline constexpr auto install_timeout = std::chrono::seconds{900};
    using Discovery = machines::MachineDiscovery<PATH_MAX>;

    std::string decode(std::string_view word);

    // The SSH argv that runs `command` there, with a terminal there only when `terminal`.
    template <Allocator Memory>
    std::vector<std::string> ssh(Memory& memory, std::string_view destination, std::string_view command, bool terminal = false);
    extern template std::vector<std::string> ssh<Memory>(Memory& memory, std::string_view destination, std::string_view command, bool terminal);

    // `GIT_SSH_COMMAND` for Git traffic to `destination` over the same options.
    template <Allocator Memory>
    std::string gitSshCommand(Memory& memory, std::string_view destination);
    extern template std::string gitSshCommand<Memory>(Memory& memory, std::string_view destination);

    // The shell command that runs `words` as one telar command there.
    template <typename Words>
    std::string remoteCommand(const MachineProfile& profile, const Words& words);
    extern template std::string remoteCommand<std::vector<std::string>>(const MachineProfile& profile, const std::vector<std::string>& words);

    // Runs one telar command on the machine with this terminal's streams and
    // returns its exit status. When stdin and stdout are a terminal, so is the
    // command's there, so it can ask the person here.
    template <Allocator Memory, typename Words>
    int forward(Memory& memory, const MachineProfile& profile, const Words& words);
    extern template int forward<Memory, std::vector<std::string>>(Memory& memory, const MachineProfile& profile, const std::vector<std::string>& words);
    extern template int forward<Memory, std::span<char* const>>(Memory& memory, const MachineProfile& profile, const std::span<char* const>& words);

    // Runs one telar command on the machine, reading `input` (or nothing), and
    // returns its stdout. Its stderr passes through; a failure throws `failure`.
    template <Allocator Memory, typename Words>
    std::string capture(Memory& memory, const MachineProfile& profile, const Words& words, const char* failure, int input = -1);
    extern template std::string capture<Memory, std::span<const std::string_view>>(Memory& memory, const MachineProfile& profile, const std::span<const std::string_view>& words, const char* failure, int input);
    extern template std::string capture<Memory, std::vector<std::string>>(Memory& memory, const MachineProfile& profile, const std::vector<std::string>& words, const char* failure, int input);

    // The saved machine `label` names, or nullopt for this machine's own label.
    template <Allocator Memory>
    std::optional<MachineProfile> resolve(Memory& memory, std::string_view label);
    extern template std::optional<MachineProfile> resolve<Memory>(Memory& memory, std::string_view label);

    MachineError sshFailure(const launch::Output& output);

    template <Allocator Memory>
    Discovery discover(Memory& memory, const MachineProfile& profile, std::string& detail);
    extern template Discovery discover<Memory>(Memory& memory, const MachineProfile& profile, std::string& detail);

    template <Allocator Memory>
    int check(Memory& memory, const MachineProfile& profile, bool json);
    extern template int check<Memory>(Memory& memory, const MachineProfile& profile, bool json);

  }
}

// Interface: machines/config_filter.cppm
export {
  namespace telar::runtime::cli::machine::filter {

    std::string rewriteHome(std::string_view bytes, std::string_view from, std::string_view to);

    std::string stripJsonc(std::string_view bytes);

    template <Allocator Memory>
    void json(Memory& memory, const JsonValue& value, String<Memory>& output, std::vector<std::string>& dropped);
    extern template void json<Memory>(Memory& memory, const JsonValue& value, String<Memory>& output, std::vector<std::string>& dropped);

    std::string toml(std::string_view bytes, std::vector<std::string>& dropped);

    std::optional<std::pair<std::size_t, std::string_view>> findSecret(std::string_view bytes);

  }
}

// Interface: window_launch_options.cppm
export {
  namespace telar::runtime::cli {

    struct WindowOptions {
      std::optional<std::string> config;
      std::optional<std::string> profile;
      std::optional<std::string> theme;
      std::optional<std::string> remote;
      std::optional<std::string> machine;
      bool no_config = false;
      bool fresh = false;
      bool login_shell = false;
      std::vector<std::string> command;

      static std::string canonicalTheme(std::string_view name);

      static WindowOptions parse(std::span<char* const> input, bool gui = false);
    };

  }
}

// Interface: window_launch.cppm
export {
  namespace telar::runtime::cli {

    void relaunchLogin(std::span<char* const> words);

    template <Allocator Memory>
    int openWindow(Memory& memory, const WindowOptions& options);
    extern template int openWindow<Memory>(Memory& memory, const WindowOptions& options);

  }
}
