#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.runtime.editors.remote_editor;
import telar.runtime.platform.background_executor;
import telar.runtime.platform.process_probe;
import telar.runtime.transport.connection;
import telar.wire.editor;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::string text(std::string_view value) {
    return std::string{value};
  }

  void writeScript(const std::string& path, std::string_view body) {
    std::ofstream{path} << "#!/bin/sh\n"
                        << body;
    check(::chmod(path.c_str(), 0700) == 0);
  }

  // A listening socket at `path`, as an editor server leaves one.
  int listenAt(const std::string& path) {
    const int descriptor = ::socket(AF_UNIX, SOCK_STREAM, 0);
    sockaddr_un address{};

    address.sun_family = AF_UNIX;
    check(path.size() < sizeof(address.sun_path));
    std::strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
    check(::bind(descriptor, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0);
    check(::listen(descriptor, 1) == 0);
    return descriptor;
  }

  // A running process standing in for the editor a pane runs.
  class EditorProcess {
  public:
    EditorProcess() {
      process_ = ::fork();
      check(process_ >= 0);
      if (process_ == 0) {
        // Off the test's output, so a failed check does not leave CTest waiting for it.
        const int null = ::open("/dev/null", O_WRONLY);

        ::dup2(null, STDOUT_FILENO);
        ::dup2(null, STDERR_FILENO);
        ::execl("/bin/sleep", "sleep", "30", nullptr);
        ::_exit(127);
      }
    }

    ~EditorProcess() {
      ::kill(process_, SIGKILL);
      ::waitpid(process_, nullptr, 0);
    }

    EditorProcess(const EditorProcess&) = delete;
    EditorProcess& operator=(const EditorProcess&) = delete;

    pid_t pid() const noexcept {
      return process_;
    }

    RequestContext context() const {
      RequestContext context;
      const auto identity = ProcessInspector{}.identity(process_);

      check(identity.hasValue());
      context.editor_candidates[0] = {.pane = 7, .generation = 9, .process = *identity};
      context.editor_candidate_count = 1;
      return context;
    }

  private:
    pid_t process_ = -1;
  };

  EditorOutcome open(ConcurrentMemory& memory, const RequestContext& context, std::string_view editor, const std::string& file, EditorOpened* opened = nullptr) {
    RemoteEditor remote{memory};
    EncodedReply reply{memory};
    std::array<Byte, 1024> scratch;
    DecodeStorage storage{scratch};

    remote.open(OpenEditor{.request_id = 1, .editor = editor, .path = file, .line = 2, .column = 1}, context, reply);
    const auto result = Codec::decode<EditorOpened>(reply.payload(), storage);

    if (opened != nullptr) {
      *opened = result;
    }

    return result.outcome;
  }

  // Neovim servers in a shared runtime directory that another user could have planted: one that
  // anyone may write to, and a link to a socket elsewhere. telar sends neither an expression.
  void testForeignSocketIgnored() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory runtime{"/tmp/telar-editor-XXXXXX"};
    TemporaryDirectory elsewhere{"/tmp/telar-editor-XXXXXX"};
    const auto root = text(runtime.path());
    const auto invoked = text(elsewhere.path()) + "/invoked";
    const auto editor = text(elsewhere.path()) + "/nvim";
    const auto file = text(elsewhere.path()) + "/file.txt";

    std::ofstream{file} << "first\nsecond\n";
    writeScript(editor, "touch '" + invoked + "'\nexit 1\n");
    const int open_socket = listenAt(root + "/nvim.open");

    check(::chmod((root + "/nvim.open").c_str(), 0777) == 0);
    const int linked_socket = listenAt(text(elsewhere.path()) + "/target");

    check(::symlink((text(elsewhere.path()) + "/target").c_str(), (root + "/nvim.linked").c_str()) == 0);

    // Only the planted servers can be found: no user name or temporary directory leads elsewhere.
    check(::setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);
    check(::setenv("TMPDIR", elsewhere.path().data(), 1) == 0);
    check(::setenv("USER", "telar-test-nobody", 1) == 0);
    EditorProcess process;

    check(open(memory, process.context(), editor, file) == EditorOutcome::unavailable);
    check(!std::filesystem::exists(invoked), "telar ran the editor against a socket it does not trust");
    ::close(open_socket);
    ::close(linked_socket);
  }

  // vim lists its servers itself; the one whose process is the pane's editor opens the file.
  void testVimServerList() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-editor-XXXXXX"};
    const auto vim = text(directory.path()) + "/vim";
    const auto file = text(directory.path()) + "/file.txt";
    const auto opened_marker = text(directory.path()) + "/opened";
    EditorProcess process;
    std::array<char, 256> host{};

    check(::gethostname(host.data(), host.size() - 1) == 0);
    std::ofstream{file} << "first\nsecond\n";
    writeScript(vim, std::format(R"(case "$1" in
--serverlist) printf 'OTHER\nEDITOR\n' ;;
--servername)
  [ "$2" = EDITOR ] || exit 1
  case "$4" in
  'getpid() . '*) printf '%s\n%s\n' {} '{}' ;;
  *) touch '{}'; printf '1\n' ;;
  esac ;;
*) exit 1 ;;
esac
)",
                         process.pid(),
                         host.data(),
                         opened_marker));
    EditorOpened opened{};

    check(open(memory, process.context(), vim, file, &opened) == EditorOutcome::opened, "the listed vim server was not found");
    check(opened.pane_id == 7 && opened.pane_generation == 9);
    check(std::filesystem::exists(opened_marker));
  }

  const telar::testing::Case case_foreign_socket_ignored{"remote_editor.foreign_socket_ignored", testForeignSocketIgnored};
  const telar::testing::Case case_vim_server_list{"remote_editor.vim_server_list", testVimServerList};

}
