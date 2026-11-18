module telar.gui.application;

import std;

import :access;
import telar.gui.features.terminal.links;
import telar.wire.editor;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::application::terminal::links {

  namespace {

    // The editor's arguments for `target`, as its conventions place the line and the column.
    template <typename Open>
    void launch(const features::terminal::links::EditorTarget& target, const Open& open) {
      features::terminal::links::EditorLaunch command;

      open(command.arguments(target.editor(), target.path(), target.line(), target.column()));
    }

    void split(Session& session, const features::terminal::links::EditorRequest& request) {
      launch(request.target, [&](std::span<const std::string_view> arguments) {
        workbench::launchSplit(session, request.source.pane_id, arguments);
      });
    }

    Change report(Session& session, std::string_view message) {
      notifications::publish(session, {.level = NotificationLevel::failure, .title = "Could not open link", .message = message, .link = {}});

      return Change::notification;
    }

  }

  ds::Option<std::string_view> base(const Session& session, const FilePath& path, std::string_view executable, ds::Option<std::uint64_t> source_id) {
    if (executable.empty()) {
      throw std::runtime_error{"EditorUnavailable"};
    }

    if (!source_id) {
      if (!path.text().starts_with('/')) {
        throw std::invalid_argument{"RelativeFileLink"};
      }

      return ds::none;
    }

    const auto* source = session.findPane(*source_id);
    const auto& active = Access::activeTab(session);
    if (source == nullptr || !active || !sameTab(source->location, *active)) {
      throw std::runtime_error{"PaneNotFound"};
    }

    if (path.text().starts_with('/')) {
      return ds::none;
    }

    return std::string_view{source->cwd};
  }

  void openAnchored(Session& session, const FilePath& path, std::string_view executable, std::string_view anchored, ds::Option<std::uint64_t> source_id) {
    if (!source_id) {
      launch(features::terminal::links::EditorTarget{executable, path.text(), path.line(), path.column()}, [&](std::span<const std::string_view> arguments) {
        workbench::launchTab(session, arguments);
      });

      return;
    }

    const auto* source = session.findPane(*source_id);
    const features::terminal::links::EditorRequest request{
        .request_id = source->generation == 0 ? 0 : Access::nextRequest(session),
        .source = {.pane_id = source->id, .pane_generation = source->generation, .attachment_generation = source->attachment_generation, .location = source->location},
        .target = features::terminal::links::EditorTarget{executable, path.text().starts_with('/') ? path.text() : anchored, path.line(), path.column()},
    };

    if (source->generation == 0) {
      split(session, request);

      return;
    }

    auto& state = Access::links(session);
    const auto message = features::terminal::links::open(state, request);

    try {
      Access::send(session, message);
    } catch (...) {
      static_cast<void>(features::terminal::links::complete(state, request.request_id));
      throw;
    }
  }

  Change receive(Session& session, const EditorOpened& message) {
    const auto request = features::terminal::links::complete(Access::links(session), message.request_id);
    if (!request) {
      return Change::none;
    }

    const auto& source = request->source;
    const auto& active = Access::activeTab(session);
    const auto* pane = session.findPane(source.pane_id);
    if (pane == nullptr || !active || !sameTab(source.location, *active) || !sameTab(pane->location, source.location) || pane->generation != source.pane_generation || pane->attachment_generation != source.attachment_generation) {
      return Change::none;
    }

    switch (message.outcome) {
    case EditorOutcome::unavailable:
      try {
        split(session, *request);
      } catch (const std::exception& error) {
        return report(session, error.what());
      }

      return Change::model;
    case EditorOutcome::failed:
      return report(session, "EditorOpenFailed");
    case EditorOutcome::missing:
      return report(session, "FileNotFound");
    case EditorOutcome::opened: {
      const auto* editor = session.findPane(message.pane_id);
      if (editor == nullptr || !sameTab(editor->location, source.location) || editor->generation != message.pane_generation) {
        return Change::none;
      }

      workbench::focusPane(session, editor->id);

      return Change::model;
    }
    }

    return Change::none;
  }

  ds::Option<Change> fail(Session& session, std::uint64_t request_id, std::string_view message) {
    if (!features::terminal::links::complete(Access::links(session), request_id)) {
      return ds::none;
    }

    return report(session, message);
  }

}
