#ifndef TELAR_TAB_SWITCH_PACKET_H
#define TELAR_TAB_SWITCH_PACKET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { TabPacketDataCells = 7, TabPacketCells = TabPacketDataCells + 1 };

typedef struct {
    unsigned tab;
    unsigned generation;
} TabPacket;

static inline uint8_t tab_packet_checksum(unsigned tab, unsigned generation) {
    const unsigned bytes[] = {tab, generation >> 8, generation & 255};
    uint8_t result = 0;
    for (size_t index = 0; index < sizeof(bytes) / sizeof(bytes[0]); ++index) {
        result ^= (uint8_t)bytes[index];
        for (unsigned bit = 0; bit < 8; ++bit) {
            result = (uint8_t)((result << 1) ^ ((result & 128) ? 7 : 0));
        }
    }
    return result;
}

// Input starts at the anchor's center; every cell sample must be opaque and exact.
static inline bool tab_packet_decode(const uint8_t *pixels, size_t length, size_t cell_bytes, TabPacket *result) {
    if (cell_bytes < 4 || length < 4 || cell_bytes > (length - 4) / TabPacketDataCells) {
        return false;
    }
    if (pixels[0] != 60 || pixels[1] != 20 || pixels[2] != 230 || pixels[3] != 255) {
        return false;
    }
    unsigned values[TabPacketDataCells];
    for (size_t index = 0; index < TabPacketDataCells; ++index) {
        const uint8_t *pixel = pixels + (index + 1) * cell_bytes;
        if (pixel[0] != pixel[1] || pixel[1] != pixel[2] || pixel[3] != 255 || pixel[0] < 8 || (pixel[0] - 8) % 16 != 0) {
            return false;
        }
        values[index] = (pixel[0] - 8) / 16;
    }
    const unsigned generation = (values[1] << 12) | (values[2] << 8) | (values[3] << 4) | values[4];
    if (!generation || tab_packet_checksum(values[0], generation) != ((values[5] << 4) | values[6])) {
        return false;
    }
    *result = (TabPacket){values[0], generation};
    return true;
}

#endif
