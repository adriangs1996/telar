// What the use cases of application::<feature> reach of the state they compose. A partition the
// module does not export: only the module's own units import it, and ui cannot name Access.
module telar.gui.application:access;

import :session;

namespace telar::gui::application {

  // Session befriends it; each accessor hands out one member, so a use case reaches what it
  // works on and the members stay out of Session's public interface. Accessors are added with
  // the use cases that need them, and stay inline so a use case costs what the method it
  // replaces did.
  struct Access {
    [[nodiscard]] static constexpr Configuration& configuration(Session& session) noexcept {
      return session.configuration_;
    }

    [[nodiscard]] static constexpr const Configuration& configuration(const Session& session) noexcept {
      return session.configuration_;
    }
  };

}
