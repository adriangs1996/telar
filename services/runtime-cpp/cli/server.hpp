#pragma once

#include "../config/loader.hpp"
#include "../graphics/png_decoder.hpp"
#include "../history/sqlite_allocator.hpp"
#include "../plugins/service.hpp"
#include "../plugins/tap_configuration.hpp"
#include "../proxy/runtime.hpp"
#include "../traffic/tap.hpp"
#include "../traffic/control_backend.hpp"
#include "../traffic/control_service.hpp"
#include "../runtime/background_pool.hpp"
#include "../runtime/background_service.hpp"
#include "../runtime/editor_service.hpp"
#include "../runtime/path_service.hpp"
#include "../runtime/runtime.hpp"
#include "../runtime/suggestion_service.hpp"
#include "daemon.hpp"
#include "runtime_connection.hpp"
#include <cstdio>
#include <thread>

namespace telar::runtime::cli {

inline bool connectExisting(std::optional<RuntimeConnection> &connection, const char *path) {
  try {
    connection.emplace(path);
    return true;
  } catch (const SystemError &error) {
    if (error.code() != ENOENT && error.code() != ECONNREFUSED) {
      throw;
    }

    return false;
  }
}

template <Allocator Memory>
void printEndpoint(Memory &memory, const ServerOptions &options, const RuntimePaths<Memory> &paths) {
  std::optional<RuntimeConnection> connection;
  if (!connectExisting(connection, paths.socket.c_str())) {
    paths.prepareSocket();
    const auto child = launchDaemon(memory, options, paths);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
    while (!connectExisting(connection, paths.socket.c_str())) {
      int status = 0;
      if (::waitpid(child, &status, WNOHANG) == child) {
        throw SystemError{"Runtime failed to start; inspect its .runtime.start.log", ECHILD};
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"Runtime did not start within ten seconds", ETIMEDOUT};
      }

      std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }
  }

  std::printf("%s\n", paths.socket.c_str());
  std::fwrite(handshake::schema_id.data(), 1, handshake::schema_id.size(), stdout);
  std::fputc('\n', stdout);
}

inline void stopRuntime(const char *socket) {
  std::optional<RuntimeConnection> connection;
  if (!connectExisting(connection, socket)) {
    std::puts("telar runtime is not running");
    return;
  }

  connection->requestStop();
  std::puts("telar runtime is stopping");
}

template <ConcurrentAllocator Memory>
void runRuntime(Memory &memory, const ServerOptions &options, const RuntimePaths<Memory> &paths, const config::RuntimeValues<Memory> &configuration) {
#if TELAR_DEBUG
  trace::Session tracing{memory, options.trace.empty() ? nullptr : options.trace.data()};
#endif
  ExecutablePath executable;
  plugins::TapConfiguration tap_configuration{memory, configuration.configuration_directory.view(), configuration.plugins.configured(), ProcessEnvironment{}};
  installPngDecoder();
  SqliteAllocator sqlite_memory{memory};
  std::optional<traffic::Service<Memory>> traffic_service;
  if (configuration.proxy.network_capture) {
    String<Memory> endpoint{paths.socket, AllocatorRef<char, Memory>{memory}};
    endpoint += traffic::socket_suffix;
    traffic_service.emplace(memory, endpoint, configuration.proxy.stream_interception);
  }
  plugins::Service plugin_service{memory, tap_configuration.specifications(), executable.c_str(), options.trace, traffic_service ? &*traffic_service : nullptr};
  if (!tap_configuration.specifications().empty()) { plugin_service.watchTrust(plugins::Paths::trust(memory, ProcessEnvironment{})); }

  traffic::Tap<Memory, plugins::Service<Memory>> tap{plugin_service, traffic_service ? &*traffic_service : nullptr};
  ProxyRuntime<Memory, Kqueue, SystemNameResolver, decltype(tap)> proxy{memory, configuration.proxy, paths.socket, configuration.proxy.enabled && paths.isDefaultSocket(ProcessEnvironment{}), tap};
  traffic::control::Backend network_backend{memory, proxy, traffic_service ? &*traffic_service : nullptr, traffic::control::Configuration{
      .endpoint = paths.socket,
      .executable = executable.view(),
      .proxy = configuration.proxy.enabled,
      .redirect = configuration.proxy.transparent_redirect,
      .transparent_tls = configuration.proxy.transparent_tls,
      .interception = configuration.proxy.stream_interception,
      .administration = configuration.proxy.network_control,
  }};
  std::optional<traffic::control::Service<Memory, decltype(network_backend)>> network_control;
  if (traffic_service) {
    String<Memory> endpoint{paths.socket, AllocatorRef<char, Memory>{memory}};
    endpoint += traffic::control::socket_suffix;
    network_control.emplace(memory, endpoint, network_backend);
    traffic_service->packageControl(&*network_control);
  }
  // Queued halves borrow the proxy's capture quota, so workers must release them before the proxy is destroyed.
  plugins::ShutdownGuard stop_plugins{plugin_service};
  BackgroundService background_service{memory, paths.history.c_str(), configuration.history_filters};
  PathService path_service{memory};
  EditorService editor_service{memory};
  std::array<std::string_view, 32> engine_arguments;
  std::transform(configuration.engine.arguments.begin(), configuration.engine.arguments.end(), engine_arguments.begin(), [](const auto &argument) { return std::string_view{argument}; });
  const auto selected_arguments = options.engine_argument_count == 0 ? std::span<const std::string_view>{engine_arguments}.first(configuration.engine.arguments.size()) : std::span{options.engine_arguments}.first(options.engine_argument_count);
  SuggestionService suggestion_service{memory, SuggestionOptions{.arguments = selected_arguments, .timeout = configuration.engine.timeout, .idle_timeout = configuration.engine.idle_timeout}};
  std::array<std::string_view, 32> description_arguments;
  std::transform(configuration.descriptions.arguments.begin(), configuration.descriptions.arguments.end(), description_arguments.begin(), [](const auto &argument) { return std::string_view{argument}; });
  BackgroundPool background{memory, background_service, path_service, editor_service, suggestion_service};
  Kqueue poller;
  poller.watchSignal(SIGTERM);
  poller.watchSignal(SIGINT);
  poller.watchSignal(SIGCHLD);
  const auto shell = ProcessEnvironment{}.lookup("SHELL");
  Runtime runtime{memory, poller, background, RuntimeOptions{
                                                  .socket = paths.socket,
                                                  .executable = executable.view(),
                                                  .session = {.path = paths.session, .resume_agents = options.resume_agents},
                                                  .fresh = options.fresh,
                                                  .capture_output = configuration.capture_output,
                                                  .manifests = &configuration.manifests,
                                                  .descriptions = {.arguments = std::span{description_arguments}.first(configuration.descriptions.arguments.size()), .timeout = configuration.descriptions.timeout},
                                                  .clone = {.source_checkpoint = options.clone_session, .source_socket = options.clone_from, .shell = shell.empty() ? "/bin/sh" : shell},
                                                  .graphics = configuration.graphics,
                                                  .control_policy = configuration.control_policy,
                                              },
                  proxy.clientConfiguration()};
  runtime.run(proxy, plugin_service);
}

template <ConcurrentAllocator Memory>
void runServer(Memory &memory, const ServerOptions &options) {
  if (options.action == ServerAction::help) {
    std::puts("Usage: telar-runtime server [stop|endpoint|bridge] [--socket PATH] [--no-config] [--fresh]\n       telar-runtime --socket PATH [--history PATH] [--session PATH | --no-session] [--no-resume]");
    return;
  }
#if !TELAR_DEBUG
  if (!options.trace.empty()) {
    throw std::invalid_argument{"Tracing is available in Debug builds only"};
  }
#endif

  const ProcessEnvironment environment;
  RuntimePaths paths{memory, options, environment};
  switch (options.action) {
  case ServerAction::stop:
    stopRuntime(paths.socket.c_str());
    return;
  case ServerAction::endpoint:
    printEndpoint(memory, options, paths);
    return;
  case ServerAction::bridge:
    RuntimeConnection{paths.socket.c_str(), false}.bridge();
  case ServerAction::run:
    break;
  case ServerAction::help:
    return;
  }

  config::RuntimeValues configuration{memory};
  config::Loader{memory, configuration}.load(options, environment);
  configuration.limits.print();
  auto resolved_options = options;
  if (resolved_options.history.empty()) {
    resolved_options.history = configuration.history_path;
  }
  if (resolved_options.session.empty()) {
    resolved_options.session = configuration.session_path;
  }
  resolved_options.persist_session = options.persist_session && configuration.persist_session;
  resolved_options.resume_agents = options.resume_agents && configuration.resume_agents;

  paths.prepareSocket();
  if (options.mode == ServerMode::background) {
    launchDaemon(memory, options, paths);
    return;
  }

  paths.resolveStorage(resolved_options, environment);
  paths.prepareStorage();
  runRuntime(memory, resolved_options, paths, configuration);
}

}
