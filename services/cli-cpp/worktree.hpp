#pragma once

#include "session_history_paths.hpp"
#include "worktree_git.hpp"
#include "worktree_options.hpp"
#include "worktree_output.hpp"
#include "worktree_setup.hpp"
#include <openssl/sha.h>

namespace telar::runtime::cli::sessions {

inline std::optional<std::uint64_t> currentWorkspace() {
  const auto value = ::getenv("TELAR_WORKSPACE_ID");
  return value ? maybeUnsigned(value) : std::nullopt;
}

inline bool confirmRemoval(const char *question) {
  if (!::isatty(STDIN_FILENO)) {
    throw Failure{"this removal needs a person to confirm it at a terminal"};
  }
  std::fprintf(stderr, "%s? [y/N] ", question);
  std::array<char, 16> buffer;
  if (!std::fgets(buffer.data(), buffer.size(), stdin)) {
    return false;
  }
  std::string answer{buffer.data()};
  const auto begin = answer.find_first_not_of(" \r\t\n"), end = answer.find_last_not_of(" \r\t\n");
  if (begin == std::string::npos) {
    return false;
  }
  answer = answer.substr(begin, end - begin + 1);
  for (auto &byte : answer) {
    if (byte >= 'A' && byte <= 'Z') {
      byte += 'a' - 'A';
    }
  }
  return answer == "y" || answer == "yes";
}

template <Allocator Memory>
class WorktreeCommand {
public:
  WorktreeCommand(Memory &memory, const WorktreeOptions &options)
      : memory_(memory),
        options_(options),
        catalog_channel_(memory, options.socket, true),
        catalog_(catalog_channel_.catalog()),
        session_(memory, options.socket, false),
        git_(memory),
        output_(memory) {}

  int run() {
    using Action = WorktreeOptions::Action;
    int result = 0;
    switch (options_.action) {
    case Action::create:
      create();
      break;
    case Action::exec:
      result = exec();
      break;
    case Action::list:
      list();
      break;
    case Action::open:
      open();
      break;
    case Action::diff:
      diff();
      break;
    case Action::remove:
      remove();
      break;
    case Action::resolve:
      resolve();
      break;
    case Action::fetch:
      throw Failure{"fetch needs another machine"};
    }

    output_.flush();
    return result;
  }

private:
  const WorkspaceListEntry *workspace(std::uint64_t id) const {
    const auto found = std::ranges::find(catalog_.entries, id, &WorkspaceListEntry::workspace);
    return found == catalog_.entries.end() ? nullptr : &*found;
  }

  const WorkspaceListEntry *workspaceAt(std::string_view path) const {
    for (const auto &entry : catalog_.entries) {
      const bool holds_worktree = std::ranges::any_of(catalog_.worktrees, [&](const auto &worktree) { return worktree.workspace == entry.workspace; });
      if (entry.path == path && !holds_worktree) {
        return &entry;
      }
    }
    return nullptr;
  }

  const WorktreeListEntry *find(std::string_view reference) const {
    const WorktreeListEntry *found = nullptr;
    for (const auto &entry : catalog_.worktrees) {
      if (entry.branch != reference) {
        continue;
      }
      if (found) {
        throw Failure{"more than one worktree has that branch or title; name it by the other"};
      }
      found = &entry;
    }
    if (found) {
      return found;
    }

    const auto lower = [](unsigned char byte) { return byte >= 'A' && byte <= 'Z' ? byte + ('a' - 'A') : byte; };
    for (const auto &entry : catalog_.worktrees) {
      if (entry.title.size() != reference.size() || !std::equal(entry.title.begin(), entry.title.end(), reference.begin(), [&](auto left, auto right) { return lower(left) == lower(right); })) {
        continue;
      }
      if (found) {
        throw Failure{"more than one worktree has that branch or title; name it by the other"};
      }
      found = &entry;
    }
    return found;
  }

  std::string originDirectory() {
    if (options_.workspace) {
      if (const auto id = maybeUnsigned(*options_.workspace)) {
        const auto entry = workspace(*id);
        if (!entry) {
          throw Failure{"workspace not found", 2};
        }
        return std::string{entry->path};
      }
      return realDirectory(*options_.workspace);
    }

    if (const auto id = currentWorkspace()) {
      if (const auto entry = workspace(*id)) {
        return std::string{entry->path};
      }
    }
    return realDirectory(".");
  }

  std::uint64_t sourceWorkspace(std::string_view root) {
    if (options_.workspace) {
      if (const auto id = maybeUnsigned(*options_.workspace)) {
        return *id;
      }
    }
    if (const auto id = currentWorkspace()) {
      if (const auto entry = workspace(*id)) {
        try {
          if (git_.root(entry->path) == root) {
            return *id;
          }
        } catch (const std::exception &) {
        }
      }
    }
    if (const auto entry = workspaceAt(root)) {
      return entry->workspace;
    }

    const auto name = std::filesystem::path{root}.filename().string();
    const std::array shell{loginShell()};
    const auto opened = session_.template exchange<PaneOpened>(CreateWorkspace{.size = workspace_size, .name = name, .launch = {.cwd = root, .arguments = shell}});
    return opened.location.workspace.id;
  }

  std::optional<std::uint64_t> attributedPane() {
    const auto id_text = ::getenv("TELAR_PANE_ID"), generation_text = ::getenv("TELAR_PANE_GENERATION");
    if (!id_text || !generation_text) {
      return std::nullopt;
    }
    const auto id = maybeUnsigned(id_text), generation = maybeUnsigned(generation_text);
    if (!id || !generation || *id == 0 || *generation == 0) {
      return std::nullopt;
    }
    try {
      session_.template exchange<RequestCompleted>(VerifyPaneDescent{.pane_id = *id, .pane_generation = *generation});
      verified_generation_ = *generation;
      return id;
    } catch (const std::exception &) {
      return std::nullopt;
    }
  }

  std::optional<CoordinatorReference> coordinator(std::optional<std::uint64_t> pane) {
    if (options_.coordinator) {
      return options_.coordinator;
    }
    if (!pane) {
      return std::nullopt;
    }
    const auto agents = session_.template exchange<AgentSnapshot>(QueryAgents{});
    for (const auto &entry : agents.entries) {
      if (entry.pane_id == *pane && entry.pane_generation == verified_generation_ && std::ranges::any_of(entry.session_id, [](Byte byte) { return byte != 0; })) {
        return CoordinatorReference{.session_id = entry.session_id, .pane_id = *pane, .pane_generation = verified_generation_};
      }
    }
    return std::nullopt;
  }

  std::string brief() const {
    std::string result;
    for (std::size_t index = 1; index < options_.command.size(); ++index) {
      if (index != 1 && result.size() < brief_bytes) {
        result += ' ';
      }
      for (const unsigned char byte : std::string_view{options_.command[index]}) {
        if (result.size() == brief_bytes) {
          break;
        }
        if ((byte >= ' ' && byte != 0x7f) || byte == '\n' || byte == '\t') {
          result += static_cast<char>(byte);
        }
      }
    }
    while (!result.empty()) {
      try {
        validateUtf8(result);
        break;
      } catch (const EncodingError &) {
        result.pop_back();
      }
    }
    return result;
  }

  PaneOpened launch(std::uint64_t id, std::string_view directory) {
    std::vector<std::string_view> argv;
    const auto shell = loginShell();
    if (options_.command.empty()) {
      argv.push_back(shell);
    } else {
      const auto name = std::filesystem::path{shell}.filename().string();
      std::string_view line;
      if (name == "bash" || name == "zsh" || name == "ksh") {
        line = "exec -- \"$0\" \"$@\"";
      } else if (name == "sh" || name == "dash") {
        line = "exec \"$0\" \"$@\"";
      } else if (name == "fish") {
        line = "exec $argv";
      }
      if (!line.empty()) {
        argv = {shell, "-l", "-i", "-c", line};
      }
      for (const auto word : options_.command) {
        argv.push_back(word);
      }
    }
    return session_.template exchange<PaneOpened>(LaunchWorktree{.worktree = id, .label = options_.label.value_or(""), .size = launch_size, .launch = {.cwd = directory, .arguments = argv}});
  }

  void create() {
    const auto directory = originDirectory();
    const auto root = git_.root(directory);
    const auto branch = *options_.branch;
    auto suffix = std::string{branch};
    std::replace(suffix.begin(), suffix.end(), '/', '-');
    std::replace(suffix.begin(), suffix.end(), '\\', '-');
    const auto checkout = options_.directory ? std::string{*options_.directory} : root + "-worktrees/" + suffix;
    for (const auto &entry : catalog_.worktrees) {
      if (entry.path == checkout || entry.branch == branch) {
        throw Failure{"that worktree already exists; use `telar worktree exec` to run more there"};
      }
    }
    const auto base = options_.from ? std::string{*options_.from} : git_.currentBranch(root);
    try {
      sessions::branch(base);
    } catch (const std::invalid_argument &) {
      throw Failure{"UnusableBase"};
    }
    constexpr std::size_t maximum_worktrees = 64;
    if (catalog_.worktrees.size() >= maximum_worktrees) {
      throw Failure{"WorktreeLimitReached"};
    }
    const auto source = sourceWorkspace(root);
    git_.add(root, checkout, branch, base);
    const auto pane = attributedPane();
    const auto reference = coordinator(pane);
    const auto description = brief();
    const auto registered = session_.template exchange<WorktreeRegistered>(RegisterWorktree{.source = source, .created_by = pane, .path = checkout, .branch = branch, .base = base, .title = options_.title.value_or(""), .brief = description, .dispatched_from = options_.dispatched_from.value_or(""), .coordinator = reference});
    const auto setup = worktreeSetup(memory_, session_, checkout, options_.setup);
    const auto opened = launch(registered.worktree, checkout);
    worktreeLaunch(output_, WorktreeLaunch{.setup = setup, .worktree = registered.worktree, .path = checkout, .branch = branch, .base = base, .opened = opened}, options_.json);
  }

  std::vector<GitWorktree> untracked() {
    std::vector<GitWorktree> entries;
    try {
      entries = git_.listed(realDirectory("."), [&](std::string_view path) { return std::ranges::none_of(catalog_.worktrees, [&](const auto &tracked) { return tracked.path == path; }); });
    } catch (const std::exception &) {
      return {};
    }
    return entries;
  }

  WorktreeListEntry findOrAdopt() {
    if (const auto entry = find(*options_.branch)) {
      return *entry;
    }
    for (const auto &entry : untracked()) {
      if (entry.branch != *options_.branch) {
        continue;
      }
      const auto root = git_.root(entry.path);
      adopted_path_ = entry.path;
      adopted_branch_ = entry.branch;
      adopted_base_ = git_.currentBranch(root);
      const auto source = sourceWorkspace(root);
      const auto pane = attributedPane();
      const auto reference = coordinator(pane);
      const auto registered = session_.template exchange<WorktreeRegistered>(RegisterWorktree{.source = source, .created_by = pane, .path = adopted_path_, .branch = adopted_branch_, .base = adopted_base_, .coordinator = reference});
      return {.worktree = registered.worktree, .source = source, .path = adopted_path_, .branch = adopted_branch_, .base = adopted_base_};
    }
    throw Failure{"no tracked worktree matches that branch or title", 2};
  }

  int exec() {
    const auto entry = findOrAdopt();
    const auto opened = launch(entry.worktree, entry.path);
    if (options_.wait) {
      return wait(opened);
    }
    worktreeLaunch(output_, WorktreeLaunch{.worktree = entry.worktree, .path = entry.path, .branch = entry.branch, .base = entry.base, .opened = opened}, options_.json);
    return 0;
  }

  int wait(const PaneOpened &opened) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{options_.timeout};
    constexpr std::uint16_t maximum_rows = 2000;
    constexpr unsigned wait_poll_ms = 250;
    for (;;) {
      const auto reply = session_.template exchange<PaneText>(ReadPane{.pane_id = opened.pane_id, .pane_generation = opened.pane_generation, .rows = maximum_rows, .source = PaneTextSource::recent});
      if (reply.exit_code) {
        auto text = reply.text;
        while (text.ends_with(' ') || text.ends_with('\n')) {
          text.remove_suffix(1);
        }
        if (options_.json) {
          output_.raw("{\"pane_id\":").number(opened.pane_id).raw(",\"exit_code\":").signedNumber(*reply.exit_code).raw(",\"truncated\":").boolean(reply.truncated).raw(",\"output\":").quoted(text).raw("}\n");
        } else {
          output_.raw(text).raw("\n");
          if (reply.truncated) {
            std::fprintf(stderr, "telar worktree: older rows were omitted\n");
          }
        }
        return *reply.exit_code >= 0 && *reply.exit_code <= std::numeric_limits<std::uint8_t>::max() ? *reply.exit_code : 1;
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        std::fprintf(stderr, "telar worktree: the command is still running after %us; pane %llu\n", options_.timeout, static_cast<unsigned long long>(opened.pane_id));
        return 3;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds{wait_poll_ms});
    }
  }

  void list() {
    Channel agents_channel{memory_, options_.socket, false};
    const auto agents = agents_channel.template exchange<AgentSnapshot>(QueryAgents{});
    std::optional<std::uint64_t> source;
    if (options_.workspace) {
      source = maybeUnsigned(*options_.workspace);
      if (!source) {
        const auto entry = workspaceAt(*options_.workspace);
        if (!entry) {
          throw Failure{"workspace not found", 2};
        }
        source = entry->workspace;
      }
    }
    output_.raw(options_.json ? "[" : "BRANCH\tTITLE\tSTATE\tAGENT\tDIFF\tCOMMAND\tPATH\n");
    bool first = true;
    for (const auto &entry : catalog_.worktrees) {
      if (source && entry.source != *source) {
        continue;
      }
      if (options_.json && !first) {
        output_.raw(",");
      }
      worktreeEntry(output_, entry, agents.entries, options_.json);
      first = false;
    }
    for (const auto &entry : untracked()) {
      if (options_.json) {
        if (!first) {
          output_.raw(",");
        }
        output_.raw("{\"worktree_id\":null,\"branch\":").quoted(entry.branch, JsonEscapes::control).raw(",\"path\":").quoted(entry.path, JsonEscapes::control).raw(",\"origin\":\"untracked\",\"agents\":[]}");
      } else {
        output_.raw(entry.branch).raw("\t-\tuntracked\t-\t-\t-\t").raw(entry.path).raw("\n");
      }
      first = false;
    }
    if (options_.json) {
      output_.raw("]\n");
    }
  }

  void open() {
    const auto entry = find(*options_.branch);
    if (!entry) {
      throw Failure{"no tracked worktree matches that branch or title", 2};
    }
    if (!entry->workspace) {
      throw Failure{"nothing was launched in that worktree yet; use `telar worktree exec`", 2};
    }
    const auto clients = session_.template exchange<ClientList>(QueryClients{});
    ClientDescriptor client;
    try {
      client = chooseClient(clients.entries, options_.client);
    } catch (const Failure &) {
      throw Failure{"no UI client is attached; pass --client ID"};
    }
    RequestClientCommand request;
    request.route = {.id = client.id, .generation = client.generation};
    request.action = ClientAction::workspace_select;
    request.target_id = *entry->workspace;
    const auto reply = session_.template exchange<ClientCommandResult>(request);
    if (reply.status == ClientCommandStatus::failed) {
      throw Failure{"the UI client could not open the worktree"};
    }
    if (options_.json) {
      output_.raw("{\"worktree_id\":").number(entry->worktree).raw(",\"workspace_id\":").number(*entry->workspace).raw(",\"client_id\":").number(client.id).raw("}\n");
    } else {
      output_.raw("opened ").raw(entry->branch).raw(" in client ").number(client.id).raw("\n");
    }
  }

  void diff() {
    const auto entry = findOrAdopt();
    const auto against = options_.uncommitted ? std::string{"HEAD"} : git_.line({"git", "-C", entry.path, "merge-base", entry.base.empty() ? "HEAD" : entry.base, "HEAD"});
    std::vector<std::string_view> argv{"git", "-C", entry.path, "--no-pager", "diff"};
    if (options_.stat) {
      argv.push_back("--stat");
    }
    argv.push_back(against);
    git_.run(argv, "GitDiffFailed", true);
  }

  void remove() {
    const auto entry = find(*options_.branch);
    if (!entry) {
      throw Failure{"no tracked worktree matches that branch or title", 2};
    }
    std::optional<std::string> root;
    try {
      root = git_.root(entry->path);
    } catch (const std::exception &) {
    }
    if (root && !options_.force && !git_.run({"git", "-C", entry->path, "status", "--porcelain"}, "GitFailed").empty()) {
      throw Failure{"the worktree has local changes; commit them or pass --force"};
    }
    if (options_.force && !confirmRemoval("Remove the worktree and discard its local changes")) {
      throw Failure{"removal cancelled"};
    }
    const bool merged = options_.delete_branch && root && git_.merged(*root, entry->branch);
    if (options_.delete_branch && !merged && !confirmRemoval("Also delete its branch and the commits no other branch has")) {
      throw Failure{"removal cancelled"};
    }
    session_.template exchange<RequestCompleted>(ForgetWorktree{.worktree = entry->worktree});
    if (root) {
      if (options_.force) {
        git_.run({"git", "-C", *root, "worktree", "remove", "--force", "--", entry->path}, "git worktree remove failed");
      } else {
        git_.run({"git", "-C", *root, "worktree", "remove", "--", entry->path}, "git worktree remove failed");
      }
      if (options_.delete_branch) {
        git_.run({"git", "-C", *root, "branch", merged ? "-d" : "-D", "--", entry->branch}, "git branch deletion failed; the branch may not be merged");
      }
    }
    if (options_.json) {
      output_.raw("{\"worktree_id\":").number(entry->worktree).raw(",\"path\":").quoted(entry->path).raw(",\"branch_deleted\":").boolean(options_.delete_branch).raw("}\n");
    } else {
      output_.raw("removed ").raw(entry->branch).raw(" at ").raw(entry->path).raw("\n");
    }
  }

  std::optional<std::string> matchingRepository(std::string_view path) {
    try {
      auto root = git_.root(path);
      const auto identity = repositoryIdentity(git_.line({"git", "-C", root, "config", "--get", "remote.origin.url"}));
      if (identity && *identity == *options_.repository) {
        return root;
      }
    } catch (const std::exception &) {
    }
    return std::nullopt;
  }

  void resolve() {
    std::optional<std::string> found;
    if (options_.workspace) {
      auto path = *options_.workspace;
      if (const auto id = maybeUnsigned(path)) {
        const auto entry = workspace(*id);
        if (!entry) {
          throw Failure{"workspace not found", 2};
        }
        path = entry->path;
      }
      found = matchingRepository(path);
      if (!found) {
        throw Failure{"that workspace holds another repository"};
      }
    } else {
      const auto consider = [&](std::string_view path) {
        const auto candidate = matchingRepository(path);
        if (!candidate) {
          return;
        }
        if (found && *found != *candidate) {
          throw Failure{"several clones of this repository are open on the machine; pass --workspace PATH"};
        }
        found = candidate;
      };
      for (const auto &entry : catalog_.entries) {
        consider(entry.path);
      }
      for (const auto &entry : catalog_.worktrees) {
        consider(entry.path);
      }
      historyPaths(memory_, session_.socket(), consider);
      const auto data_home = ::getenv("XDG_DATA_HOME"), home = ::getenv("HOME");
      if (!data_home && !home) {
        throw Failure{"HomeDirectoryUnavailable"};
      }
      const auto base = data_home ? std::string{data_home} : std::string{home} + "/.local/share";
      if (!base.starts_with('/')) {
        throw Failure{"InvalidDataDirectory"};
      }
      std::array<unsigned char, SHA256_DIGEST_LENGTH> digest;
      SHA256(reinterpret_cast<const unsigned char *>(options_.repository->data()), options_.repository->size(), digest.data());
      constexpr std::string_view hex = "0123456789abcdef";
      std::string suffix;
      for (const auto byte : digest) {
        suffix += hex[byte >> 4];
        suffix += hex[byte & 15];
      }
      consider(base + "/telar/repositories/" + suffix);
    }
    if (!found) {
      throw Failure{"no workspace on the machine holds this repository; open one there or pass --workspace PATH"};
    }
    if (options_.json) {
      output_.raw("{\"repository\":").quoted(*options_.repository).raw(",\"path\":").quoted(*found).raw("}\n");
    } else {
      output_.raw(*found).raw("\n");
    }
  }

  Memory &memory_;
  const WorktreeOptions &options_;
  Channel<Memory> catalog_channel_;
  WorkspaceList catalog_;
  Channel<Memory> session_;
  WorktreeGit<Memory> git_;
  Output<Memory> output_;
  std::uint64_t verified_generation_ = 0;
  std::string adopted_path_, adopted_branch_, adopted_base_;
};

template <Allocator Memory>
int worktree(Memory &memory, const WorktreeOptions &options) {
  try {
    if (options.machine) {
      throw Failure{"cross-machine worktrees require the machine and repository CLI ports"};
    }
    return WorktreeCommand{memory, options}.run();
  } catch (const Failure &error) {
    const std::string_view message = error.what();
    std::fprintf(stderr, "telar worktree: %s\n", message == "NotARepository" ? "not inside a git repository" : error.what());
    return error.status() == 2 || error.code() == FailureCode::worktree_not_found || error.code() == FailureCode::workspace_not_found ? 2 : 1;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar worktree: %s\n", error.what());
    return 1;
  }
}

}
