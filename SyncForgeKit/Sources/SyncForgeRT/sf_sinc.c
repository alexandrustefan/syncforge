// Kaiser-windowed sinc table for fractional-delay interpolation / sample-rate conversion.
#include <stdlib.h>
#include "sf_internal.h"

static double bessel_i0(double x) {
    double sum = 1.0, term = 1.0, q = x * x / 4.0;
    for (int k = 1; k < 64; k++) {
        term *= q / ((double)k * (double)k);
        sum += term;
        if (term < sum * 1e-17) break;
    }
    return sum;
}

SFSinc *sf_sinc_create(int half, int phases, double cutoff, double beta) {
    SFSinc *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->half = half;
    s->taps = 2 * half;
    s->phases = phases;
    s->table = calloc((size_t)(phases + 1) * (size_t)s->taps, sizeof(float));
    if (!s->table) { free(s); return NULL; }
    double i0b = bessel_i0(beta);
    for (int row = 0; row <= phases; row++) {
        double f = (double)row / (double)phases;
        double sum = 0.0;
        double tmp[256];
        for (int k = 0; k < s->taps; k++) {
            double d = (double)(k - (half - 1)) - f;      // distance from interpolation point
            double x = cutoff * d;
            double sinc = fabs(x) < 1e-12 ? 1.0 : sin(M_PI * x) / (M_PI * x);
            double u = d / (double)half;
            double w = fabs(u) >= 1.0 ? 0.0 : bessel_i0(beta * sqrt(1.0 - u * u)) / i0b;
            tmp[k] = cutoff * sinc * w;
            sum += tmp[k];
        }
        // Normalise for exact unity gain at DC.
        for (int k = 0; k < s->taps; k++) {
            s->table[(size_t)row * (size_t)s->taps + (size_t)k] = (float)(sum != 0.0 ? tmp[k] / sum : 0.0);
        }
    }
    return s;
}

void sf_sinc_destroy(SFSinc *s) {
    if (!s) return;
    free(s->table);
    free(s);
}
