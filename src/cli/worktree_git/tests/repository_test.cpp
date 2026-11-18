#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.cli.worktree_git;
import telar.base.memory.allocators;

namespace {

  using telar::testing::check;

  using namespace telar::runtime::cli;

  // The result of a repository function, or the name of the error it threw.
  template <typename Call>
  std::string outcome(Call call) {
    try {
      return call();
    } catch (const std::runtime_error& error) {
      return error.what();
    }
  }

  std::string normalized(std::string_view url) {
    telar::SystemAllocator system;
    telar::MemoryAdapter adapter{system};

    return outcome([&] {
      return std::string{repository::normalize(adapter, url).view()};
    });
  }

  std::string sanitized(std::string_view origin) {
    telar::SystemAllocator system;
    telar::MemoryAdapter adapter{system};

    return outcome([&] {
      return std::string{repository::sanitized(adapter, origin).view()};
    });
  }

  // One repository has one identity whichever transport, user, default port or case
  // its origin is spelled with: the identity names its clone on every machine.
  void normalizeEquivalentOrigins() {
    check(normalized("git@Host.com:team/repo.git") == "host.com/team/repo");
    check(normalized("ssh://git@host.com:22/team/repo/") == "host.com/team/repo");
    check(normalized("https://u:t@HOST.com:443/team/repo.git") == "host.com/team/repo");
    check(normalized("http://host.com:80/team/repo") == "host.com/team/repo");

    // A port other than the scheme's default names another server.
    check(normalized("ssh://h:2222/r") == "h:2222/r");
    check(normalized("https://h:22/r") == "h:22/r");

    check(normalized("ssh://[::1]:22/x") == "::1/x");
    check(normalized("ssh://[::1]/x") == "::1/x");
  }

  // The origin handed to another machine keeps its transport and drops any secret.
  void sanitizedStripsCredentials() {
    check(sanitized("https://user:tok@host/t/r.git") == "https://host/t/r.git");
    check(sanitized("ssh://user:pw@h/r") == "ssh://h/r");
    check(sanitized("ssh://git@h/r") == "ssh://git@h/r");
    check(sanitized("git@h:t/r.git") == "git@h:t/r.git");

    check(sanitized("https://h/r?x") == "UnsupportedOrigin");
    check(sanitized("https://h/r#f") == "UnsupportedOrigin");
    check(sanitized("https://h/r x") == "UnsupportedOrigin");
  }

  // An origin with no host and path another machine can clone from has no identity: dispatch
  // says why instead of looking for a clone that cannot exist there.
  void normalizeRejectsNonRemoteOrigins() {
    for (const auto origin : {"file:///srv/r.git", "file://host/srv/r.git", "/srv/r", "https://host", "ssh://[::1/x"}) {
      check(normalized(origin) == "UnsupportedOrigin", origin);
    }

    check(normalized("host:" + std::string(2048, 'p')) == "OriginTooLong");
  }

  const telar::testing::Case case_normalize_equivalent_origins{"repository.normalize_equivalent_origins", normalizeEquivalentOrigins};
  const telar::testing::Case case_sanitized_strips_credentials{"repository.sanitized_strips_credentials", sanitizedStripsCredentials};
  const telar::testing::Case case_normalize_rejects_non_remote_origins{"repository.normalize_rejects_non_remote_origins", normalizeRejectsNonRemoteOrigins};

}
