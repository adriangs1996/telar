#include <wayland-server-core.h>
#include <wayland-server-protocol.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct Server {
  struct wl_display *display;
  struct wl_global *seat;
  struct wl_global *manager;
  struct wl_list devices;
  uint32_t generation;
  unsigned seat_version;
  unsigned manager_version;
  int control;
};

struct Device {
  struct wl_list link;
  struct wl_resource *resource;
  struct Server *server;
  int active;
};

struct Offer {
  uint32_t generation;
};

static void destroy_resource(struct wl_client *client, struct wl_resource *resource) {
  (void)client;
  wl_resource_destroy(resource);
}

static void free_offer(struct wl_resource *resource) {
  free(wl_resource_get_user_data(resource));
}

static void accept_offer(struct wl_client *client, struct wl_resource *resource, uint32_t serial, const char *mime) {
  (void)client;
  (void)resource;
  (void)serial;
  (void)mime;
}

static void receive_offer(struct wl_client *client, struct wl_resource *resource, const char *mime, int32_t descriptor) {
  (void)client;
  const struct Offer *offer = wl_resource_get_user_data(resource);
  if (strcmp(mime, "image/png") == 0) {
    ssize_t count;
    do {
      count = write(descriptor, &offer->generation, sizeof(offer->generation));
    } while (count < 0 && errno == EINTR);
  }

  close(descriptor);
}

static void finish_offer(struct wl_client *client, struct wl_resource *resource) {
  (void)client;
  (void)resource;
}

static void set_actions(struct wl_client *client, struct wl_resource *resource, uint32_t supported, uint32_t preferred) {
  (void)client;
  (void)resource;
  (void)supported;
  (void)preferred;
}

static const struct wl_data_offer_interface offer_implementation = {
    .accept = accept_offer,
    .receive = receive_offer,
    .destroy = destroy_resource,
    .finish = finish_offer,
    .set_actions = set_actions,
};

static struct wl_resource *announce(struct Device *device) {
  struct wl_client *client = wl_resource_get_client(device->resource);
  struct Offer *offer = calloc(1, sizeof(*offer));
  if (offer == NULL) {
    wl_client_post_no_memory(client);
    return NULL;
  }

  offer->generation = device->server->generation;
  struct wl_resource *resource = wl_resource_create(client, &wl_data_offer_interface, wl_resource_get_version(device->resource), 0);
  if (resource == NULL) {
    free(offer);
    wl_client_post_no_memory(client);
    return NULL;
  }

  wl_resource_set_implementation(resource, &offer_implementation, offer, free_offer);
  wl_data_device_send_data_offer(device->resource, resource);
  wl_data_offer_send_offer(resource, "image/png");

  return resource;
}

static void free_device(struct wl_resource *resource) {
  struct Device *device = wl_resource_get_user_data(resource);
  wl_list_remove(&device->link);
  free(device);
}

static const struct wl_data_device_interface device_implementation = {
    .release = destroy_resource,
};

static void get_device(struct wl_client *client, struct wl_resource *manager, uint32_t id, struct wl_resource *seat) {
  (void)seat;
  struct Server *server = wl_resource_get_user_data(manager);
  struct Device *device = calloc(1, sizeof(*device));
  if (device == NULL) {
    wl_client_post_no_memory(client);
    return;
  }

  device->server = server;
  device->active = 1;
  device->resource = wl_resource_create(client, &wl_data_device_interface, wl_resource_get_version(manager), id);
  if (device->resource == NULL) {
    free(device);
    wl_client_post_no_memory(client);
    return;
  }

  wl_list_insert(&server->devices, &device->link);
  wl_resource_set_implementation(device->resource, &device_implementation, device, free_device);
  struct wl_resource *offer = announce(device);
  if (offer != NULL) {
    wl_data_device_send_selection(device->resource, offer);
  }
}

static const struct wl_data_device_manager_interface manager_implementation = {
    .get_data_device = get_device,
};

static void bind_manager(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
  struct wl_resource *resource = wl_resource_create(client, &wl_data_device_manager_interface, (int)version, id);
  if (resource != NULL) {
    wl_resource_set_implementation(resource, &manager_implementation, data, NULL);
  } else {
    wl_client_post_no_memory(client);
  }
}

static const struct wl_seat_interface seat_implementation = {
    .release = destroy_resource,
};

static void bind_seat(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
  struct wl_resource *resource = wl_resource_create(client, &wl_seat_interface, (int)version, id);
  if (resource == NULL) {
    wl_client_post_no_memory(client);
    return;
  }

  wl_resource_set_implementation(resource, &seat_implementation, data, NULL);
  wl_seat_send_capabilities(resource, 0);
  if (version >= WL_SEAT_NAME_SINCE_VERSION) {
    wl_seat_send_name(resource, "owned-clipboard-seat");
  }
}

static int control(int descriptor, uint32_t mask, void *data) {
  (void)mask;
  struct Server *server = data;
  char command[64] = {0};
  const ssize_t count = read(descriptor, command, sizeof(command) - 1);
  if (count <= 0) {
    wl_display_terminate(server->display);
    return 0;
  }

  if (strcmp(command, "remove-manager") == 0 || strcmp(command, "remove-seat") == 0) {
    struct Device *device;
    wl_list_for_each(device, &server->devices, link) {
      device->active = 0;
    }
  }

  if (strcmp(command, "remove-manager") == 0) {
    if (server->manager != NULL) {
      wl_global_destroy(server->manager);
      server->manager = NULL;
    }
  } else if (strcmp(command, "restore-manager") == 0) {
    ++server->generation;
    server->manager = wl_global_create(server->display, &wl_data_device_manager_interface, (int)server->manager_version, server, bind_manager);
  } else if (strcmp(command, "remove-seat") == 0) {
    if (server->seat != NULL) {
      wl_global_destroy(server->seat);
      server->seat = NULL;
    }
  } else if (strcmp(command, "restore-seat") == 0) {
    ++server->generation;
    server->seat = wl_global_create(server->display, &wl_seat_interface, (int)server->seat_version, server, bind_seat);
  } else if (strcmp(command, "clear") == 0) {
    struct Device *device;
    wl_list_for_each(device, &server->devices, link) {
      if (!device->active) {
        continue;
      }

      wl_data_device_send_selection(device->resource, NULL);
    }
  } else if (strcmp(command, "select") == 0 || strcmp(command, "flood8") == 0 || strcmp(command, "flood20") == 0) {
    ++server->generation;
    const unsigned offers = strcmp(command, "flood8") == 0 ? 8 : (strcmp(command, "flood20") == 0 ? 20 : 1);
    struct Device *device;
    wl_list_for_each(device, &server->devices, link) {
      if (!device->active) {
        continue;
      }

      struct wl_resource *last = NULL;
      for (unsigned index = 0; index < offers; ++index) {
        last = announce(device);
      }

      wl_data_device_send_selection(device->resource, last);
    }
  }

  wl_display_flush_clients(server->display);
  const char acknowledgment = 'K';
  if (write(descriptor, &acknowledgment, 1) != 1) {
    wl_display_terminate(server->display);
  }

  return 0;
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  const unsigned seat_version = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 10) : 8;
  const unsigned manager_version = argc > 2 ? (unsigned)strtoul(argv[2], NULL, 10) : 3;
  if (seat_version < 1 || seat_version > 8 || manager_version < 1 || manager_version > 3) {
    return 1;
  }

  struct Server server = {.generation = 1, .seat_version = seat_version, .manager_version = manager_version, .control = STDIN_FILENO};
  wl_list_init(&server.devices);
  server.display = wl_display_create();
  if (server.display == NULL) {
    return 1;
  }

  if (getenv("TELAR_WAYLAND_TEST_LATE_SEAT") == NULL) {
    server.seat = wl_global_create(server.display, &wl_seat_interface, (int)seat_version, &server, bind_seat);
  }
  server.manager = wl_global_create(server.display, &wl_data_device_manager_interface, (int)manager_version, &server, bind_manager);
  const char *socket = wl_display_add_socket_auto(server.display);
  struct wl_event_source *source = wl_event_loop_add_fd(wl_display_get_event_loop(server.display), server.control, WL_EVENT_READABLE, control, &server);
  if (socket == NULL || source == NULL || server.manager == NULL) {
    wl_display_destroy(server.display);
    return 1;
  }

  puts(socket);
  fflush(stdout);
  wl_display_run(server.display);
  wl_event_source_remove(source);
  wl_display_destroy_clients(server.display);
  wl_display_destroy(server.display);

  return 0;
}
