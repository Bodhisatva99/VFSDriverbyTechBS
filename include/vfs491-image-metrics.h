#ifndef VFS491_IMAGE_METRICS_H
#define VFS491_IMAGE_METRICS_H

#include <stddef.h>
#include <stdint.h>

struct vfs491_image_metrics {
    uint8_t minimum;
    uint8_t percentile_05;
    uint8_t percentile_50;
    uint8_t percentile_95;
    uint8_t maximum;
    double mean;
    double stddev;
    double entropy_bits;
    double dark_pct;
    double bright_pct;
    double row_mean_stddev;
    double column_mean_stddev;
    double horizontal_gradient_mean;
    double vertical_gradient_mean;
};

/* Returns 0 on success and -1 for invalid input. Does not retain pixel data. */
int vfs491_image_metrics_compute(const uint8_t *pixels,
                                 size_t length,
                                 size_t width,
                                 size_t height,
                                 struct vfs491_image_metrics *result);

#endif
