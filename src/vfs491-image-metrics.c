#include "vfs491-image-metrics.h"

#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

static uint8_t
percentile_value(const size_t histogram[256], size_t count, size_t percentile)
{
    size_t target = (count / 100U) * percentile +
                    (((count % 100U) * percentile + 99U) / 100U);
    size_t accumulated = 0;

    if (target == 0)
        target = 1;
    target--;

    for (size_t value = 0; value < 256; value++) {
        accumulated += histogram[value];
        if (accumulated > target)
            return (uint8_t)value;
    }
    return 255;
}

int
vfs491_image_metrics_compute(const uint8_t *pixels,
                             size_t length,
                             size_t width,
                             size_t height,
                             struct vfs491_image_metrics *result)
{
    size_t histogram[256] = {0};
    uint64_t sum = 0;
    long double sum_squares = 0.0L;
    long double entropy = 0.0L;
    long double row_sum = 0.0L;
    long double row_sum_squares = 0.0L;
    long double column_sum = 0.0L;
    long double column_sum_squares = 0.0L;
    uint64_t horizontal_delta = 0;
    uint64_t vertical_delta = 0;
    size_t dark = 0;
    size_t bright = 0;
    uint8_t minimum = 255;
    uint8_t maximum = 0;

    if (pixels == NULL || result == NULL || width == 0 || height == 0 ||
        width > SIZE_MAX / height || width * height != length || length == 0 ||
        length > UINT64_MAX / 255U) {
        errno = EINVAL;
        return -1;
    }

    memset(result, 0, sizeof(*result));

    for (size_t i = 0; i < length; i++) {
        const uint8_t value = pixels[i];
        histogram[value]++;
        sum += value;
        sum_squares += (long double)value * (long double)value;
        if (value < minimum)
            minimum = value;
        if (value > maximum)
            maximum = value;
        if (value <= 15)
            dark++;
        if (value >= 240)
            bright++;
    }

    const long double count = (long double)length;
    const long double mean = (long double)sum / count;
    long double variance = sum_squares / count - mean * mean;
    if (variance < 0.0L)
        variance = 0.0L;

    for (size_t value = 0; value < 256; value++) {
        if (histogram[value] != 0) {
            const long double probability = (long double)histogram[value] / count;
            entropy -= probability * log2l(probability);
        }
    }

    for (size_t y = 0; y < height; y++) {
        uint64_t line_sum = 0;
        const size_t row = y * width;
        for (size_t x = 0; x < width; x++)
            line_sum += pixels[row + x];
        const long double line_mean = (long double)line_sum / (long double)width;
        row_sum += line_mean;
        row_sum_squares += line_mean * line_mean;
    }

    for (size_t x = 0; x < width; x++) {
        uint64_t line_sum = 0;
        for (size_t y = 0; y < height; y++)
            line_sum += pixels[y * width + x];
        const long double line_mean = (long double)line_sum / (long double)height;
        column_sum += line_mean;
        column_sum_squares += line_mean * line_mean;
    }

    for (size_t y = 0; y < height; y++) {
        const size_t row = y * width;
        for (size_t x = 1; x < width; x++) {
            const int left = pixels[row + x - 1];
            const int right = pixels[row + x];
            horizontal_delta += (uint64_t)(left > right ? left - right : right - left);
        }
    }

    for (size_t y = 1; y < height; y++) {
        const size_t row = y * width;
        const size_t previous = row - width;
        for (size_t x = 0; x < width; x++) {
            const int above = pixels[previous + x];
            const int below = pixels[row + x];
            vertical_delta += (uint64_t)(above > below ? above - below : below - above);
        }
    }

    const long double row_mean = row_sum / (long double)height;
    long double row_variance = row_sum_squares / (long double)height - row_mean * row_mean;
    if (row_variance < 0.0L)
        row_variance = 0.0L;

    const long double column_mean = column_sum / (long double)width;
    long double column_variance = column_sum_squares / (long double)width - column_mean * column_mean;
    if (column_variance < 0.0L)
        column_variance = 0.0L;

    result->minimum = minimum;
    result->percentile_05 = percentile_value(histogram, length, 5);
    result->percentile_50 = percentile_value(histogram, length, 50);
    result->percentile_95 = percentile_value(histogram, length, 95);
    result->maximum = maximum;
    result->mean = (double)mean;
    result->stddev = (double)sqrtl(variance);
    result->entropy_bits = (double)entropy;
    result->dark_pct = 100.0 * (double)dark / (double)length;
    result->bright_pct = 100.0 * (double)bright / (double)length;
    result->row_mean_stddev = (double)sqrtl(row_variance);
    result->column_mean_stddev = (double)sqrtl(column_variance);
    result->horizontal_gradient_mean = width > 1
        ? (double)horizontal_delta / (double)(height * (width - 1)) : 0.0;
    result->vertical_gradient_mean = height > 1
        ? (double)vertical_delta / (double)((height - 1) * width) : 0.0;

    return 0;
}
