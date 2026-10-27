#pragma once
#include <math.h>

// A short retained header has no vertical scroll range; a tall one remains reachable.
static inline double GCCMaxOffset(double bottom, double viewport, double topInset, double bottomInset) {
    return fmax(-topInset, bottom - viewport + bottomInset);
}
static inline double GCCClampOffset(double proposed, double bottom, double viewport, double topInset, double bottomInset) {
    if (!isfinite(proposed)) return -topInset;
    return fmin(fmax(proposed, -topInset), GCCMaxOffset(bottom, viewport, topInset, bottomInset));
}
