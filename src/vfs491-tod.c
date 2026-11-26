#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>

#include <gio/gio.h>
#include <gmodule.h>

#include "fp-device.h"
#include "fp-image-device.h"
#include "fpi-device.h"
#include "fpi-image-device.h"
#include "fpi-image.h"

#include "vfs491-protocol.h"
#include "vfs491-image-metrics.h"

#ifndef VFS491_DEFAULT_CLIENT
#define VFS491_DEFAULT_CLIENT "/usr/libexec/vfs491/vfs491-client"
#endif
#ifndef VFS491_DEFAULT_BRIDGE
#define VFS491_DEFAULT_BRIDGE "/usr/libexec/vfs491/vfs491-bridge"
#endif
#ifndef VFS491_DEFAULT_HELPER
#define VFS491_DEFAULT_HELPER "/usr/libexec/vfs491/vfs_proprietary-capture-helper"
#endif
#ifndef VFS491_DEFAULT_HP_LIBDIR
#define VFS491_DEFAULT_HP_LIBDIR "/usr/lib/vfs491/vendor"
#endif
#ifndef VFS491_DEFAULT_READFULL
#define VFS491_DEFAULT_READFULL "/usr/lib/vfs491/libvfs491-readfull.so"
#endif
#ifndef VFS491_DEFAULT_FIRMWARE
#define VFS491_DEFAULT_FIRMWARE "/usr/lib/vfs491/vendor/firmware/HPUsbVFS491.img"
#endif

#define VFS491_MAX_CAPTURE_ERROR_RETRIES 2
#define VFS491_ENROLL_STAGES 1
#define VFS491_CANCEL_GRACE_SECONDS 8
#define VFS491_MAX_FRAME_SIZE (sizeof (struct vfs491_frame_header) + VFS491_MAX_IMAGE_BYTES)

typedef struct _FpDeviceVfs491 FpDeviceVfs491;
typedef struct _FpDeviceVfs491Class FpDeviceVfs491Class;

struct _FpDeviceVfs491 {
    FpImageDevice parent_instance;

    GSubprocess *session_job;
    GDataInputStream *session_stdout;
    GOutputStream *session_stdin;
    guint force_exit_source;
    gboolean active;
    gboolean opening;
    gboolean open_completed;
    gboolean deactivating;
    gboolean session_starting;
    gboolean session_ready;
    gboolean activation_completed;
    gboolean capture_pending;
    gboolean session_failed;
    gboolean session_process_exited;
    gboolean close_pending;
    guint io_pending;
    guint capture_error_count;
    gchar *claim_id;
    guint capture_sequence;
    gint64 session_started_us;
    gint64 capture_started_us;
    guint8 *pending_frame;
    gsize pending_frame_length;
};

struct _FpDeviceVfs491Class {
    FpImageDeviceClass parent_class;
};

#define FPI_TYPE_DEVICE_VFS491 (fp_device_vfs491_get_type ())
G_DEFINE_TYPE (FpDeviceVfs491, fp_device_vfs491, FP_TYPE_IMAGE_DEVICE)

static void vfs491_start_session (FpDeviceVfs491 *self);
static void vfs491_start_capture (FpDeviceVfs491 *self);
static void vfs491_maybe_finish_deactivation (FpDeviceVfs491 *self);

static void
vfs491_report_error (FpDeviceVfs491 *self, GError *error)
{
    if (!error)
        error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED,
                                     "VFS491 session failed without an error detail");

    if (self->active && !self->deactivating && !self->session_failed) {
        self->session_failed = TRUE;
        fpi_image_device_session_error (FP_IMAGE_DEVICE (self), error);
    } else {
        g_error_free (error);
    }
}

static gboolean
vfs491_force_session_exit (gpointer user_data)
{
    FpDeviceVfs491 *self = user_data;
    self->force_exit_source = 0;
    /* Killing only the per-claim proxy closes its socket. The persistent
     * vendor service and its USB ownership are deliberately left untouched. */
    if (self->session_job)
        g_subprocess_force_exit (self->session_job);
    return G_SOURCE_REMOVE;
}

static void
vfs491_clear_session_handles (FpDeviceVfs491 *self)
{
    g_clear_object (&self->session_stdout);
    g_clear_object (&self->session_stdin);
    g_clear_object (&self->session_job);
    g_clear_pointer (&self->pending_frame, g_free);
    self->pending_frame_length = 0;
    self->session_starting = FALSE;
    self->session_ready = FALSE;
    self->capture_pending = FALSE;
}

static void
vfs491_cleanup_failed_open_if_idle (FpDeviceVfs491 *self)
{
    if (self->session_process_exited && self->session_failed &&
        !self->opening && !self->active && !self->close_pending &&
        self->io_pending == 0) {
        vfs491_clear_session_handles (self);
        self->session_process_exited = FALSE;
        self->session_failed = FALSE;
    }
}

static void
vfs491_finish_deactivation (FpDeviceVfs491 *self)
{
    if (self->force_exit_source) {
        g_source_remove (self->force_exit_source);
        self->force_exit_source = 0;
    }

    /* Image-device deactivation ends a capture cycle, not the fprintd device
     * claim. Keep the per-claim broker proxy open until img_close(). */
    self->active = FALSE;
    self->deactivating = FALSE;
    fpi_image_device_deactivate_complete (FP_IMAGE_DEVICE (self), NULL);
}

static void
vfs491_finish_close (FpDeviceVfs491 *self)
{
    if (self->force_exit_source) {
        g_source_remove (self->force_exit_source);
        self->force_exit_source = 0;
    }

    vfs491_clear_session_handles (self);
    self->active = FALSE;
    self->opening = FALSE;
    self->open_completed = FALSE;
    self->deactivating = FALSE;
    self->activation_completed = FALSE;
    self->session_failed = FALSE;
    self->session_process_exited = FALSE;
    self->close_pending = FALSE;
    self->capture_error_count = 0;
    g_clear_pointer (&self->claim_id, g_free);
    self->capture_sequence = 0;
    fpi_image_device_close_complete (FP_IMAGE_DEVICE (self), NULL);
}

static void
vfs491_maybe_finish_deactivation (FpDeviceVfs491 *self)
{
    if (!self->session_process_exited || self->io_pending != 0)
        return;

    if (self->close_pending)
        vfs491_finish_close (self);
    else if (self->deactivating)
        vfs491_finish_deactivation (self);
}

static gboolean
vfs491_parse_image_frame (GBytes *bytes,
                          guint *width_out,
                          guint *height_out,
                          const guint8 **pixels_out,
                          gsize *length_out,
                          GError **error)
{
    gsize size = 0;
    const guint8 *data = g_bytes_get_data (bytes, &size);
    struct vfs491_frame_header header;
    guint32 magic, version, width, height, image_len;

    if (size < sizeof (header)) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                             "VFS491 broker returned a truncated frame header");
        return FALSE;
    }

    memcpy (&header, data, sizeof (header));
    magic = GUINT32_FROM_LE (header.magic_le);
    version = GUINT32_FROM_LE (header.version_le);
    width = GUINT32_FROM_LE (header.width_le);
    height = GUINT32_FROM_LE (header.height_le);
    image_len = GUINT32_FROM_LE (header.image_len_le);

    if (magic != VFS491_FRAME_MAGIC || version != VFS491_FRAME_VERSION ||
        width != VFS491_IMAGE_WIDTH || height == 0 ||
        height > VFS491_MAX_IMAGE_HEIGHT ||
        image_len != width * height || image_len > VFS491_MAX_IMAGE_BYTES ||
        size != sizeof (header) + image_len) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                     "Invalid VFS491 frame (width=%u height=%u length=%u total=%" G_GSIZE_FORMAT ")",
                     width, height, image_len, size);
        return FALSE;
    }

    *width_out = width;
    *height_out = height;
    *pixels_out = data + sizeof (header);
    *length_out = image_len;
    return TRUE;
}

static void
vfs491_log_frame_statistics (FpDeviceVfs491 *self,
                             const guint8 *pixels,
                             gsize image_len,
                             guint width,
                             guint height,
                             gdouble capture_ms)
{
    struct vfs491_image_metrics metrics;

    if (vfs491_image_metrics_compute (pixels, image_len, width, height,
                                      &metrics) != 0) {
        g_warning ("VFS491: could not calculate image quality telemetry");
        return;
    }

    /* Derived statistics only: never journal pixels, templates or minutiae.
     * The claim/capture key lets the verification-study tool associate these
     * measurements with one fprintd-verify result without storing biometrics. */
    g_message ("VFS491_EVENT type=frame claim_id=%s capture=%u"
               " width=%u height=%u bytes=%" G_GSIZE_FORMAT
               " capture_ms=%.1f min=%u p05=%u p50=%u p95=%u max=%u"
               " mean=%.2f stddev=%.2f entropy=%.3f"
               " dark_pct=%.2f bright_pct=%.2f row_sd=%.2f col_sd=%.2f"
               " grad_h=%.2f grad_v=%.2f",
               self->claim_id ? self->claim_id : "unassigned",
               self->capture_sequence, width, height, image_len, capture_ms,
               (guint)metrics.minimum,
               (guint)metrics.percentile_05,
               (guint)metrics.percentile_50,
               (guint)metrics.percentile_95,
               (guint)metrics.maximum,
               metrics.mean, metrics.stddev, metrics.entropy_bits,
               metrics.dark_pct, metrics.bright_pct,
               metrics.row_mean_stddev, metrics.column_mean_stddev,
               metrics.horizontal_gradient_mean,
               metrics.vertical_gradient_mean);
}

static void
vfs491_deliver_frame (FpDeviceVfs491 *self, GBytes *bytes,
                      gdouble capture_ms)
{
    g_autoptr(GError) error = NULL;
    guint width = 0, height = 0;
    const guint8 *pixels = NULL;
    gsize image_len = 0;
    FpImage *image;

    if (!vfs491_parse_image_frame (bytes, &width, &height,
                                   &pixels, &image_len, &error)) {
        vfs491_report_error (self, g_steal_pointer (&error));
        return;
    }

    vfs491_log_frame_statistics (self, pixels, image_len, width, height,
                                 capture_ms);

    image = fp_image_new ((gint) width, (gint) height);
    if (!image) {
        g_set_error_literal (&error, G_IO_ERROR, G_IO_ERROR_NO_SPACE,
                             "Could not allocate a VFS491 fingerprint image");
        vfs491_report_error (self, g_steal_pointer (&error));
        return;
    }

    memcpy (image->data, pixels, image_len);
    self->capture_error_count = 0;
    /* Match the established Validity proprietary driver convention.
     * Do not resize, rotate or normalize these pixels in the transport layer;
     * libfprint applies these flags consistently for enrollment and verify. */
    image->flags = FPI_IMAGE_COLORS_INVERTED | FPI_IMAGE_V_FLIPPED;

    fpi_image_device_report_finger_status (FP_IMAGE_DEVICE (self), TRUE);
    fpi_image_device_image_captured (FP_IMAGE_DEVICE (self), image);
    fpi_image_device_report_finger_status (FP_IMAGE_DEVICE (self), FALSE);
}

static void
vfs491_retry_scan_or_fail (FpDeviceVfs491 *self, const gchar *reason)
{
    if (!self->active || self->deactivating || self->session_failed)
        return;

    self->capture_error_count++;
    if (self->capture_error_count > VFS491_MAX_CAPTURE_ERROR_RETRIES) {
        g_autoptr(GError) error = g_error_new (G_IO_ERROR, G_IO_ERROR_FAILED,
                                               "VFS491 capture failed repeatedly (%s)", reason);
        vfs491_report_error (self, g_steal_pointer (&error));
        return;
    }

    g_warning ("VFS491: %s; requesting another capture in the same device session (%u/%u)",
               reason, self->capture_error_count, VFS491_MAX_CAPTURE_ERROR_RETRIES);
    fpi_image_device_retry_scan (FP_IMAGE_DEVICE (self), FP_DEVICE_RETRY_GENERAL);
}

static void vfs491_session_read_response (FpDeviceVfs491 *self);

static void
vfs491_frame_read_done (GObject *source_object,
                        GAsyncResult *result,
                        gpointer user_data)
{
    FpDeviceVfs491 *self = user_data;
    gsize bytes_read = 0;
    g_autoptr(GError) error = NULL;

    gboolean ok = g_input_stream_read_all_finish (G_INPUT_STREAM (source_object),
                                                   result, &bytes_read, &error);
    if (self->io_pending > 0)
        self->io_pending--;
    self->capture_pending = FALSE;

    if (self->deactivating || self->session_failed) {
        g_clear_pointer (&self->pending_frame, g_free);
        self->pending_frame_length = 0;
        vfs491_maybe_finish_deactivation (self);
        g_object_unref (self);
        return;
    }

    if (!ok || bytes_read != self->pending_frame_length) {
        if (!error)
            error = g_error_new (G_IO_ERROR, G_IO_ERROR_PARTIAL_INPUT,
                                 "VFS491 session frame was truncated (%" G_GSIZE_FORMAT "/%" G_GSIZE_FORMAT ")",
                                 bytes_read, self->pending_frame_length);
        g_clear_pointer (&self->pending_frame, g_free);
        self->pending_frame_length = 0;
        vfs491_report_error (self, g_steal_pointer (&error));
        vfs491_maybe_finish_deactivation (self);
        g_object_unref (self);
        return;
    }

    GBytes *bytes = g_bytes_new_take (self->pending_frame, bytes_read);
    self->pending_frame = NULL;
    self->pending_frame_length = 0;
    const gdouble capture_ms = self->capture_started_us > 0
        ? (g_get_monotonic_time () - self->capture_started_us) / 1000.0
        : 0.0;
    g_message ("VFS491: received a complete frame (%" G_GSIZE_FORMAT
               " bytes) in %.1f ms", bytes_read, capture_ms);
    self->capture_started_us = 0;
    vfs491_deliver_frame (self, bytes, capture_ms);
    g_bytes_unref (bytes);
    vfs491_maybe_finish_deactivation (self);
    g_object_unref (self);
}

static void
vfs491_response_line_done (GObject *source_object,
                           GAsyncResult *result,
                           gpointer user_data)
{
    FpDeviceVfs491 *self = user_data;
    gsize line_length = 0;
    g_autoptr(GError) error = NULL;
    gchar *line = g_data_input_stream_read_line_finish (G_DATA_INPUT_STREAM (source_object),
                                                        result, &line_length, &error);
    if (self->io_pending > 0)
        self->io_pending--;

    if (self->deactivating || self->session_failed) {
        g_free (line);
        vfs491_maybe_finish_deactivation (self);
        g_object_unref (self);
        return;
    }

    if (!line) {
        self->capture_pending = FALSE;
        if (!error)
            error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED,
                                         "VFS491 broker connection closed while waiting for a capture result");
        vfs491_report_error (self, g_steal_pointer (&error));
        vfs491_maybe_finish_deactivation (self);
        g_object_unref (self);
        return;
    }

    if (g_str_has_prefix (line, "ERR ")) {
        gchar *end = NULL;
        gint status = (gint) g_ascii_strtoll (line + 4, &end, 10);
        gboolean valid = end != line + 4 && *end == '\0';
        g_free (line);
        self->capture_pending = FALSE;
        const gdouble capture_ms = self->capture_started_us > 0
            ? (g_get_monotonic_time () - self->capture_started_us) / 1000.0
            : 0.0;
        g_message ("VFS491: capture response received in %.1f ms", capture_ms);
        if (valid)
            g_message ("VFS491_EVENT type=capture_error claim_id=%s capture=%u broker_status=%d capture_ms=%.1f",
                       self->claim_id ? self->claim_id : "unassigned",
                       self->capture_sequence, status, capture_ms);
        self->capture_started_us = 0;
        if (!valid) {
            vfs491_report_error (self,
                g_error_new_literal (G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                                     "VFS491 broker returned a malformed error response"));
        } else if (status == VFS491_BROKER_ERR_ACQUISITION) {
            vfs491_retry_scan_or_fail (self, "vendor capture returned an acquisition error");
        } else if (status == VFS491_BROKER_ERR_NO_SWIPE_SESSION_RESET ||
                   status == VFS491_BROKER_ERR_HELPER_FAILURE ||
                   status == VFS491_BROKER_ERR_SESSION_RESET) {
            vfs491_report_error (self,
                g_error_new (G_IO_ERROR, G_IO_ERROR_FAILED,
                             "VFS491 capture session is no longer safe to reuse (broker status %d); close the device claim so the vendor service can be restarted", status));
        } else {
            vfs491_report_error (self,
                g_error_new (G_IO_ERROR, G_IO_ERROR_FAILED,
                             "VFS491 broker capture failed with status %d", status));
        }
        vfs491_maybe_finish_deactivation (self);
        g_object_unref (self);
        return;
    }

    if (g_str_has_prefix (line, "OK ")) {
        gchar *end = NULL;
        guint64 length = g_ascii_strtoull (line + 3, &end, 10);
        gboolean valid = end != line + 3 && *end == '\0' &&
                         length >= sizeof (struct vfs491_frame_header) &&
                         length <= VFS491_MAX_FRAME_SIZE;
        g_free (line);
        if (!valid) {
            self->capture_pending = FALSE;
            vfs491_report_error (self,
                g_error_new_literal (G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                                     "VFS491 broker returned an invalid frame length"));
            vfs491_maybe_finish_deactivation (self);
            g_object_unref (self);
            return;
        }

        self->pending_frame_length = (gsize) length;
        self->pending_frame = g_malloc (self->pending_frame_length);
        self->io_pending++;
        g_input_stream_read_all_async (G_INPUT_STREAM (self->session_stdout),
                                       self->pending_frame,
                                       self->pending_frame_length,
                                       G_PRIORITY_DEFAULT, NULL,
                                       vfs491_frame_read_done, g_object_ref (self));
        g_object_unref (self);
        return;
    }

    g_free (line);
    self->capture_pending = FALSE;
    vfs491_report_error (self,
        g_error_new_literal (G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                             "VFS491 broker returned an unknown response"));
    vfs491_maybe_finish_deactivation (self);
    g_object_unref (self);
}

static void
vfs491_session_read_response (FpDeviceVfs491 *self)
{
    self->io_pending++;
    g_data_input_stream_read_line_async (self->session_stdout,
                                         G_PRIORITY_DEFAULT, NULL,
                                         vfs491_response_line_done,
                                         g_object_ref (self));
}

static void
vfs491_capture_command_written (GObject *source_object,
                                GAsyncResult *result,
                                gpointer user_data)
{
    FpDeviceVfs491 *self = user_data;
    gsize bytes_written = 0;
    g_autoptr(GError) error = NULL;
    gboolean ok = g_output_stream_write_all_finish (G_OUTPUT_STREAM (source_object),
                                                     result, &bytes_written, &error);
    if (self->io_pending > 0)
        self->io_pending--;

    if (self->deactivating || self->session_failed) {
        vfs491_maybe_finish_deactivation (self);
        g_object_unref (self);
        return;
    }

    if (!ok || bytes_written != 8) {
        self->capture_pending = FALSE;
        if (!error)
            error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED,
                                         "Could not send capture request to VFS491 broker");
        vfs491_report_error (self, g_steal_pointer (&error));
    } else {
        vfs491_session_read_response (self);
    }
    vfs491_maybe_finish_deactivation (self);
    g_object_unref (self);
}

static void
vfs491_start_capture (FpDeviceVfs491 *self)
{
    static const gchar command[] = "CAPTURE\n";

    if (!self->active || self->deactivating || !self->session_ready ||
        self->capture_pending || self->session_failed)
        return;

    self->capture_pending = TRUE;
    self->capture_sequence++;
    self->capture_started_us = g_get_monotonic_time ();
    g_message ("VFS491_EVENT type=capture_start claim_id=%s capture=%u",
               self->claim_id ? self->claim_id : "unassigned",
               self->capture_sequence);
    g_message ("VFS491: requesting swipe capture in the current session");
    self->io_pending++;
    g_output_stream_write_all_async (self->session_stdin,
                                     command, sizeof (command) - 1,
                                     G_PRIORITY_DEFAULT, NULL,
                                     vfs491_capture_command_written,
                                     g_object_ref (self));
}

static void
vfs491_session_ready_line_done (GObject *source_object,
                                GAsyncResult *result,
                                gpointer user_data)
{
    FpDeviceVfs491 *self = user_data;
    gsize line_length = 0;
    g_autoptr(GError) error = NULL;
    gchar *line = g_data_input_stream_read_line_finish (G_DATA_INPUT_STREAM (source_object),
                                                        result, &line_length, &error);
    if (self->io_pending > 0)
        self->io_pending--;

    if (!self->session_starting || self->deactivating) {
        g_free (line);
        vfs491_maybe_finish_deactivation (self);
        vfs491_cleanup_failed_open_if_idle (self);
        g_object_unref (self);
        return;
    }

    if (!line || g_strcmp0 (line, "READY") != 0) {
        g_warning ("VFS491: persistent service client did not publish READY; closing the client connection");
        g_free (line);
        if (self->session_job)
            g_subprocess_force_exit (self->session_job);
        g_object_unref (self);
        return;
    }

    self->session_starting = FALSE;
    g_free (line);
    self->session_ready = TRUE;
    g_message ("VFS491: persistent broker client connected in %.1f ms",
               self->session_started_us > 0
                   ? (g_get_monotonic_time () - self->session_started_us) / 1000.0
                   : 0.0);
    self->session_started_us = 0;
    g_message ("VFS491: systemd-managed vendor service is ready for this device session");

    if (self->opening && !self->open_completed) {
        self->opening = FALSE;
        self->open_completed = TRUE;
        fpi_image_device_open_complete (FP_IMAGE_DEVICE (self), NULL);
    } else {
        self->activation_completed = TRUE;
        fpi_image_device_activate_complete (FP_IMAGE_DEVICE (self), NULL);
    }
    vfs491_maybe_finish_deactivation (self);
    g_object_unref (self);
}

static void
vfs491_session_wait_done (GObject *source_object,
                          GAsyncResult *result,
                          gpointer user_data)
{
    FpDeviceVfs491 *self = user_data;
    GSubprocess *process = G_SUBPROCESS (source_object);
    g_autoptr(GError) error = NULL;

    if (!g_subprocess_wait_finish (process, result, &error)) {
        if (self->deactivating || self->close_pending) {
            /* A requested stop/close may make wait_finish report cancellation. */
        } else if (self->opening && !self->open_completed) {
            self->session_starting = FALSE;
            self->opening = FALSE;
            self->open_completed = TRUE;
            self->session_failed = TRUE;
            fpi_image_device_open_complete (FP_IMAGE_DEVICE (self),
                                            g_steal_pointer (&error));
        } else if (self->session_starting && !self->activation_completed) {
            self->session_starting = FALSE;
            self->active = FALSE;
            self->activation_completed = TRUE;
            fpi_image_device_activate_complete (FP_IMAGE_DEVICE (self),
                                                g_steal_pointer (&error));
        } else if (!self->session_failed) {
            vfs491_report_error (self, g_steal_pointer (&error));
        }
    } else if (self->deactivating || self->close_pending) {
        /* Normal close/cancel path. */
    } else if (self->opening && !self->open_completed) {
        self->session_starting = FALSE;
        self->opening = FALSE;
        self->open_completed = TRUE;
        self->session_failed = TRUE;
        fpi_image_device_open_complete (
            FP_IMAGE_DEVICE (self),
            g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED,
                                 "VFS491 persistent broker client exited before device-open readiness"));
    } else if (self->session_starting && !self->activation_completed) {
        self->session_starting = FALSE;
        self->active = FALSE;
        self->activation_completed = TRUE;
        fpi_image_device_activate_complete (
            FP_IMAGE_DEVICE (self),
            g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED,
                                 "VFS491 persistent broker client exited before readiness"));
    } else if (!self->close_pending && !self->deactivating) {
        self->session_failed = TRUE;
        if (self->active)
            vfs491_report_error (self,
                g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED,
                                     "VFS491 persistent broker connection exited unexpectedly; recovery requires device close"));
    }

    self->session_process_exited = TRUE;
    g_clear_object (&self->session_job);
    vfs491_maybe_finish_deactivation (self);
    vfs491_cleanup_failed_open_if_idle (self);
    g_object_unref (self);
}

static void
vfs491_complete_start_error (FpDeviceVfs491 *self, GError *error)
{
    if (self->opening && !self->open_completed) {
        self->opening = FALSE;
        self->open_completed = TRUE;
        self->session_failed = TRUE;
        fpi_image_device_open_complete (FP_IMAGE_DEVICE (self), error);
    } else {
        self->active = FALSE;
        self->activation_completed = TRUE;
        fpi_image_device_activate_complete (FP_IMAGE_DEVICE (self), error);
    }
}

static void
vfs491_start_session (FpDeviceVfs491 *self)
{
    const gchar *client = VFS491_DEFAULT_CLIENT;
    g_autoptr(GSubprocessLauncher) launcher = NULL;
    g_autoptr(GError) error = NULL;
    const gchar *argv[2];

    if ((!self->active && !self->opening) || self->deactivating || self->session_job)
        return;

    if (!g_file_test (client, G_FILE_TEST_IS_EXECUTABLE)) {
        error = g_error_new (G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                             "VFS491 persistent-service client is missing: %s", client);
        vfs491_complete_start_error (self, g_steal_pointer (&error));
        return;
    }

    self->session_started_us = g_get_monotonic_time ();
    argv[0] = client;
    argv[1] = NULL;

    launcher = g_subprocess_launcher_new (G_SUBPROCESS_FLAGS_STDIN_PIPE |
                                          G_SUBPROCESS_FLAGS_STDOUT_PIPE);
    self->session_job = g_subprocess_launcher_spawnv (launcher, argv, &error);
    if (!self->session_job) {
        vfs491_complete_start_error (self, g_steal_pointer (&error));
        return;
    }

    self->session_stdin = g_object_ref (g_subprocess_get_stdin_pipe (self->session_job));
    self->session_stdout = g_data_input_stream_new (
        g_subprocess_get_stdout_pipe (self->session_job));
    self->session_starting = TRUE;
    self->session_failed = FALSE;
    self->session_process_exited = FALSE;
    self->io_pending = 1;

    g_subprocess_wait_async (self->session_job, NULL,
                             vfs491_session_wait_done, g_object_ref (self));
    g_data_input_stream_read_line_async (self->session_stdout,
                                         G_PRIORITY_DEFAULT, NULL,
                                         vfs491_session_ready_line_done,
                                         g_object_ref (self));
}

static void
vfs491_img_open (FpImageDevice *device)
{
    FpDeviceVfs491 *self = (FpDeviceVfs491 *) device;
    GError *error = NULL;

    if (geteuid () != 0) {
        error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
                                     "VFS491 TOD backend must be opened by fprintd");
    } else if (!g_file_test (VFS491_DEFAULT_CLIENT, G_FILE_TEST_IS_EXECUTABLE)) {
        error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                                     "VFS491 persistent-service client is missing");
    } else if (!g_file_test (VFS491_DEFAULT_BRIDGE, G_FILE_TEST_IS_EXECUTABLE) ||
               !g_file_test (VFS491_DEFAULT_HELPER, G_FILE_TEST_IS_EXECUTABLE) ||
               !g_file_test (VFS491_DEFAULT_HP_LIBDIR "/vcsFPService", G_FILE_TEST_IS_EXECUTABLE) ||
               !g_file_test (VFS491_DEFAULT_HP_LIBDIR "/libvfsFprintWrapper.so", G_FILE_TEST_IS_REGULAR) ||
               !g_file_test (VFS491_DEFAULT_READFULL, G_FILE_TEST_IS_REGULAR) ||
               !g_file_test (VFS491_DEFAULT_FIRMWARE, G_FILE_TEST_IS_REGULAR)) {
        error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                                     "VFS491 session runtime is incomplete; verify vfs491-fprintd-tod");
    }

    if (error) {
        fpi_image_device_open_complete (device, error);
        return;
    }

    if (self->session_job || self->session_starting || self->io_pending != 0 ||
        self->session_process_exited || self->session_stdout) {
        fpi_image_device_open_complete (
            device,
            g_error_new_literal (G_IO_ERROR, G_IO_ERROR_BUSY,
                                 "VFS491 still has an earlier session shutting down; close and retry"));
        return;
    }

    g_clear_pointer (&self->claim_id, g_free);
    self->claim_id = g_uuid_string_random ();
    self->capture_sequence = 0;
    self->opening = TRUE;
    self->open_completed = FALSE;
    self->active = FALSE;
    self->deactivating = FALSE;
    self->session_failed = FALSE;
    self->session_process_exited = FALSE;
    self->capture_error_count = 0;

    /* Connect to the systemd-managed broker during device claim. The proxy is
     * per-claim; the vendor service and USB ownership outlive every claim. */
    vfs491_start_session (self);
}

static void
vfs491_img_close (FpImageDevice *device)
{
    FpDeviceVfs491 *self = (FpDeviceVfs491 *) device;
    static const gchar quit_command[] = "QUIT\n";

    if (self->close_pending)
        return;

    self->close_pending = TRUE;
    self->active = FALSE;
    /* Drain outstanding I/O without delivering frames or reporting a new
     * capture error while the FpDevice close is in progress. */
    self->deactivating = TRUE;
    self->session_failed = TRUE;

    if (!self->session_job) {
        self->session_process_exited = TRUE;
        if (self->io_pending == 0)
            vfs491_finish_close (self);
        return;
    }

    if (self->session_stdin && self->session_ready) {
        gsize written = 0;
        (void) g_output_stream_write_all (self->session_stdin,
                                          quit_command, sizeof (quit_command) - 1,
                                          &written, NULL, NULL);
        (void) g_output_stream_close (self->session_stdin, NULL, NULL);
    } else {
        /* Closing stdin makes the proxy close its broker connection even if
         * device-open readiness has not arrived yet. */
        if (self->session_stdin)
            (void) g_output_stream_close (self->session_stdin, NULL, NULL);
    }

    if (!self->force_exit_source) {
        self->force_exit_source = g_timeout_add_seconds_full (
            G_PRIORITY_DEFAULT, VFS491_CANCEL_GRACE_SECONDS,
            vfs491_force_session_exit, g_object_ref (self), g_object_unref);
    }
}

static void
vfs491_activate (FpImageDevice *device)
{
    FpDeviceVfs491 *self = (FpDeviceVfs491 *) device;
    g_autoptr(GError) error = NULL;

    if (self->close_pending) {
        fpi_image_device_activate_complete (device,
            g_error_new_literal (G_IO_ERROR, G_IO_ERROR_BUSY,
                                 "VFS491 device is closing"));
        return;
    }

    if (self->session_failed) {
        fpi_image_device_activate_complete (device,
            g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED,
                                 "VFS491 session failed; close and reopen the device before recovery"));
        return;
    }

    self->active = TRUE;
    self->deactivating = FALSE;
    self->activation_completed = FALSE;
    self->capture_error_count = 0;

    if (self->session_job && self->session_ready && !self->session_process_exited) {
        self->activation_completed = TRUE;
        fpi_image_device_activate_complete (device, NULL);
        return;
    }

    if (self->session_job || self->session_starting) {
        error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_BUSY,
                                     "VFS491 session is still starting or shutting down");
        self->active = FALSE;
        self->activation_completed = TRUE;
        fpi_image_device_activate_complete (device, g_steal_pointer (&error));
        return;
    }

    vfs491_start_session (self);
}

static void
vfs491_deactivate (FpImageDevice *device)
{
    FpDeviceVfs491 *self = (FpDeviceVfs491 *) device;

    /* A completed swipe only deactivates the image FSM. The broker connection
     * and the systemd-managed vendor service remain available for later swipes. */
    if (!self->capture_pending && !self->session_starting) {
        self->active = FALSE;
        self->deactivating = FALSE;
        fpi_image_device_deactivate_complete (device, NULL);
        return;
    }

    /* Cancellation or an active-session failure is terminal for this device
     * claim. Recovery is deferred until fprintd closes the device. */
    self->active = FALSE;
    self->deactivating = TRUE;
    self->session_failed = TRUE;
    self->session_ready = FALSE;
    if (self->session_job && self->session_stdin) {
        static const gchar quit_command[] = "QUIT\n";
        gsize written = 0;
        (void) g_output_stream_write_all (self->session_stdin,
                                          quit_command, sizeof (quit_command) - 1,
                                          &written, NULL, NULL);
        (void) g_output_stream_close (self->session_stdin, NULL, NULL);
    } else if (self->io_pending == 0) {
        vfs491_finish_deactivation (self);
        return;
    }

    if (!self->force_exit_source) {
        self->force_exit_source = g_timeout_add_seconds_full (
            G_PRIORITY_DEFAULT, VFS491_CANCEL_GRACE_SECONDS,
            vfs491_force_session_exit, g_object_ref (self), g_object_unref);
    }
}

static void
vfs491_change_state (FpImageDevice *device, FpiImageDeviceState state)
{
    FpDeviceVfs491 *self = (FpDeviceVfs491 *) device;
    if (state == FPI_IMAGE_DEVICE_STATE_AWAIT_FINGER_ON)
        vfs491_start_capture (self);
}

static const FpIdEntry vfs491_id_table[] = {
    { .vid = 0x138a, .pid = 0x003d },
    { .vid = 0, .pid = 0, .driver_data = 0 },
};

static void
fp_device_vfs491_finalize (GObject *object)
{
    FpDeviceVfs491 *self = (FpDeviceVfs491 *) object;

    g_clear_pointer (&self->claim_id, g_free);
    G_OBJECT_CLASS (fp_device_vfs491_parent_class)->finalize (object);
}

static void
fp_device_vfs491_init (FpDeviceVfs491 *self)
{
    (void) self;
}

static void
fp_device_vfs491_class_init (FpDeviceVfs491Class *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);
    FpDeviceClass *device_class = FP_DEVICE_CLASS (klass);
    FpImageDeviceClass *image_class = FP_IMAGE_DEVICE_CLASS (klass);

    object_class->finalize = fp_device_vfs491_finalize;
    device_class->id = "vfs491";
    device_class->full_name = "Validity VFS491 (persistent service / session client)";
    device_class->type = FP_DEVICE_TYPE_USB;
    device_class->id_table = vfs491_id_table;
    device_class->scan_type = FP_SCAN_TYPE_SWIPE;
    /* Match the archived Validity VFS proprietary driver's one-stage
     * enrollment declaration. Multi-stage enrollment remains an unvalidated
     * experiment and is not enabled in the reliability baseline. */
    device_class->nr_enroll_stages = VFS491_ENROLL_STAGES;

    /* libfprint 1.94.7 default is 40. Set it explicitly for a reproducible
     * matcher configuration; do not lower it without false-accept testing. */
    image_class->bz3_threshold = 40;

    image_class->img_width = (gint) VFS491_IMAGE_WIDTH;
    image_class->img_height = -1;
    image_class->img_open = vfs491_img_open;
    image_class->img_close = vfs491_img_close;
    image_class->activate = vfs491_activate;
    image_class->change_state = vfs491_change_state;
    image_class->deactivate = vfs491_deactivate;
}

G_MODULE_EXPORT GType
fpi_tod_shared_driver_get_type (void)
{
    return FPI_TYPE_DEVICE_VFS491;
}
