#pragma once

#if defined(__APPLE__)
#include "../redirect/helper.hpp"

namespace telar::runtime::cli {

template <Allocator Memory>
void runRedirect(Memory &memory, std::span<char *const> arguments, bool cleanup) {
  const char *socket = nullptr;
  std::array<redirect::Target, redirect::Target::maximum_targets> targets;
  std::size_t count = 0;
  std::array<ProcessIdentity, redirect::SocketOwners::maximum_processes> processes;
  std::size_t process_count = 0;
  bool dry_run = false;
  auto direction = redirect::Direction::outbound;
  bool direction_given = false;
  for (std::size_t index = 0; index < arguments.size(); ++index) {
    const std::string_view argument{arguments[index]};
    if (argument == "--dry-run" && !cleanup && !dry_run) {
      dry_run = true;
      continue;
    }
    if (index + 1 == arguments.size()) {
      throw std::invalid_argument{"Missing redirect option value"};
    }
    const std::string_view value{arguments[++index]};
    if (argument == "--socket" && socket == nullptr && !value.empty() && value.find_first_of("\r\n") == std::string_view::npos) {
      socket = arguments[index];
    } else if (argument == "--target" && !cleanup && count < targets.size()) {
      const auto target = redirect::Target::parse(value);
      if (std::ranges::any_of(std::span{targets}.first(count), [&](const auto &previous) { return previous.host.view() == target.host.view() && previous.port == target.port; })) {
        throw std::invalid_argument{"Duplicate redirect destination"};
      }
      targets[count++] = target;
    } else if (argument == "--direction" && !cleanup && !direction_given) {
      direction = redirect::parseDirection(value);
      direction_given = true;
    } else if (argument == "--process" && !cleanup && process_count < processes.size()) {
      const auto process = redirect::ProcessToken::parse(value);
      if (std::ranges::any_of(std::span{processes}.first(process_count), [&](const auto &other) { return other.pid == process.pid; })) { throw std::invalid_argument{"Duplicate selected process"}; }
      processes[process_count++] = process;
    } else {
      throw std::invalid_argument{"Unknown, duplicate or excessive redirect option"};
    }
  }
  if (!socket || (!cleanup && count == 0)) {
    throw std::invalid_argument{"Expected traffic redirect --socket PATH --target IP:PORT [--direction outbound|inbound|both] [--process PID[@SECONDS.MICROSECONDS]] [--dry-run]"};
  }
  String<Memory> endpoint{socket, AllocatorRef<char, Memory>{memory}};
  endpoint += redirect::socket_suffix;
  if (endpoint.front() != '/' || endpoint.size() >= sizeof(sockaddr_un::sun_path)) {
    throw std::invalid_argument{"Invalid absolute redirect endpoint"};
  }
  const redirect::PfIdentity identity{memory, endpoint};
  if (cleanup) {
    if (::geteuid() != 0) {
      throw std::invalid_argument{"Redirect recovery requires root"};
    }
    redirect::Record state{memory, identity, endpoint};
    redirect::PfCommand command{memory};
    redirect::PfLoopback interface{command};
    redirect::SharedLoopback loopback{memory, interface, identity.label};
    redirect::PfSession session{command, state, identity, loopback};
    session.recover();
    std::printf("telar redirect: recovered %s\n", identity.anchor.c_str());
    return;
  }
  if (!dry_run && ::geteuid() != 0) {
    throw std::invalid_argument{"Use sudo only for traffic redirect; keep the runtime unprivileged"};
  }
  redirect::Helper helper{memory, std::string_view{socket}, std::span{targets}.first(count), std::span{processes}.first(process_count), direction};
  if (dry_run) {
    struct stat metadata{};
    if (::lstat(endpoint.c_str(), &metadata) != 0 || !S_ISSOCK(metadata.st_mode) || (metadata.st_mode & 0077) != 0 || (::geteuid() != 0 && metadata.st_uid != ::geteuid())) {
      throw SystemError{"Enable runtime.proxy.transparent_redirect on an owned runtime first", EACCES};
    }
    if (process_count != 0) { const redirect::SocketOwners selected{metadata.st_uid, std::span{processes}.first(process_count)}; }
    const auto rules = helper.plan(metadata.st_uid, identity, true);
    redirect::PfCommand command{memory};
    const std::array<std::string_view, 5> arguments{"-n", "-a", identity.anchor, "-f", "-"};
    command.run(arguments, rules);
    std::fwrite(rules.data(), 1, rules.size(), stdout);
    return;
  }
  helper.run(identity);
}

}

#else
#include "../memory/allocator.hpp"
#include "../platform/error.hpp"
#include <span>

namespace telar::runtime::cli {

template <Allocator Memory>
void runRedirect(Memory &, std::span<char *const>, bool) {
  throw SystemError{"Transparent redirect requires a native Linux firewall adapter", ENOTSUP};
}

}
#endif
