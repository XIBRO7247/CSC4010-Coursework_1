// process-b_tc2.c
// OpenMP team-per-run structure:
//   - One parallel region for the whole program.
//   - p-loop is executed in lockstep using single + barriers (preserves bleeding dependency).
//   - Both searches are parallelised over i with schedule(runtime) for your matrix baking.
//   - Pixel values are copied to local scalars before parallel regions to avoid races.
//   - Small vectorisation hint for averaging (no algorithm change).

#include <stdio.h>
#include <stdlib.h>
#include <omp.h>
#include "rawimage.h"

int main(int ac, char **av)
{
    // require the three command-line parameters of input file, output file and search file
    char *infilename;
    char *outfilename;
    char *searchfilename;

    if (ac < 4) {
        FatalError("Usage: create in_filename out_filename search_filename");
    }

    infilename     = av[1];
    outfilename    = av[2];
    searchfilename = av[3];

    // The image for loading from the source file and transformation
    struct Image img;

    printf("Loading file %s\n", infilename);
    LoadFile(infilename, &img, 0); // load the file as a single line
    printf("Loaded file with %lu pixels, a line length of %lu and a line count of %lu.\n",
           img.length, img.linesize, img.lines);

    // Load the search pixels
    struct Image search;

    printf("Loading file %s\n", searchfilename);
    LoadFile(searchfilename, &search, 0); // load the search file onto a single line
    printf("Found %lu search term pixels\n", search.length);

    unsigned long *counter = (unsigned long *)malloc(search.length * sizeof(unsigned long));
    if (!counter) {
        FatalError("malloc failed for counter");
    }
    for (unsigned long i = 0; i < search.length; ++i) counter[i] = 0;

    // LOADING COMPLETE

    printf("Processing Bleeding, Greyscale, XOR and Searching (b_tc2: team-per-run + i-parallel, schedule(runtime))\n");

    // Single parallel region for entire processing
    #pragma omp parallel
    {
        for (unsigned long p = 0; p < img.linesize; ++p)
        {
            // --- Phase 1: search original values (parallel over i) ---
            // Copy pixel to scalars in a single region to avoid races with updates
            int r0, g0, b0;
            #pragma omp single
            {
                r0 = img.pixels[0][p].red;
                g0 = img.pixels[0][p].green;
                b0 = img.pixels[0][p].blue;
            }
            #pragma omp barrier

            #pragma omp for schedule(runtime)
            for (unsigned long i = 0; i < search.length; ++i)
            {
                if (r0 == search.pixels[0][i].red &&
                    g0 == search.pixels[0][i].green &&
                    b0 == search.pixels[0][i].blue) // match
                {
                    #pragma omp atomic
                    counter[i]++;
                }
            }

            // --- Phase 2: sequential bleeding + greyscale + XOR (must be ordered) ---
            #pragma omp single
            {
                // "Bleed" colours from left to right up to 10 pixels (if we have pixels to the left)
                if (p > 0)
                {
                    int pixlen = 10;
                    unsigned long startpix = 0;
                    if (p > (unsigned long)pixlen)
                        startpix = p - (unsigned long)pixlen;
                    else
                        pixlen = (int)p;

                    int rav = 0, gav = 0, bav = 0;

                    // Small loop; hint vectorisation without changing results
                    #pragma omp simd reduction(+:rav,gav,bav)
                    for (unsigned long i = startpix; i < p; ++i)
                    {
                        rav += img.pixels[0][i].red;
                        gav += img.pixels[0][i].green;
                        bav += img.pixels[0][i].blue;
                    }

                    if (pixlen > 0) {
                        rav = rav / pixlen;
                        gav = gav / pixlen;
                        bav = bav / pixlen;

                        img.pixels[0][p].red   += (rav - img.pixels[0][p].red) / 3;
                        img.pixels[0][p].green += (gav - img.pixels[0][p].green) / 3;
                        img.pixels[0][p].blue  += (bav - img.pixels[0][p].blue) / 3;
                    }
                }

                // Transform first to greyscale
                Greyscale(&(img.pixels[0][p]));
                // XOR by 13
                XOR(&(img.pixels[0][p]), 13);
            }
            #pragma omp barrier

            // --- Phase 3: search transformed values (parallel over i) ---
            int r1, g1, b1;
            #pragma omp single
            {
                r1 = img.pixels[0][p].red;
                g1 = img.pixels[0][p].green;
                b1 = img.pixels[0][p].blue;
            }
            #pragma omp barrier

            #pragma omp for schedule(runtime)
            for (unsigned long i = 0; i < search.length; ++i)
            {
                if (r1 == search.pixels[0][i].red &&
                    g1 == search.pixels[0][i].green &&
                    b1 == search.pixels[0][i].blue) // match
                {
                    #pragma omp atomic
                    counter[i]++;
                }
            }

            // Synchronise before proceeding to next pixel p
            #pragma omp barrier
        } // end for p
    } // end parallel

    // Transformation finished - save the file
    printf("Saving file %s\n", outfilename);
    WriteFile(outfilename, &img);

    // Now print the search results (careful of the format!)
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
