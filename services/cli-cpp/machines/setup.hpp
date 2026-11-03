#pragma once

#include "../config_receive.hpp"
#include "../machine_store.hpp"
#include "agents.hpp"
#include "config_sync.hpp"
#include "help_texts.hpp"
#include "logins.hpp"
#include "machine_assets.hpp"
#include "platform.hpp"
#include "remote_shell.hpp"
#include "setup_report.hpp"
#include "telar_platform/sha256.hpp"
#include <fstream>

namespace telar::runtime::cli::machine {

struct Target {
  std::string label;
  std::string destination;
  std::optional<MachineProfile> saved;
};

inline Target resolve(const MachineProfiles &profiles, const MachineOptions &options) {
  for (const auto &profile : profiles.rows()) {
    if (profile.label() == options.label || profile.destination() == options.label) {
      return {.label = std::string{profile.label()}, .destination = std::string{profile.destination()}, .saved = profile};
    }
  }

  MachineFieldRules::profileDestination(options.label);
  auto host = options.label;
  if (host.starts_with("ssh://")) {
    host.remove_prefix(std::string_view{"ssh://"}.size());
  }

  if (const auto at = host.rfind('@'); at != std::string_view::npos) {
    host.remove_prefix(at + 1);
  }

  while (host.starts_with('[')) {
    host.remove_prefix(1);
  }

  host = host.substr(0, host.find_first_of(":]/"));
  std::string label{host.substr(0, MachineLimits::label_bytes)};
  for (auto &byte : label) {
    if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '-')) {
      byte = '-';
    }
  }

  if (options.new_label) {
    label = *options.new_label;
  }

  try {
    MachineFieldRules::label(label);
  } catch (const MachineFailure &) {
    if (!options.new_label) {
      throw CommandError{"MachineLabelNeeded"};
    }

    throw;
  }

  MachineOptions trial{.action = MachineOptions::Action::add, .label = label, .value = options.label};
  auto copy = profiles;
  change(copy, trial);
  return {.label = label, .destination = std::string{options.label}};
}

inline std::string fileDigest(const std::string &path) {
  FileDescriptor file{::open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC)};
  struct stat state{};
  if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode)) {
    throw CommandError{"SetupBinaryUnreadable"};
  }

  Sha256 digest;
  std::array<std::uint8_t, 64 * 1024> buffer;
  for (;;) {
    const auto count = ::read(file.get(), buffer.data(), buffer.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count < 0) {
      throw CommandError{"SetupBinaryUnreadable"};
    }

    if (count == 0) {
      break;
    }

    digest.update({reinterpret_cast<const char *>(buffer.data()), static_cast<std::size_t>(count)});
  }

  const auto bytes = digest.finish();
  constexpr std::string_view hexadecimal = "0123456789abcdef";
  std::string text;
  for (const auto byte : bytes) {
    text += hexadecimal[byte >> 4];
    text += hexadecimal[byte & 15];
  }

  return text;
}

template <Allocator Memory>
std::optional<Platform> reach(Memory &memory, SetupReport &report, const Target &target, const std::string &directory) {
  launch::Output probe;
  bool confirmed = false;
  const auto run = [&] { return runScript(memory, target.destination, assign("dir", directory) + std::string{assets::probe}); };
  try {
    probe = run();
    const auto failure = sshFailure(probe);
    if (probe.status != 0 && !report.json && ::isatty(STDIN_FILENO) && (failure == MachineError::host_key_rejected || failure == MachineError::authentication_failed)) {
      std::printf("Batch-mode SSH to %s was refused. Connecting once with your terminal: OpenSSH asks, you answer; telar accepts nothing for you.\n", target.destination.c_str());
      std::fflush(stdout);
      confirmed = launch::inherit({"ssh", "-o", "ControlPath=none", "-o", "ForwardAgent=no", "--", target.destination, "true"}) == 0;
      if (confirmed) {
        probe = run();
      }
    }
  } catch (const std::exception &error) {
    report.end(Step::ssh, Status::failed, std::string{"ssh did not run to the end: "} + error.what());
    return std::nullopt;
  }

  if (probe.status != 0) {
    const auto failure = sshFailure(probe);
    if (probe.status != launch::ssh_failure && failure != MachineError::remote_runtime_incompatible) {
      report.end(Step::ssh, Status::ok, "batch-mode SSH to " + target.destination + " works");
      report.end(Step::platform, Status::failed, "the probe failed there: " + std::string{probe.errorLine()});
    } else if (failure == MachineError::authentication_failed) {
      report.end(Step::ssh, Status::failed, target.destination + (confirmed ? " accepts your login only interactively; windows need a key. Run `ssh-copy-id " + target.destination + "`, then setup again" : " refused the login in batch mode; add a key with `ssh-copy-id " + target.destination + "` or run setup from a terminal"));
    } else if (failure == MachineError::host_key_rejected) {
      report.end(Step::ssh, Status::failed, "the host key of " + target.destination + " is not confirmed: " + std::string{probe.errorLine()});
    } else {
      report.end(Step::ssh, Status::failed, std::string{probe.errorLine()});
    }

    return std::nullopt;
  }

  report.end(Step::ssh, confirmed ? Status::changed : Status::ok, "batch-mode SSH to " + target.destination + " works");
  try {
    const auto platform = Platform::parse(whole(probe));
    report.end(Step::platform, Status::ok, std::string{platform.os == "linux" ? "Linux " : "macOS "} + platform.arch + (platform.libc == "musl" ? " (musl)" : "") + ", " + platform.assetName());
    return platform;
  } catch (const std::exception &error) {
    report.end(Step::platform, Status::failed, std::string{error.what()} + ": " + probe.out.substr(0, probe.out.find('\n')));
    return std::nullopt;
  }
}

struct Install {
  std::optional<std::string> binary;
  std::optional<std::string> digest;
  std::string directory;
};

inline std::string releasesUrl() {
  const auto *configured = std::getenv("TELAR_RELEASES_URL");
  return configured && *configured ? configured : "https://github.com/adriangs1996/telar/releases";
}

inline std::string releaseDigest(const std::string &asset) {
  const auto url = releasesUrl() + "/download/v" + std::string{version} + "/SHA256SUMS";
  constexpr std::size_t max_url_bytes = 2048;
  if (url.size() >= max_url_bytes) {
    throw CommandError{"ReleaseUrlTooLong"};
  }

  launch::Output output;
  try {
    output = launch::capture({"curl", "--proto", "=https,file", "--tlsv1.2", "-fsSL", "--", url}, -1, probe_timeout);
  } catch (const std::exception &) {
    throw CommandError{"ReleaseUnavailable"};
  }

  constexpr std::size_t max_sums_bytes = 64 * 1024;
  if (output.status != 0 || output.dropped != 0 || output.out.size() > max_sums_bytes) {
    throw CommandError{"ReleaseUnavailable"};
  }

  std::istringstream lines{output.out};
  std::string line;
  while (std::getline(lines, line)) {
    std::istringstream words{line};
    std::string digest;
    std::string name;
    if (!(words >> digest >> name)) {
      continue;
    }

    if (name.starts_with('*')) {
      name.erase(0, 1);
    }

    if (name != asset) {
      continue;
    }

    constexpr std::size_t digest_hex_bytes = SHA256_DIGEST_LENGTH * 2;
    if (digest.size() != digest_hex_bytes || !std::ranges::all_of(digest, [](unsigned char byte) { return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F'); })) {
      throw CommandError{"ReleaseDigestUnreadable"};
    }

    return filter::lower(digest);
  }

  throw CommandError{"ReleaseAssetMissing"};
}

template <Allocator Memory>
std::optional<bool> installRuntime(Memory &memory, SetupReport &report, const Target &target, const Platform &platform, const Install &build) {
  if (!build.binary) {
    return false;
  }

  bool changed = false;
  for (const auto *tool : {"telar-runtime", "telar-launch.so"}) {
    const auto sibling = std::filesystem::path{*build.binary}.parent_path() / tool;
    if (::access(sibling.c_str(), R_OK) != 0) {
      continue;
    }

    try {
      const auto digest = fileDigest(sibling.string());
      const auto remote = (std::filesystem::path{platform.target}.parent_path() / tool).string();
      static constexpr std::string_view hasher = R"Hash(hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
)Hash";
      const auto inspect = runScript(memory, target.destination, assign("target", remote) + assign("expected", digest) + std::string{hasher} + "[ -f \"$target\" ] && [ \"$(hash \"$target\")\" = \"$expected\" ]\n");
      if (inspect.status == 0) {
        continue;
      }

      if (inspect.status == launch::ssh_failure) {
        throw CommandError{"SshFailed"};
      }

      FileDescriptor runtime{::open(sibling.c_str(), O_RDONLY | O_CLOEXEC)};
      if (!runtime) {
        throw fileError(errno);
      }

      const auto script = assign("target", remote) + assign("expected", digest) + std::string{hasher} + R"Upload(umask 077
temporary=$target.upload.$$
trap 'rm -f "$temporary"' EXIT
cat > "$temporary" && [ "$(hash "$temporary")" = "$expected" ] && chmod 755 "$temporary" && mv -f "$temporary" "$target"
)Upload";
      const auto command = "exec /bin/sh -c " + launch::quote(script);
      const auto uploaded = launch::capture(ssh(memory, target.destination, command), runtime.get(), install_timeout);
      if (uploaded.status != 0) {
        report.end(Step::telar, Status::failed, "the runtime upload failed: " + std::string{uploaded.errorLine()});
        return std::nullopt;
      }

      changed = true;
    } catch (const std::exception &error) {
      report.end(Step::telar, Status::failed, std::string{"the runtime upload did not run to the end: "} + error.what());
      return std::nullopt;
    }
  }

  return changed;
}

template <Allocator Memory>
bool install(Memory &memory, SetupReport &report, const Target &target, const Platform &platform, const Install &build) {
  try {
    MachineFieldRules::program(platform.target);
  } catch (const MachineFailure &) {
    report.end(Step::telar, Status::failed, platform.target + " holds a character a remote command cannot carry unquoted; telar needs a home of letters, digits and /._+-");
    return false;
  }

  if (platform.installed == "telar " + std::string{version}) {
    const auto runtime = installRuntime(memory, report, target, platform, build);
    if (!runtime) {
      return false;
    }

    report.end(Step::telar, *runtime ? Status::changed : Status::ok, (*runtime ? "installed telar " : "telar ") + std::string{version} + " at " + platform.target);
    return true;
  }

  std::string script;
  if (build.binary) {
    const auto upload_command = "exec /bin/sh -c 'umask 077 && mkdir -p \"$HOME/.local/share/telar/versions\" && exec cat > \"$HOME/.local/share/telar/versions/.upload-" + build.digest->substr(0, MachineId::hex_digits) + "\"'";
    FileDescriptor binary{::open(build.binary->c_str(), O_RDONLY | O_CLOEXEC)};
    if (!binary) {
      report.end(Step::telar, Status::failed, std::string{fileError(errno).what()} + ": cannot open --binary");
      return false;
    }

    try {
      const auto uploaded = launch::capture(ssh(memory, target.destination, upload_command), binary.get(), install_timeout);
      if (uploaded.status != 0) {
        report.end(Step::telar, Status::failed, "the upload failed: " + std::string{uploaded.errorLine()});
        return false;
      }
    } catch (const std::exception &error) {
      report.end(Step::telar, Status::failed, std::string{"the upload did not run to the end: "} + error.what());
      return false;
    }

    script = "upload=$HOME/.local/share/telar/versions/.upload-" + build.digest->substr(0, MachineId::hex_digits) + "\n";
    script += assign("digest", *build.digest) + assign("bin_dir", std::filesystem::path{platform.target}.parent_path().string());
    script += "(\nset -- --binary \"$upload\" --sha256 \"$digest\" --bin-dir \"$bin_dir\"\n";
  } else {
    if (version == "0.0.0") {
      report.end(Step::telar, Status::failed, "this is a development build (" + std::string{version} + ") with no release to download; pass --binary with a telar built for " + platform.os + " " + platform.arch);
      return false;
    }

    if (!platform.tools.contains("curl")) {
      report.end(Step::telar, Status::failed, target.label + " has no curl, which the installer needs to download the release; install curl there, or pass --binary");
      return false;
    }

    std::string digest;
    try {
      digest = releaseDigest(platform.assetName());
    } catch (const std::exception &error) {
      report.end(Step::telar, Status::failed, std::string{error.what()} + ": cannot read the hash of " + platform.assetName() + " from release " + std::string{version} + " at " + releasesUrl());
      return false;
    }

    script = assign("upload", "") + assign("digest", digest) + assign("version", version) + assign("bin_dir", std::filesystem::path{platform.target}.parent_path().string());
    if (const auto *url = std::getenv("TELAR_RELEASES_URL")) {
      script += assign("TELAR_RELEASES_URL", url) + "export TELAR_RELEASES_URL\n";
    }

    script += "(\nset -- --version \"$version\" --sha256 \"$digest\" --bin-dir \"$bin_dir\"";
    if (platform.os == "linux") {
      script += " --headless";
    }

    script += '\n';
  }

  script += assets::installer;
  script += "\n)\nstatus=$?\nif [ -n \"$upload\" ]; then rm -f \"$upload\"; fi\nexit $status\n";
  try {
    const auto output = runScript(memory, target.destination, script, install_timeout);
    if (output.status != 0) {
      report.end(Step::telar, Status::failed, "the installer refused: " + std::string{output.errorLine()});
      return false;
    }
  } catch (const std::exception &error) {
    report.end(Step::telar, Status::failed, std::string{"the installer did not run to the end: "} + error.what());
    return false;
  }

  if (!installRuntime(memory, report, target, platform, build)) {
    return false;
  }

  report.end(Step::telar, Status::changed, "installed telar " + std::string{version} + " at " + platform.target);
  return true;
}

template <Allocator Memory>
bool startRuntime(Memory &memory, SetupReport &report, const Target &target, const MachineProfile &remote, bool interactive) {
  const std::string program{*remote.program()};
  std::string detail;
  try {
    const auto found = discover(memory, remote, detail);
    if (!found.compatible()) {
      report.end(Step::runtime, Status::failed, "the telar at " + program + " speaks wire schema " + std::string{found.schema().begin(), found.schema().end()} + ", this one " + std::string{handshake::schema_id.begin(), handshake::schema_id.end()} + "; pass a --binary built from this tree");
      return false;
    }

    report.end(Step::runtime, Status::ok, "running at " + std::string{found.endpoint()});
    return true;
  } catch (const MachineFailure &error) {
    if (error.code() != MachineError::remote_runtime_incompatible) {
      report.end(Step::runtime, Status::failed, std::string{error.what()} + ": " + std::string{trimmed(detail)});
      return false;
    }
  }

  bool agreed = false;
  if (interactive) {
    std::printf("A telar runtime of another build runs on %s. Stopping it ends every pane and agent it runs. Stop it now? [y/N] ", target.label.c_str());
    std::fflush(stdout);
    agreed = answeredYes();
  }

  if (!agreed) {
    report.end(Step::runtime, Status::failed, "a runtime of another telar build runs there and keeps its panes; this build cannot attach until it stops. Run setup again from a terminal and agree to stop it");
    return false;
  }

  const auto script = assign("target", program) + assign("stopping", "is stopping") + R"Stop(for candidate in "$HOME/.local/bin/telar" "$HOME"/.local/share/telar/versions/*/telar $(command -v telar 2>/dev/null); do
    [ -x "$candidate" ] && [ "$candidate" != "$target" ] || continue
    if "$candidate" server stop 2>/dev/null | grep -q "$stopping"; then
        exit 0
    fi
done
echo 'no telar there could stop the running runtime' >&2
exit 1
)Stop";
  try {
    const auto stopped = runScript(memory, target.destination, script);
    if (stopped.status != 0) {
      report.end(Step::runtime, Status::failed, std::string{stopped.errorLine()});
      return false;
    }
  } catch (const std::exception &error) {
    report.end(Step::runtime, Status::failed, std::string{"stopping the old runtime did not run to the end: "} + error.what());
    return false;
  }

  constexpr unsigned restart_attempts = 20;
  constexpr auto restart_wait = std::chrono::milliseconds{250};
  for (unsigned attempt = 0; attempt < restart_attempts; ++attempt) {
    try {
      const auto found = discover(memory, remote, detail);
      if (found.compatible()) {
        report.end(Step::runtime, Status::changed, "stopped the runtime of another build; this one runs at " + std::string{found.endpoint()});
        return true;
      }
    } catch (const MachineFailure &) {
    }

    std::this_thread::sleep_for(restart_wait);
  }

  report.end(Step::runtime, Status::failed, "the old runtime stopped but this build's did not answer");
  return false;
}

template <Allocator Memory>
int setup(Memory &memory, const MachineOptions &options) {
  SetupReport report{.json = options.json};
  const auto path = profilesPath();
  const auto profiles = load(memory, path);
  Target target;
  Install build;
  try {
    target = resolve(profiles, options);
    build.directory = version;
    if (options.binary) {
      build.binary = *options.binary;
      build.digest = fileDigest(*build.binary);
      build.directory += "-" + build.digest->substr(0, MachineId::hex_digits);
      for (const auto *tool : {"telar-runtime", "telar-launch.so"}) {
        const auto companion = std::filesystem::path{*build.binary}.parent_path() / tool;
        if (::access(companion.c_str(), R_OK) != 0) {
          throw CommandError{"SetupBinaryCompanionsMissing"};
        }

        build.directory += "-" + fileDigest(companion.string()).substr(0, MachineId::hex_digits);
      }
    }
  } catch (const std::exception &error) {
    if (std::string_view{error.what()} == "DuplicateMachineLabel") {
      std::fprintf(stderr, "telar machine setup: the label for %.*s is taken by another machine; name it with --label\n", static_cast<int>(options.label.size()), options.label.data());
    } else {
      const auto *detail = describe(error.what());
      std::fprintf(stderr, "telar machine setup: %s\n", detail ? detail : error.what());
    }

    return 1;
  }

  if (!options.json) {
    std::printf("Setting up %s (%s) with telar %.*s\n", target.label.c_str(), target.destination.c_str(), static_cast<int>(version.size()), version.data());
    std::fflush(stdout);
  }

  const bool interactive = !options.json && ::isatty(STDIN_FILENO);
  if (options.confirm) {
    if (!interactive) {
      return report.refuse(memory, target.label, target.destination, "--confirm needs a terminal to ask on; nothing was changed");
    }

    std::printf("This installs telar %.*s on %s (%s), and the agents you have here with their official installers; it copies their configuration, never a credential, and opens their logins there. Set it up? [y/N] ", static_cast<int>(version.size()), version.data(), target.label.c_str(), target.destination.c_str());
    std::fflush(stdout);
    if (!answeredYes()) {
      std::printf("Nothing was changed on %s.\n", target.label.c_str());
      return 0;
    }
  }

  const auto platform = reach(memory, report, target, build.directory);
  if (!platform || !install(memory, report, target, *platform, build)) {
    return report.finish(memory, target.label, target.destination);
  }

  Random random;
  auto remote = MachineProfile::create(MachineId::generate(random), {.label = target.label, .destination = target.destination, .program = platform->target});
  std::string detail;
  if (!startRuntime(memory, report, target, remote, interactive)) {
    return report.finish(memory, target.label, target.destination);
  }

  const auto link = runScript(memory, target.destination, assign("telar", platform->target) + R"Link(link=$HOME/.local/bin/telar
if [ -L "$link" ] && [ "$(readlink "$link")" = "$telar" ]; then exit 0; fi
if [ -e "$link" ] && [ ! -L "$link" ]; then echo 'it is a file telar did not link, so it stays; remove it to let setup link it' >&2; exit 1; fi
mkdir -p "$HOME/.local/bin" && "$telar" cli install --dir "$HOME/.local/bin" >/dev/null && echo linked
)Link");
  if (link.status != 0) {
    report.note(Step::runtime, "~/.local/bin/telar left as it was: " + std::string{link.errorLine()});
  } else if (link.out.contains("linked")) {
    report.note(Step::runtime, "~/.local/bin/telar now links to " + platform->target);
  }

  try {
    const auto previous = target.saved ? target.saved->program() : std::nullopt;
    const bool changed = !target.saved || previous != platform->target || (!target.saved->enabled() && !options.disabled);
    if (changed) {
      update(memory, path, [&](MachineProfiles &saved) {
        if (!target.saved) {
          MachineOptions add{.action = MachineOptions::Action::add, .label = target.label, .value = target.destination, .disabled = options.disabled};
          change(saved, add);
        }

        saved.placeProgram(target.label, platform->target);
        if (!options.disabled && target.saved) {
          saved.enable(target.label, true);
        }
      });
    }

    const bool enabled = (target.saved && target.saved->enabled()) || !options.disabled;
    const std::string state = enabled ? "enabled" : "disabled, as asked";
    report.end(Step::profile, changed ? Status::changed : Status::ok, changed ? target.label + (target.saved ? " updated, " : " saved, ") + state + ", telar at " + platform->target : target.label + " is saved, " + state + " and names " + platform->target);
  } catch (const std::exception &error) {
    const auto *description = describe(error.what());
    report.end(Step::profile, Status::failed, description ? description : error.what());
  }

  const auto wanted = localAgents();
  auto current = *platform;
  if (options.skip[0]) {
    report.end(Step::agents, Status::skipped, "--skip agents");
  } else if (installAgents(memory, report, target.destination, current, wanted)) {
    try {
      const auto probe = runScript(memory, target.destination, assign("dir", build.directory) + std::string{assets::probe});
      if (probe.status == 0) {
        current = Platform::parse(whole(probe));
      }
    } catch (const std::exception &) {
    }
  }

  integrateAgents(memory, report, target.destination, current);
  if (options.skip[1]) {
    report.end(Step::configuration, Status::skipped, "--skip config");
  } else {
    syncConfig(memory, report, target.destination, current, wanted);
  }

  if (options.skip[2]) {
    report.end(Step::logins, Status::skipped, "--skip login");
  } else {
    std::optional<MachineProfile> saved;
    try {
      const auto profiles_now = load(memory, path);
      if (const auto row = profiles_now.find(target.label); row && profiles_now.rows()[*row].destination() == target.destination) {
        saved = profiles_now.rows()[*row];
      }
    } catch (const std::exception &) {
    }

    if (saved) {
      Logins logins{memory, report, *saved, current, interactive};
      logins.run(wanted, path);
    } else {
      report.end(Step::logins, Status::skipped, target.label + " is not saved, so its logins cannot be recorded");
    }
  }

  try {
    const auto found = discover(memory, remote, detail);
    report.end(Step::check, found.compatible() ? Status::ok : Status::failed, found.compatible() ? "a window can attach: schema " + std::string{handshake::schema_id.begin(), handshake::schema_id.end()} + " on both sides" : "schema " + std::string{found.schema().begin(), found.schema().end()} + " there, " + std::string{handshake::schema_id.begin(), handshake::schema_id.end()} + " here");
  } catch (const MachineFailure &error) {
    report.end(Step::check, Status::failed, std::string{error.what()} + ": " + std::string{trimmed(detail)});
  }

  return report.finish(memory, target.label, target.destination);
}

}
