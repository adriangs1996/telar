export module telar.runtime.files.entry;

import std;
import telar.sys.posix;
import telar.wire.files;

export namespace telar::runtime {

  // What tells the file `status` describes from another that takes its name later.
  [[nodiscard]] FileIdentity identityOf(const struct stat& status) noexcept;

  // What `mode` says an entry is, without following a link.
  [[nodiscard]] FileKind kindOf(mode_t mode) noexcept;

  // Whether `path` still names the file `identity` does; an identity of zeros names any.
  [[nodiscard]] bool names(const struct stat& status, const FileIdentity& identity) noexcept;

  // What starts the name a file that arrives from another machine has until it is whole: hidden,
  // and no name a listing shows.
  inline constexpr std::string_view arriving_prefix = ".telar-partial-";

  // Whether `name` is one a file that arrives has until it is whole.
  [[nodiscard]] bool arriving(std::string_view name) noexcept;

  // The home of the runtime's account, as its environment names it; empty when it names none.
  [[nodiscard]] std::string_view accountHome() noexcept;

}
