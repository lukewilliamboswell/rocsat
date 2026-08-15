#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    unsigned long m = strtoul(argv[1],0,10), cap = strtoul(argv[2],0,10), n = strtoul(argv[3],0,10);
    unsigned long *blocks = calloc(m*cap, 8), *counts = calloc(m, 8);
    for (unsigned long i = 0; i < n; i++) {
        unsigned long lit = i % m, c = counts[lit];
        blocks[lit*cap + c] = i;
        counts[lit] = c + 1;
    }
    unsigned long t = 0;
    for (unsigned long i = 0; i < m; i++) t += counts[i];
    for (unsigned long i = 0; i < m*cap; i++) t += blocks[i];
    printf("checksum=%lu\n", t);
    return 0;
}
