#include "support.hpp"

// CASE: gui.font_bytes_escape
// PAIR: gui.font_input
// SOURCE: services/gui-cpp/fonts/face.cppm :: Face / selectFace
// STATUS: pending
// CONTRACT: A font face retains its input font bytes through the foreign font object's destruction.
// SCENARIO: Reject returning a face constructed over a local font-data buffer.
tbc::view<spec::font_face, tbc::lt::a> fontBytesEscape() {
  const std::array<std::byte, 8> bytes{};
  return spec::font_face{bytes}; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: gui.font_caller_bytes
// PAIR: gui.font_input
// SOURCE: services/gui-cpp/fonts/face.cppm :: Face
// STATUS: pending
// CONTRACT: The returned face carries a dependency on the caller-owned font storage.
// SCENARIO: A span descriptor is local, but its referent belongs to the caller; accept.
tbc::view<spec::font_face, tbc::lt::a> fontCallerBytes(spec::bytes_a bytes) {
  return spec::font_face{bytes};
}

// END CASE

// CASE: gui.shape_reuses_scratch
// PAIR: gui.shaping_scratch
// SOURCE: services/gui-cpp/fonts/face.cpp :: Face::shape / hb_buffer_reset
// STATUS: pending
// CONTRACT: A shaped run borrows the face's shaping buffer until the next shape call.
// SCENARIO: The face remains alive but a second shape invalidates the first run.
void shapeReusesScratch(tbc::view<spec::font_face &> face) {
  const auto first = face.shape("first");
  const auto second = face.shape("second"); // expected-error [tbc-invalidated-borrow]
  spec::observe(first);
  spec::observe(second);
}

// END CASE

// CASE: gui.shape_copied_scratch
// PAIR: gui.shaping_scratch
// SOURCE: services/gui-cpp/fonts/face_views.cppm :: ShapedRunView::glyph
// STATUS: pending
// CONTRACT: Copying shaped glyph values produces owned data; input text is consumed, not retained.
// SCENARIO: A temporary text input and a subsequent shape are safe for the copied glyphs.
void shapeCopiedScratch(tbc::view<spec::font_face &> face) {
  const auto first = face.shape(std::string{"temporary input"});
  const std::vector<int> copied{first.begin(), first.end()};
  const auto second = face.shape("second");
  spec::observe(copied);
  spec::observe(second);
}

// END CASE

// CASE: gui.shape_independent_faces
// PAIR: gui.shaping_scratch
// SOURCE: services/gui-cpp/fonts/face.cppm :: shaping_buffer_
// STATUS: pending
// CONTRACT: Scratch invalidation is scoped to a resource instance, not globally to a type.
// SCENARIO: Construct distinct faces; shaping the second must not invalidate the first's run.
void shapeIndependentFaces(spec::bytes_a bytes) {
  spec::font_face first_face{bytes};
  spec::font_face second_face{bytes};
  const auto first = first_face.shape("first");
  const auto second = second_face.shape("second");
  spec::observe(first);
  spec::observe(second);
}

// END CASE

// CASE: gui.bitmap_reuses_slot
// PAIR: gui.raster_scratch
// SOURCE: services/gui-cpp/fonts/face.cpp :: Face::rasterize / FT_Load_Glyph
// STATUS: pending
// CONTRACT: Glyph bitmap coverage borrows the foreign face's reusable glyph slot.
// SCENARIO: Reject loading another glyph before the previous coverage's final read.
void bitmapReusesSlot(tbc::view<spec::font_face &> face) {
  const auto bitmap = face.rasterize();
  const auto next = face.rasterize(); // expected-error [tbc-invalidated-borrow]
  spec::observe(bitmap);
  spec::observe(next);
}

// END CASE

// CASE: gui.bitmap_owned_copy
// PAIR: gui.raster_scratch
// SOURCE: services/gui-cpp/fonts/face.cppm :: GlyphBitmapView::coverage
// STATUS: pending
// CONTRACT: Copying coverage bytes into owned storage ends the scratch dependency.
// SCENARIO: Upload/copy the old bytes before rasterizing again; accept the owned result.
void bitmapOwnedCopy(tbc::view<spec::font_face &> face) {
  const auto bitmap = face.rasterize();
  const std::vector<std::byte> copied{bitmap.begin(), bitmap.end()};
  const auto next = face.rasterize();
  spec::observe(copied);
  spec::observe(next);
}

// END CASE
