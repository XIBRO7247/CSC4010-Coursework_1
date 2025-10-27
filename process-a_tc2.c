// process-a_tc2.c
// Parallel testcase for Process A:
//  - Parallel over rows with schedule(runtime)
//  - Per-thread private counters, merged at end (reduces atomics)
//  - Pixel processing order per row remains left→right (identical semantics)

#include <stdio.h>
#include <stdlib.h>
#include <omp.h>
#include "rawimage.h"

// Loads data as lines of 1000 pixels (same as sequential A)
int main(int ac, char **av)
{
    if (ac < 4) {
        FatalError("Usage: create in_filename out_filename search_filename");
    }

    char *infilename   = av[1];
    char *outfilename  = av[2];
    char *searchfilename = av[3];

    struct Image img;
    printf("Loading file %s\n", infilename);
    LoadFile(infilename, &img, 1000);
    printf("Loaded file with %lu pixels, a line length of %lu and a line count of %lu.\n",
           img.length, img.linesize, img.lines);

    struct Image search;
    printf("Loading file %s\n", searchfilename);
    LoadFile(searchfilename, &search, 0);
    printf("Found %lu search term pixels\n", search.length);

    unsigned long *counter = malloc(search.length * sizeof(unsigned long));
    if (!counter) FatalError("malloc failed for counter");
    for (unsigned long i = 0; i < search.length; ++i) counter[i] = 0;

    printf("Processing Bleeding, Greyscale, XOR and Searching (tc2: parallel rows + thread-local counters)\n");

    // Parallel region with per-thread private counters
    #pragma omp parallel default(none) shared(img, search, counter)
    {
        unsigned long *local = (unsigned long*)calloc(search.length, sizeof(unsigned long));
        if (!local) FatalError("calloc failed for local counter");

        // Parallelise outer row loop; keep inner pixel loop sequential to preserve left->right dependency
        #pragma omp for schedule(runtime)
        for (unsigned long l = 0; l < img.lines; ++l)
        {
            for (unsigned long p = 0; p < img.linesize; ++p)
            {
                // Search for the original values
                for (unsigned long i = 0; i < search.length; ++i)
                {
                    if (img.pixels[l][p].red   == search.pixels[0][i].red &&
                        img.pixels[l][p].green == search.pixels[0][i].green &&
                        img.pixels[l][p].blue  == search.pixels[0][i].blue)
                    {
                        local[i]++;   // thread-local count (no atomics here)
                    }
                }

                // Bleeding (leftwards average of up to 10 pixels in same row)
                if (p > 0)
                {
                    int pixlen = 10;
                    unsigned long startpix = 0;
                    if (p > (unsigned long)pixlen) startpix = p - (unsigned long)pixlen;
                    else                           pixlen   = (int)p;

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

                // Transform: Greyscale then XOR (same as sequential)
                Greyscale(&(img.pixels[l][p]));
                XOR(&(img.pixels[l][p]), 13);

                // Search for the new values
                for (unsigned long i = 0; i < search.length; ++i)
                {
                    if (img.pixels[l][p].red   == search.pixels[0][i].red &&
                        img.pixels[l][p].green == search.pixels[0][i].green &&
                        img.pixels[l][p].blue  == search.pixels[0][i].blue)
                    {
                        local[i]++;   // thread-local count (no atomics here)
                    }
                }
            }
        }

        // Merge thread-local counts into the shared counter
        #pragma omp for schedule(static)
        for (unsigned long i = 0; i < search.length; ++i) {
            #pragma omp atomic
            counter[i] += local[i];
        }

        free(local);
    } // end parallel

    // Save the transformed image
    printf("Saving file %s\n", outfilename);
    WriteFile(outfilename, &img);

    // Print search results (same format)
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
