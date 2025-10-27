// process-b_tc1.c
// Minimal OpenMP parallel variant for Process B.
// - Keep the p-sweep strictly sequential (preserves bleed dependency).
// - Parallelise only the 'i' search loops with schedule(runtime).
// - Use atomics for counter[i] updates (no algorithm change).

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

    printf("Processing Bleeding, Greyscale, XOR and Searching (b_tc1: i-parallel + atomics, schedule(runtime))\n");

    // Loop through the data points (p stays strictly sequential to preserve bleeding)
    for (unsigned long p = 0; p < img.linesize; ++p)
    {
        // Search for the original values (parallel over i)
        #pragma omp parallel for schedule(runtime)
        for (unsigned long i = 0; i < search.length; ++i)
        {
            if (img.pixels[0][p].red   == search.pixels[0][i].red &&
                img.pixels[0][p].green == search.pixels[0][i].green &&
                img.pixels[0][p].blue  == search.pixels[0][i].blue) // match
            {
                #pragma omp atomic
                counter[i]++;
            }
        }

        // "Bleed" colours from left to right up to 10 pixels (if we have pixels to the left)
        if (p > 0)
        {
            int pixlen = 10;
            // start at 0 or p-10
            unsigned long startpix = 0;
            if (p > (unsigned long)pixlen)
                startpix = p - (unsigned long)pixlen;
            else
                pixlen = (int)p;

            // initialise average values
            int rav = 0;
            int gav = 0;
            int bav = 0;
            for (unsigned long i = startpix; i < p; ++i)
            {
                rav += img.pixels[0][i].red;
                gav += img.pixels[0][i].green;
                bav += img.pixels[0][i].blue;
            }
            // calculate averages
            if (pixlen > 0) {
                rav = rav / pixlen;
                gav = gav / pixlen;
                bav = bav / pixlen;
                // add (or -) one third of the difference
                img.pixels[0][p].red   += (rav - img.pixels[0][p].red) / 3;
                img.pixels[0][p].green += (gav - img.pixels[0][p].green) / 3;
                img.pixels[0][p].blue  += (bav - img.pixels[0][p].blue) / 3;
            }
        }

        // Transform first to greyscale
        Greyscale(&(img.pixels[0][p]));

        // XOR by 13
        XOR(&(img.pixels[0][p]), 13);

        // Now search for the new grey and XOR values (parallel over i)
        #pragma omp parallel for schedule(runtime)
        for (unsigned long i = 0; i < search.length; ++i)
        {
            if (img.pixels[0][p].red   == search.pixels[0][i].red &&
                img.pixels[0][p].green == search.pixels[0][i].green &&
                img.pixels[0][p].blue  == search.pixels[0][i].blue) // match
            {
                #pragma omp atomic
                counter[i]++;
            }
        }
    }

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
