module;
#include "telar_platform/trace_macro.hpp"

#include "telar_base/diagnostics/config.hpp"

module telar.runtime.core.delivery.client_delivery;

import telar.ghostty.vt;
import telar.sys.process;

import telar.runtime.terminal.control;
import telar.render.document;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.runtime.diagnostics.line;
import telar.platform.paths;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // Whether the wire takes `text` as display text: valid UTF-8 without control bytes.
    bool displayable(std::string_view text) noexcept {
      constexpr unsigned char first_printable = 0x20;
      constexpr unsigned char delete_byte = 0x7f;

      return inspectUtf8(text) == Utf8Validation::valid && std::ranges::none_of(text, [](char character) {
        const auto byte = static_cast<unsigned char>(character);

        return byte < first_printable || byte == delete_byte;
      });
    }

    // The command blocks of a pane with an integrated shell; null for every other pane.
    const auto* commandBlocks(const Pane& pane) noexcept {
      const auto* terminal = pane.template as<TerminalBody>();

      return terminal == nullptr || !terminal->blocks ? nullptr : &*terminal->blocks;
    }

    // What an editor pane titles itself, which names the file its focused window shows, and the
    // count of the times it changed; nothing for any other pane, whose title is its program's to
    // set as it likes.
    ProgramTitle documentOf(const Pane& pane) noexcept {
      return pane.template as<NvimBody>() == nullptr ? ProgramTitle{} : programTitle(pane);
    }

    // What a client that heard the pane's facts now has heard: the pane, where it is, and the
    // count of the changes to its command, its directory, its repository and its document. Each
    // count only grows, so their sum moves when any of them does.
    ClientSession::FactsStamp factsStamp(const Pane& pane) noexcept {
      const auto* blocks = commandBlocks(pane);

      return {.pane = pane.id, .generation = pane.generation, .workspace = pane.location.workspace.id, .revision = pane.cwd_revision + pane.git_revision + documentOf(pane).revision + (blocks == nullptr ? 0 : blocks->commandRevision())};
    }

    // Whether `cwd` is the workspace's directory, or lies in it.
    bool worksIn(std::string_view cwd, const Workspace* workspace) {
      if (workspace == nullptr || workspace->path.view().empty() || !cwd.starts_with(workspace->path.view())) {
        return false;
      }

      const auto rest = cwd.substr(workspace->path.view().size());

      return rest.empty() || rest.front() == '/' || workspace->path.view().ends_with('/');
    }

    // The facts of `pane`, which view it and `directory`, its label. Text the wire would refuse
    // is left out: every client that lists the panes is sent this, and what one pane's shell
    // printed must not end their delivery.
    tbc::val_a<PaneFacts> describe(tbc::ref_a<Pane> pane, const Workspace* workspace, tbc::val_a<std::string_view> directory) {
      PaneFacts facts{.pane_id = pane.id, .pane_generation = pane.generation, .in_workspace = worksIn(pane.cwd, workspace)};

      if (displayable(directory)) {
        facts.directory = directory;
      }

      const auto* blocks = commandBlocks(pane);
      const auto* last = blocks == nullptr || !blocks->latest() ? nullptr : &*blocks->latest();
      const auto command = last == nullptr ? std::string_view{} : utf8Prefix(last->command.view(), max_pane_command_bytes);
      if (last != nullptr && !command.empty() && displayable(command)) {
        const auto& latest = *last;
        const bool running = latest.state == CommandBlockState::running || latest.state == CommandBlockState::session;

        facts.command_state = running ? PaneCommandState::running : PaneCommandState::finished;
        facts.command = command;
        facts.command_truncated = latest.truncated || command.size() < latest.command.view().size();
        facts.duration_ms = running ? 0 : latest.duration_ms;
        // A command a signal stopped keeps the status its shell reported, 130 or 141; one cut short
        // otherwise, by the shell going away, reported none.
        const bool interrupted = latest.state == CommandBlockState::interrupted && latest.status != 0;
        if (latest.state == CommandBlockState::succeeded || latest.state == CommandBlockState::failed || interrupted) {
          facts.exit_code = latest.status;
        }
      }

      if (const auto branch = utf8Prefix(pane.git.branch.view(), max_pane_branch_bytes); pane.git.repository && displayable(branch)) {
        facts.branch = branch;
        facts.dirty = !branch.empty() && pane.git.changes_known && (pane.git.staged != 0 || pane.git.unstaged != 0 || pane.git.conflicted != 0);
      }

      if (const auto document = utf8Prefix(documentOf(pane).text, max_pane_document_bytes); displayable(document)) {
        facts.document = document;
      }

      return facts;
    }

    // Tells the client that held the pane's clipboard request that it is withdrawn; the client being gone
    // withdraws it too.
    void sendCancellation(ClientSession* client, const control::Clipboard::Cancellation& cancellation, control::Clipboard& clipboard) {
      if (client == nullptr || client->generation != cancellation.route.generation || client->connection.flags().closing) {
        clipboard.cancelled();
        return;
      }

      try {
        client->connection.send(CancelClipboardDesktop{cancellation.ticket});
        clipboard.cancelled();
      } catch (const ResponseQueueFull&) { // NOLINT(bugprone-empty-catch): the cancellation stays pending and is sent again on the next turn
      } catch (const std::bad_alloc&) {    // NOLINT(bugprone-empty-catch): the cancellation stays pending and is sent again on the next turn
      }
    }

    // Sends the routed client the pane's request, or once it is announced, the execution it settled on.
    void sendRequest(ClientSession& client, PaneRef<TerminalBody> pane) {
      auto& clipboard = pane.body.terminal.clipboardControl();

      try {
        if (const auto request = clipboard.request(pane.core.id, pane.core.generation)) {
          client.connection.send(*request);
          clipboard.announced();
        } else {
          clipboard.expire(std::chrono::steady_clock::now());
          if (const auto execution = clipboard.execution()) {
            client.connection.send(*execution);
            clipboard.committed();
          }
        }
      } catch (const ResponseQueueFull&) { // NOLINT(bugprone-empty-catch): the owned request survives queue pressure until its deadline
      } catch (const std::bad_alloc&) {    // NOLINT(bugprone-empty-catch): the deadline also bounds retries under the runtime memory budget
      }
    }

  }

  bool ClipboardService::eligible(const ClientSession& client, PaneRef<const TerminalBody> pane) noexcept {
    const auto* attachment = client.attachment(pane.core.id);

    return !pane.core.close_requested && !pane.core.output_closed && client.role == ClientRole::interactive && !client.connection.flags().closing && attachment != nullptr && attachment->desktop && attachment->desktop->pane_generation == pane.core.generation && attachment->desktop->visible && attachment->desktop->clipboard;
  }

  void ClipboardService::configure(const ClientStore& clients, PaneRef<TerminalBody> pane) {
    ds::Array<control::ClipboardRoute, control::ClipboardGrants::capacity> routes;
    std::size_t count = 0;
    const ClientSession* preferred = nullptr;

    for (const auto* client : clients.items()) {
      if (client == nullptr || !eligible(*client, pane)) {
        continue;
      }

      if (count == routes.size()) {
        break;
      }

      routes.atMut(count++) = {.client = client->id, .generation = client->generation};
      if (preferred == nullptr || precedes(*client, *preferred, pane.core.id)) {
        preferred = client;
      }
    }

    pane.body.terminal.clipboardControl().routes(std::span{routes}.first(count), preferred != nullptr ? ds::Option{control::ClipboardRoute{.client = preferred->id, .generation = preferred->generation}} : ds::none);
  }

  bool ClipboardService::advance(ClientStore& clients, PaneRef<TerminalBody> pane, std::chrono::steady_clock::time_point now) {
    auto& clipboard = pane.body.terminal.clipboardControl();

    clipboard.expire(now);
    if (const auto cancellation = clipboard.cancellation()) {
      sendCancellation(clients.find(cancellation->route.client), *cancellation, clipboard);
    }

    const auto route = clipboard.route();
    if (route) {
      auto* client = clients.find(route->client);
      if (client == nullptr || client->generation != route->generation || !eligible(*client, pane)) {
        configure(clients, pane);
      } else {
        sendRequest(*client, pane);
      }
    }

    // Reached again: configuring the pane may have borrowed it whole.
    if (pane.body.terminal.clipboardControl().hasReply()) {
      pane.body.resumeControl();
      return true;
    }

    return false;
  }

  tbc::val_a<ds::Option<PaneRef<TerminalBody>>> ClipboardService::complete(tbc::mut_a<PaneStore> panes, ClientSession& sender, const CompleteClipboardDesktop& completion) {
    auto pane = asTerminal(findPane(panes, {.id = completion.ticket.pane_id, .generation = completion.ticket.pane_generation}));
    if (!pane || sender.generation != completion.ticket.client_generation || !eligible(sender, *pane)) {
      return ds::none;
    }

    pane.getMut().body.terminal.clipboardControl().expire(std::chrono::steady_clock::now());
    if (!pane.getMut().body.terminal.clipboardControl().complete({.client = sender.id, .generation = sender.generation}, completion)) {
      return ds::none;
    }

    pane.getMut().body.resumeControl();
    return *pane;
  }

  bool ClipboardService::precedes(const ClientSession& candidate, const ClientSession& current, std::uint64_t pane) noexcept {
    const bool candidate_focus = candidate.attachment(pane)->desktop->focused;
    const bool current_focus = current.attachment(pane)->desktop->focused;
    if (candidate_focus != current_focus) {
      return candidate_focus;
    }

    const auto candidate_input = candidate.last_input_pane == pane ? candidate.last_input_sequence : 0;
    const auto current_input = current.last_input_pane == pane ? current.last_input_sequence : 0;

    return candidate_input != current_input ? candidate_input > current_input : candidate.id < current.id;
  }

  AttachmentDelivery::AttachmentDelivery(const RuntimeModel& model, const ClientSession& client) { // NOLINT(cppcoreguidelines-pro-type-member-init): a slot is read only where occupied_ marks it written, so zeroing every slot on each write is work no read needs
    for (std::size_t index = 0; index < client.attachments.size(); ++index) {
      const auto& attachment = *client.attachments[index];
      if (model.panes.find(attachment.pane_id) != nullptr && !attachment.exit_sent) {
        slots_.atMut(attachment.slot) = {.index = static_cast<std::uint8_t>(index), .cells_current = false};
        occupied_ |= std::uint64_t{1} << attachment.slot;
      }
    }
  }

  bool AttachmentDelivery::prepare(RuntimeModel& model, ClientSession& client, DeliveryLane lane, Clock::time_point now, std::chrono::nanoseconds& timeout) {
    const auto start = client.next_attachment;
    auto candidates = std::rotr(occupied_, static_cast<int>(start));

    while (candidates != 0) {
      const auto slot = (start + static_cast<std::size_t>(std::countr_zero(candidates))) % ClientSession::attachment_capacity;

      candidates &= candidates - 1;
      auto& attachment = client.attachments.atMut(slots_[slot].index).getMut();
      auto* found = model.panes.find(attachment.pane_id);
      if (found == nullptr) {
        continue;
      }

      Output output{.connection = client.connection, .completing_exit = client.completing_exit, .frame_interval = client.frame_interval, .metrics = model.metrics, .editor_frames = model.editor_frames, .now = now, .timeout = timeout};
      bool prepared = false;

      // Each kind of pane fills the lanes it has something for.
      visitPaneAs(*found, [&](auto pane) {
        prepared = prepare(output, attachment, pane, lane);
      });

      if (prepared) {
        client.next_attachment = (slot + 1) % ClientSession::attachment_capacity;
        return true;
      }
    }

    return false;
  }

  bool AttachmentDelivery::prepare(Output& output, Attachment& attachment, PaneRef<NvimBody> pane, DeliveryLane lane) {
    switch (lane) {
    case DeliveryLane::cells:
      return editorFrame(output, attachment, pane);
    case DeliveryLane::cwd:
      return metadata(output.connection, attachment.cwd_revision, pane.core.cwd_revision + 1, PaneCwd{.pane_id = pane.core.id, .cwd = pane.core.cwd});
    case DeliveryLane::foreground:
      return metadata(output.connection, attachment.foreground_revision, pane.core.foreground_revision, PaneForeground{.pane_id = pane.core.id, .name = pane.core.foreground.view()});
    case DeliveryLane::title: {
      const auto title = programTitle(pane.core);

      // An attachment starts at revision one, and a screen that was told no title at zero.
      return metadata(output.connection, attachment.title_revision, title.revision + 1, PaneTitle{.pane_id = pane.core.id, .title = title.text});
    }
    case DeliveryLane::exit:
      return exit(output, attachment, pane.core, attachment.editor_sent == attachment.editor_seen);
    case DeliveryLane::scrollback:
    case DeliveryLane::progress:
    case DeliveryLane::shell:
    case DeliveryLane::git:
    case DeliveryLane::blocks:
    case DeliveryLane::graphics:
    case DeliveryLane::document:
    case DeliveryLane::stopping:
    case DeliveryLane::management:
    case DeliveryLane::resync:
    case DeliveryLane::clipboard:
    case DeliveryLane::layout:
    case DeliveryLane::proxy:
    case DeliveryLane::agents:
    case DeliveryLane::metrics:
    case DeliveryLane::workspaces:
    case DeliveryLane::panes:
    case DeliveryLane::observation:
    case DeliveryLane::count:
      return false;
    }

    return false;
  }

  bool AttachmentDelivery::prepare(Output& output, Attachment& attachment, PaneRef<ExplorerBody> pane, DeliveryLane lane) {
    switch (lane) {
    case DeliveryLane::foreground:
      return metadata(output.connection, attachment.foreground_revision, pane.core.foreground_revision, PaneForeground{.pane_id = pane.core.id, .name = pane.core.foreground.view()});
    case DeliveryLane::exit:
      return exit(output, attachment, pane.core, true);
    case DeliveryLane::cells:
      // It has no cells to send, so the client has all of them.
      slots_.atMut(attachment.slot).cells_current = true;
      return false;
    case DeliveryLane::cwd:
      return metadata(output.connection, attachment.cwd_revision, pane.core.cwd_revision + 1, PaneCwd{.pane_id = pane.core.id, .cwd = pane.core.cwd});
    case DeliveryLane::title:
    case DeliveryLane::scrollback:
    case DeliveryLane::progress:
    case DeliveryLane::shell:
    case DeliveryLane::git:
    case DeliveryLane::blocks:
    case DeliveryLane::graphics:
    case DeliveryLane::document:
    case DeliveryLane::stopping:
    case DeliveryLane::management:
    case DeliveryLane::resync:
    case DeliveryLane::clipboard:
    case DeliveryLane::layout:
    case DeliveryLane::proxy:
    case DeliveryLane::agents:
    case DeliveryLane::metrics:
    case DeliveryLane::workspaces:
    case DeliveryLane::panes:
    case DeliveryLane::observation:
    case DeliveryLane::count:
      return false;
    }

    return false;
  }

  bool AttachmentDelivery::editorFrame(Output& output, Attachment& attachment, PaneRef<const NvimBody> pane) {
    const auto& screen = pane.body.editor.screen();

    // One frame is out at a time: the client says when it applied it. A screen in the middle of
    // a redraw shows a state Neovim never meant to be seen, so it waits for the flush.
    if (attachment.editor_sent != attachment.editor_seen || !screen.settled()) {
      return false;
    }

    if (!NvimFrames::pending(screen, attachment.editor_seen)) {
      slots_.atMut(attachment.slot).cells_current = true;
      return editorPrompt(output.connection, attachment, pane);
    }

    TELAR_TRACE("runtime.publishEditorFrame");
    auto& frames = output.editor_frames;

    frames.begin(screen, {.pane_id = pane.core.id, .seen = attachment.editor_seen});
    for (auto grid = frames.next(screen); !grid.empty(); grid = frames.next(screen)) {
      output.connection.sendPayload(grid);
    }

    // Each native surface that changed, to take effect with the grids.
    if (const auto cmdline = frames.cmdline(screen); !cmdline.empty()) {
      output.connection.sendPayload(cmdline);
    }

    if (const auto menu = frames.popupMenu(screen); !menu.empty()) {
      output.connection.sendPayload(menu);
    }

    if (const auto messages = frames.messageList(screen); !messages.empty()) {
      output.connection.sendPayload(messages);
    }

    if (const auto tabs = frames.tabLine(screen); !tabs.empty()) {
      output.connection.sendPayload(tabs);
    }

    if (const auto files = frames.openFiles(screen); !files.empty()) {
      output.connection.sendPayload(files);
    }

    output.connection.sendPayload(frames.end(screen));
    attachment.editor_sent = frames.frame();
    slots_.atMut(attachment.slot).cells_current = true;
    return true;
  }

  bool AttachmentDelivery::prepare(Output& output, Attachment& attachment, PaneRef<TerminalBody> pane, DeliveryLane lane) {
    const auto& effects = pane.body.terminal.effects();

    switch (lane) {
    case DeliveryLane::scrollback:
      return scrollback(output.connection, attachment, pane);
    case DeliveryLane::cells:
      return cells(output, attachment, pane, output.now, output.timeout);
    case DeliveryLane::cwd:
      return metadata(output.connection, attachment.cwd_revision, pane.core.cwd_revision + 1, PaneCwd{.pane_id = pane.core.id, .cwd = pane.core.cwd});
    case DeliveryLane::foreground:
      return metadata(output.connection, attachment.foreground_revision, pane.core.foreground_revision, PaneForeground{.pane_id = pane.core.id, .name = pane.core.foreground.view()});
    case DeliveryLane::title:
      return metadata(output.connection, attachment.title_revision, effects.title_revision, PaneTitle{.pane_id = pane.core.id, .title = effects.title()});
    case DeliveryLane::progress:
      return metadata(output.connection, attachment.progress_revision, effects.progress_revision, PaneProgress{.pane_id = pane.core.id, .state = effects.progress_state, .percent = effects.progress_percent});
    case DeliveryLane::shell:
      // The shell reports its line before the command the report cleared it for runs: the line
      // goes first, or a client told the shell is back at its prompt would keep the line for the
      // prompt after.
      return typeahead(output.connection, attachment, pane) || metadata(output.connection, attachment.shell_revision, pane.body.shell_revision, pane.body.shell_state);
    case DeliveryLane::git:
      return metadata(output.connection, attachment.git_revision, pane.core.git_revision, pane.core.git.message(pane.core.id));
    case DeliveryLane::blocks:
      return blocks(output.connection, attachment, pane);
    case DeliveryLane::exit:
      return exit(output, attachment, pane.core, pane.body.media->idle() && !attachment.frames.waitingForAck());
    case DeliveryLane::graphics:
      return graphics(output, attachment, pane, output.timeout);
    case DeliveryLane::document:
      return document(output.connection, attachment, pane) || inlineDocuments(output.connection, attachment, pane);
    case DeliveryLane::stopping:
    case DeliveryLane::management:
    case DeliveryLane::resync:
    case DeliveryLane::clipboard:
    case DeliveryLane::layout:
    case DeliveryLane::proxy:
    case DeliveryLane::agents:
    case DeliveryLane::metrics:
    case DeliveryLane::workspaces:
    case DeliveryLane::panes:
    case DeliveryLane::observation:
    case DeliveryLane::count:
      return false;
    }

    // A lane outside the enum delivers nothing, as the lanes no attachment owns.
    return false;
  }

  template <typename Message>
  bool AttachmentDelivery::metadata(Connection<ConcurrentMemory>& connection, std::uint64_t& observed, std::uint64_t revision, const Message& message) {
    if (observed == revision) {
      return false;
    }

    connection.send(message);
    observed = revision;
    return true;
  }

  bool AttachmentDelivery::document(Connection<ConcurrentMemory>& connection, Attachment& attachment, PaneRef<const TerminalBody> pane) {
    static_assert(PaneDocument::max_size == ::telar::render::max_document_bytes);
    const auto& effects = pane.body.terminal.effects();
    if (attachment.document_revision != effects.document_revision) {
      attachment.document_revision = effects.document_revision;
      attachment.document_offset = 0;
      attachment.document_whole = false;
    } else if (attachment.document_whole) {
      return false;
    }

    const auto size = static_cast<std::uint32_t>(effects.document.size());
    const auto chunk = std::min(size - attachment.document_offset, PaneDocument::chunk_bytes);

    connection.send(PaneDocument{
        .pane_id = pane.core.id,
        .revision = effects.document_revision,
        .size = size,
        .offset = attachment.document_offset,
        .bytes = std::span<const Byte>{effects.document}.subspan(attachment.document_offset, chunk),
    });

    attachment.document_offset += chunk;
    attachment.document_whole = attachment.document_offset == size;
    return true;
  }

  bool AttachmentDelivery::inlineDocuments(Connection<ConcurrentMemory>& connection, Attachment& attachment, PaneRef<const TerminalBody> pane) {
    const auto& effects = pane.body.terminal.effects();
    const auto generation = pane.body.terminal.scrollbackGeneration();
    const auto trimmed = pane.body.terminal.scrollbackTrimmed();
    auto& sent = attachment.inline_documents;
    const SentDocuments::Mark current{.revision = effects.inline_revision, .generation = generation, .trimmed = trimmed};
    if (sent.settled(current)) {
      return false;
    }

    for (std::size_t index = 0; index < sent.count; ++index) {
      const auto id = sent.items[index].id;
      if (std::ranges::find(effects.inline_documents, id, &TerminalEffects::InlineDocument::id) == effects.inline_documents.end()) {
        connection.send(PaneDocument{.pane_id = pane.core.id, .id = id, .revision = id});
        sent.erase(index);
        return true;
      }
    }

    for (const auto& document : effects.inline_documents) {
      if (document.rows == 0) {
        continue;
      }

      auto* item = sent.entry(document.id);
      if (item == nullptr) {
        continue;
      }

      const auto size = static_cast<std::uint32_t>(document.bytes.size());
      const auto first_row = trimmed + document.row;
      if (item->offset < size || item->generation != generation || item->first_row != first_row || item->rows != document.rows) {
        const auto chunk = std::min(size - item->offset, PaneDocument::chunk_bytes);

        connection.send(PaneDocument{
            .pane_id = pane.core.id,
            .id = document.id,
            .revision = document.id,
            .generation = generation,
            .first_row = first_row,
            .rows = document.rows,
            .size = size,
            .offset = item->offset,
            .bytes = std::span<const Byte>{document.bytes}.subspan(item->offset, chunk),
        });

        item->offset += chunk;
        item->generation = generation;
        item->first_row = first_row;
        item->rows = document.rows;
        return true;
      }
    }

    sent.settle(current);
    return false;
  }

  bool AttachmentDelivery::blocks(Connection<ConcurrentMemory>& connection, Attachment& attachment, PaneRef<const TerminalBody> pane) {
    if (!pane.body.blocks || attachment.blocks_revision == pane.body.blocks->revision()) {
      return false;
    }

    ds::Array<CommandBlock, PaneBlocks::capacity> storage;

    connection.send(pane.body.blocks->message(pane.core.id, storage));
    attachment.blocks_revision = pane.body.blocks->revision();
    return true;
  }

  bool AttachmentDelivery::typeahead(Connection<ConcurrentMemory>& connection, Attachment& attachment, PaneRef<const TerminalBody> pane) {
    if (!pane.body.shell_zones || attachment.typeahead_serial == pane.body.shell_zones->typeaheadSerial()) {
      return false;
    }

    attachment.typeahead_serial = pane.body.shell_zones->typeaheadSerial();
    connection.send(PaneTypeahead{.pane_id = pane.core.id, .text = pane.body.shell_zones->typeahead()});
    return true;
  }

  bool AttachmentDelivery::scrollback(Connection<ConcurrentMemory>& connection, Attachment& attachment, PaneRef<TerminalBody> pane) {
    const auto generation = pane.body.terminal.scrollbackGeneration();
    const auto trimmed = pane.body.terminal.scrollbackTrimmed();
    if (attachment.scrollback_generation == generation && attachment.scrollback_trimmed == trimmed) {
      return false;
    }

    if (attachment.viewport && attachment.scrollback_generation == generation && trimmed > attachment.scrollback_trimmed) {
      const auto dropped = trimmed - attachment.scrollback_trimmed;

      attachment.viewport = static_cast<std::uint32_t>(*attachment.viewport > dropped ? *attachment.viewport - dropped : 0);
      attachment.frames.requestSnapshot();
    }

    connection.send(PaneScrollback{.pane_id = pane.core.id, .generation = generation, .trimmed = trimmed});
    attachment.scrollback_generation = generation;
    attachment.scrollback_trimmed = trimmed;
    return true;
  }

  bool AttachmentDelivery::cells(Output& output, Attachment& attachment, PaneRef<TerminalBody> pane, Clock::time_point now, std::chrono::nanoseconds& timeout) {
    if (attachment.frames.waitingForAck(pane.body.terminal.screen())) {
      return false;
    }

    const bool snapshot = attachment.frames.needsSnapshot(pane.body.terminal.screen());
    if (!snapshot && !pane.body.terminal.dirty() && attachment.frames.observedRevision() == pane.body.terminal.screen().revision) {
      slots_.atMut(attachment.slot).cells_current = true;
      return false;
    }

    attachment.pacer.configure(output.frame_interval);
    if (pane.core.last_input) {
      attachment.pacer.noteInput(*pane.core.last_input);
    }

    const auto deadline = attachment.pacer.deadline(now);
    if (!snapshot && !pane.core.output_closed && deadline && now < *deadline) {
      timeout = std::min(timeout, std::chrono::duration_cast<std::chrono::nanoseconds>(*deadline - now));
      return false;
    }

    if (pane.body.terminal.mode(GHOSTTY_MODE_SYNC_OUTPUT)) {
      if (pane.body.sync_started == Clock::time_point{}) {
        pane.body.sync_started = now;
      }

      const auto release = pane.body.sync_started + std::chrono::seconds{1};
      if (now < release) {
        timeout = std::min(timeout, std::chrono::duration_cast<std::chrono::nanoseconds>(release - now));
        return false;
      }
    } else {
      pane.body.sync_started = {};
    }

    TELAR_TRACE("runtime.publishFrame");
    if (attachment.viewport) {
      pane.body.terminal.scrollTo(*attachment.viewport);
    }

    pane.body.terminal.refresh();
    const auto payload = attachment.frames.prepare(pane.body.terminal.screen());

    TELAR_DIAGNOSTIC(output.metrics.frames.merge(attachment.frames.takeCounters()));
    slots_.atMut(attachment.slot).cells_current = true;
    if (attachment.viewport) {
      pane.body.terminal.scrollToBottom();
    }

    if (!snapshot) {
      attachment.pacer.record(now, deadline);
    }

    if (payload.empty()) {
      return false;
    }

    output.connection.sendPayload(payload);
    return true;
  }

  bool AttachmentDelivery::editorPrompt(Connection<ConcurrentMemory>& connection, Attachment& attachment, PaneRef<const NvimBody> pane) {
    const auto serial = pane.body.editor.promptSerial();
    if (attachment.editor_prompt == serial) {
      return false;
    }

    const auto& prompt = pane.body.editor.prompt();
    const std::string_view text{prompt.text.data(), prompt.text.size()};
    ds::Array<std::string_view, max_nvim_choices> choices;
    std::size_t count = 0;

    for (const auto& choice : prompt.choices) {
      choices.atMut(count++) = choice.of(text);
    }

    connection.send(NvimPrompt{
        .pane_id = pane.core.id,
        .serial = serial,
        .prompt_id = prompt.id,
        .kind = prompt.kind,
        .title = prompt.title,
        .initial = prompt.initial,
        .choices = choices.view().first(count),
        .origin = prompt.origin,
    });

    attachment.editor_prompt = serial;
    return true;
  }

  bool AttachmentDelivery::exit(Output& output, Attachment& attachment, const Pane& pane, bool delivered) {
    if (!pane.output_closed || !pane.exit_status || !delivered || !slots_[attachment.slot].cells_current) {
      return false;
    }

    const auto status = *pane.exit_status;

    output.connection.send(PaneExited{
        .pane_id = pane.id,
        .kind = WIFEXITED(status) ? ExitKind::exited : ExitKind::signaled,
        .value = static_cast<std::uint32_t>(WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status)),
    });

    attachment.exit_sent = true;
    output.completing_exit = pane.id;
    return true;
  }

  bool AttachmentDelivery::graphics(Output& output, Attachment& attachment, PaneRef<TerminalBody> pane, std::chrono::nanoseconds& timeout) {
    const bool sent = publishGraphics(output.connection, attachment, pane, timeout);

    TELAR_DIAGNOSTIC(output.metrics.graphics.merge(attachment.graphics.takeCounters()));
    return sent;
  }

  bool AttachmentDelivery::publishGraphics(Connection<ConcurrentMemory>& connection, Attachment& attachment, PaneRef<TerminalBody> pane, std::chrono::nanoseconds& timeout) {
    const auto queued = connection.queuedBytes();

    if (pane.body.media->busy()) {
      if (attachment.graphics.advanceTransfer(connection)) {
        timeout = std::chrono::nanoseconds::zero();
      }

      return connection.queuedBytes() != queued;
    }

    const auto* terminal = pane.body.media->terminal();

    try {
      const bool pending = terminal == nullptr ? attachment.graphics.publish(connection, pane.body.terminal.graphics()) : attachment.graphics.publish(connection, terminal->graphics());
      if (pending) {
        timeout = std::chrono::nanoseconds::zero();
      }
    } catch (const std::bad_alloc&) {
      attachment.graphics.abandon(terminal == nullptr ? pane.body.terminal.graphics().revision() : terminal->graphics().revision());
    }

    return connection.queuedBytes() != queued;
  }

  ResponseProjection::ResponseProjection(ConcurrentMemory& memory, RuntimeModel& model) noexcept
      : memory_(memory),
        model_(model) {}

  bool ResponseProjection::matchesSnapshot(const Pane& pane, TabLocation location) noexcept {
    return !pane.close_requested && !pane.exit_status && pane.location.workspace.kind == location.workspace.kind && pane.location.workspace.id == location.workspace.id && pane.location.tab_id == location.tab_id;
  }

  [[nodiscard]] std::string_view ResponseProjection::snapshotDirectory(std::string_view cwd) noexcept {
    constexpr std::size_t maximum_bytes = 4096;

    return cwd.size() <= maximum_bytes && !cwd.contains('\0') ? cwd : std::string_view{};
  }

  void labelDirectory(FixedText<max_pane_directory_bytes>& label, std::string_view cwd) {
    const auto home = processHome();
    if (!home.empty() && cwd.starts_with(home) && (cwd.size() == home.size() || cwd[home.size()] == '/')) {
      ds::Array<char, max_pane_directory_bytes> shortened{'~'};
      const auto suffix = utf8Prefix(cwd.substr(home.size()), max_pane_directory_bytes - 1);

      std::ranges::copy(suffix, shortened.viewMut().subspan(1).begin());
      label.assign({shortened.data(), suffix.size() + 1});
      return;
    }

    label.assign(utf8Prefix(cwd, max_pane_directory_bytes));
  }

  ClientDelivery::ClientDelivery(ConcurrentMemory& memory, RuntimeModel& model)
      : memory_(memory),
        model_(model) {}

  bool ClientDelivery::resync(ClientSession& client) {
    if (!client.workspace_resync) {
      return false;
    }

    TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.client_resyncs));
    auto& change = client.workspace_resync.getMut();

    change.workspace_closed = model_.workspaces.find(change.workspace.id) == nullptr;
    client.connection.send(change);
    client.workspace_resync.reset();
    return true;
  }

  bool ClientDelivery::clipboard(ClientSession& client) {
    if (client.clipboard.pending()) {
      client.connection.send(client.clipboard.message());
      client.clipboard.delivered();
      return true;
    }

    for (auto& attachment : client.attachments.viewMut()) {
      const auto pane = asTerminal(model_.panes.find(attachment->pane_id));
      if (!pane || attachment->clipboard_revision == pane->body.terminal.effects().clipboard_revision) {
        continue;
      }

      client.connection.send(PaneClipboard{.pane_id = pane->core.id, .bytes = pane->body.terminal.effects().clipboard});
      attachment.getMut().clipboard_revision = pane->body.terminal.effects().clipboard_revision;
      return true;
    }

    return false;
  }

  bool ClientDelivery::paneList(ClientSession& client, Clock::time_point now) {
    if (!client.subscribed || (client.pane_revision == model_.pane_revision && client.pane_workspace_revision == model_.workspace_revision)) {
      return false;
    }

    ds::Array<PaneListEntry, max_pane_list_entries> entries;
    std::size_t count = 0;

    for (const auto* pane : model_.panes.items()) {
      if (pane == nullptr || pane->exit_status || pane->close_requested) {
        continue;
      }

      if (count == entries.size()) {
        break;
      }

      const auto age = std::chrono::duration_cast<std::chrono::seconds>(now - pane->foreground_since).count();
      const auto name = pane->foreground.view();

      entries.atMut(count++) = {
          .pane_id = pane->id,
          .pane_generation = pane->generation,
          .location = pane->location,
          .foreground = name.empty() ? "shell" : name,
          .foreground_age_s = static_cast<std::uint32_t>(std::clamp<std::int64_t>(age, 0, std::numeric_limits<std::uint32_t>::max())),
          .shell = pane->foreground_shell,
          .ports = pane->listening_ports.view(),
      };
    }

    client.connection.send(PaneList{.revision = model_.pane_revision + model_.workspace_revision, .entries = std::span{entries}.first(count)});
    client.pane_revision = model_.pane_revision;
    client.pane_workspace_revision = model_.workspace_revision;
    return true;
  }

  bool ClientDelivery::paneFacts(ClientSession& client) {
    if (!client.subscribed) {
      return false;
    }

    const auto panes = model_.panes.items();

    for (std::size_t slot = 0; slot < panes.size(); ++slot) {
      const auto* pane = panes[slot];
      if (pane == nullptr || pane->exit_status || pane->close_requested) {
        continue;
      }

      const auto stamp = factsStamp(*pane);
      auto& sent = client.facts.atMut(slot);
      if (sent == stamp) {
        continue;
      }

      FixedText<max_pane_directory_bytes> directory;

      labelDirectory(directory, pane->cwd);
      client.connection.send(describe(*pane, model_.workspaces.find(pane->location.workspace.id), directory.view()));
      sent = stamp;
      return true;
    }

    return false;
  }

  bool ClientDelivery::foreground(ClientSession& client) {
    if (!client.subscribed) {
      return false;
    }

    const auto panes = model_.panes.items();

    for (std::size_t slot = 0; slot < panes.size(); ++slot) {
      const auto* pane = panes[slot];
      if (pane == nullptr || pane->exit_status || pane->close_requested || (pane->observers & client.observerBit()) != 0) {
        continue;
      }

      auto& sent = client.foregrounds.atMut(slot);
      if (sent.pane != pane->id || sent.revision != pane->foreground_revision) {
        client.connection.send(PaneForeground{.pane_id = pane->id, .name = pane->foreground.view()});
        sent = {.pane = pane->id, .revision = pane->foreground_revision};
        return true;
      }
    }

    return false;
  }

  EditorService::EditorService(ConcurrentMemory& memory)
      : editor_(memory),
        search_(memory) {}

  void EditorService::process(std::span<const Byte> payload, EncodedReply<ConcurrentMemory>& reply, const RequestContext& context) {
    constexpr std::size_t decode_scratch_bytes = 1024;
    ds::Array<Byte, decode_scratch_bytes> scratch{};
    DecodeStorage storage{scratch.viewMut()};

    if (!payload.empty() && static_cast<ClientTag>(payload.front()) == ClientTag::find_text) {
      static const std::atomic<bool> never{false};

      search_.find(Codec::decode<FindText>(payload, storage), context.cancelled == nullptr ? never : *context.cancelled, reply);
      return;
    }

    editor_.open(Codec::decode<OpenEditor>(payload, storage), context, reply);
  }

}
