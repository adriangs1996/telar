#ifndef TELAR_GUI_TESTS_PLATFORM_PROMISED_FILE_HPP
#define TELAR_GUI_TESTS_PLATFORM_PROMISED_FILE_HPP

#include "platform/file_drag.hpp"
#include <cstddef>
#include <memory>
#include <string>

namespace telar::gui::test {

  // How the system was told that writing a promised file ended: nothing while it waits, and
  // then why the file is not there, or nothing when it is.
  struct PromiseAnswer {
    bool answered = false;
    std::string failure;
  };

  // The name the row `row` promises its file under, among the rows `drag` gave to the system's
  // drag; empty when that row promises none.
  std::string promisedName(const platform::FileDrag& drag, std::size_t row);

  // Asks that row's promise for its file at `path`, as the system does once the row is let go.
  // `answer` is written when the window tells the system how that ended. False when the row
  // promises no file.
  bool askPromisedFile(const platform::FileDrag& drag, std::size_t row, const std::string& path, const std::shared_ptr<PromiseAnswer>& answer);

}

#endif // TELAR_GUI_TESTS_PLATFORM_PROMISED_FILE_HPP
