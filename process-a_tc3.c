// process-a_tc3.c
// Parallel variant for Process A: row-parallel with schedule(runtime),
// algorithm unchanged, atomics on each match (no per-thread local counters).

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

    if (ac<4)
    {
        FatalError("Usage: create in_filename out_filename search_filename");
    }

    infilename     = av[1];
    outfilename    = av[2];
    searchfilename = av[3];

    // The image for loading from the source file and transformation
    struct Image img;

    printf("Loading file %s\n",infilename);
    LoadFile(infilename, &img, 1000); // load the file as lines of 1000 pixels
    printf("Loaded file with %lu pixels, a line length of %lu and a line count of %lu.\n",
        img.length, img.linesize, img.lines);

    // Now we load the search pixels into the search Image
    struct Image search;

    printf("Loading file %s\n",searchfilename);
    LoadFile(searchfilename, &search, 0); // load the search file onto a single line
    printf("Found %lu search term pixels\n",search.length);

    unsigned long *counter = (unsigned long*)malloc(search.length * sizeof(unsigned long)); // allocate the counter array
    if (!counter) FatalError("malloc failed for counter");
    for(unsigned long i=0; i<search.length; ++i)
        counter[i] = 0; // initialise as zero

    // LOADING COMPLETE

    printf("Processing Bleeding, Greyscale, XOR and Searching (tc3: row-parallel + atomic on matches)\n");

    // Parallelise across rows; keep left->right order within each row for the bleed dependency.
    #pragma omp parallel default(none) shared(img, search, counter)
    {
        #pragma omp for schedule(runtime)
        for(unsigned long l=0; l<img.lines; ++l)
        {
            // Loop through the data points in this row (must be sequential for bleed)
            for(unsigned long p=0; p<img.linesize; ++p)
            {
                // Search for the original values (algorithm unchanged)
                for(unsigned long i=0; i<search.length; ++i)
                {
                    if (img.pixels[l][p].red == search.pixels[0][i].red &&
                        img.pixels[l][p].green == search.pixels[0][i].green &&
                        img.pixels[l][p].blue == search.pixels[0][i].blue) // match
                    {
                        #pragma omp atomic
                        counter[i]++;
                    }
                }

                // "Bleed" colours from left to right up to 10 pixels (if we have pixels to the left)
                if (p>0)
                {
                    int pixlen = 10;
                    // start at 0 or p-10
                    unsigned long startpix = 0;
                    if (p > (unsigned long)pixlen)
                        startpix = p-(unsigned long)pixlen;
                    else
                        pixlen = (int)p;

                    // initialise average values
                    int rav = 0;
                    int gav = 0;
                    int bav = 0;
                    for (unsigned long i=startpix; i<p; ++i)
                    {
                        rav += img.pixels[l][i].red;
                        gav += img.pixels[l][i].green;
                        bav += img.pixels[l][i].blue;
                    }
                    // calculate averages
                    if (pixlen > 0) {
                        rav = rav / pixlen;
                        gav = gav / pixlen;
                        bav = bav / pixlen;
                        // add (or -) one third of the difference
                        img.pixels[l][p].red   += (rav - img.pixels[l][p].red) / 3;
                        img.pixels[l][p].green += (gav - img.pixels[l][p].green) / 3;
                        img.pixels[l][p].blue  += (bav - img.pixels[l][p].blue) / 3;
                    }
                }

                // Transform first to greyscale
                Greyscale(&(img.pixels[l][p]));

                // XOR by 13
                XOR(&(img.pixels[l][p]),13);

                // Now search for the new grey and XOR values (algorithm unchanged)
                for(unsigned long i=0; i<search.length; ++i)
                {
                    if (img.pixels[l][p].red == search.pixels[0][i].red &&
                        img.pixels[l][p].green == search.pixels[0][i].green &&
                        img.pixels[l][p].blue == search.pixels[0][i].blue) // match
                    {
                        #pragma omp atomic
                        counter[i]++;
                    }
                }
            }
        }
    } // end parallel region

    // Transformation finished - save the file
    printf("Saving file %s\n",outfilename);
    WriteFile(outfilename, &img);

    // Now print the search results (careful of the format!)
    printf("Search Results:\n");
    for(unsigned long i=0; i<search.length; ++i)
    {
        printf("** (");
        PrintRGBValue(search.pixels[0][i].red);
        printf(",");
        PrintRGBValue(search.pixels[0][i].green);
        printf(",");
        PrintRGBValue(search.pixels[0][i].blue);
        printf(") = %lu\n",counter[i]);
    }

    return 0;
}
