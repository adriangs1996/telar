#pragma once

#include "command_limit.hpp"
#include "repository_identity.hpp"
#include "telar_platform/command_output.hpp"
#include "telar_platform/git_observation_policy.hpp"

namespace telar::runtime::cli::repository {

inline constexpr std::size_t max_git_output = 8 * 1024 * 1024;
inline constexpr std::size_t max_bundle_bytes = 256 * 1024 * 1024;
inline constexpr std::chrono::seconds git_timeout{600};

template <Allocator Memory>
class Git {
public:
  Git(Memory &memory, std::string_view root)
      : memory_(memory),
        root_(root) {
    auto [status, listing] = execute({"config", "--show-scope", "-z", "--get-regexp", "^(filter\\.|extensions\\.partialclone$|remote\\..*\\.(promisor|partialclonefilter|uploadpack)$)"}, false);
    const auto facts = GitRepositoryFacts::parse(listing);
    if (status > 1 || !facts) {
      throw std::runtime_error{"GitFailed"};
    }

    for (std::size_t index = 0; index < facts->driver_count; ++index) {
      for (const auto suffix : {".clean=", ".smudge=", ".process="}) {
        overrides_.push_back("filter." + std::string{facts->drivers[index]} + suffix);
      }
    }

    if (facts->may_fetch) {
      const auto version = read({"version"});
      constexpr std::string_view prefix = "git version ";
      unsigned major = 0;
      unsigned minor = 0;
      if (!version.starts_with(prefix) || std::sscanf(version.c_str() + prefix.size(), "%u.%u", &major, &minor) != 2 || major < 2 || (major == 2 && minor < 45)) {
        throw std::runtime_error{"GitFailed"};
      }
    }
  }

  std::string read(std::initializer_list<std::string_view> arguments) {
    auto [status, output] = execute(arguments, true);
    if (status != 0) {
      throw std::runtime_error{"GitFailed"};
    }

    return std::string{trim(output, " \r\n")};
  }

  void bundle(std::string_view ref, int descriptor) {
    const std::array args{std::string_view{"bundle"}, std::string_view{"create"}, std::string_view{"-"}, ref};
    auto command = makeCommand(args);
    configure(command);
    CommandOutput output{memory_, max_git_output};
    std::size_t total = 0;
    const auto status = output.stream(command, std::chrono::steady_clock::now() + git_timeout, [&](std::span<const Byte> bytes) {
      total += bytes.size();
      if (total > max_bundle_bytes) {
        reportCommandLimit({.name = "repository.max_bundle_bytes", .noun = "bytes", .value = max_bundle_bytes, .requested = total});
        throw std::runtime_error{"RepositoryBundleLimit"};
      }

      writeBytes(descriptor, bytes);
      return true;
    });
    if (status != 0) {
      throw std::runtime_error{"GitFailed"};
    }
  }

private:
  Command<Memory> makeCommand(std::span<const std::string_view> arguments) {
    std::vector<std::string_view> complete(git_observation_options.begin(), git_observation_options.end());
    for (const auto &value : overrides_) {
      complete.push_back("-c");
      complete.push_back(value);
    }

    complete.insert(complete.end(), arguments.begin(), arguments.end());
    return Command<Memory>{memory_, Launch{.cwd = root_, .arguments = complete}, CommandPurpose::administration};
  }

  std::pair<int, std::string> execute(std::initializer_list<std::string_view> arguments, bool bounded) {
    auto command = makeCommand(std::span{arguments.begin(), arguments.size()});
    configure(command);
    constexpr std::size_t max_configuration_bytes = 64 * 1024;
    CommandOutput output{memory_, bounded ? max_git_output : max_configuration_bytes};
    const auto status = output.run(command, std::chrono::steady_clock::now() + git_timeout, true);
    if (output.truncated()) {
      if (bounded) {
        reportCommandLimit({.name = "repository.max_git_output_bytes", .noun = "bytes", .value = max_git_output});
      }

      throw std::runtime_error{bounded ? "RepositoryGitOutputLimit" : "GitFailed"};
    }

    return {status, std::string{output.text()}};
  }

  static void configure(Command<Memory> &command) {
    command.removeEnvironmentPrefix("GIT_");
    command.setEnvironment("GIT_OPTIONAL_LOCKS", "0");
    command.setEnvironment("GIT_NO_LAZY_FETCH", "1");
    command.setEnvironment("GIT_TERMINAL_PROMPT", "0");
    command.setEnvironment("LC_ALL", "C");
  }

  Memory &memory_;
  std::string root_;
  std::vector<std::string> overrides_;
};

template <Allocator Memory>
void ready(Git<Memory> &git, std::string_view commit) {
  if (git.read({"rev-parse", "--is-shallow-repository"}) != "false") {
    throw std::runtime_error{"ShallowRepositoryUnsupported"};
  }

  const auto config = git.read({"config", "--local", "--name-only", "--list"});
  if (config.contains("extensions.partialclone") || config.contains(".promisor")) {
    throw std::runtime_error{"PartialRepositoryUnsupported"};
  }

  const auto tree = git.read({"ls-tree", "-rz", commit});
  std::string_view remaining = tree;
  while (!remaining.empty()) {
    const auto end = remaining.find('\0');
    const auto line = remaining.substr(0, end);
    if (line.starts_with("160000 ")) {
      throw std::runtime_error{"SubmoduleRepositoryUnsupported"};
    }

    const auto tab = line.find('\t');
    if (tab != line.npos) {
      const auto name = line.substr(tab + 1);
      if (name == ".gitattributes" || name.ends_with("/.gitattributes")) {
        const auto space = line.rfind(' ', tab);
        if (space == line.npos) {
          throw std::runtime_error{"InvalidGitTree"};
        }

        const auto attributes = git.read({"cat-file", "blob", line.substr(space + 1, tab - space - 1)});
        if (attributes.contains("filter=lfs") || attributes.contains("filter = lfs")) {
          throw std::runtime_error{"LfsRepositoryUnsupported"};
        }
      }
    }

    if (end == remaining.npos) {
      break;
    }

    remaining.remove_prefix(end + 1);
  }

  git.read({"fsck", "--connectivity-only", "--no-reflogs", commit});
}

}
