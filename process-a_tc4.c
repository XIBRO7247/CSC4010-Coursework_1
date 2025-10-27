// process-a_tc4.c
// Parallel testcase for Process A (task-per-row):
//  - Create an OpenMP task for each row
//  - Inside each task, process the row strictly left->right (bleed dependency preserved)
//  - Use per-task local counters; merge once at the end with atomics
//  - Keeps original O(search.length) scans (no algorithmic changes)
//  - No schedule(runtime) used here (tasking instead)

#include <stdio.h>
#include <stdlib.h>
#include <omp.h>
#include "rawimage.h"

int main(int ac, char **av)
{
    if (ac < 4) {
        FatalError("Usage: create in_filename out_filename search_filename");
    }

    char *infilename    = av[1];
    char *outfilename   = av[2];
    char *searchfilename= av[3];

    struct Image img;
    printf("Loading file %s\n", infilename);
    LoadFile(infilename, &img, 1000);
    printf("Loaded file with %lu pixels, a line length of %lu and a line count of %lu.\n",
           img.length, img.linesize, img.lines);

    struct Image search;
    printf("Loading file %s\n", searchfilename);
    LoadFile(searchfilename, &search, 0);
    printf("Found %lu search term pixels\n", search.length);

    unsigned long *counter = (unsigned long*)malloc(search.length * sizeof(unsigned long));
    if (!counter) FatalError("malloc failed for counter");
    for (unsigned long i = 0; i < search.length; ++i) counter[i] = 0;

    printf("Processing Bleeding, Greyscale, XOR and Searching (tc4: task-per-row, no algorithm changes)\n");

    // Parallel region that spawns tasks; each row is its own task
    #pragma omp parallel
    {
        #pragma omp single nowait
        {
            for (unsigned long l = 0; l < img.lines; ++l) {
                #pragma omp task firstprivate(l) default(none) shared(img, search, counter)
                {
                    // Per-task local counter to avoid contention
                    unsigned long *local = (unsigned long*)calloc(search.length, sizeof(unsigned long));
                    if (!local) FatalError("calloc failed for local counter");

                    for (unsigned long p = 0; p < img.linesize; ++p)
                    {
                        // Search for the original values (exact same O(search.length) loop)
                        for (unsigned long i = 0; i < search.length; ++i)
                        {
                            if (img.pixels[l][p].red   == search.pixels[0][i].red &&
                                img.pixels[l][p].green == search.pixels[0][i].green &&
                                img.pixels[l][p].blue  == search.pixels[0][i].blue)
                            {
                                local[i]++;
                            }
                        }

                        // Bleeding left->right within the same row (must remain sequential across p)
                        if (p > 0)
                        {
                            int pixlen = 10;
                            unsigned long startpix = 0;
                            if (p > (unsigned long)pixlen) startpix = p - (unsigned long)pixlen;
                            else                            pixlen   = (int)p;

                            int rav = 0, gav = 0, bav = 0;
                            for (unsigned long i = startpix; i < p; ++i) {
                                rav += img.pixels[l][i].red;
                                gav += img.pixels[l][i].green;
                                bav += img.pixels[l][i].blue;
                            }
                            if (pixlen > 0) {
                                rav /= pixlen; gav /= pixlen; bav /= pixlen;
                                img.pixels[l][p].red   += (rav - img.pixels[l][p].red) / 3;
                                img.pixels[l][p].green += (gav - img.pixels[l][p].green) / 3;
                                img.pixels[l][p].blue  += (bav - img.pixels[l][p].blue) / 3;
                            }
                        }

                        // Transform: Greyscale then XOR by 13 (unchanged)
                        Greyscale(&(img.pixels[l][p]));
                        XOR(&(img.pixels[l][p]), 13);

                        // Search for the new values (unchanged)
                        for (unsigned long i = 0; i < search.length; ++i)
                        {
                            if (img.pixels[l][p].red   == search.pixels[0][i].red &&
                                img.pixels[l][p].green == search.pixels[0][i].green &&
                                img.pixels[l][p].blue  == search.pixels[0][i].blue)
                            {
                                local[i]++;
                            }
                        }
                    }

                    // Merge local counts once (atomic per element)
                    for (unsigned long i = 0; i < search.length; ++i) {
                        #pragma omp atomic
                        counter[i] += local[i];
                    }
                    free(local);
                } // task
            } // rows
        } // single
        #pragma omp taskwait
    } // parallel

    printf("Saving file %s\n", outfilename);
    WriteFile(outfilename, &img);

    // Output format identical to baseline
    printf("Search Results:\n");
    for (unsigned long i = 0; i < search.length; ++i)
    {
        printf("** (");
        PrintRGBValue(search.pixels[0][i].red);
        printf(",");
        PrintRGBValue(search.pixels[0][i].green);
        printf(",");
        PrintRGBValue(search.pixels[0][i].blue);
        printf(") = %lu\n", counter[i]);
    }

    return 0;
}
