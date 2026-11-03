#pragma once

#include "machine_ssh.hpp"
#include "repository_prepare.hpp"
#include "session_channel.hpp"
#include "telar_base/text/json_node.hpp"
#include "worktree_git.hpp"
#include "worktree_options.hpp"
#include <filesystem>

// Worktrees on another machine, from the machine that dispatches them, as
// Zig's `worktree_dispatch.zig`: `create --machine` finds the project's clone
// there, pushes the commit the branch starts from and asks that machine's
// telar to create the worktree; `fetch --machine` brings the branch back into
// a remote-tracking ref. All Git traffic starts here over telar's managed SSH
// connection, so no machine ever needs SSH back to this one.
namespace telar::runtime::cli::sessions {

enum class GitDirection : std::uint8_t {
  push,
  fetch
};

// Zig's `describe` for the errors only dispatch raises.
inline std::string_view describeDispatchError(std::string_view name) {
  static constexpr std::array<std::pair<std::string_view, std::string_view>, 12> descriptions{{
      {"UnknownMachine", "no saved machine or local label has that name; see `telar machine list`"},
      {"FetchNeedsAnotherMachine", "fetch brings a branch from another machine; this label names this one"},
      {"NoOriginRemote", "the repository has no `origin` remote to find its clone by on the other machine"},
      {"UnsupportedOrigin", "the `origin` remote is a local path, which names no clone on another machine"},
      {"UnexpectedResolveOutput", "the machine answered `worktree resolve` with something else; is its telar up to date?"},
      {"MachineCommandFailed", "the command failed on the machine"},
      {"UnknownRevision", "that revision names no commit here"},
      {"GitPushFailed", "git push to the machine failed; a branch with other history there is never overwritten"},
      {"GitFetchFailed", "git fetch from the machine failed"},
      {"DestinationNotUsableByGit", "the machine's SSH destination has ':', '/' or brackets; save it as a host alias"},
      {"UnquotableSshOption", "telar's runtime directory has a quote in its path, which git cannot be given safely"},
      {"NotARepository", "not inside a git repository"},
  }};
  const auto found = std::ranges::find(descriptions, name, &std::pair<std::string_view, std::string_view>::first);
  return found == descriptions.end() ? name : found->second;
}

template <Allocator Memory>
class WorktreeDispatch {
public:
  WorktreeDispatch(Memory &memory, const WorktreeOptions &options, const machines::MachineProfile &profile)
      : memory_(memory),
        options_(options),
        profile_(profile),
        git_(memory),
        root_(git_.root(std::filesystem::canonical(".").string())) {}

  int create() {
    const auto branch = *options_.branch;
    const bool continued = git_.succeeds({"git", "-C", root_, "rev-parse", "--verify", "--quiet", "refs/heads/" + std::string{branch}});
    const auto source = continued ? branch : options_.from.value_or("HEAD");
    const auto commit = commitOf(source);
    const RepositoryOptions prepare_options{
        .action = RepositoryOptions::Action::prepare,
        .from = commit,
        .workspace = options_.workspace,
    };
    const auto clone = repository::prepare(memory_, prepare_options, profile_).path;
    transfer(clone, commit + ":refs/heads/" + std::string{branch}, GitDirection::push);
    const auto profiles = machine::load(memory_, machine::profilesPath());
    const auto local = machine::localLabel(profiles).substr(0, machines::MachineLimits::label_bytes);
    const auto coordinator = options_.coordinator ? options_.coordinator : sourceCoordinator();
    std::vector<std::string> words{"worktree", "create", std::string{branch}, "--workspace", clone, "--dispatched-from", std::string{local}};
    const auto optional = [&](std::string_view flag, std::optional<std::string> value) {
      if (value) {
        words.emplace_back(flag);
        words.push_back(std::move(*value));
      }
    };
    optional("--title", options_.title ? std::optional<std::string>{*options_.title} : std::nullopt);
    optional("--label", options_.label ? std::optional<std::string>{*options_.label} : std::nullopt);
    optional("--coordinator", coordinator ? std::optional{formatCoordinator(*coordinator)} : std::nullopt);
    optional("--from", continued ? std::nullopt : std::optional{commit});
    if (options_.setup) {
      words.emplace_back("--setup");
    }

    if (options_.json) {
      words.emplace_back("--json");
    }

    if (!options_.command.empty()) {
      words.emplace_back("--");
      words.insert(words.end(), options_.command.begin(), options_.command.end());
    }

    return machine::forward(memory_, profile_, words);
  }

  int fetch() {
    const auto branch = *options_.branch;
    const auto label = *options_.machine;
    const auto clone = findClone();
    const auto ref = std::format("refs/remotes/{}/{}", label, branch);
    transfer(clone, std::format("+refs/heads/{}:{}", branch, ref), GitDirection::fetch);
    const auto commit = commitOf(ref);
    Output output{memory_};
    if (options_.json) {
      output.text("{\"machine\":").json(label).text(",\"branch\":").json(branch).text(",\"ref\":").json(ref).text(",\"commit\":").json(commit).text("}\n");
    } else {
      output.text(std::format("fetched {} from {} into {} at {}\n", branch, label, ref, commit));
    }

    output.flush();
    return 0;
  }

private:
  std::string commitOf(std::string_view revision) {
    try {
      return git_.line({"git", "-C", root_, "rev-parse", "--verify", "--quiet", "--end-of-options", std::string{revision} + "^{commit}"});
    } catch (const std::exception &) {
      throw Failure{"UnknownRevision"};
    }
  }

  std::string originIdentity() {
    std::string url;
    try {
      url = git_.line({"git", "-C", root_, "config", "--get", "remote.origin.url"});
    } catch (const std::exception &) {
      throw Failure{"NoOriginRemote"};
    }

    return repository::normalize(url);
  }

  // Asks the other machine which of its workspaces holds this repository.
  std::string findClone() {
    const std::vector<std::string> words{"worktree", "resolve", "--repository", originIdentity(), "--json"};
    const auto output = machine::capture(memory_, profile_, words, "MachineCommandFailed");
    try {
      const auto resolved = JsonNode<Memory>::parse(memory_, output);
      const auto *path = resolved.find("path");
      if (path != nullptr && path->kind() == JsonKind::string && path->text().starts_with('/')) {
        return std::string{path->text()};
      }
    } catch (const std::exception &) {
    }

    throw Failure{"UnexpectedResolveOutput"};
  }

  // One push or fetch against the other machine's clone, through the control
  // master the dispatch uses. A push never forces.
  void transfer(std::string_view clone, std::string_view refspec, GitDirection direction) {
    const auto destination = profile_.destination();
    if (destination.find_first_of(":/[]") != std::string_view::npos) {
      throw Failure{"DestinationNotUsableByGit"};
    }

    const auto url = std::format("ssh://{}{}", destination, clone);
    const auto ssh = machine::gitSshCommand(memory_, destination);
    const std::array<std::pair<std::string_view, std::string_view>, 2> environment{{{"GIT_SSH_COMMAND", ssh}, {"GIT_TERMINAL_PROMPT", "0"}}};
    if (direction == GitDirection::push) {
      const std::array<std::string_view, 8> argv{"git", "-C", root_, "push", "--quiet", "--", url, refspec};
      git_.run(argv, "GitPushFailed", true, false, environment);
    } else {
      const std::array<std::string_view, 9> argv{"git", "-C", root_, "fetch", "--quiet", "--no-tags", "--", url, refspec};
      git_.run(argv, "GitFetchFailed", true, false, environment);
    }
  }

  // The agent session of the pane this command runs in, when the runtime
  // confirms the process descends from it.
  std::optional<CoordinatorReference> sourceCoordinator() {
    const auto id = maybeUnsigned(ProcessEnvironment{}.lookup("TELAR_PANE_ID"));
    const auto generation = maybeUnsigned(ProcessEnvironment{}.lookup("TELAR_PANE_GENERATION"));
    if (!id || !generation || *id == 0 || *generation == 0) {
      return std::nullopt;
    }

    try {
      Channel<Memory> session{memory_, std::nullopt, false};
      session.template exchange<RequestCompleted>(VerifyPaneDescent{.pane_id = *id, .pane_generation = *generation});
      const auto agents = session.template exchange<AgentSnapshot>(QueryAgents{});
      for (const auto &entry : agents.entries) {
        if (entry.pane_id == *id && entry.pane_generation == *generation && std::ranges::any_of(entry.session_id, [](Byte byte) { return byte != 0; })) {
          return CoordinatorReference{.session_id = entry.session_id, .pane_id = *id, .pane_generation = *generation};
        }
      }
    } catch (const std::exception &) {
    }

    return std::nullopt;
  }

  static std::string formatCoordinator(const CoordinatorReference &reference) {
    std::string text;
    for (const auto byte : reference.session_id) {
      text += std::format("{:02x}", static_cast<unsigned>(byte));
    }

    return std::format("{}:{}:{}", text, reference.pane_id, reference.pane_generation);
  }

  Memory &memory_;
  const WorktreeOptions &options_;
  const machines::MachineProfile &profile_;
  WorktreeGit<Memory> git_;
  std::string root_;
};

}
