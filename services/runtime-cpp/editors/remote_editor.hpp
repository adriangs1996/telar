#pragma once

#include "../diagnostics/trace.hpp"

#include "../platform/command_output.hpp"
#include "../runtime/request_context.hpp"
#include "../transport/encoded_reply.hpp"
#include "telar_base/editors/kind.hpp"
#include <charconv>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>

namespace telar::runtime {

template <Allocator Memory>
class RemoteEditor {
public:
  explicit RemoteEditor(Memory &memory)
      : memory_(memory),
        output_(memory, output_limit),
        expression_(AllocatorRef<char, Memory>{memory}),
        path_(AllocatorRef<char, Memory>{memory}),
        editor_(AllocatorRef<char, Memory>{memory}) {
    expression_.reserve(10 * 1024);
  }

  void open(const OpenEditor &request, const RequestContext &context, EncodedReply<Memory> &reply) {
    TELAR_TRACE("editor.open");
    request_ = &request;
    context_ = &context;
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

    kind_ = identifyEditor(request.editor);
    deadline_ = Clock::now() + std::chrono::seconds{3};
    entries_left_ = 128;
    endpoints_left_ = 32;
    commands_left_ = 128;
    opened_ = nullptr;
    try {
      if (context.editor_candidate_count != 0) {
        switch (kind_) {
        case EditorKind::neovim:
          discoverNeovim();
          break;
        case EditorKind::vim:
          discoverVim();
          break;
        case EditorKind::emacs:
          discoverEmacs();
          break;
        case EditorKind::unsupported:
          break;
        }
      }

      if (opened_ != nullptr) {
        result.outcome = EditorOutcome::opened;
        result.pane_id = opened_->pane;
        result.pane_generation = opened_->generation;
      }
    } catch (...) {
      result.outcome = EditorOutcome::failed;
    }

    reply.send(result);
  }

private:
  using Clock = std::chrono::steady_clock;
  static constexpr std::size_t output_limit = 16 * 1024;

  std::string_view command(std::span<const std::string_view> arguments) {
    if (commands_left_-- == 0 || Clock::now() >= deadline_) {
      throw RequestError{FailureCode::resource_limit, "Editor command limit reached"};
    }
    Command launch{memory_, Launch{.cwd = "/", .arguments = arguments}, CommandPurpose::administration};
    if (output_.run(launch, deadline_, false, context_->cancelled) != 0) {
      throw RequestError{FailureCode::internal, "Editor command failed"};
    }
    return output_.text();
  }

  static std::string_view trim(std::string_view text) noexcept {
    const auto first = text.find_first_not_of(" \r\n\t");
    if (first == std::string_view::npos) {
      return {};
    }
    return text.substr(first, text.find_last_not_of(" \r\n\t") - first + 1);
  }

  static bool ownedPath(const char *path, bool directory) noexcept {
    struct stat status{};
    return path[0] == '/' && ::lstat(path, &status) == 0 && status.st_uid == ::geteuid() && (status.st_mode & 0022) == 0 && (directory ? S_ISDIR(status.st_mode) : S_ISSOCK(status.st_mode));
  }

  void scan(std::string_view root, bool descend) {
    if (opened_ != nullptr || root.size() >= PATH_MAX) {
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
    while (entries_left_ != 0 && endpoints_left_ != 0 && opened_ == nullptr) {
      const auto *entry = ::readdir(stream.get());
      if (entry == nullptr) {
        break;
      }
      --entries_left_;
      if (std::string_view{entry->d_name} == "." || std::string_view{entry->d_name} == "..") {
        continue;
      }
      std::array<char, PATH_MAX> path{};
      const int count = std::snprintf(path.data(), path.size(), "%s/%s", directory.data(), entry->d_name);
      if (count < 0 || static_cast<std::size_t>(count) >= path.size()) {
        continue;
      }
      if (descend && ownedPath(path.data(), true)) {
        scan(path.data(), false);
      } else if (ownedPath(path.data(), false)) {
        --endpoints_left_;
        if (kind_ == EditorKind::emacs) {
          emacsEndpoint(path.data());
        } else if (std::string_view{entry->d_name}.starts_with("nvim.")) {
          vimEndpoint(path.data());
        }
      }
    }
  }

  void discoverNeovim() {
    if (const char *root = std::getenv("XDG_RUNTIME_DIR")) {
      scan(root, true);
    }
    const char *user = std::getenv("USER");
    if (opened_ != nullptr || user == nullptr || *user == '\0' || std::strchr(user, '/') != nullptr) {
      return;
    }
    const char *temporary = std::getenv("TMPDIR");
    for (const char *root : {temporary, "/tmp"}) {
      if (root == nullptr) {
        continue;
      }
      std::array<char, PATH_MAX> directory{};
      const int count = std::snprintf(directory.data(), directory.size(), "%s/nvim.%s", root, user);
      if (count > 0 && static_cast<std::size_t>(count) < directory.size()) {
        scan(directory.data(), true);
      }
    }
  }

  void discoverVim() {
    const std::array<std::string_view, 2> arguments{editor_, "--serverlist"};
    String<Memory> names{AllocatorRef<char, Memory>{memory_}};
    try {
      names.assign(command(arguments));
    } catch (...) {
      return;
    }
    std::string_view remaining = names;
    while (!remaining.empty() && endpoints_left_ != 0 && opened_ == nullptr) {
      const auto split = remaining.find('\n');
      const auto endpoint = trim(remaining.substr(0, split));
      remaining = split == std::string_view::npos ? std::string_view{} : remaining.substr(split + 1);
      if (endpoint.empty()) {
        continue;
      }
      --endpoints_left_;
      vimEndpoint(endpoint);
    }
  }

  const EditorCandidate *candidate(pid_t pid) const noexcept {
    const auto current = inspector_.identity(pid);
    if (!current) {
      return nullptr;
    }
    for (const auto &candidate : std::span{context_->editor_candidates}.first(context_->editor_candidate_count)) {
      if ((pid == candidate.process.pid || current->parent == candidate.process.pid) && inspector_.identity(candidate.process.pid) == candidate.process) {
        return &candidate;
      }
    }
    return nullptr;
  }

  void quote(std::string_view value, bool lisp) {
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

  void number(std::uint32_t value) {
    std::array<char, 16> bytes;
    const auto result = std::to_chars(bytes.data(), bytes.data() + bytes.size(), value);
    expression_.append(bytes.data(), result.ptr);
  }

  void vimEndpoint(std::string_view endpoint) {
    const std::string_view option = kind_ == EditorKind::neovim ? "--server" : "--servername";
    const std::array<std::string_view, 5> identity_arguments{editor_, option, endpoint, "--remote-expr", "getpid() . \"\\n\" . hostname()"};
    std::string_view identity;
    try {
      identity = command(identity_arguments);
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
    const auto *target = candidate(pid);
    if (target == nullptr) {
      return;
    }

    expression_ = "getpid() == ";
    number(pid);
    expression_ += " && hostname() == ";
    quote(host.data(), false);
    expression_ += " ? [execute('drop ' . fnameescape(";
    quote(request_->path, false);
    expression_ += "))";
    if (request_->line != 0) {
      expression_ += ", cursor(";
      number(request_->line);
      expression_ += ", ";
      number(std::max(request_->column, 1u));
      expression_ += ')';
    }
    expression_ += ", 1][-1] : 0";
    const std::array<std::string_view, 5> arguments{editor_, option, endpoint, "--remote-expr", expression_};
    if (trim(command(arguments)) != "1") {
      throw RequestError{FailureCode::internal, "Editor rejected open"};
    }
    opened_ = target;
  }

  void discoverEmacs() {
    if (const char *socket = std::getenv("EMACS_SOCKET_NAME"); socket != nullptr && ownedPath(socket, false)) {
      emacsEndpoint(socket);
    }
    if (const char *root = std::getenv("XDG_RUNTIME_DIR")) {
      std::array<char, PATH_MAX> path{};
      const int count = std::snprintf(path.data(), path.size(), "%s/emacs", root);
      if (count > 0 && static_cast<std::size_t>(count) < path.size()) {
        scan(path.data(), false);
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
        scan(path.data(), false);
      }
    }
  }

  void emacsEndpoint(std::string_view endpoint) {
    if (opened_ != nullptr) {
      return;
    }
    const auto slash = request_->editor.rfind('/');
    editor_.assign(slash == std::string_view::npos ? std::string_view{} : request_->editor.substr(0, slash + 1));
    editor_ += "emacsclient";
    const std::array<std::string_view, 6> identity_arguments{editor_, "--alternate-editor=/usr/bin/false", "--socket-name", endpoint, "--eval", "(emacs-pid)"};
    std::string_view identity;
    try {
      identity = trim(command(identity_arguments));
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
    for (const auto &target : std::span{context_->editor_candidates}.first(context_->editor_candidate_count)) {
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
      quote(request_->path, true);
      expression_ += "))";
      if (request_->line != 0) {
        expression_ += " (goto-char (point-min)) (forward-line ";
        number(request_->line - 1);
        expression_ += ") (move-to-column ";
        number(request_->column == 0 ? 0 : request_->column - 1);
        expression_ += ')';
      }
      expression_ += " 1) 0)) 0)";
      const std::array<std::string_view, 6> arguments{editor_, "--alternate-editor=/usr/bin/false", "--socket-name", endpoint, "--eval", expression_};
      const auto result = trim(command(arguments));
      if (result == "1") {
        opened_ = &target;
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
  const OpenEditor *request_ = nullptr;
  const RequestContext *context_ = nullptr;
  const EditorCandidate *opened_ = nullptr;
  EditorKind kind_ = EditorKind::unsupported;
  Clock::time_point deadline_{};
  unsigned entries_left_ = 0;
  unsigned endpoints_left_ = 0;
  unsigned commands_left_ = 0;
};

}
