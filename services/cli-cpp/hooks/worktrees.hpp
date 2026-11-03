#pragma once

#include "telar_platform/random_bytes.hpp"
#include "object.hpp"
#include "target.hpp"
#include "telar_base/memory/retained_stream.hpp"
#include "telar_platform/command_output.hpp"
#include "telar_platform/git_files.hpp"
#include "telar_platform/runtime_paths.hpp"

namespace telar::runtime::cli::hooks {

inline bool validWorktreeBranch(std::string_view branch) noexcept {
  if (branch.empty() || branch.size() > 200 || branch.front() == '-' || branch.front() == '.' || branch.contains("..")) {
    return false;
  }

  try {
    validateUtf8(branch);
  } catch (const EncodingError &) {
    return false;
  }

  return std::ranges::none_of(branch, [](unsigned char byte) { return byte <= ' ' || byte == 0x7f || byte == '~' || byte == '^' || byte == ':'; });
}

template <Allocator Memory, EnvironmentLookup Environment>
class Worktrees {
public:
  explicit Worktrees(Memory &memory, const Environment &environment, std::string_view socket)
      : memory_(memory), environment_(environment), socket_(socket), output_(memory, maximum_output_bytes), root_(AllocatorRef<char, Memory>{memory}), branch_(AllocatorRef<char, Memory>{memory}), base_(AllocatorRef<char, Memory>{memory}), path_(AllocatorRef<char, Memory>{memory}) {}

  void answer(Object<Memory> &input) {
    TELAR_TRACE("hooks.worktree");
    if (input.text("hook_event_name") == "WorktreeCreate") {
      create(input);
    } else {
      remove(input);
    }
  }

private:
  std::string_view git(std::initializer_list<std::string_view> arguments, const char *failure) {
    if (std::ranges::any_of(arguments, [](std::string_view argument) { return argument.contains('\0'); })) {
      throw std::runtime_error{failure};
    }

    Command command{memory_, Launch{.arguments = {arguments.begin(), arguments.size()}}, CommandPurpose::configured_helper};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{300};
    const bool mutation = std::ranges::find(arguments, "worktree") != arguments.end();
    if (mutation) {
      RetainedStream diagnostics{memory_, maximum_output_bytes};
      const auto status = output_.streamDiagnostics(command, deadline, [](std::span<const Byte>) { return true; }, [&](std::span<const Byte> bytes) { diagnostics.append(bytes); });
      if (status != 0) {
        std::array<Byte, maximum_output_bytes> buffer;
        const auto kept = diagnostics.read(diagnostics.retainedOffset(), buffer);
        if (diagnostics.retainedOffset() != 0) {
          std::fprintf(stderr, "(%llu earlier bytes of Git's output omitted)\n", static_cast<unsigned long long>(diagnostics.retainedOffset()));
        }

        std::fwrite(kept.data(), 1, kept.size(), stderr);
        throw std::runtime_error{failure};
      }

      return {};
    }
    if (output_.run(command, deadline) != 0) {
      throw std::runtime_error{failure};
    }

    return GitFiles::trim(output_.text(), " \r\n");
  }

  void mainRoot(std::string_view directory) {
    auto common = git({"git", "-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"}, "NotARepository");
    while (common.ends_with('/')) {
      common.remove_suffix(1);
    }
    if (!common.starts_with('/') || !common.ends_with("/.git")) {
      throw std::runtime_error{"NotARepository"};
    }

    root_ = common.substr(0, common.size() - 5);
  }

  void chooseBranch(std::string_view name) {
    branch_ = name;
    if (validWorktreeBranch(branch_)) {
      return;
    }

    branch_.resize(std::min<std::size_t>(branch_.size(), 200));
    for (auto &character : branch_) {
      const auto byte = static_cast<unsigned char>(character);
      const bool safe = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '/';
      if (!safe) {
        character = '-';
      }
    }

    branch_ = GitFiles::trim(branch_, "-./");
    if (!validWorktreeBranch(branch_)) {
      throw std::runtime_error{"InvalidWorktreeBranch"};
    }
  }

  void create(Object<Memory> &input) {
    std::array<char, PATH_MAX> current;
    auto cwd = input.text("cwd");
    if (cwd.empty()) {
      if (::getcwd(current.data(), current.size()) == nullptr) {
        throw SystemError{"Read working directory"};
      }

      cwd = current.data();
    }

    mainRoot(cwd);
    chooseBranch(input.text("name"));
    base_ = git({"git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"}, "NotARepository");
    if (!validWorktreeBranch(base_)) {
      throw std::runtime_error{"InvalidWorktreeBranch"};
    }

    path_ = root_;
    path_ += "-worktrees/";
    const auto suffix = path_.size();
    path_ += branch_;
    std::replace(path_.begin() + suffix, path_.end(), '/', '-');
    std::replace(path_.begin() + suffix, path_.end(), '\\', '-');
    String<Memory> reference{"refs/heads/", AllocatorRef<char, Memory>{memory_}};
    reference += branch_;
    bool exists = true;
    try {
      git({"git", "-C", root_, "show-ref", "--verify", "--quiet", reference}, "branch unavailable");
    } catch (const std::exception &) {
      exists = false;
    }

    if (exists) {
      git({"git", "-C", root_, "worktree", "add", "--", path_, branch_}, "WorktreeAddFailed");
    } else {
      git({"git", "-C", root_, "worktree", "add", "-b", branch_, "--", path_, base_}, "WorktreeAddFailed");
    }

    try {
      registerWorktree();
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar hook: worktree created but not tracked: %s\n", error.what());
    }

    std::printf("%s\n", path_.c_str());
  }

  RuntimePaths<Memory> paths() {
    ServerOptions options;
    options.socket = socket_;
    return RuntimePaths{memory_, options, environment_};
  }

  void registerWorktree() {
    const auto pane = unsignedValue(environment_.lookup("TELAR_PANE_ID"));
    const auto workspace_text = environment_.lookup("TELAR_WORKSPACE_ID");
    if (!pane || workspace_text.empty()) {
      return;
    }

    const auto workspace = unsignedValue(workspace_text);
    if (!workspace || *workspace == 0) {
      throw std::runtime_error{"InvalidWorkspaceId"};
    }
    if (*pane == 0) {
      throw std::runtime_error{"InvalidPaneId"};
    }

    const auto target = paneTarget(environment_, AgentProvider::claude);
    if (!target || target->generation == 0) {
      throw std::runtime_error{missing_pane_context};
    }

    const auto resolved = paths();
    Session session{memory_, resolved.socket.c_str(), *target};
    session.template exchange<WorktreeRegistered>(RegisterWorktree{.source = *workspace, .created_by = target->pane_id, .path = path_, .branch = branch_, .base = base_});
  }

  void remove(Object<Memory> &input) {
    path_ = input.text("worktree_path");
    if (!path_.starts_with('/') || path_.contains('\0')) {
      throw std::runtime_error{"InvalidWorktreePath"};
    }

    if (const auto pane = unsignedValue(environment_.lookup("TELAR_PANE_ID")); pane) {
      try {
        forgetWorktree();
      } catch (const std::exception &) {
      }
    }

    mainRoot(path_);
    try {
      git({"git", "-C", root_, "worktree", "remove", "--", path_}, "git worktree remove failed");
    } catch (const std::exception &) {
      std::fprintf(stderr, "telar hook: kept %s; it has changes to review\n", path_.c_str());
    }
  }

  void forgetWorktree() {
    const auto resolved = paths();
    RuntimeConnection connection{resolved.socket.c_str()};
    connection.receiveTimeout(30);
    Vector<Byte, Memory> incoming{AllocatorRef<Byte, Memory>{memory_}};
    Vector<Byte, Memory> decoded{AllocatorRef<Byte, Memory>{memory_}};
    incoming.resize(max_payload_size);
    decoded.resize(max_payload_size);
    std::array<Byte, 64> outgoing;
    std::uint64_t identity = 0;
    while (identity == 0) {
      randomBytes(&identity, sizeof(identity));
    }

    connection.send(RequestRuntimeState{.client_identity = identity, .interactive = false}, outgoing);
    for (;;) {
      const auto frame = connection.receive(incoming);
      if (frame.front() == static_cast<Byte>(ServerTag::workspace_list)) {
        DecodeStorage storage{decoded};
        const auto catalog = Codec::decode<WorkspaceList>(frame, storage);
        for (const auto &worktree : catalog.worktrees) {
          if (worktree.path == path_) {
            connection.send(ForgetWorktree{.request_id = 1, .worktree = worktree.worktree}, outgoing);
            waitForgotten(connection, incoming);
            return;
          }
        }

        return;
      }
      if (frame.front() == static_cast<Byte>(ServerTag::request_failed) || frame.front() == static_cast<Byte>(ServerTag::runtime_stopping)) {
        return;
      }
    }
  }

  static void waitForgotten(RuntimeConnection &connection, std::span<Byte> incoming) {
    for (;;) {
      const auto frame = connection.receive(incoming);
      if (frame.front() == static_cast<Byte>(ServerTag::request_completed) || frame.front() == static_cast<Byte>(ServerTag::request_failed)) {
        return;
      }
    }
  }

  static constexpr std::size_t maximum_output_bytes = 64 * 1024;
  Memory &memory_;
  const Environment &environment_;
  std::string_view socket_;
  CommandOutput<Memory> output_;
  String<Memory> root_;
  String<Memory> branch_;
  String<Memory> base_;
  String<Memory> path_;
};

template <Allocator Memory, EnvironmentLookup Environment>
Worktrees(Memory &memory, const Environment &environment, std::string_view socket) -> Worktrees<Memory, Environment>;

template <Allocator Memory, EnvironmentLookup Environment>
std::optional<int> answerWorktree(Memory &memory, const Environment &environment, Object<Memory> &fields, std::string_view socket) {
  try {
    for (const auto name : {"hook_event_name", "cwd", "name", "worktree_path"}) {
      fields.text(name);
    }

    const auto event = fields.text("hook_event_name");
    if (event == "WorktreeCreate" || event == "WorktreeRemove") {
      try {
        Worktrees{memory, environment, socket}.answer(fields);
        return 0;
      } catch (const std::exception &error) {
        std::fprintf(stderr, "telar hook: %.*s failed: %s\n", static_cast<int>(event.size()), event.data(), error.what());
        return 1;
      }
    }
  } catch (const std::exception &) {
  }

  return std::nullopt;
}

}
