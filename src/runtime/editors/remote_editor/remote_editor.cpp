module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.editors.remote_editor;

import std;
import telar.base.text;
import telar.sys.posix;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::runtime {

  namespace {
    // A path the environment names, copied with its NUL, as Rust's env::var returns its own String: a
    // later lookup may replace the environment it lives in. A path too long to use reads as absent.
    class EnvironmentPath {
    public:
      explicit EnvironmentPath(const char* name) noexcept {
        // Asked for before the lookup, which any later call into the project may replace.
        auto* destination = text_.dataMut();
        const char* value = std::getenv(name);
        if (value == nullptr) {
          return;
        }

        const auto length = std::strlen(value);
        if (length < PATH_MAX) {
          std::memcpy(destination, value, length + 1);
          present_ = true;
        }
      }

      [[nodiscard]] const char* get() const noexcept {
        return present_ ? text_.data() : nullptr;
      }

    private:
      ds::Array<char, PATH_MAX> text_{};
      bool present_ = false;
    };
  }

  RemoteEditor::RemoteEditor(ConcurrentMemory& memory)
      : memory_(memory),
        output_(memory, output_limit),
        expression_(memory),
        path_(memory),
        editor_(memory) {
    expression_.reserve(10 * 1024);
  }

  void RemoteEditor::open(const OpenEditor& request, const RequestContext& context, EncodedReply<ConcurrentMemory>& reply) {
    TELAR_TRACE("editor.open");
    path_.assign(request.path);
    editor_.assign(request.editor);
    struct stat status{};
    EditorOpened result{.request_id = request.request_id, .outcome = EditorOutcome::unavailable};

    if (::stat(path_.data(), &status) != 0 || !S_ISREG(status.st_mode)) {
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

  std::string_view RemoteEditor::command(Session& session, std::span<const std::string_view> arguments) {
    if (session.commands_left-- == 0 || Clock::now() >= session.deadline) {
      throw RequestError{FailureCode::resource_limit, "Editor command limit reached"};
    }

    Command launch{memory_, Launch{.cwd = "/", .arguments = arguments}, CommandPurpose::administration};
    if (output_.run(launch, session.deadline, false, session.context.cancelled) != 0) {
      throw RequestError{FailureCode::internal, "Editor command failed"};
    }

    return output_.text();
  }

  bool RemoteEditor::ownedPath(const char* path, bool directory) noexcept {
    struct stat status{};

    return path[0] == '/' && ::lstat(path, &status) == 0 && status.st_uid == ::geteuid() && (status.st_mode & 0022) == 0 && (directory ? S_ISDIR(status.st_mode) : S_ISSOCK(status.st_mode));
  }

  void RemoteEditor::scan(Session& session, std::string_view root, bool descend) {
    if (session.opened != nullptr || root.size() >= PATH_MAX) {
      return;
    }

    ds::Array<char, PATH_MAX> directory{};

    std::copy(root.begin(), root.end(), directory.dataMut());
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
      const auto* entry = ::readdir(stream.get());
      if (entry == nullptr) {
        break;
      }

      --session.entries_left;
      if (std::string_view{entry->d_name} == "." || std::string_view{entry->d_name} == "..") {
        continue;
      }

      ds::Array<char, PATH_MAX> path{};
      const int count = std::snprintf(path.dataMut(), path.size(), "%s/%s", directory.data(), entry->d_name);
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

  void RemoteEditor::discoverNeovim(Session& session) {
    if (const EnvironmentPath root{"XDG_RUNTIME_DIR"}; root.get() != nullptr) {
      scan(session, root.get(), true);
    }

    // A later lookup may overwrite what getenv returned, so the name is copied first.
    const EnvironmentPath user{"USER"};
    const char* name = user.get();
    if (session.opened != nullptr || name == nullptr || *name == '\0' || std::strchr(name, '/') != nullptr) {
      return;
    }

    const EnvironmentPath temporary{"TMPDIR"};

    for (const char* root : {temporary.get(), "/tmp"}) {
      if (root == nullptr) {
        continue;
      }

      ds::Array<char, PATH_MAX> directory{};
      const int count = std::snprintf(directory.dataMut(), directory.size(), "%s/nvim.%s", root, name);
      if (count > 0 && static_cast<std::size_t>(count) < directory.size()) {
        scan(session, directory.data(), true);
      }
    }
  }

  void RemoteEditor::discoverVim(Session& session) {
    const ds::Array<std::string_view, 2> arguments{editor_, "--serverlist"};
    ds::String<ConcurrentMemory> names{memory_};

    try {
      names.assign(command(session, arguments));
    } catch (...) {
      return;
    }

    std::string_view remaining = names;

    while (!remaining.empty() && session.endpoints_left != 0 && session.opened == nullptr) {
      const auto split = remaining.find('\n');
      const auto endpoint = trimText(remaining.substr(0, split), " \r\n\t");

      remaining = split == std::string_view::npos ? std::string_view{} : remaining.substr(split + 1);
      if (endpoint.empty()) {
        continue;
      }

      --session.endpoints_left;
      vimEndpoint(session, endpoint);
    }
  }

  tbc::view<const EditorCandidate*, tbc::lt::a> RemoteEditor::candidate(const Session& session, pid_t pid) const noexcept {
    const auto current = inspector_.identity(pid);
    if (!current) {
      return nullptr;
    }

    for (const auto& candidate : std::span{session.context.editor_candidates}.first(session.context.editor_candidate_count)) {
      if ((pid == candidate.process.pid || current->parent == candidate.process.pid) && inspector_.identity(candidate.process.pid) == candidate.process) {
        return &candidate;
      }
    }

    return nullptr;
  }

  void RemoteEditor::quote(std::string_view value, bool lisp) {
    const char delimiter = lisp ? '"' : '\'';

    expression_.push(delimiter);
    for (const char byte : value) {
      if (lisp && (byte == '"' || byte == '\\')) {
        expression_.push('\\');
      }

      expression_.push(byte);
      if (!lisp && byte == '\'') {
        expression_.push('\'');
      }
    }

    expression_.push(delimiter);
  }

  void RemoteEditor::number(std::uint32_t value) {
    ds::Array<char, 16> bytes;
    const auto result = std::to_chars(bytes.dataMut(), bytes.dataMut() + bytes.size(), value);

    expression_.append(std::string_view{bytes.data(), static_cast<std::size_t>(result.ptr - bytes.data())});
  }

  void RemoteEditor::vimEndpoint(Session& session, std::string_view endpoint) {
    const std::string_view option = session.kind == EditorKind::neovim ? "--server" : "--servername";
    const ds::Array<std::string_view, 5> identity_arguments{editor_, option, endpoint, "--remote-expr", "getpid() . \"\\n\" . hostname()"};
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

    ds::Array<char, 256> host{};
    if (::gethostname(host.dataMut(), host.size() - 1) != 0 || trimText(identity.substr(split), " \r\n\t") != host.data()) {
      return;
    }

    const auto* target = candidate(session, pid);
    if (target == nullptr) {
      return;
    }

    expression_.assign("getpid() == ");
    number(pid);
    expression_.append(" && hostname() == ");
    quote(host.data(), false);
    expression_.append(" ? [execute('drop ' . fnameescape(");
    quote(session.request.path, false);
    expression_.append("))");
    if (session.request.line != 0) {
      expression_.append(", cursor(");
      number(session.request.line);
      expression_.append(", ");
      number(std::max(session.request.column, 1u));
      expression_.push(')');
    }

    expression_.append(", 1][-1] : 0");
    const ds::Array<std::string_view, 5> arguments{editor_, option, endpoint, "--remote-expr", expression_};
    if (trimText(command(session, arguments), " \r\n\t") != "1") {
      throw RequestError{FailureCode::internal, "Editor rejected open"};
    }

    session.opened = target;
  }

  void RemoteEditor::discoverEmacs(Session& session) {
    if (const EnvironmentPath socket{"EMACS_SOCKET_NAME"}; socket.get() != nullptr && ownedPath(socket.get(), false)) {
      emacsEndpoint(session, socket.get());
    }

    if (const EnvironmentPath root{"XDG_RUNTIME_DIR"}; root.get() != nullptr) {
      ds::Array<char, PATH_MAX> path{};
      const int count = std::snprintf(path.dataMut(), path.size(), "%s/emacs", root.get());
      if (count > 0 && static_cast<std::size_t>(count) < path.size()) {
        scan(session, path.data(), false);
      }
    }

    const EnvironmentPath temporary{"TMPDIR"};

    for (const char* root : {temporary.get(), "/tmp"}) {
      if (root == nullptr) {
        continue;
      }

      ds::Array<char, PATH_MAX> path{};
      const int count = std::snprintf(path.dataMut(), path.size(), "%s/emacs%u", root, ::getuid());
      if (count > 0 && static_cast<std::size_t>(count) < path.size()) {
        scan(session, path.data(), false);
      }
    }
  }

  void RemoteEditor::emacsEndpoint(Session& session, std::string_view endpoint) {
    if (session.opened != nullptr) {
      return;
    }

    const auto slash = session.request.editor.rfind('/');

    editor_.assign(slash == std::string_view::npos ? std::string_view{} : session.request.editor.substr(0, slash + 1));
    editor_.append("emacsclient");
    const ds::Array<std::string_view, 6> identity_arguments{editor_, "--alternate-editor=/usr/bin/false", "--socket-name", endpoint, "--eval", "(emacs-pid)"};
    std::string_view identity;

    try {
      identity = trimText(command(session, identity_arguments), " \r\n\t");
    } catch (...) {
      return;
    }

    const auto parsed = parseExact<pid_t>(identity);
    if (!parsed) {
      return;
    }

    const auto pid = *parsed;
    ds::Array<char, 256> host{};
    if (::gethostname(host.dataMut(), host.size() - 1) != 0) {
      return;
    }

    for (const auto& target : std::span{session.context.editor_candidates}.first(session.context.editor_candidate_count)) {
      if (inspector_.identity(target.process.pid) != target.process) {
        continue;
      }

      const auto terminal = inspector_.terminal(target.process.pid);
      if (terminal.view().empty()) {
        continue;
      }

      expression_.assign("(if (and (= (emacs-pid) ");
      number(pid);
      expression_.append(") (equal (system-name) ");
      quote(host.data(), true);
      expression_.append(")) (let ((f (catch 'found (dolist (f (frame-list)) (when (and (not (display-graphic-p f)) (equal (terminal-name (frame-terminal f)) (concat \"/dev/\" ");
      quote(terminal.view().substr(sizeof("/dev/") - 1), true);
      expression_.append("))) (throw 'found f)))))) (if f (with-selected-frame f (find-file (concat \"/:\" ");
      quote(session.request.path, true);
      expression_.append("))");
      if (session.request.line != 0) {
        expression_.append(" (goto-char (point-min)) (forward-line ");
        number(session.request.line - 1);
        expression_.append(") (move-to-column ");
        number(session.request.column == 0 ? 0 : session.request.column - 1);
        expression_.push(')');
      }

      expression_.append(" 1) 0)) 0)");
      const ds::Array<std::string_view, 6> arguments{editor_, "--alternate-editor=/usr/bin/false", "--socket-name", endpoint, "--eval", expression_};
      const auto result = trimText(command(session, arguments), " \r\n\t");
      if (result == "1") {
        session.opened = &target;
        return;
      }

      if (result != "0") {
        throw RequestError{FailureCode::internal, "Editor rejected open"};
      }
    }
  }

}
