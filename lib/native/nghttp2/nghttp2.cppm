module;
#include <nghttp2/nghttp2.h>

export module telar.native.nghttp2;

// nghttp2's header stays in this global module fragment only; importers reach it through these
// declarations instead of including it.
export {
  using ::nghttp2_data_provider2;
  using ::nghttp2_data_source;
  using ::nghttp2_frame;
  using ::nghttp2_hd_inflater;
  using ::nghttp2_mem;
  using ::nghttp2_nv;
  using ::nghttp2_option;
  using ::nghttp2_session;
  using ::nghttp2_session_callbacks;
  using ::nghttp2_settings_entry;
  using ::nghttp2_ssize;

  using ::nghttp2_hd_inflate_change_table_size;
  using ::nghttp2_hd_inflate_del;
  using ::nghttp2_hd_inflate_end_headers;
  using ::nghttp2_hd_inflate_hd2;
  using ::nghttp2_hd_inflate_new2;
  using ::nghttp2_option_del;
  using ::nghttp2_option_new;
  using ::nghttp2_option_set_max_outbound_ack;
  using ::nghttp2_option_set_no_auto_window_update;
  using ::nghttp2_session_callbacks_del;
  using ::nghttp2_session_callbacks_new;
  using ::nghttp2_session_callbacks_set_on_begin_headers_callback;
  using ::nghttp2_session_callbacks_set_on_data_chunk_recv_callback;
  using ::nghttp2_session_callbacks_set_on_frame_not_send_callback;
  using ::nghttp2_session_callbacks_set_on_frame_recv_callback;
  using ::nghttp2_session_callbacks_set_on_header_callback;
  using ::nghttp2_session_callbacks_set_on_stream_close_callback;
  using ::nghttp2_session_client_new3;
  using ::nghttp2_session_consume_connection;
  using ::nghttp2_session_consume_stream;
  using ::nghttp2_session_del;
  using ::nghttp2_session_get_stream_user_data;
  using ::nghttp2_session_mem_recv2;
  using ::nghttp2_session_mem_send2;
  using ::nghttp2_session_resume_data;
  using ::nghttp2_session_server_new3;
  using ::nghttp2_session_set_stream_user_data;
  using ::nghttp2_session_want_write;
  using ::nghttp2_strerror;
  using ::nghttp2_submit_goaway;
  using ::nghttp2_submit_headers;
  using ::nghttp2_submit_request2;
  using ::nghttp2_submit_response2;
  using ::nghttp2_submit_rst_stream;
  using ::nghttp2_submit_settings;
  using ::nghttp2_submit_trailer;

  using ::NGHTTP2_CANCEL;
  using ::NGHTTP2_DATA;
  using ::NGHTTP2_DATA_FLAG_EOF;
  using ::NGHTTP2_DATA_FLAG_NO_END_STREAM;
  using ::NGHTTP2_ERR_CALLBACK_FAILURE;
  using ::NGHTTP2_ERR_DEFERRED;
  using ::NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
  using ::NGHTTP2_FLAG_END_STREAM;
  using ::NGHTTP2_FLAG_NONE;
  using ::NGHTTP2_GOAWAY;
  using ::NGHTTP2_HCAT_REQUEST;
  using ::NGHTTP2_HD_INFLATE_EMIT;
  using ::NGHTTP2_HD_INFLATE_FINAL;
  using ::NGHTTP2_HD_INFLATE_NONE;
  using ::NGHTTP2_HEADERS;
  using ::NGHTTP2_NO_ERROR;
  using ::NGHTTP2_NV_FLAG_NONE;
  using ::NGHTTP2_REFUSED_STREAM;
  using ::NGHTTP2_SETTINGS_ENABLE_PUSH;
  using ::NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE;
  using ::NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS;
  using ::NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE;
}
