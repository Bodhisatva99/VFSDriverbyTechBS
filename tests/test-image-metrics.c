#include "vfs491-image-metrics.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void
expect_near(const char *name, double actual, double expected, double tolerance)
{
    if (fabs(actual - expected) > tolerance) {
        fprintf(stderr, "FAIL: %s: got %.9f expected %.9f\n", name, actual, expected);
        exit(EXIT_FAILURE);
    }
}

int
main(void)
{
    const uint8_t pixels[] = {0, 80, 160, 240};
    struct vfs491_image_metrics m;

    if (vfs491_image_metrics_compute(pixels, sizeof(pixels), 2, 2, &m) != 0) {
        perror("metrics for 2x2 image");
        return EXIT_FAILURE;
    }

    if (m.minimum != 0 || m.percentile_05 != 0 || m.percentile_50 != 80 ||
        m.percentile_95 != 240 || m.maximum != 240) {
        fprintf(stderr, "FAIL: intensity statistics\n");
        return EXIT_FAILURE;
    }
    expect_near("mean", m.mean, 120.0, 1e-9);
    expect_near("standard deviation", m.stddev, 89.4427191, 1e-6);
    expect_near("entropy", m.entropy_bits, 2.0, 1e-9);
    expect_near("dark percentage", m.dark_pct, 25.0, 1e-9);
    expect_near("bright percentage", m.bright_pct, 25.0, 1e-9);
    expect_near("row mean standard deviation", m.row_mean_stddev, 80.0, 1e-9);
    expect_near("column mean standard deviation", m.column_mean_stddev, 40.0, 1e-9);
    expect_near("horizontal gradient", m.horizontal_gradient_mean, 80.0, 1e-9);
    expect_near("vertical gradient", m.vertical_gradient_mean, 160.0, 1e-9);

    const uint8_t flat[] = {64, 64, 64, 64, 64, 64};
    if (vfs491_image_metrics_compute(flat, sizeof(flat), 3, 2, &m) != 0) {
        perror("metrics for flat image");
        return EXIT_FAILURE;
    }
    expect_near("flat standard deviation", m.stddev, 0.0, 1e-9);
    expect_near("flat entropy", m.entropy_bits, 0.0, 1e-9);
    expect_near("flat horizontal gradient", m.horizontal_gradient_mean, 0.0, 1e-9);
    expect_near("flat vertical gradient", m.vertical_gradient_mean, 0.0, 1e-9);

    if (vfs491_image_metrics_compute(pixels, sizeof(pixels), 3, 2, &m) == 0) {
        fprintf(stderr, "FAIL: mismatched dimensions accepted\n");
        return EXIT_FAILURE;
    }
    if (vfs491_image_metrics_compute(NULL, 0, 0, 0, &m) == 0) {
        fprintf(stderr, "FAIL: empty image accepted\n");
        return EXIT_FAILURE;
    }

    puts("PASS: VFS491 image metrics (percentiles, entropy, saturation, gradients, invalid input)");
    return EXIT_SUCCESS;
}
