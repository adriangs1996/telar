#pragma once

#include "session_channel.hpp"
#include "telar_base/memory/retained_stream.hpp"
#include "telar_platform/command_output.hpp"
#include <vector>

namespace telar::runtime::cli::sessions {

struct GitWorktree {
  std::string path, branch;
};

template <Allocator Memory>
class WorktreeGit {
public:
  explicit WorktreeGit(Memory &memory)
      : memory_(memory) {}

  // Mutations retain only the tail of diagnostics; diff streams both byte
  // streams. Every invocation uses literal argv and a bounded deadline.
  std::string run(std::span<const std::string_view> arguments, const char *failure = "NotARepository", bool stream = false, bool hardened = false) {
    Command command{memory_, Launch{.arguments = arguments}, CommandPurpose::configured_helper};
    if (hardened) {
      command.removeEnvironmentPrefix("GIT_");
      command.setEnvironment("GIT_OPTIONAL_LOCKS", "0");
      command.setEnvironment("GIT_NO_LAZY_FETCH", "1");
      command.setEnvironment("GIT_TERMINAL_PROMPT", "0");
    }
    constexpr std::size_t diagnostic_bytes = 64 * 1024;
    constexpr std::size_t listing_bytes = 1024 * 1024;
    constexpr unsigned git_timeout_seconds = 300;
    RetainedStream diagnostics{memory_, diagnostic_bytes};
    CommandOutput output{memory_, listing_bytes};
    std::string kept;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{git_timeout_seconds};
    const auto status = output.streamDiagnostics(command, deadline, [&](std::span<const Byte> bytes) {
      if (stream) { std::fwrite(bytes.data(), 1, bytes.size(), stdout); }
      else {
        if (bytes.size() > listing_bytes - kept.size()) { throw Failure{"StreamTooLong"}; }
        kept.append(reinterpret_cast<const char *>(bytes.data()), bytes.size());
      }
      return true; }, [&](std::span<const Byte> bytes) {
      if (stream) { std::fwrite(bytes.data(), 1, bytes.size(), stderr); }
      else { diagnostics.append(bytes); } });

    if (status != 0) {
      if (std::string_view{failure} != "NotARepository" && !stream) {
        std::array<Byte, diagnostic_bytes> bytes;
        const auto tail = diagnostics.read(diagnostics.retainedOffset(), bytes);
        if (diagnostics.retainedOffset() != 0) {
          std::fprintf(stderr, "(%llu earlier bytes of Git's output omitted)\n", static_cast<unsigned long long>(diagnostics.retainedOffset()));
        }
        std::fwrite(tail.data(), 1, tail.size(), stderr);
      }
      throw Failure{failure};
    }

    return kept;
  }

  std::string run(std::initializer_list<std::string_view> arguments, const char *failure = "NotARepository", bool stream = false, bool hardened = false) {
    return run(std::span{arguments.begin(), arguments.size()}, failure, stream, hardened);
  }

  std::string line(std::initializer_list<std::string_view> arguments, bool hardened = false) {
    auto value = run(arguments, "NotARepository", false, hardened);
    const auto start = value.find_first_not_of(" \r\n"), end = value.find_last_not_of(" \r\n");
    if (start == std::string::npos) {
      throw Failure{"NotARepository"};
    }
    return value.substr(start, end - start + 1);
  }

  std::string root(std::string_view directory) {
    auto common = line({"git", "-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"});
    while (common.ends_with('/')) {
      common.pop_back();
    }
    constexpr std::string_view suffix = "/.git";
    if (!common.starts_with('/') || !common.ends_with(suffix) || common.size() <= suffix.size()) {
      throw Failure{"not inside a git repository"};
    }
    common.resize(common.size() - suffix.size());
    return common;
  }

  std::string currentBranch(std::string_view directory) {
    return line({"git", "-C", directory, "rev-parse", "--abbrev-ref", "HEAD"});
  }

  bool succeeds(std::initializer_list<std::string_view> arguments, bool hardened = false) {
    try {
      run(arguments, "NotARepository", false, hardened);
      return true;
    } catch (const std::exception &) {
      return false;
    }
  }

  void add(std::string_view root, std::string_view directory, std::string_view branch, std::string_view base) {
    const auto reference = "refs/heads/" + std::string{branch};
    if (succeeds({"git", "-C", root, "rev-parse", "--verify", "--quiet", reference})) {
      run({"git", "-C", root, "worktree", "add", "--", directory, branch}, "git worktree add failed");
    } else {
      run({"git", "-C", root, "worktree", "add", "-b", branch, "--", directory, base}, "git worktree add failed");
    }
  }

  template <typename Keep>
  std::vector<GitWorktree> listed(std::string_view directory, Keep &&keep) {
    const auto main = root(directory);
    const auto bytes = run({"git", "-C", main, "worktree", "list", "--porcelain"});
    std::vector<GitWorktree> result;
    std::string_view path, branch;
    constexpr std::size_t maximum_untracked = 256;
    bool first = true;
    std::string_view remaining = bytes;
    while (!remaining.empty()) {
      const auto end = remaining.find('\n');
      const auto line = remaining.substr(0, end);
      remaining.remove_prefix(end == std::string_view::npos ? remaining.size() : end + 1);
      if (line.starts_with("worktree ")) {
        path = line.substr(std::string_view{"worktree "}.size());
      } else if (line.starts_with("branch refs/heads/")) {
        branch = line.substr(std::string_view{"branch refs/heads/"}.size());
      } else if (line.empty()) {
        if (!first && !path.empty() && !branch.empty() && keep(path) && result.size() < maximum_untracked) {
          result.push_back(GitWorktree{.path = std::string{path}, .branch = std::string{branch}});
        }
        first = false;
        path = {};
        branch = {};
      }
    }

    return result;
  }

  bool merged(std::string_view root, std::string_view branch) {
    const auto upstream = std::string{branch} + "@{upstream}";
    const auto reference = "refs/heads/" + std::string{branch};
    // Avoid invoking repository configured helpers while deciding whether a
    // branch may be deleted without a person's confirmation.
    std::string against = "HEAD";
    try {
      against = line({"git", "--no-pager", "--no-lazy-fetch", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", root, "rev-parse", "--verify", "--quiet", "--end-of-options", upstream}, true);
    } catch (const std::exception &) {
    }
    return succeeds({"git", "--no-pager", "--no-lazy-fetch", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", root, "merge-base", "--is-ancestor", reference, against}, true);
  }

private:
  Memory &memory_;
};

inline std::optional<std::string> repositoryIdentity(std::string_view url) {
  const auto begin = url.find_first_not_of(" \t\r\n"), end = url.find_last_not_of(" \t\r\n");
  if (begin == std::string_view::npos) {
    return std::nullopt;
  }
  url = url.substr(begin, end - begin + 1);
  std::string_view scheme = "ssh", authority, path;
  const auto separator = url.find("://");
  if (separator != std::string_view::npos) {
    scheme = url.substr(0, separator);
    if (scheme == "file" || scheme == "FILE") {
      return std::nullopt;
    }
    url.remove_prefix(separator + std::string_view{"://"}.size());
    const auto slash = url.find('/');
    if (slash == std::string_view::npos) {
      return std::nullopt;
    }
    authority = url.substr(0, slash);
    path = url.substr(slash);
  } else {
    const auto colon = url.find(':');
    if (colon == std::string_view::npos || url.substr(0, colon).contains('/')) {
      return std::nullopt;
    }
    authority = url.substr(0, colon);
    path = url.substr(colon + 1);
  }

  if (const auto at = authority.rfind('@'); at != std::string_view::npos) {
    authority.remove_prefix(at + 1);
  }
  while (path.starts_with('/')) {
    path.remove_prefix(1);
  }
  while (path.ends_with('/')) {
    path.remove_suffix(1);
  }
  if (path.ends_with(".git")) {
    path.remove_suffix(std::string_view{".git"}.size());
  }
  while (path.ends_with('/')) {
    path.remove_suffix(1);
  }
  const auto port = authority.starts_with('[') ? authority.find(':', authority.find(']')) : authority.find(':');
  if (port != std::string_view::npos) {
    const auto number = authority.substr(port + 1);
    if ((scheme == "ssh" && number == "22") || (scheme == "https" && number == "443") || (scheme == "http" && number == "80")) {
      authority = authority.substr(0, port);
    }
  }
  if (authority.starts_with('[') && authority.ends_with(']')) {
    authority = authority.substr(1, authority.size() - 2);
  }
  if (authority.empty() || path.empty()) {
    return std::nullopt;
  }
  std::string identity{authority};
  for (auto &byte : identity) {
    if (byte >= 'A' && byte <= 'Z') {
      byte += 'a' - 'A';
    }
  }
  identity += '/';
  identity += path;
  return identity;
}

}
