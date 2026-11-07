module;
#include "telar_platform/trace_macro.hpp"
#include <ghostty/vt.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <zlib.h>

#include "telar_base/diagnostics/config.hpp"
#include <sys/types.h>
#include <cstdint>
#include <cassert>
#include <cstring>
#include <cstddef>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include "cell_layout.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>

#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif

#include <new>



export module telar.runtime.runtime.execution_service;

import std;

export import telar.runtime.model.client_layouts;
export import telar.base.diagnostics;


export import telar.runtime.platform.system_certificates;
export import telar.runtime.platform.stream_read_buffer;
export import telar.runtime.transport.connection;


export import telar.client;
export import telar.platform;


export import telar.runtime.proxy.runtime;


export import telar.runtime.terminal.text_reader;
export import telar.runtime.runtime.delivery.client_delivery;


export import telar.runtime.execution.execution;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: runtime/limit_service.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class LimitService {
public:
  inline explicit LimitService(RuntimeModel<Memory> &model) noexcept
      : model_(model) {}

  inline void receive(ClientSession<Memory> &client, const ReportLimit &message) {
    if (!admit(client)) {
      return;
    }

    const auto recorded = model_.limits.clients.record(message.reach, message.hits);
    if (recorded.show && client.role == ClientRole::control) {
      show(recorded.row);
    }
  }

  inline void report(const LimitReach &reach) {
    const auto recorded = model_.limits.runtime.record(reach, 1);
    if (recorded.show) {
      show(recorded.row);
    }
  }

  inline void query(ClientSession<Memory> &client, const QueryLimits &request) {
    client.connection.defer(request);
  }

private:
  inline bool admit(ClientSession<Memory> &client) noexcept {
    const auto now = std::chrono::steady_clock::now();
    if (now - client.limit_report_window >= std::chrono::seconds{1}) {
      client.limit_report_window = now;
      client.limit_reports = 0;
    }

    if (client.limit_reports == reports_per_second) {
      model_.limits.refused_reports = saturatedAdd(model_.limits.refused_reports, 1);
      return false;
    }

    ++client.limit_reports;
    return true;
  }

  inline void show(const LimitLedger::Row &row) noexcept {
    std::array<char, 256> text{};
    const auto reach = row.reach();
    const char *separator = reach.noun.empty() ? "" : " ";
    int length = 0;
    if (reach.requested) {
      length = std::snprintf(text.data(), text.size(), "%.*s: %llu%s%.*s; limit %llu", static_cast<int>(reach.name.size()), reach.name.data(), static_cast<unsigned long long>(*reach.requested), separator, static_cast<int>(reach.noun.size()), reach.noun.data(), static_cast<unsigned long long>(reach.value));
    } else if (reach.value == 0) {
      length = std::snprintf(text.data(), text.size(), "%.*s: limit reached", static_cast<int>(reach.name.size()), reach.name.data());
    } else {
      length = std::snprintf(text.data(), text.size(), "%.*s: limit %llu%s%.*s reached", static_cast<int>(reach.name.size()), reach.name.data(), static_cast<unsigned long long>(reach.value), separator, static_cast<int>(reach.noun.size()), reach.noun.data());
    }

    if (row.hits > 1) {
      length += std::snprintf(text.data() + length, text.size() - length, " (%llu times)", static_cast<unsigned long long>(row.hits));
    }

    const Notification notification{NotificationBody{.level = NotificationLevel::warning,
                                                     .duration_ms = 8000,
                                                     .title = "Limit reached",
                                                     .message = {text.data(), static_cast<std::size_t>(length)}}};
    for (auto *client : model_.clients.items()) {
      if (client == nullptr || client->role != ClientRole::interactive || client->connection.closing) {
        continue;
      }

      try {
        client->connection.trySend(notification);
      } catch (...) {
        client->connection.closing = true;
      }
    }
  }

  static constexpr unsigned reports_per_second = 32;
  RuntimeModel<Memory> &model_;
};

template <Allocator Memory>
LimitService(RuntimeModel<Memory> &model) -> LimitService<Memory>;

}
}

// Interface: runtime/client_admission.cppm
export {
namespace telar::runtime {

template <Allocator Memory, EventLoop Poller>
class ClientAdmission {
public:
  inline explicit ClientAdmission(RuntimeModel<Memory> &model, Poller &poller, LimitService<Memory> &limits)
      : model_(model),
        poller_(poller),
        limits_(limits) {}

  inline ~ClientAdmission() {
    clear();
  }

  inline void begin(FileDescriptor descriptor) {
    constexpr std::size_t maximum_clients = 32;
    std::size_t reserved = 0;
    for (const auto &pending : pending_) {
      reserved += pending && pending->reservesClient();
    }
    const auto requested = model_.clients.size() + reserved + 1;
    const bool refused = requested > maximum_clients;
    if (refused) {
      limits_.report({"clients.max_clients", "clients", maximum_clients, requested, {}});
    }

    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (pending_[slot] || generations_[slot] >= maximum_event_identity / capacity - 1) {
        continue;
      }

      ++generations_[slot];
      pending_[slot].emplace(std::move(descriptor), refused);
      ++count_;
      try {
        poller_.watch(pending_[slot]->descriptor(), token(slot));
      } catch (...) {
        drop(slot);
        throw;
      }
      return;
    }
    limits_.report({"clients.max_pending_handshakes", "handshakes", capacity, {}, {}});
  }

  template <typename Admit>
  inline void event(const Event &event, const Admit &admit) {
    const auto slot = eventIdentity(event.token) % capacity;
    auto &pending = pending_[slot];
    if (!pending || event.token != token(slot) || event.descriptor != pending->descriptor()) {
      return;
    }

    try {
      if (event.kind == EventKind::readable) {
        pending->read();
      }
      pending->write();
      switch (pending->stage()) {
      case ClientHandshake::Stage::accepted: {
        poller_.remove(pending->descriptor());
        auto descriptor = pending->takeDescriptor();
        pending.reset();
        --count_;
        admit(std::move(descriptor));
        break;
      }
      case ClientHandshake::Stage::rejected:
        drop(slot);
        break;
      case ClientHandshake::Stage::reply:
        poller_.readInterest(pending->descriptor(), event.token, false);
        poller_.writeInterest(pending->descriptor(), event.token, true);
        break;
      case ClientHandshake::Stage::prefix:
      case ClientHandshake::Stage::hello:
        break;
      }
    } catch (const std::exception &) {
      if (pending) {
        drop(slot);
      }
    }
  }

  inline void expire(std::chrono::steady_clock::time_point now) noexcept {
    if (count_ == 0) {
      return;
    }

    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (pending_[slot] && pending_[slot]->expired(now)) {
        drop(slot);
      }
    }
  }

  inline void clear() noexcept {
    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (pending_[slot]) {
        drop(slot);
      }
    }
  }

private:
  inline std::uint64_t token(std::size_t slot) const noexcept {
    return eventToken(EventSource::handshake, generations_[slot] * capacity + slot);
  }

  inline void drop(std::size_t slot) noexcept {
    poller_.remove(pending_[slot]->descriptor());
    pending_[slot].reset();
    --count_;
  }

  static constexpr std::size_t capacity = 16;
  std::array<std::optional<ClientHandshake>, capacity> pending_;
  std::array<std::uint64_t, capacity> generations_{};
  std::size_t count_ = 0;
  RuntimeModel<Memory> &model_;
  Poller &poller_;
  LimitService<Memory> &limits_;
};

}
}

// Interface: runtime/workspace_notifications.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
void notifyWorkspaceObservers(RuntimeModel<Memory> &model, std::uint64_t workspace, std::uint64_t origin, std::optional<std::uint64_t> previous = {}) noexcept {
  for (auto *client : model.clients.items()) {
    if (client != nullptr && client->id != origin && client->connection.negotiated && !client->connection.closing && client->workspace == workspace) {
      client->workspace_resync = ResyncRequired{.workspace = {.id = workspace}, .previous_workspace = previous};
    }
  }
}

template <Allocator Memory>
std::optional<std::uint64_t> previousWorkspace(const RuntimeModel<Memory> &model, std::uint64_t identity) noexcept {
  const auto items = model.workspaces.items();
  for (std::size_t index = 0; index < items.size(); ++index) {
    if (items[index] == nullptr || items[index]->id != identity) {
      continue;
    }

    for (std::size_t offset = 1; offset < items.size(); ++offset) {
      const auto *previous = items[(index + items.size() - offset) % items.size()];
      if (previous != nullptr) {
        return previous->id;
      }
    }
    break;
  }

  return std::nullopt;
}

}
}

// Interface: runtime/geometry_lease.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
bool acquireGeometry(RuntimeModel<Memory> &model, const ClientSession<Memory> &client, Workspace<Memory> &workspace) {
  if (workspace.geometry_client) {
    TELAR_DIAGNOSTIC(if (*workspace.geometry_client != client.id) { diagnostics::accumulate(model.metrics.geometry_rejections); });
    return *workspace.geometry_client == client.id;
  }

  workspace.geometry_client = client.id;
  for (auto *pane : model.panes.items()) {
    if (pane != nullptr && pane->location.workspace.id == workspace.id) {
      if (!pane->desktop_theme) {
        pane->terminal.configureColors(client.colors);
        pane->terminal.resumeControl();
      }
    }
  }

  return true;
}

template <Allocator Memory>
void releaseGeometry(RuntimeModel<Memory> &model, std::uint64_t client, Workspace<Memory> &workspace) noexcept {
  if (workspace.geometry_client == client) {
    workspace.geometry_client.reset();
    notifyWorkspaceObservers(model, workspace.id, client);
  }
}

template <Allocator Memory>
void releaseAllGeometry(RuntimeModel<Memory> &model, std::uint64_t client) noexcept {
  for (auto *workspace : model.workspaces.items()) {
    if (workspace != nullptr) {
      releaseGeometry(model, client, *workspace);
    }
  }
}

}
}

// Interface: runtime/launch_failure_cause.cppm
export {
namespace telar::runtime {

inline std::string_view launchFailureCause(const std::exception &error) noexcept {
  if (dynamic_cast<const std::bad_alloc *>(&error) != nullptr) {
    return "OutOfMemory";
  }
  if (const auto *request = dynamic_cast<const RequestError *>(&error)) {
    return request->code() == FailureCode::resource_limit ? "PaneLimitReached" : "Unexpected";
  }
  if (const auto *system = dynamic_cast<const SystemError *>(&error)) {
    switch (system->code()) {
    case ENOMEM:
    case ENOBUFS:
      return "SystemResources";
    case EACCES:
    case EPERM:
      return "PermissionDenied";
    case EBADF:
      return "InvalidDescriptor";
    default:
      return "Unexpected";
    }
  }

  return "Unexpected";
}

}
}

// Interface: runtime/pane_launch_options.cppm
export {
namespace telar::runtime {

struct PaneLaunchOptions {
  std::string_view socket;
  ProxyClientConfiguration proxy{};
  control::Policy control_policy{};
};

}
}

// Interface: runtime/pane_service.cppm
export {
namespace telar::runtime {

struct IgnorePaneInput {
  template <typename PaneType>
  inline void operator()(const PaneType &, std::span<const Byte>) const noexcept {}
};

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class PaneService {
public:
  inline explicit PaneService(Memory &memory, RuntimeModel<Memory> &model, Poller &poller, PaneLaunchOptions options, History &history = discarded_history)
      : memory_(memory),
        model_(model),
        poller_(poller),
        history_(history),
        socket_path_(options.socket),
        proxy_(options.proxy),
        control_policy_(options.control_policy) {}

  inline Pane<Memory> &require(std::uint64_t identity) const {
    auto *pane = model_.panes.find(identity);
    if (pane == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "Pane does not exist"};
    }

    return *pane;
  }

  inline Pane<Memory> &requireGeneration(std::uint64_t identity, std::uint64_t generation) const {
    auto &pane = require(identity);
    if (generation != 0 && pane.generation != generation) {
      throw RequestError{FailureCode::pane_not_found, "Pane generation no longer exists"};
    }

    return pane;
  }

  inline Pane<Memory> &launch(const Launch &launch, TabLocation location, TerminalSize size) {
    const auto identity = allocateIdentity();
    if (launch.environment_mode != EnvironmentMode::inherit_runtime || !launch.environment.empty()) {
      throw RequestError{FailureCode::invalid_request, "custom pane environment is not supported"};
    }

    Command command{memory_, launch};
    return launchPrepared(command, location, size, identity);
  }

  inline Pane<Memory> &launch(Command<Memory> &command, TabLocation location, TerminalSize size, std::uint64_t restored_identity = 0) {
    return launchPrepared(command, location, size, allocateIdentity(restored_identity));
  }

  inline Attachment<Memory> &attach(ClientSession<Memory> &client, Pane<Memory> &pane, TerminalSize size) {
    auto *workspace = model_.workspaces.find(pane.location.workspace.id);
    if (workspace == nullptr) {
      throw RequestError{FailureCode::workspace_not_found, "Workspace does not exist"};
    }

    if (client.workspace && *client.workspace != workspace->id) {
      throw EncodingError{"Client must leave its workspace before attaching another"};
    }

    const bool controls_geometry = acquireGeometry(model_, client, *workspace);
    if (controls_geometry) {
      pane.resize(size);
    }

    if (auto *existing = client.attachment(pane.id)) {
      return *existing;
    }

    const auto slot = client.availableAttachmentSlot();
    auto attachment = makeOwned<Attachment<Memory>>(memory_, memory_, client.graphics_credit, pane.id, pane.media);
    attachment->slot = slot;
    attachment->graphics.configure(client.shared_graphics);
    attachment->clipboard_revision = pane.terminal.effects.clipboard_revision;

    auto &result = *attachment;
    client.attachments.push_back(std::move(attachment));
    client.workspace = workspace->id;
    pane.observers |= model_.clientBit(client.id);
    return result;
  }

  inline void detach(ClientSession<Memory> &client, std::uint64_t identity) noexcept {
    if (release(client, identity) && client.attachments.empty()) {
      detachAll(client);
    }
  }

  inline bool release(ClientSession<Memory> &client, std::uint64_t identity) noexcept {
    const auto removed = std::erase_if(client.attachments, [identity](const auto &attachment) {
      return attachment->pane_id == identity;
    });

    if (auto *pane = model_.panes.find(identity)) {
      pane->observers &= ~model_.clientBit(client.id);
      refreshAfterDetach(*pane);
    }

    return removed != 0;
  }

  inline void detachAll(ClientSession<Memory> &client) noexcept {
    for (const auto &attachment : client.attachments) {
      if (auto *pane = model_.panes.find(attachment->pane_id)) {
        pane->observers &= ~model_.clientBit(client.id);
        attachment->desktop.reset();
        refreshAfterDetach(*pane);
      }
    }

    if (client.workspace) {
      if (auto *workspace = model_.workspaces.find(*client.workspace)) {
        releaseGeometry(model_, client.id, *workspace);
      }
    }

    client.attachments.clear();
    client.workspace.reset();
  }

  inline void remove(std::uint64_t identity) noexcept {
    auto *pane = model_.panes.find(identity);
    if (pane == nullptr) {
      return;
    }

    for (auto *client : model_.clients.items()) {
      if (client != nullptr) {
        release(*client, identity);
      }
    }

    poller_.remove(pane->process->descriptor());
    if (pane->exit_status && !pane->exit_observed) {
      pane->observer->shellExit(*pane->exitCode());
      pane->exit_observed = true;
    }

    pane->observer->finishSession();
    pane->media->cancel();
    pane->observer->retired_next = std::move(model_.retired_observers);
    model_.retired_observers = pane->observer;
    ++model_.retired_observer_count;
    pane->media->retired_next = std::move(model_.retired_media);
    model_.retired_media = pane->media;
    ++model_.retired_media_count;
    model_.panes.erase(identity);
  }

  template <typename Observer = IgnorePaneInput>
  inline void input(ClientSession<Memory> &client, const PaneInput &request, const Observer &observe = {}) {
    if (client.attachment(request.pane_id) == nullptr) {
      return;
    }

    auto &pane = require(request.pane_id);
    if (pane.output_closed) {
      return;
    }

    if (admitInput(pane, request.bytes.size())) {
      pane.enqueueInput(request.bytes);
      observe(pane, request.bytes);
      pane.last_input = std::chrono::steady_clock::now();
      flushInput(pane);
    }

    recordInputOrigin(client, pane.id);
    ClipboardService{model_}.configure(pane);
  }

  inline bool admitInput(Pane<Memory> &pane, std::size_t bytes) {
    if (bytes <= Pane<Memory>::input_limit - pane.input.size()) {
      return true;
    }

    TELAR_DIAGNOSTIC(diagnostics::accumulate(pane.input_dropped_bytes, bytes));
    LimitService{model_}.report(LimitReach{.name = "panes.input_queue_capacity",
                                           .noun = "queued input bytes",
                                           .value = Pane<Memory>::input_limit,
                                           .requested = saturatedAdd(pane.input.size(), bytes)});
    return false;
  }

  inline void resize(ClientSession<Memory> &client, const PaneResize &request) {
    if (client.attachment(request.pane_id) == nullptr) {
      return;
    }

    auto &pane = require(request.pane_id);
    auto *workspace = model_.workspaces.find(pane.location.workspace.id);
    if (workspace == nullptr || !acquireGeometry(model_, client, *workspace)) {
      return;
    }

    pane.resize(request.size);
  }

  inline void flushInput(Pane<Memory> &pane) {
    if (pane.output_closed) {
      return;
    }
    if (pane.media->failed()) {
      failOutput(pane);
      return;
    }
    try {
      pane.terminal.resumeControl();
      pane.write();
      const bool needs_write = pane.hasInput();
      if (needs_write != pane.write_interest) {
        poller_.writeInterest(pane.process->descriptor(), eventToken(EventSource::pane, pane.event_identity), needs_write);
        pane.write_interest = needs_write;
      }
    } catch (const std::exception &) {
      failOutput(pane);
    }
  }

  inline void failOutput(Pane<Memory> &pane) noexcept {
    pane.terminal.abortControl();
    pane.media->cancel();
    pane.requestClose();
    pane.output_closed = true;
    poller_.remove(pane.process->descriptor());
  }

  inline void configureDesktop(ClientSession<Memory> &client, const ConfigurePaneDesktop &request) {
    auto &pane = requireGeneration(request.pane_id, request.pane_generation);
    auto *attachment = client.attachment(pane.id);
    if (attachment == nullptr || client.connection.closing) {
      throw RequestError{FailureCode::invalid_request, "Desktop state requires a live pane attachment"};
    }
    if (attachment->desktop == request) {
      return;
    }

    attachment->desktop = request;
    refreshDesktop(pane);
    flushInput(pane);
  }

  // Visibility is the union of explicit live reports. The oldest visible
  // reporter supplies theme facts; focus and the geometry lease cannot steal it.
  inline void refreshDesktop(Pane<Memory> &pane) {
    control::ClientFacts facts;
    const ConfigurePaneDesktop *theme = nullptr;
    std::uint64_t theme_client = UINT64_MAX;
    for (const auto *client : model_.clients.items()) {
      if (client == nullptr || client->connection.closing) {
        continue;
      }
      const auto *attachment = client->attachment(pane.id);
      if (attachment == nullptr || !attachment->desktop || attachment->desktop->pane_generation != pane.generation) {
        continue;
      }
      const auto &desktop = *attachment->desktop;
      facts.visible |= desktop.visible;
      facts.focused |= desktop.focused && desktop.visible;
      if (desktop.visible && client->id < theme_client) {
        theme_client = client->id;
        theme = &desktop;
      }
    }

    if (theme != nullptr) {
      facts.light = theme->light;
      const auto &previous = pane.desktop_theme;
      if (!previous || previous->foreground != theme->foreground || previous->background != theme->background || previous->palette != theme->palette || previous->cursor != theme->cursor) {
        pane.terminal.configureColors({theme->foreground, theme->background, theme->palette});
        pane.terminal.configureCursorColor(theme->cursor);
      }
      pane.desktop_theme = *theme;
    } else if (pane.desktop_theme) {
      pane.desktop_theme.reset();
      const auto *workspace = model_.workspaces.find(pane.location.workspace.id);
      const auto *owner = workspace != nullptr && workspace->geometry_client ? model_.clients.find(*workspace->geometry_client) : nullptr;
      pane.terminal.configureColors(owner != nullptr && !owner->connection.closing ? owner->colors : ConfigureTerminalColors{});
      pane.terminal.configureCursorColor(std::nullopt);
    }
    pane.terminal.configureClientFacts(facts);
    ClipboardService{model_}.configure(pane);
  }

  inline void configureColors(ClientSession<Memory> &client, const ConfigureTerminalColors &request) {
    if (client.colors.foreground == request.foreground && client.colors.background == request.background && client.colors.palette == request.palette) {
      return;
    }

    client.colors = request;
    for (auto *pane : model_.panes.items()) {
      const auto *workspace = pane == nullptr ? nullptr : model_.workspaces.find(pane->location.workspace.id);
      if (workspace != nullptr && workspace->geometry_client == client.id && !pane->desktop_theme) {
        pane->terminal.configureColors(request);
        flushInput(*pane);
      }
    }
  }

  inline void readText(ClientSession<Memory> &client, const ReadPane &request) {
    client.connection.defer(request);
  }

  inline void copySelection(ClientSession<Memory> &client, const CopySelection &request) {
    if (client.attachment(request.pane_id) == nullptr) {
      return;
    }

    auto &pane = require(request.pane_id);
    constexpr std::size_t clipboard_limit = 1024 * 1024;
    TextReader reader{memory_, pane.terminal, clipboard_limit};
    reader.copy(request);
    if (reader.truncated()) {
      throw RequestError{FailureCode::resource_limit, "Selection exceeds the clipboard limit"};
    }

    client.clipboard.replace(pane.id, reader.bytes());
  }

  template <typename Observer = IgnorePaneInput>
  inline void sendText(ClientSession<Memory> &client, const SendPaneText &request, std::string_view prefix = {}, const Observer &observe = {}) {
    auto &pane = requireGeneration(request.pane_id, request.pane_generation);
    if (pane.output_closed) {
      throw RequestError{FailureCode::pane_exited, "Pane process has exited"};
    }

    const auto text = std::span<const Byte>{reinterpret_cast<const Byte *>(request.text.data()), request.text.size()};
    const bool paste = request.mode == PaneTextMode::prompt && pane.terminal.mode(GHOSTTY_MODE_BRACKETED_PASTE);
    constexpr std::array<Byte, 6> paste_start{0x1b, '[', '2', '0', '0', '~'};
    constexpr std::array<Byte, 6> paste_end{0x1b, '[', '2', '0', '1', '~'};
    std::array<Byte, 128> encoded_enter;
    const auto enter = request.mode == PaneTextMode::raw ? std::span<const Byte>{} : pane.terminal.encodeKey(GHOSTTY_KEY_ENTER, 0, encoded_enter);
    const auto required = prefix.size() + text.size() + (paste ? paste_start.size() + paste_end.size() : 0) + (request.mode != PaneTextMode::raw ? enter.size() : 0);
    if (!admitInput(pane, required)) {
      std::array<char, 160> message;
      const auto length = std::snprintf(message.data(), message.size(), "the pane's input queue holds its limit of %zu bytes; the program in it is not reading input", Pane<Memory>::input_limit);
      client.connection.send(RequestFailed{.request_id = request.request_id,
                                           .code = FailureCode::resource_limit,
                                           .message = {message.data(), static_cast<std::size_t>(length)}});
      return;
    }

    const auto forward = [&](std::span<const Byte> bytes) {
      pane.enqueueInput(bytes);
      observe(pane, bytes);
    };
    if (paste) {
      forward(paste_start);
    }

    forward({reinterpret_cast<const Byte *>(prefix.data()), prefix.size()});
    forward(text);
    if (paste) {
      forward(paste_end);
    }
    if (request.mode != PaneTextMode::raw) {
      forward(enter);
    }

    if (request.mode != PaneTextMode::raw || request.text.find('\r') != std::string_view::npos) {
      pane.observer->noteInjectedSubmission();
    }

    pane.last_input = std::chrono::steady_clock::now();
    flushInput(pane);
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  inline void pasteClipboard(ClientSession<Memory> &client, const PastePaneClipboard &request) {
    auto &pane = requireGeneration(request.pane_id, request.pane_generation);
    if (!ClipboardService<Memory>::eligible(client, pane) || pane.output_closed) {
      throw RequestError{FailureCode::invalid_request, "Clipboard paste requires a live visible attachment"};
    }
    if (request.listing_only) {
      // A listing begun before a mode reset completes without reading text.
      if (pane.terminal.pasteEvents()) {
        if (!pane.terminal.clipboardControl().paste({client.id, client.generation}, request.primary, request.available)) {
          throw RequestError{FailureCode::resource_limit, "Clipboard response is pending"};
        }
        pane.terminal.resumeControl();
      }
    } else if (!request.text.empty()) {
      const bool bracketed = pane.terminal.mode(GHOSTTY_MODE_BRACKETED_PASTE);
      constexpr std::array<Byte, 6> start{0x1b, '[', '2', '0', '0', '~'};
      constexpr std::array<Byte, 6> end{0x1b, '[', '2', '0', '1', '~'};
      if (!admitInput(pane, request.text.size() + (bracketed ? start.size() + end.size() : 0))) {
        throw RequestError{FailureCode::resource_limit, "Paste exceeds available pane input capacity"};
      }
      if (bracketed) {
        pane.enqueueInput(start);
      }
      pane.enqueueInput(request.text);
      if (bracketed) {
        pane.enqueueInput(end);
      }
    }
    recordInputOrigin(client, pane.id);
    flushInput(pane);
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  inline void search(ClientSession<Memory> &client, const SearchPane &request) {
    auto &pane = require(request.pane_id);
    if (client.interactive && client.attachment(pane.id) == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "Pane is not attached"};
    }

    if (client.search) {
      client.connection.send(RequestFailed{.request_id = client.search->request_id,
                                           .code = FailureCode::resource_limit,
                                           .message = "Pane search superseded"});
    }
    client.search.emplace(request, pane.terminal.contentRevision());
  }

  inline bool advanceSearch(ClientSession<Memory> &client) {
    if (!client.search) {
      return false;
    }

    try {
      auto &pane = require(client.search->pane_id);
      if (client.search->advance(pane.terminal.handle(), pane.terminal.contentRevision())) {
        client.connection.send(client.search->result());
        client.search.reset();
      }
    } catch (const std::exception &) {
      client.connection.send(RequestFailed{.request_id = client.search->request_id,
                                           .code = FailureCode::resource_limit,
                                           .message = "Pane search stopped; retry"});
      client.search.reset();
    }

    return client.search.has_value();
  }

private:
  inline void recordInputOrigin(ClientSession<Memory> &client, std::uint64_t pane) noexcept {
    ++model_.input_sequence;
    if (model_.input_sequence == 0) {
      for (auto *session : model_.clients.items()) {
        if (session != nullptr) {
          session->last_input_sequence = 0;
        }
      }
      model_.input_sequence = 1;
    }

    client.last_input_pane = pane;
    client.last_input_sequence = model_.input_sequence;
  }

  struct Identity {
    std::uint64_t id;
    std::uint64_t generation;
  };

  inline Identity allocateIdentity(std::uint64_t restored_identity = 0) {
    if (model_.panes.size() + std::max(model_.retired_observer_count, model_.retired_media_count) >= pane_capacity) {
      throw RequestError{FailureCode::resource_limit, "Pane capacity is occupied by active processes or pending observations"};
    }
    if (model_.next_pane_generation == 0 || model_.next_pane_generation == UINT64_MAX || (restored_identity == 0 && model_.panes.nextCounter() == 0)) {
      throw RequestError{FailureCode::spawn_failed, "could not start the command"};
    }

    const auto identity = restored_identity == 0 ? model_.panes.nextId() : restored_identity;
    model_.panes.advanceCounter(identity + 1);
    return {identity, model_.next_pane_generation++};
  }

  inline Pane<Memory> &launchPrepared(Command<Memory> &command, TabLocation location, TerminalSize size, Identity identity) {
    const auto setIdentity = [&](std::string_view name, std::uint64_t value) {
      std::array<char, 32> text{};
      const auto converted = std::to_chars(text.data(), text.data() + text.size(), value);
      command.setEnvironment(name, {text.data(), converted.ptr});
    };
    setIdentity("TELAR_PANE_ID", identity.id);
    setIdentity("TELAR_PANE_GENERATION", identity.generation);
    setIdentity("TELAR_WORKSPACE_ID", location.workspace.id);
    setIdentity("TELAR_TAB_ID", location.tab_id);
    command.setEnvironment("TELAR_SOCKET_PATH", socket_path_);
    if (!model_.cli_executable.empty()) {
      command.setEnvironment("TELAR_BIN_PATH", model_.cli_executable);
    }
    proxy_.apply(command);
    auto pane = makeOwned<Pane<Memory>>(memory_, memory_, identity.id, location, command, PaneLaunch{size, model_.media_budget, model_.graphics_limits});
    TELAR_DIAGNOSTIC(pane->counters = &model_.metrics.panes);
    pane->generation = identity.generation;
    pane->terminal.controlPolicy() = control_policy_;
    const auto *workspace = model_.workspaces.find(location.workspace.id);
    const HistorySession session{.id = pane->history_session, .pane = pane->id, .location = location, .started_at_ms = ObservationTime::now().milliseconds, .workspace_path = workspace == nullptr ? std::string_view{} : std::string_view{workspace->path}, .shell = command.arguments().front()};
    auto &result = *pane;
    auto phase = LaunchPhase::pane_registration;
    bool registered = false;
    try {
      if (workspace != nullptr && workspace->geometry_client) {
        if (const auto *owner = model_.clients.find(*workspace->geometry_client)) {
          pane->terminal.configureColors(owner->colors);
        }
      }

      pane->observer->configureHistory(session, model_.capture_output);
      result.event_identity = model_.panes.insert(identity.id, std::move(pane));
      registered = true;
      if (result.event_identity > maximum_event_identity) {
        throw RequestError{FailureCode::resource_limit, "Pane event identity space exhausted"};
      }

      phase = LaunchPhase::output_actor;
      poller_.watch(result.process->descriptor(), eventToken(EventSource::pane, result.event_identity));
    } catch (const std::exception &error) {
      history_.recordHistory(HistoryEventView{.kind = HistoryEventKind::launch_failed, .session = session, .finished_at_ms = ObservationTime::now().milliseconds, .failure = {identity.generation, phase, launchFailureCause(error)}});
      if (registered) {
        poller_.remove(result.process->descriptor());
        model_.panes.erase(identity.id);
      }

      throw;
    }

    return result;
  }

  inline void refreshAfterDetach(Pane<Memory> &pane) noexcept {
    try {
      refreshDesktop(pane);
      flushInput(pane);
    } catch (...) {
      pane.requestClose();
    }
  }

  static constexpr std::size_t pane_capacity = 256;

  Memory &memory_;
  RuntimeModel<Memory> &model_;
  Poller &poller_;
  History &history_;
  std::string_view socket_path_;
  ProxyClientConfiguration proxy_;
  control::Policy control_policy_;
};

}
}

// Interface: runtime/execution_service.cppm
export {
namespace telar::runtime {

template <Allocator Memory, EventLoop Poller>
class ExecutionService {
public:
  inline explicit ExecutionService(Memory &memory, RuntimeModel<Memory> &model, Poller &poller, LimitService<Memory> &limits)
      : memory_(memory),
        model_(model),
        poller_(poller),
        limits_(limits),
        executions_(memory) {}

  inline ~ExecutionService() {
    for (auto *execution : executions_.items()) {
      if (execution != nullptr) {
        unwatch(*execution);
      }
    }
  }

  inline void request(ClientSession<Memory> &client, const ExecutionRequest &request) {
    TELAR_TRACE("execution.request");
    if (request.action == ExecutionAction::list) {
      list(client, request);
      return;
    }

    auto *execution = find(request.execution_id);
    const bool started = execution == nullptr;
    if (started) {
      if (request.action != ExecutionAction::start) {
        throw RequestError{FailureCode::invalid_request, "ExecutionNotFound"};
      }

      execution = &start(client.id, request);
    }

    if (request.action == ExecutionAction::start && !execution->matches(request)) {
      throw RequestError{FailureCode::invalid_request, "ExecutionIdentityConflict"};
    }

    switch (request.action) {
    case ExecutionAction::input:
      receiveInput(*execution, client.id, request);
      break;
    case ExecutionAction::eof:
      execution->eof = true;
      break;
    case ExecutionAction::cancel:
      if (execution->process) {
        execution->process->signal(SIGKILL);
      }
      break;
    case ExecutionAction::forget:
      if (execution->state != ExecutionState::exited && execution->state != ExecutionState::failed) {
        throw RequestError{FailureCode::invalid_request, "ExecutionStillRunning"};
      }
      break;
    default:
      break;
    }

    flushInput(*execution);
    send(client, *execution, request, started);
    if (request.action == ExecutionAction::forget) {
      unwatch(*execution);
      executions_.erase(execution->token);
    }
  }

  inline void event(const Event &event) {
    auto *execution = executions_.find(eventIdentity(event.token));
    if (execution == nullptr || !execution->process) {
      return;
    }

    auto &process = *execution->process;
    if (eventSource(event.token) == EventSource::execution_input) {
      if (event.descriptor == process.input()) {
        flushInput(*execution);
      }
      return;
    }

    const bool standard_output = eventSource(event.token) == EventSource::execution_output;
    const int descriptor = standard_output ? process.output() : process.error();
    if (event.descriptor != descriptor) {
      return;
    }

    std::array<Byte, 16 * 1024> bytes;
    const auto count = ::read(descriptor, bytes.data(), bytes.size());
    if (count > 0) {
      (standard_output ? execution->output : execution->error).append(std::span{bytes}.first(static_cast<std::size_t>(count)));
      return;
    }

    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
      return;
    }

    poller_.remove(descriptor);
    if (standard_output) {
      process.closeOutput();
    } else {
      process.closeError();
    }
  }

  inline bool refresh() noexcept {
    bool running = false;
    for (auto *execution : executions_.items()) {
      if (execution == nullptr || execution->state != ExecutionState::running) {
        continue;
      }

      auto &process = *execution->process;
      if (process.output() >= 0 || process.error() >= 0) {
        running = true;
        continue;
      }

      const auto status = process.reap();
      if (!status) {
        running = true;
        continue;
      }

      execution->exit_code = WIFEXITED(*status) ? WEXITSTATUS(*status) : 128 + WTERMSIG(*status);
      execution->state = ExecutionState::exited;
      execution->eof = true;
      execution->input_owner.reset();
      closeInput(*execution);
    }

    releaseAdministration();
    return running;
  }

  inline void disconnect(std::uint64_t client_id) {
    for (auto *execution : executions_.items()) {
      if (execution != nullptr && execution->input_owner == client_id) {
        execution->input_owner.reset();
        execution->eof = true;
        flushInput(*execution);
      }
    }
  }

private:
  inline Execution<Memory> *find(std::uint64_t identity) const noexcept {
    for (auto *execution : executions_.items()) {
      if (execution != nullptr && execution->id == identity) {
        return execution;
      }
    }

    return nullptr;
  }

  inline Execution<Memory> &start(std::uint64_t client_id, const ExecutionRequest &request) {
    if (executions_.size() == capacity) {
      limits_.report(LimitReach{.name = "executions.capacity", .noun = "retained executions", .value = capacity, .requested = capacity + 1});
      throw RequestError{FailureCode::resource_limit, "ExecutionLimitReached"};
    }

    const auto token = executions_.nextId();
    const auto workspace_id = request.workspace_id == 0 ? administration() : request.workspace_id;
    const auto *workspace = model_.workspaces.find(workspace_id);
    if (workspace == nullptr) {
      throw RequestError{FailureCode::invalid_request, "WorkspaceNotFound"};
    }

    const std::string_view cwd = request.cwd.empty() ? std::string_view{workspace->path} : request.cwd;
    auto execution = makeOwned<Execution<Memory>>(memory_, memory_, token, request, workspace_id, cwd);
    execution->input_owner = request.stdin_open ? std::optional{client_id} : std::nullopt;
    try {
      if (execution->process) {
        poller_.watch(execution->process->output(), eventToken(EventSource::execution_output, token));
        poller_.watch(execution->process->error(), eventToken(EventSource::execution_error, token));
      }
    } catch (...) {
      unwatch(*execution);
      throw;
    }

    auto *result = execution.get();
    executions_.insert(token, std::move(execution));
    return *result;
  }

  inline std::uint64_t administration() {
    if (model_.workspaces.find(administration_) != nullptr) {
      return administration_;
    }

    const char *home = std::getenv("HOME");
    if (home == nullptr || home[0] != '/') {
      throw RequestError{FailureCode::invalid_request, "DestinationHomeUnavailable"};
    }

    const auto identity = model_.workspaces.nextId();
    auto workspace = makeOwned<Workspace<Memory>>(memory_, memory_, identity, home, "Administration");
    model_.workspaces.insert(identity, std::move(workspace));
    administration_ = identity;
    ++model_.workspace_revision;
    return identity;
  }

  inline void releaseAdministration() noexcept {
    if (administration_ == 0) {
      return;
    }

    for (const auto *execution : executions_.items()) {
      if (execution != nullptr && execution->workspace == administration_ && execution->state == ExecutionState::running) {
        return;
      }
    }

    const auto *workspace = model_.workspaces.find(administration_);
    if (workspace != nullptr && workspace->tabs.empty()) {
      model_.workspaces.erase(administration_);
      ++model_.workspace_revision;
    }

    administration_ = 0;
  }

  inline void receiveInput(Execution<Memory> &execution, std::uint64_t client_id, const ExecutionRequest &request) {
    if (execution.input_owner != client_id) {
      throw RequestError{FailureCode::invalid_request, "ExecutionInputOwned"};
    }

    if (request.input_offset > execution.input_written) {
      throw RequestError{FailureCode::invalid_request, "ExecutionInputGap"};
    }

    if (request.input_offset < execution.input_written) {
      if (request.bytes.size() > execution.input_written - request.input_offset) {
        throw RequestError{FailureCode::invalid_request, "ExecutionInputOverlap"};
      }
      return;
    }

    if (execution.eof) {
      throw RequestError{FailureCode::invalid_request, "ExecutionInputClosed"};
    }

    if (request.bytes.size() > Execution<Memory>::input_capacity - execution.input.size()) {
      throw RequestError{FailureCode::invalid_request, "ExecutionBusy"};
    }

    execution.input.append(request.bytes);
    execution.input_written += request.bytes.size();
  }

  inline void flushInput(Execution<Memory> &execution) {
    if (!execution.process || execution.process->input() < 0) {
      return;
    }

    if (!execution.input.empty()) {
      const auto bytes = execution.input.readable();
      const auto count = ::write(execution.process->input(), bytes.data(), bytes.size());
      if (count > 0) {
        execution.input.consume(static_cast<std::size_t>(count));
      } else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        execution.eof = true;
        execution.input.clear();
      }
    }

    if (execution.eof && execution.input.empty()) {
      closeInput(execution);
      return;
    }

    const bool needed = !execution.input.empty();
    if (needed != execution.write_interest) {
      poller_.writeInterest(execution.process->input(), eventToken(EventSource::execution_input, execution.token), needed);
      execution.write_interest = needed;
    }
  }

  inline void closeInput(Execution<Memory> &execution) noexcept {
    if (execution.process && execution.process->input() >= 0) {
      poller_.remove(execution.process->input());
      execution.process->closeInput();
      execution.write_interest = false;
    }
  }

  inline void unwatch(Execution<Memory> &execution) noexcept {
    if (!execution.process) {
      return;
    }

    for (const int descriptor : {execution.process->input(), execution.process->output(), execution.process->error()}) {
      if (descriptor >= 0) {
        poller_.remove(descriptor);
      }
    }
  }

  // The reply to the request that started an execution says `starting`, as
  // Zig's does before its spawning thread confirms the child; later replies
  // report it running.
  inline void send(ClientSession<Memory> &client, const Execution<Memory> &execution, const ExecutionRequest &request, bool started = false) {
    const auto state = started && execution.state == ExecutionState::running ? ExecutionState::starting : execution.state;
    std::array<Byte, 4096> output;
    std::array<Byte, 4096> error;
    const auto output_offset = std::max(request.stdout_offset, execution.output.retainedOffset());
    const auto error_offset = std::max(request.stderr_offset, execution.error.retainedOffset());
    // Output older than the retained megabyte is gone; Zig reports that limit.
    if (output_offset != request.stdout_offset || error_offset != request.stderr_offset) {
      limits_.report(LimitReach{.name = "executions.retained_bytes", .noun = "bytes per stream", .value = Execution<Memory>::retained_capacity, .requested = std::max(execution.output.total(), execution.error.total())});
    }

    client.connection.send(ExecutionReply{
        .request_id = request.request_id,
        .execution_id = execution.id,
        .workspace_id = execution.workspace,
        .stdout_offset = output_offset,
        .stderr_offset = error_offset,
        .stdout_total = execution.output.total(),
        .stderr_total = execution.error.total(),
        .input_offset = execution.input_written,
        .input_available = Execution<Memory>::input_capacity - execution.input.size(),
        .state = state,
        .exit_code = execution.exit_code,
        .stdin_open = !execution.eof,
        .failure = {reinterpret_cast<const Byte *>(execution.failure_name.data()), execution.failure_name.size()},
        .stdout_bytes = execution.output.read(output_offset, output),
        .stderr_bytes = execution.error.read(error_offset, error),
    });
  }

  inline void list(ClientSession<Memory> &client, const ExecutionRequest &request) {
    const Execution<Memory> *selected = nullptr;
    for (const auto *execution : executions_.items()) {
      if (execution != nullptr && execution->id > request.execution_id && (selected == nullptr || execution->id < selected->id)) {
        selected = execution;
      }
    }

    ExecutionReply reply{.request_id = request.request_id,
                         .state = ExecutionState::exited};
    if (selected != nullptr) {
      reply.execution_id = selected->id;
      reply.workspace_id = selected->workspace;
      reply.state = selected->state;
      reply.exit_code = selected->exit_code;
    }

    client.connection.send(reply);
  }

  static constexpr std::size_t capacity = 32;
  Memory &memory_;
  RuntimeModel<Memory> &model_;
  Poller &poller_;
  LimitService<Memory> &limits_;
  SlotStore<Execution<Memory>, capacity, Memory> executions_;
  std::uint64_t administration_ = 0;
};

}
}
