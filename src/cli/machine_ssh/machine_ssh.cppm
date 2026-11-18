export module telar.cli.machine_ssh;

import std;
import telar.sys.posix;

import telar.machines;

import telar.base.text.json;
import telar.base.text;
import telar.cli.output;
import telar.cli.plugin;
import telar.platform.paths;
import telar.platform.process;
import telar.base.memory.allocators;
import telar.base.ds;

// Interface: config_receive.cppm
export {
  namespace telar::runtime::cli::config_receive {

    inline constexpr std::size_t max_file_bytes = 1024 * 1024;
    inline constexpr std::size_t max_total_bytes = 16 * max_file_bytes;
    inline constexpr std::size_t max_files = 4096;

    // Directories that hold credentials, which no configuration sync reads or writes below.
    inline constexpr auto credential_directories = ds::Array<std::string_view, 8>{".ssh", ".gnupg", ".aws", ".kube", ".docker", "keychains", "gcloud", ".password-store"};

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
    Output captureFile(Memory& memory, const std::vector<std::string>& arguments, int file, std::chrono::seconds timeout);

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
      ds::Option<std::string_view> color;
      ds::Option<std::string_view> new_label;
      ds::Option<std::string_view> binary;
      bool disabled = false;
      bool check = false;
      bool json = false;
      bool setup = false;
      bool confirm = false;
      ds::Array<bool, 3> skip{};

      static MachineOptions parse(std::span<char* const> args);
    };

  }
}

// Interface: machine_store.cppm
export {
  namespace telar::runtime::cli::machine {

    using namespace machines;

    std::string profilesPath();

    MachineProfiles load(Memory& memory, const std::string& path);

    std::string localLabel(const MachineProfiles& profiles);

    struct Random {
      void fill(std::span<std::uint8_t> bytes);
    };

    MachineProfile newProfile(const MachineProfiles& profiles, const MachineOptions& options);

    void change(MachineProfiles& profiles, const MachineOptions& options);

    const char* describe(std::string_view error);

    int report(const std::exception& error);

    int list(Memory& memory, const MachineProfiles& profiles, bool json);

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
    std::vector<std::string> ssh(Memory& memory, std::string_view destination, std::string_view command, bool terminal = false);

    // `GIT_SSH_COMMAND` for Git traffic to `destination` over the same options.
    std::string gitSshCommand(Memory& memory, std::string_view destination);

    // The shell command that runs `words` as one telar command there.
    template <typename Words>
    std::string remoteCommand(const MachineProfile& profile, const Words& words);
    extern template std::string remoteCommand<std::vector<std::string>>(const MachineProfile& profile, const std::vector<std::string>& words);

    // Runs one telar command on the machine with this terminal's streams and
    // returns its exit status. When stdin and stdout are a terminal, so is the
    // command's there, so it can ask the person here.
    template <typename Words>
    int forward(Memory& memory, const MachineProfile& profile, const Words& words);
    extern template int forward<std::vector<std::string>>(Memory& memory, const MachineProfile& profile, const std::vector<std::string>& words);
    extern template int forward<std::span<char* const>>(Memory& memory, const MachineProfile& profile, const std::span<char* const>& words);

    // Runs one telar command on the machine, reading `input` (or nothing), and
    // returns its stdout. Its stderr passes through; a failure throws `failure`.
    template <Allocator Memory, typename Words>
    std::string capture(Memory& memory, const MachineProfile& profile, const Words& words, const char* failure, int input = -1);
    extern template std::string capture<Memory, std::span<const std::string_view>>(Memory& memory, const MachineProfile& profile, const std::span<const std::string_view>& words, const char* failure, int input);
    extern template std::string capture<Memory, std::vector<std::string>>(Memory& memory, const MachineProfile& profile, const std::vector<std::string>& words, const char* failure, int input);

    // The saved machine `label` names, or nullopt for this machine's own label.
    ds::Option<MachineProfile> resolve(Memory& memory, std::string_view label);

    MachineError sshFailure(const launch::Output& output);

    Discovery discover(Memory& memory, const MachineProfile& profile, std::string& detail);

    int check(Memory& memory, const MachineProfile& profile, bool json);

  }
}

// Interface: machines/config_filter.cppm
export {
  namespace telar::runtime::cli::machine::filter {

    std::string rewriteHome(std::string_view bytes, std::string_view from, std::string_view to);

    std::string stripJsonc(std::string_view bytes);

    void json(Memory& memory, const JsonValue& value, ds::String<Memory>& output, std::vector<std::string>& dropped);

    std::string toml(std::string_view bytes, std::vector<std::string>& dropped);

    ds::Option<std::pair<std::size_t, std::string_view>> findSecret(std::string_view bytes);

  }
}

// Interface: window_launch_options.cppm
export {
  namespace telar::runtime::cli {

    struct WindowOptions {
      ds::Option<std::string> config;
      ds::Option<std::string> profile;
      ds::Option<std::string> theme;
      ds::Option<std::string> remote;
      ds::Option<std::string> machine;
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

    int openWindow(Memory& memory, const WindowOptions& options);

  }
}
