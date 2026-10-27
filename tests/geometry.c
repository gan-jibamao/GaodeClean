#include "../src/GCCGeometry.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    // Short home / explore headers: pulling or attempting a multi-screen jump cannot scroll.
    assert(GCCClampOffset(2000, 240, 700, 0, 0) == 0);
    assert(GCCClampOffset(-200, 240, 700, 0, 0) == 0);
    // Safe areas: the resting position is -topInset, not an unconditional zero.
    assert(GCCClampOffset(2000, 330, 700, 44, 34) == -44);
    assert(GCCClampOffset(-200, 330, 700, 44, 34) == -44);
    // A tall retained "Mine" section remains scrollable all the way to its end.
    assert(GCCClampOffset(2000, 1000, 700, 44, 34) == 334);
    assert(GCCClampOffset(150, 1000, 700, 44, 34) == 150);
    // Layout / orientation changes update the permitted endpoint.
    assert(GCCClampOffset(334, 1000, 850, 44, 34) == 184);
    assert(GCCClampOffset(NAN, 1000, 700, 44, 34) == -44);
    // Fling and programmatic offsets always stay within the retained content.
    for (int i = -10000; i <= 10000; i++) {
        double result = GCCClampOffset(i, 1000, 700, 44, 34);
        assert(result >= -44 && result <= 334);
    }
    puts("PASS: scroll boundary regression cases and 20,001 offset checks");
}
