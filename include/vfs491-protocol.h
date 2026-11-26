#ifndef VFS491_PROTOCOL_H
#define VFS491_PROTOCOL_H

#include <stdint.h>

#define VFS491_FRAME_MAGIC 0x31534656u /* ASCII "VFS1" in little-endian */
#define VFS491_FRAME_VERSION 1u
#define VFS491_IMAGE_WIDTH 200u
#define VFS491_MAX_IMAGE_HEIGHT 1023u
#define VFS491_MAX_IMAGE_BYTES (VFS491_IMAGE_WIDTH * VFS491_MAX_IMAGE_HEIGHT)

/* Broker ERR status values shared with the native TOD backend. */
#define VFS491_BROKER_ERR_NO_SWIPE_SESSION_RESET 10u
#define VFS491_BROKER_ERR_ACQUISITION 11u
#define VFS491_BROKER_ERR_HELPER_FAILURE 12u
#define VFS491_BROKER_ERR_ACCESS_DENIED 13u
/* The proprietary session is tainted. The active fprintd claim must close
 * before systemd restarts the vendor stack. */
#define VFS491_BROKER_ERR_SESSION_RESET 14u

/* The bridge writes this header followed by exactly image_len grayscale bytes. */
struct __attribute__((packed)) vfs491_frame_header {
    uint32_t magic_le;
    uint32_t version_le;
    uint32_t width_le;
    uint32_t height_le;
    uint32_t image_len_le;
};

#endif
