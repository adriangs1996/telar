#pragma once

#include "ensure_runtime.hpp"
#include "file_transfer.hpp"
#include "repository_git.hpp"
#include "history_paths.hpp"
#include <openssl/sha.h>

namespace telar::runtime::cli::repository {

struct Catalog {
  std::vector<std::pair<std::uint64_t, std::string>> workspaces;
  std::vector<std::string> worktrees;
};

template <Allocator Memory>
Catalog catalog(Memory &memory, const char *socket) {
  RuntimeConnection connection{socket};
  connection.receiveTimeout(30);
  std::array<Byte, 32> outgoing;
  connection.send(RequestRuntimeState{.client_identity = randomIdentity(), .interactive = false}, outgoing);
  Vector<Byte, Memory> incoming(max_payload_size, Byte{}, AllocatorRef<Byte, Memory>{memory});
  Vector<Byte, Memory> decoded(max_payload_size, Byte{}, AllocatorRef<Byte, Memory>{memory});
  for (;;) {
    const auto frame = connection.receive(incoming);
    if (static_cast<ServerTag>(frame.front()) != ServerTag::workspace_list) {
      continue;
    }

    DecodeStorage storage{decoded};
    const auto list = Codec::decode<WorkspaceList>(frame, storage);
    Catalog result;
    for (const auto &entry : list.entries) {
      result.workspaces.emplace_back(entry.workspace, entry.path);
    }

    for (const auto &entry : list.worktrees) {
      result.worktrees.emplace_back(entry.path);
    }

    return result;
  }
}

inline std::string managedPath(std::string_view identity) {
  const ProcessEnvironment environment;
  const auto home = environment.lookup("HOME");
  if (home.empty()) {
    throw std::runtime_error{"HomeDirectoryUnavailable"};
  }

  const auto configured = environment.lookup("XDG_DATA_HOME");
  const auto base = configured.empty() ? std::string{home} + "/.local/share" : std::string{configured};
  if (!base.starts_with('/')) {
    throw std::runtime_error{"InvalidDataDirectory"};
  }

  std::array<unsigned char, SHA256_DIGEST_LENGTH> digest;
  ::SHA256(reinterpret_cast<const unsigned char *>(identity.data()), identity.size(), digest.data());
  auto result = base + "/telar/repositories/";
  for (const auto byte : digest) {
    result += std::format("{:02x}", byte);
  }

  return result;
}

template <Allocator Memory>
std::string mainRoot(Memory &memory, std::string_view path) {
  Git git{memory, path};
  const auto common = git.read({"rev-parse", "--path-format=absolute", "--git-common-dir"});
  auto trimmed = std::string_view{common};
  while (trimmed.ends_with('/')) {
    trimmed.remove_suffix(1);
  }

  constexpr std::string_view suffix = "/.git";
  if (!trimmed.ends_with(suffix)) {
    throw std::runtime_error{"NotARepository"};
  }

  trimmed.remove_suffix(suffix.size());
  if (trimmed.empty() || !trimmed.starts_with('/')) {
    throw std::runtime_error{"NotARepository"};
  }

  return std::string{trimmed};
}

template <Allocator Memory>
std::optional<std::string> matching(Memory &memory, std::string_view path, std::string_view identity) {
  if (path.contains('\0') || path.size() >= PATH_MAX) {
    return std::nullopt;
  }

  std::string root;
  try {
    root = mainRoot(memory, path);
  } catch (const std::exception &) {
    return std::nullopt;
  }

  auto directory = file_transfer::openDirectory(root);
  try {
    Git git{memory, root};
    if (normalize(git.read({"config", "--get", "remote.origin.url"})) != identity) {
      return std::nullopt;
    }
  } catch (const std::exception &) {
    return std::nullopt;
  }

  return root;
}

// Zig's `repository_discovery.find`: the main checkout whose origin is
// `identity` among the runtime's workspaces and worktrees, the workspaces
// history recorded and the managed clone. It starts the runtime if needed.
template <Allocator Memory>
std::optional<std::string> find(Memory &memory, std::string_view identity, std::optional<std::string_view> selected, std::optional<std::string_view> socket = std::nullopt) {
  const ProcessEnvironment environment;
  ServerOptions server;
  if (socket) {
    server.socket = *socket;
  }

  const RuntimePaths paths{memory, server, environment};
  ensureRuntime(memory, paths);
  const auto available = catalog(memory, paths.socket.c_str());
  if (selected) {
    std::string path{*selected};
    if (const auto id = maybeUnsigned(*selected)) {
      const auto found = std::ranges::find(available.workspaces, *id, &std::pair<std::uint64_t, std::string>::first);
      if (found == available.workspaces.end()) {
        throw std::runtime_error{"WorkspaceNotFound"};
      }

      path = found->second;
    }

    auto result = matching(memory, path, identity);
    if (!result) {
      throw std::runtime_error{"RepositoryNotInWorkspace"};
    }

    return result;
  }

  std::optional<std::string> result;
  auto consider = [&](std::string_view path) {
    const auto candidate = matching(memory, path, identity);
    if (!candidate) {
      return;
    }

    if (result && result != candidate) {
      throw std::runtime_error{"AmbiguousRepository"};
    }

    result = candidate;
  };
  for (const auto &[id, path] : available.workspaces) {
    consider(path);
  }

  for (const auto &path : available.worktrees) {
    consider(path);
  }

  RuntimePaths storage_paths{memory, ServerOptions{}, environment};
  storage_paths.resolveStorage(ServerOptions{}, environment);
  historyPaths(storage_paths.history.c_str(), consider);

  consider(managedPath(identity));
  return result;
}

}
