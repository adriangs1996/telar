#pragma once

#include "../model/runtime_model.hpp"
#include "../platform/event_loop.hpp"
#include "../platform/event_token.hpp"
#include "../proxy/client_configuration.hpp"
#include "../terminal/text_reader.hpp"
#include "geometry_lease.hpp"
#include "clipboard_service.hpp"
#include "launch_failure_cause.hpp"
#include "limit_service.hpp"
#include "pane_launch_options.hpp"
#include "request_error.hpp"
#include "workspace_notifications.hpp"
#include <charconv>
#include <sys/wait.h>

namespace telar::runtime {

struct IgnorePaneInput {
  template <typename PaneType>
  void operator()(const PaneType &, std::span<const Byte>) const noexcept {}
};

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class PaneService {
public:
  explicit PaneService(Memory &memory, RuntimeModel<Memory> &model, Poller &poller, PaneLaunchOptions options, History &history = discarded_history)
      : memory_(memory),
        model_(model),
        poller_(poller),
        history_(history),
        socket_path_(options.socket),
        proxy_(options.proxy),
        control_policy_(options.control_policy) {}

  Pane<Memory> &require(std::uint64_t identity) const {
    auto *pane = model_.panes.find(identity);
    if (pane == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "Pane does not exist"};
    }

    return *pane;
  }

  Pane<Memory> &requireGeneration(std::uint64_t identity, std::uint64_t generation) const {
    auto &pane = require(identity);
    if (generation != 0 && pane.generation != generation) {
      throw RequestError{FailureCode::pane_not_found, "Pane generation no longer exists"};
    }

    return pane;
  }

  Pane<Memory> &launch(const Launch &launch, TabLocation location, TerminalSize size) {
    const auto identity = allocateIdentity();
    if (launch.environment_mode != EnvironmentMode::inherit_runtime || !launch.environment.empty()) {
      throw RequestError{FailureCode::invalid_request, "custom pane environment is not supported"};
    }

    Command command{memory_, launch};
    return launchPrepared(command, location, size, identity);
  }

  Pane<Memory> &launch(Command<Memory> &command, TabLocation location, TerminalSize size, std::uint64_t restored_identity = 0) {
    return launchPrepared(command, location, size, allocateIdentity(restored_identity));
  }

  Attachment<Memory> &attach(ClientSession<Memory> &client, Pane<Memory> &pane, TerminalSize size) {
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

  void detach(ClientSession<Memory> &client, std::uint64_t identity) noexcept {
    if (release(client, identity) && client.attachments.empty()) {
      detachAll(client);
    }
  }

  bool release(ClientSession<Memory> &client, std::uint64_t identity) noexcept {
    const auto removed = std::erase_if(client.attachments, [identity](const auto &attachment) {
      return attachment->pane_id == identity;
    });

    if (auto *pane = model_.panes.find(identity)) {
      pane->observers &= ~model_.clientBit(client.id);
      refreshAfterDetach(*pane);
    }

    return removed != 0;
  }

  void detachAll(ClientSession<Memory> &client) noexcept {
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

  void remove(std::uint64_t identity) noexcept {
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
  void input(ClientSession<Memory> &client, const PaneInput &request, const Observer &observe = {}) {
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

  bool admitInput(Pane<Memory> &pane, std::size_t bytes) {
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

  void resize(ClientSession<Memory> &client, const PaneResize &request) {
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

  void flushInput(Pane<Memory> &pane) {
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

  void failOutput(Pane<Memory> &pane) noexcept {
    pane.terminal.abortControl();
    pane.media->cancel();
    pane.requestClose();
    pane.output_closed = true;
    poller_.remove(pane.process->descriptor());
  }

  void configureDesktop(ClientSession<Memory> &client, const ConfigurePaneDesktop &request) {
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
  void refreshDesktop(Pane<Memory> &pane) {
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

  void configureColors(ClientSession<Memory> &client, const ConfigureTerminalColors &request) {
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

  void readText(ClientSession<Memory> &client, const ReadPane &request) {
    client.connection.defer(request);
  }

  void copySelection(ClientSession<Memory> &client, const CopySelection &request) {
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
  void sendText(ClientSession<Memory> &client, const SendPaneText &request, std::string_view prefix = {}, const Observer &observe = {}) {
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

  void pasteClipboard(ClientSession<Memory> &client, const PastePaneClipboard &request) {
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

  void search(ClientSession<Memory> &client, const SearchPane &request) {
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

  bool advanceSearch(ClientSession<Memory> &client) {
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
  void recordInputOrigin(ClientSession<Memory> &client, std::uint64_t pane) noexcept {
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

  Identity allocateIdentity(std::uint64_t restored_identity = 0) {
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

  Pane<Memory> &launchPrepared(Command<Memory> &command, TabLocation location, TerminalSize size, Identity identity) {
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
    if (!model_.executable_path.empty()) {
      command.setEnvironment("TELAR_BIN_PATH", model_.executable_path);
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

  void refreshAfterDetach(Pane<Memory> &pane) noexcept {
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
