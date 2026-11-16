telar_add_domain(gui presentation
  SOURCES
    activity_order/activity_order.cpp
    application_mark/application_mark.cpp
    display_metrics/display_metrics.cpp
    form_field_geometry/form_field_geometry.cpp
    frame_pacer/frame_pacer.cpp
    history_filter_geometry/history_filter_geometry.cpp
    history_inspection/history_inspection.cpp
    history_inspection_geometry/history_inspection_geometry.cpp
    history_meta_geometry/history_meta_geometry.cpp
    history_pointer/history_pointer.cpp
    notification_center/notification_center.cpp
    notification_stack/notification_stack.cpp
    suggestion_geometry/suggestion_geometry.cpp
    suggestion_labels/suggestion_labels.cpp
    tab_drop/tab_drop.cpp
  DEPS core history layout suggestions text terminal input model machines)
