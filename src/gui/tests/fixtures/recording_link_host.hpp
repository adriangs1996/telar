// A link host for a build of the window's tests. In place of the host's browser it appends
// each link the window opens to the file TELAR_GUI_TEST_LINK_RECORD names, one to a line,
// which is where the tests read what was opened. A build takes it with
// -DTELAR_GUI_LINK_HOST_HEADER=src/gui/tests/fixtures/recording_link_host.hpp. It is included
// where the window chooses its link host, before the types that host works with are named:
// it names none of Qt's or of telar's, only what the process and the link it is given have.
#pragma once

#include <chrono>

namespace telar::gui::test {

  struct RecordingLinkHost {
    static constexpr auto timeout = std::chrono::seconds{5};

    template <typename Process, typename Target>
    static void start(Process& process, const Target& target) {
      using Text = decltype(process.program());
      using Words = decltype(process.arguments());
      const auto link = target.text();

      // The link is an argument of the shell, never a part of what it runs.
      process.start(
          Text::fromLatin1("/bin/sh"),
          Words{
              Text::fromLatin1("-c"),
              Text::fromLatin1("printf '%s\\n' \"$1\" >> \"$TELAR_GUI_TEST_LINK_RECORD\""),
              Text::fromLatin1("sh"),
              Text::fromUtf8(link.data(), static_cast<long long>(link.size())),
          }
      );
    }
  };

}

#define TELAR_GUI_LINK_HOST ::telar::gui::test::RecordingLinkHost
