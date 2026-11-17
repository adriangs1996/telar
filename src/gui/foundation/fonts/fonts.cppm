// Faces, shaping and the layout of text in cells, and the glyphs the GUI draws itself.
export module telar.gui.foundation.fonts;

export import :glyphs;
export import :curve_cache;
export import :face_views;
export import :face;
#ifdef __APPLE__
export import :glyph_rasterizer;
#endif
export import :font_requests;
export import :text_runs;
export import :row_text_layout;
