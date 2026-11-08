module;
#include "telar_platform/trace_macro.hpp"
#include <cstdlib>
#include <new>
#include <cstdio>

#include <cstdint>
#include <cstring>
#include <sys/types.h>
#include <unistd.h>
#include <cassert>
#include <cstddef>
#include <cerrno>
#include <limits.h>
#include <poll.h>
#include <sys/wait.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include "tbc/view.hpp"

export module telar.runtime.editors.remote_editor;

import std;

export import telar.runtime.runtime.background_executor;
export import telar.runtime.transport.connection;
export import telar.base.editors;
export import telar.platform;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: editors/remote_editor.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class RemoteEditor {
private:
  using Clock = std::chrono::steady_clock;

  // One open request: what it asks, the budgets it spends, and the candidate it opened, which views
  // the request's context. The editor keeps only the buffers every request reuses.
  struct Session {
    const OpenEditor &request;
    tbc::view<const RequestContext &, tbc::lt::a> context;
    EditorKind kind;
    Clock::time_point deadline;
    unsigned entries_left = 128;
    unsigned endpoints_left = 32;
    unsigned commands_left = 128;
    tbc::view<const EditorCandidate *, tbc::lt::a> opened = nullptr;
  };

public:
  inline explicit RemoteEditor(Memory &memory)
      : memory_(memory),
        output_(memory, output_limit),
        expression_(AllocatorRef<char, Memory>{memory}),
        path_(AllocatorRef<char, Memory>{memory}),
        editor_(AllocatorRef<char, Memory>{memory}) {
    expression_.reserve(10 * 1024);
  }

  inline void open(const OpenEditor &request, const RequestContext &context, EncodedReply<Memory> &reply) {
    TELAR_TRACE("editor.open");
    path_.assign(request.path);
    editor_.assign(request.editor);
    struct stat status{};
    EditorOpened result{.request_id = request.request_id,
                        .outcome = EditorOutcome::unavailable};
    if (::stat(path_.c_str(), &status) != 0 || !S_ISREG(status.st_mode)) {
      result.outcome = EditorOutcome::missing;
      reply.send(result);
      return;
    }

    Session session{.request = request, .context = context, .kind = identifyEditor(request.editor), .deadline = Clock::now() + std::chrono::seconds{3}};
    try {
      if (context.editor_candidate_count != 0) {
        switch (session.kind) {
        case EditorKind::neovim:
          discoverNeovim(session);
          break;
        case EditorKind::vim:
          discoverVim(session);
          break;
        case EditorKind::emacs:
          discoverEmacs(session);
          break;
        case EditorKind::unsupported:
          break;
        }
      }

      if (session.opened != nullptr) {
        result.outcome = EditorOutcome::opened;
        result.pane_id = session.opened->pane;
        result.pane_generation = session.opened->generation;
      }
    } catch (...) {
      result.outcome = EditorOutcome::failed;
    }

    reply.send(result);
  }

private:
  static constexpr std::size_t output_limit = 16 * 1024;

  inline std::string_view command(Session &session, std::span<const std::string_view> arguments) {
    if (session.commands_left-- == 0 || Clock::now() >= session.deadline) {
      throw RequestError{FailureCode::resource_limit, "Editor command limit reached"};
    }
    Command launch{memory_, Launch{.cwd = "/", .arguments = arguments}, CommandPurpose::administration};
    if (output_.run(launch, session.deadline, false, session.context.cancelled) != 0) {
      throw RequestError{FailureCode::internal, "Editor command failed"};
    }
    return output_.text();
  }

  inline static std::string_view trim(std::string_view text) noexcept {
    const auto first = text.find_first_not_of(" \r\n\t");
    if (first == std::string_view::npos) {
      return {};
    }
    return text.substr(first, text.find_last_not_of(" \r\n\t") - first + 1);
  }

  inline static bool ownedPath(const char *path, bool directory) noexcept {
    struct stat status{};
    return path[0] == '/' && ::lstat(path, &status) == 0 && status.st_uid == ::geteuid() && (status.st_mode & 0022) == 0 && (directory ? S_ISDIR(status.st_mode) : S_ISSOCK(status.st_mode));
  }

  inline void scan(Session &session, std::string_view root, bool descend) {
    if (session.opened != nullptr || root.size() >= PATH_MAX) {
      return;
    }
    std::array<char, PATH_MAX> directory{};
    std::copy(root.begin(), root.end(), directory.begin());
    if (!ownedPath(directory.data(), true)) {
      return;
    }
    FileDescriptor descriptor{::open(directory.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
    if (!descriptor) {
      return;
    }
    std::unique_ptr<DIR, decltype(&::closedir)> stream{::fdopendir(descriptor.get()), ::closedir};
    if (!stream) {
      return;
    }
    descriptor.release();
    while (session.entries_left != 0 && session.endpoints_left != 0 && session.opened == nullptr) {
      const auto *entry = ::readdir(stream.get());
      if (entry == nullptr) {
        break;
      }
      --session.entries_left;
      if (std::string_view{entry->d_name} == "." || std::string_view{entry->d_name} == "..") {
        continue;
      }
      std::array<char, PATH_MAX> path{};
      const int count = std::snprintf(path.data(), path.size(), "%s/%s", directory.data(), entry->d_name);
      if (count < 0 || static_cast<std::size_t>(count) >= path.size()) {
        continue;
      }
      if (descend && ownedPath(path.data(), true)) {
        scan(session, path.data(), false);
      } else if (ownedPath(path.data(), false)) {
        --session.endpoints_left;
        if (session.kind == EditorKind::emacs) {
          emacsEndpoint(session, path.data());
        } else if (std::string_view{entry->d_name}.starts_with("nvim.")) {
          vimEndpoint(session, path.data());
        }
      }
    }
  }

  inline void discoverNeovim(Session &session) {
    if (const char *root = std::getenv("XDG_RUNTIME_DIR")) {
      scan(session, root, true);
    }
    // A later lookup may overwrite what getenv returned, so the name is copied first.
    const char *found = std::getenv("USER");
    std::array<char, 256> user{};
    if (session.opened != nullptr || found == nullptr || *found == '\0' || std::strchr(found, '/') != nullptr || std::strlen(found) >= user.size()) {
      return;
    }
    std::strcpy(user.data(), found);
    const char *temporary = std::getenv("TMPDIR");
    for (const char *root : {temporary, "/tmp"}) {
      if (root == nullptr) {
        continue;
      }
      std::array<char, PATH_MAX> directory{};
      const int count = std::snprintf(directory.data(), directory.size(), "%s/nvim.%s", root, user.data());
      if (count > 0 && static_cast<std::size_t>(count) < directory.size()) {
        scan(session, directory.data(), true);
      }
    }
  }

  inline void discoverVim(Session &session) {
    const std::array<std::string_view, 2> arguments{editor_, "--serverlist"};
    String<Memory> names{AllocatorRef<char, Memory>{memory_}};
    try {
      names.assign(command(session, arguments));
    } catch (...) {
      return;
    }
    std::string_view remaining = names;
    while (!remaining.empty() && session.endpoints_left != 0 && session.opened == nullptr) {
      const auto split = remaining.find('\n');
      const auto endpoint = trim(remaining.substr(0, split));
      remaining = split == std::string_view::npos ? std::string_view{} : remaining.substr(split + 1);
      if (endpoint.empty()) {
        continue;
      }
      --session.endpoints_left;
      vimEndpoint(session, endpoint);
    }
  }

  // A candidate of the session's context, region `a`.
  inline tbc::view<const EditorCandidate *, tbc::lt::a> candidate(const Session &session, pid_t pid) const noexcept {
    const auto current = inspector_.identity(pid);
    if (!current) {
      return nullptr;
    }
    for (const auto &candidate : std::span{session.context.editor_candidates}.first(session.context.editor_candidate_count)) {
      if ((pid == candidate.process.pid || current->parent == candidate.process.pid) && inspector_.identity(candidate.process.pid) == candidate.process) {
        return &candidate;
      }
    }
    return nullptr;
  }

  inline void quote(std::string_view value, bool lisp) {
    const char delimiter = lisp ? '"' : '\'';
    expression_.push_back(delimiter);
    for (const char byte : value) {
      if (lisp && (byte == '"' || byte == '\\')) {
        expression_.push_back('\\');
      }
      expression_.push_back(byte);
      if (!lisp && byte == '\'') {
        expression_.push_back('\'');
      }
    }
    expression_.push_back(delimiter);
  }

  inline void number(std::uint32_t value) {
    std::array<char, 16> bytes;
    const auto result = std::to_chars(bytes.data(), bytes.data() + bytes.size(), value);
    expression_.append(bytes.data(), result.ptr);
  }

  inline void vimEndpoint(Session &session, std::string_view endpoint) {
    const std::string_view option = session.kind == EditorKind::neovim ? "--server" : "--servername";
    const std::array<std::string_view, 5> identity_arguments{editor_, option, endpoint, "--remote-expr", "getpid() . \"\\n\" . hostname()"};
    std::string_view identity;
    try {
      identity = command(session, identity_arguments);
    } catch (...) {
      return;
    }
    const auto split = identity.find_first_of("\r\n");
    if (split == std::string_view::npos) {
      return;
    }
    pid_t pid = 0;
    const auto parsed = std::from_chars(identity.data(), identity.data() + split, pid);
    if (parsed.ec != std::errc{} || parsed.ptr != identity.data() + split) {
      return;
    }
    std::array<char, 256> host{};
    if (::gethostname(host.data(), host.size() - 1) != 0 || trim(identity.substr(split)) != host.data()) {
      return;
    }
    const auto *target = candidate(session, pid);
    if (target == nullptr) {
      return;
    }

    expression_ = "getpid() == ";
    number(pid);
    expression_ += " && hostname() == ";
    quote(host.data(), false);
    expression_ += " ? [execute('drop ' . fnameescape(";
    quote(session.request.path, false);
    expression_ += "))";
    if (session.request.line != 0) {
      expression_ += ", cursor(";
      number(session.request.line);
      expression_ += ", ";
      number(std::max(session.request.column, 1u));
      expression_ += ')';
    }
    expression_ += ", 1][-1] : 0";
    const std::array<std::string_view, 5> arguments{editor_, option, endpoint, "--remote-expr", expression_};
    if (trim(command(session, arguments)) != "1") {
      throw RequestError{FailureCode::internal, "Editor rejected open"};
    }
    session.opened = target;
  }

  inline void discoverEmacs(Session &session) {
    if (const char *socket = std::getenv("EMACS_SOCKET_NAME"); socket != nullptr && ownedPath(socket, false)) {
      emacsEndpoint(session, socket);
    }
    if (const char *root = std::getenv("XDG_RUNTIME_DIR")) {
      std::array<char, PATH_MAX> path{};
      const int count = std::snprintf(path.data(), path.size(), "%s/emacs", root);
      if (count > 0 && static_cast<std::size_t>(count) < path.size()) {
        scan(session, path.data(), false);
      }
    }
    const char *temporary = std::getenv("TMPDIR");
    for (const char *root : {temporary, "/tmp"}) {
      if (root == nullptr) {
        continue;
      }
      std::array<char, PATH_MAX> path{};
      const int count = std::snprintf(path.data(), path.size(), "%s/emacs%u", root, ::getuid());
      if (count > 0 && static_cast<std::size_t>(count) < path.size()) {
        scan(session, path.data(), false);
      }
    }
  }

  inline void emacsEndpoint(Session &session, std::string_view endpoint) {
    if (session.opened != nullptr) {
      return;
    }
    const auto slash = session.request.editor.rfind('/');
    editor_.assign(slash == std::string_view::npos ? std::string_view{} : session.request.editor.substr(0, slash + 1));
    editor_ += "emacsclient";
    const std::array<std::string_view, 6> identity_arguments{editor_, "--alternate-editor=/usr/bin/false", "--socket-name", endpoint, "--eval", "(emacs-pid)"};
    std::string_view identity;
    try {
      identity = trim(command(session, identity_arguments));
    } catch (...) {
      return;
    }
    pid_t pid = 0;
    const auto parsed = std::from_chars(identity.data(), identity.data() + identity.size(), pid);
    if (parsed.ec != std::errc{} || parsed.ptr != identity.data() + identity.size()) {
      return;
    }
    std::array<char, 256> host{};
    if (::gethostname(host.data(), host.size() - 1) != 0) {
      return;
    }
    for (const auto &target : std::span{session.context.editor_candidates}.first(session.context.editor_candidate_count)) {
      if (inspector_.identity(target.process.pid) != target.process) {
        continue;
      }
      const auto terminal = inspector_.terminal(target.process.pid);
      if (terminal.view().empty()) {
        continue;
      }
      expression_ = "(if (and (= (emacs-pid) ";
      number(pid);
      expression_ += ") (equal (system-name) ";
      quote(host.data(), true);
      expression_ += ")) (let ((f (catch 'found (dolist (f (frame-list)) (when (and (not (display-graphic-p f)) (equal (terminal-name (frame-terminal f)) (concat \"/dev/\" ";
      quote(terminal.view().substr(sizeof("/dev/") - 1), true);
      expression_ += "))) (throw 'found f)))))) (if f (with-selected-frame f (find-file (concat \"/:\" ";
      quote(session.request.path, true);
      expression_ += "))";
      if (session.request.line != 0) {
        expression_ += " (goto-char (point-min)) (forward-line ";
        number(session.request.line - 1);
        expression_ += ") (move-to-column ";
        number(session.request.column == 0 ? 0 : session.request.column - 1);
        expression_ += ')';
      }
      expression_ += " 1) 0)) 0)";
      const std::array<std::string_view, 6> arguments{editor_, "--alternate-editor=/usr/bin/false", "--socket-name", endpoint, "--eval", expression_};
      const auto result = trim(command(session, arguments));
      if (result == "1") {
        session.opened = &target;
        return;
      }
      if (result != "0") {
        throw RequestError{FailureCode::internal, "Editor rejected open"};
      }
    }
  }

  Memory &memory_;
  CommandOutput<Memory> output_;
  String<Memory> expression_;
  String<Memory> path_;
  String<Memory> editor_;
  ProcessInspector inspector_;
};

}
}
