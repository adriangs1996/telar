module;

// The links in a terminal as ui drives them: the types a terminal's pointer holds over a link,
// and a file link opened in an editor beside its pane.
export module telar.gui.application:terminal_links;

import std;

import :session;
import telar.gui.features.terminal.links;
import telar.wire.editor;
import telar.base.ds;
import telar.tbc;

export namespace telar::gui::application::terminal::links {

  using features::terminal::links::CellLinks;
  using features::terminal::links::FilePath;
  using features::terminal::links::LinkAffordance;
  using features::terminal::links::LinkButton;
  using features::terminal::links::LinkGesture;
  using features::terminal::links::LinkGrid;
  using features::terminal::links::LinkHit;
  using features::terminal::links::LinkHover;
  using features::terminal::links::LinkMatch;
  using features::terminal::links::LinkModifiers;
  using features::terminal::links::LinkOpening;
  using features::terminal::links::LinkPointerPolicy;
  using features::terminal::links::LinkPresentation;
  using features::terminal::links::LinkPress;
  using features::terminal::links::LinkPressInput;
  using features::terminal::links::LinkRegion;
  using features::terminal::links::LinkRegions;
  using features::terminal::links::LinkScheme;
  using features::terminal::links::LinkStatusGeometry;
  using features::terminal::links::LinkTarget;
  using features::terminal::links::LocalPortLink;
  using features::terminal::links::PathEnvironment;
  using features::terminal::links::PathExpansion;
  using features::terminal::links::PresentedLink;

}

// The steps of openFile below; ui calls openFile.
namespace telar::gui::application::terminal::links {

  // The cwd a relative `path` is anchored at, after checking that the file can be opened: none
  // for an absolute path.
  [[nodiscard]] tbc::val_a<ds::Option<std::string_view>> base(tbc::ref_a<Session> session, const FilePath& path, std::string_view executable, ds::Option<std::uint64_t> source_id);

  // Opens `path` once `base` admitted it, with a relative path already `anchored`.
  void openAnchored(Session& session, const FilePath& path, std::string_view executable, std::string_view anchored, ds::Option<std::uint64_t> source_id);

}

export namespace telar::gui::application::terminal::links {

  // Opens `path` in an editor: in a pane beside pane `source_id`, or in a tab without one. A
  // relative path is anchored at that pane's cwd, after `environment` expands it.
  template <PathEnvironment Environment>
  [[tbc::generic]] void openFile(Session& session, const FilePath& path, std::string_view executable, const Environment& environment, ds::Option<std::uint64_t> source_id = {}) {
    const auto anchor = base(session, path, executable, source_id);
    const auto anchored = anchor ? PathExpansion::expand({.text = path.text(), .base = *anchor}, environment) : PathExpansion::PathText{};

    openAnchored(session, path, executable, anchored.view(), source_id);
  }

}

// What the session's routing hands the links; ui never calls these.
namespace telar::gui::application::terminal::links {

  Change receive(Session& session, const EditorOpened& message);

  // A failed request: none when it is not the editor request pending.
  ds::Option<Change> fail(Session& session, std::uint64_t request_id, std::string_view message);

}
