#include <stdbool.h>
#include <stdlib.h>
#include "mlx/c/stream.h"
#include "mlx/c/ops.h"

mlx_stream mlx_stream_new_thread_unsafe(mlx_device dev) { return mlx_stream_new_device(dev); }

#define MISSING(name) int name(void) { abort(); }
MISSING(mlx_count_nonzero)
MISSING(mlx_count_nonzero_axes)
MISSING(mlx_count_nonzero_axis)
MISSING(mlx_cummax_axis)
MISSING(mlx_cummin_axis)
MISSING(mlx_cumprod_axis)
MISSING(mlx_cumsum_axis)
MISSING(mlx_diff)
MISSING(mlx_fast_cross_entropy)
MISSING(mlx_fast_gated_delta_update)
MISSING(mlx_flip_axes)
MISSING(mlx_flip_axis)
MISSING(mlx_get_array_buffer_size)
MISSING(mlx_logcumsumexp_axis)
MISSING(mlx_logical_xor)
MISSING(mlx_matrix_transpose)
MISSING(mlx_median_axes)
MISSING(mlx_median_axis)
MISSING(mlx_metal_get_metallib_path)
MISSING(mlx_metal_set_metallib_path)
MISSING(mlx_positive)
MISSING(mlx_searchsorted)
MISSING(mlx_trace_axes)
MISSING(mlx_trunc)
MISSING(mlx_unique)
MISSING(mlx_unstack_axis)
MISSING(mlx_vecdot)

int mlx_linspace_endpoint(mlx_array* res, double start, double stop, int num, bool endpoint, mlx_dtype dtype, const mlx_stream s) {
    if (endpoint || num < 2) return mlx_linspace(res, start, stop, num, dtype, s);
    double last = start + (stop - start) * (double)(num - 1) / (double)num;
    return mlx_linspace(res, start, last, num, dtype, s);
}

int mlx_ones_like_dtype(mlx_array* res, const mlx_array a, mlx_dtype dtype, const mlx_stream s) {
    mlx_array t = mlx_array_new();
    int rc = mlx_ones_like(&t, a, s);
    if (rc == 0) rc = mlx_astype(res, t, dtype, s);
    mlx_array_free(t);
    return rc;
}

int mlx_zeros_like_dtype(mlx_array* res, const mlx_array a, mlx_dtype dtype, const mlx_stream s) {
    mlx_array t = mlx_array_new();
    int rc = mlx_zeros_like(&t, a, s);
    if (rc == 0) rc = mlx_astype(res, t, dtype, s);
    mlx_array_free(t);
    return rc;
}
