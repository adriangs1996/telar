telar_add_domain(gui features/terminal/attachments
  SOURCES
    attachments-capture.cpp
    attachments-catalog.cpp
    attachments-presentation.cpp
  DEPS foundation/core foundation/terminal foundation/actions foundation/keys foundation/forms)

if(BUILD_TESTING)
  # attachment_catalog erases through the ErasureAllocator of src/gui/tests, which the
  # platform's tests share.
  telar_add_domain_tests(features/terminal/attachments LINK gui-test-fixtures)
endif()
