#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum RenderWorkCounter {
  render_work_commits,
  render_work_passes,
  render_work_surface_passes,
  render_work_offscreen_passes,
  render_work_drawable_completions,
  render_work_drawables,
  render_work_nil_drawables,
  render_work_presentation_callbacks,
  render_work_positive_presentations,
  render_work_zero_presentations,
  render_work_unsupported_metal4,
  render_work_terminal_sync,
  render_work_terminal_rows,
  render_work_text_chunks,
  render_work_standard_paint,
  render_work_optical_paint,
  render_work_standard_rebuild,
  render_work_optical_rebuild,
  render_work_standard_spans,
  render_work_optical_spans,
  render_work_standard_meshes,
  render_work_optical_meshes,
  render_work_standard_mesh_created,
  render_work_optical_mesh_created,
  render_work_optical_mesh_reused,
  render_work_standard_requests,
  render_work_optical_requests,
  render_work_standard_hits,
  render_work_optical_hits,
  render_work_standard_rasters,
  render_work_optical_rasters,
  render_work_optical_reuses,
  render_work_tab_layout,
  render_work_tab_reconcile,
  render_work_tab_update,
  render_work_count
};

enum { render_work_sequence_capacity = 513 };

typedef struct {
  uint64_t counts[render_work_count];
  uint64_t commits_by_sequence[render_work_sequence_capacity];
  uint64_t begin_ns;
  uint64_t end_ns;
  uint64_t errors;
  bool complete;
} RenderWorkSnapshot;

int telar_render_work_begin(void);
void telar_render_work_record(enum RenderWorkCounter counter, uint64_t amount);
void telar_render_work_pair(enum RenderWorkCounter first, enum RenderWorkCounter second);
void telar_render_work_commit(unsigned sequence);
RenderWorkSnapshot telar_render_work_end(void);

#ifdef __cplusplus
}
#endif
