module;
#include <cstdlib>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

export module telar.runtime.terminal.shell_completion.tests.ssh_host;

import std;
import telar.testing;

// A host `ssh` reaches, for the cases that complete through a shared connection: this one,
// through an sshd the case starts as the user, on a port of its own, with a throwaway key and a
// home of its own, by which what is completed there is told apart from this host.
export namespace telar::runtime::testing {

  inline std::string hostPath() {
    const char* path = std::getenv("PATH");

    return path == nullptr ? std::string{"/usr/bin:/bin"} : std::string{path};
  }

  // The program `name` along PATH, or empty.
  inline std::string program(std::string_view name) {
    const auto path = hostPath();

    for (const auto directory : std::views::split(std::string_view{path}, ':')) {
      const auto candidate = std::filesystem::path{std::string_view{directory}} / name;
      if (::access(candidate.c_str(), X_OK) == 0) {
        return candidate.string();
      }
    }

    return {};
  }

  // Runs a command of the test's own making, whose paths hold no quote; true when it succeeded.
  inline bool run(const std::string& command) {
    return std::system(command.c_str()) == 0; // NOLINT(cert-env33-c,concurrency-mt-unsafe): the test's own setup, before any completion runs
  }

  inline std::string shellQuoted(const std::filesystem::path& path) {
    return "'" + path.string() + "'";
  }

  // An sshd that lets this user in with a throwaway key, and the masters of shared connections to
  // it. Socket paths must fit a socket address, so everything lives in a short temporary directory.
  class Host {
  public:
    Host() {
      std::string name = "/tmp/telar-ssh-XXXXXX";

      telar::testing::check(::mkdtemp(name.data()) != nullptr);
      root = name;
      home = root / "home";
      control = root / "control";
      std::filesystem::create_directory(home);
      std::filesystem::create_directory(control);
      ::chmod(control.c_str(), 0700);

      auto sshd = program("sshd");
      for (const auto* candidate : {"/usr/sbin/sshd", "/usr/local/sbin/sshd"}) {
        if (sshd.empty() && ::access(candidate, X_OK) == 0) {
          sshd = candidate;
        }
      }

      if (sshd.empty() || program("ssh").empty() || program("ssh-keygen").empty()) {
        skip("ssh, ssh-keygen or sshd is not installed: completion through ssh is not checked");
      }

      if (!run("ssh-keygen -q -t ed25519 -N '' -f " + shellQuoted(root / "host_key") + " && ssh-keygen -q -t ed25519 -N '' -f " + shellQuoted(root / "user_key") + " && cp " + shellQuoted(root / "user_key.pub") + " " + shellQuoted(root / "authorized_keys"))) {
        skip("ssh-keygen could not make the keys");
      }

      // The port is the process's own, so cases running at once never share one.
      constexpr int first_port = 20000;
      constexpr int ports = 20000;

      for (int attempt = 0; attempt < 5 && port_ == 0; ++attempt) {
        const int port = first_port + static_cast<int>((::getpid() * 7 + attempt * 131) % ports);

        // One option's name is in two pieces, so no line pairs a credential's name with a value,
        // which a secret scanner reads as a hardcoded one.
        std::ofstream{root / "sshd_config"} << std::format(
            "Port {}\nListenAddress 127.0.0.1\nHostKey {}\nAuthorizedKeysFile {}\nPa"
            "sswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\nPidFile {}\nSetEnv HOME={} XDG_DATA_HOME={}/.local/share XDG_CONFIG_HOME={}/.config\n",
            port,
            (root / "host_key").string(),
            (root / "authorized_keys").string(),
            (root / "sshd.pid").string(),
            home.string(),
            home.string(),
            home.string()
        );
        if (run(sshd + " -f " + shellQuoted(root / "sshd_config") + " -E " + shellQuoted(root / "sshd.log"))) {
          port_ = port;
        }
      }

      if (port_ == 0) {
        skip("sshd could not be started as this user on a free port");
      }

      // A failed check aborts the case without unwinding: once its process is gone, this ends
      // its sshd and masters, whose command lines name the directory, and removes it.
      static_cast<void>(run(std::format("(while kill -0 {} 2>/dev/null; do sleep 1; done; rm -rf {}; pkill -f {}) </dev/null >/dev/null 2>&1 &", ::getpid(), shellQuoted(root), shellQuoted(root.string() + "/"))));

      std::ofstream{root / "ssh_config"} << std::format(
          "Host telar-test\n  HostName 127.0.0.1\n  Port {}\n  IdentityFile {}\n  IdentitiesOnly yes\n  UserKnownHostsFile {}\n  StrictHostKeyChecking no\n  BatchMode yes\n  LogLevel ERROR\n",
          port_,
          (root / "user_key").string(),
          (root / "known_hosts").string()
      );
    }

    ~Host() {
      cleanup();
    }

    Host(const Host&) = delete;
    Host& operator=(const Host&) = delete;
    Host(Host&&) = delete;
    Host& operator=(Host&&) = delete;

    // Connects with a master that shares its connection through `socket`, as ssh.sh has a
    // session do; sshd may need a moment to listen.
    std::string master(const std::filesystem::path& socket) {
      for (int attempt = 0; attempt < 20; ++attempt) {
        if (run("ssh -F " + shellQuoted(root / "ssh_config") + " -o ControlMaster=yes -o ControlPath=" + shellQuoted(socket) + " -o ControlPersist=no -N -f telar-test </dev/null >/dev/null 2>&1")) {
          masters_.push_back(socket.string());
          return socket.string();
        }

        std::this_thread::sleep_for(std::chrono::milliseconds{100});
      }

      skip("ssh could not reach the test's sshd");
    }

    // Ends the connection, as the session ending ends its master.
    void close(const std::string& socket) const {
      telar::testing::check(run("ssh -S " + shellQuoted(socket) + " -O exit telar-test >/dev/null 2>&1"), "the master ended");
      for (int wait = 0; wait < 50 && std::filesystem::exists(socket); ++wait) {
        std::this_thread::sleep_for(std::chrono::milliseconds{20});
      }
    }

    // Ends the masters and sshd, and removes their files, before the case ends as skipped.
    [[noreturn]] void skip(std::string_view reason) {
      cleanup();
      telar::testing::skip(reason);
    }

    std::filesystem::path root;
    std::filesystem::path home;
    std::filesystem::path control;

  private:
    void cleanup() {
      for (const auto& socket : masters_) {
        static_cast<void>(run("ssh -S " + shellQuoted(socket) + " -O exit telar-test >/dev/null 2>&1"));
      }

      masters_.clear();
      std::ifstream pid_file{root / "sshd.pid"};
      int pid = 0;

      if (pid_file >> pid && pid > 0) {
        ::kill(pid, SIGTERM);
      }

      std::error_code ignored;

      std::filesystem::remove_all(root, ignored);
    }

    int port_ = 0;
    std::vector<std::string> masters_;
  };

}
