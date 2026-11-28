module;
#ifdef TELAR_GUI_LINK_HOST_HEADER
#include TELAR_GUI_LINK_HOST_HEADER
#endif

export module telar.gui.ui.kit.links:external_link_opener;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.process;
import telar.gui.application;
import telar.gui.foundation.system;
import telar.base.ds;
import telar.wire.vocabulary;

// A build may bring a link host of its own, as the one the window's tests record with: its
// header says which, with TELAR_GUI_LINK_HOST.

export namespace telar::gui::qt {

  using LinkOpeningFailure = CommandFailure;

  struct NativeLinkHost {
    static constexpr auto timeout = std::chrono::seconds{5};

    [[tbc::hot_path]] inline static void start(QProcess& process, const application::terminal::links::LinkTarget& target) {
      process.start(toQString(system::NativeExternalLinks::executable), {toQString(target.text())}, QIODevice::ReadOnly);
    }
  };

#ifndef TELAR_GUI_LINK_HOST
#define TELAR_GUI_LINK_HOST ::telar::gui::qt::NativeLinkHost
#endif

  using ApplicationLinkHost = TELAR_GUI_LINK_HOST;

  template <typename Host>
  concept ExternalLinkHost = CommandHost<Host, application::terminal::links::LinkTarget>;

  template <typename Observer, typename Context>
  concept LinkOpeningObserver = requires(Observer& observer, Context context, ds::Option<LinkOpeningFailure> failure) {
    { observer.linkOpeningFinished(context, failure) } -> std::same_as<void>;
  };

  template <ExternalLinkHost Host, typename Observer, std::semiregular Context = std::monostate>
  class ExternalLinkOpener final {
  public:
    static constexpr std::size_t output_limit = CommandProcess<Host, application::terminal::links::LinkTarget, ExternalLinkOpener>::output_limit;

    [[tbc::generic]] explicit ExternalLinkOpener(Observer& observer)
        : observer_(observer),
          process_(*this) {
      static_assert(LinkOpeningObserver<Observer, Context>);
    }

    ~ExternalLinkOpener() = default;
    ExternalLinkOpener(const ExternalLinkOpener&) = delete;
    ExternalLinkOpener& operator=(const ExternalLinkOpener&) = delete;
    ExternalLinkOpener(ExternalLinkOpener&&) = delete;
    ExternalLinkOpener& operator=(ExternalLinkOpener&&) = delete;

    [[tbc::generic]] void request(const application::terminal::links::LinkTarget& target, Context context = {}) {
      if (target.scheme() == application::terminal::links::LinkScheme::file || target.scheme() == application::terminal::links::LinkScheme::path) {
        throw std::invalid_argument{"File links require the editor flow"};
      }

      if (opening_.request(target)) {
        current_context_ = context;
        process_.start(target);
      } else {
        pending_context_ = context;
      }
    }

    [[tbc::generic]] [[nodiscard]] bool active() const noexcept {
      return opening_.active();
    }

    [[tbc::generic]] void commandFinished(ds::Option<CommandFailure> failure) {
      const auto completed = current_context_;

      if (const auto next = opening_.complete()) {
        current_context_ = pending_context_;
        process_.start(*next);
      }

      observer_.linkOpeningFinished(completed, failure);
    }

  private:
    Observer& observer_;
    application::terminal::links::LinkOpening opening_;
    Context current_context_{};
    Context pending_context_{};
    // The process reports back to this opener.
    tbc::val_self<CommandProcess<Host, application::terminal::links::LinkTarget, ExternalLinkOpener>> process_;
  };

}
