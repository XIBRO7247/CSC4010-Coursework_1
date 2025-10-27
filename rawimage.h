// Raw Image Data File Library for CSC4010 Assignment 1
// David Cutting
//
// Note: you are welcome for investigations to modify this file (you can add debug 
// or even change things).
//
// BUT for assessment execution an original copy of this library will be used!
//

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

// Struct to hold individual pixels
struct Pixel {
    int red;
    int green;
    int blue;
};

// Struct to hold "image" (raw file) information and pixels
struct Image {
    unsigned long length;
    unsigned long lines;
    unsigned long linesize;
    struct Pixel **pixels;
};

// Send an error string to stderr and exit
void FatalError(const char * err)
{
    fprintf(stderr,"%s\n",err);
    exit(1);
}

// For creating memory for an Image how do we initialise the pixels
enum InitialisationType {
    NONE,
    ZERO,
    RANDOM
};

// Generate an area of memory for an Image of given data dimensions
// imagedata - Image struct to load into
// length - total length of the data
// linesize - split into lines of this size (filling final line if needed to length always a multiple of linesize), 0 means all one line
// initialisation - InitialisationType to specify if initialisation and if so what type (note random does not seed)
void ImageData(struct Image *imagedata, unsigned long length, unsigned long linesize, enum InitialisationType initialisation)
{
    if (linesize == 0) { // load everything into one line of pixels
        imagedata->lines = 1;
        imagedata->length = length; // in this case the length is the length
        imagedata->linesize = length;
    }
    else {
        // we need to consider a case where, for example, we have a line length of 10 and a data length of 103
        // this would be 10 full lines only, so we'll catch this and add an 11th line padded to the right size
        unsigned long tlines = length / linesize; // how many lines floor'd by integer division
        //printf("tlines = %lu\n",tlines);
        //printf("linesize = %lu\n",linesize);
        unsigned long remainder = (length - (tlines * linesize)); // any left over (partial lines)
        //printf("%lu\n",remainder);
        if (remainder > 0) // linesize does not map directly into length - remainder out
        {
            tlines++; // add a line
            length += (linesize - remainder); // increment by remainder
        }
        imagedata->lines = tlines;
        imagedata->length = length;
        imagedata->linesize = linesize;
    }

    // Allocate memory for pointers to lines
    imagedata->pixels = (struct Pixel**)malloc(imagedata->lines * sizeof(struct Pixel**)); // memory for pointers to lines
    if (imagedata->pixels == NULL)
    {
        FatalError("Cannot allocate memory for line data");
    }

    // Allocate memory for lines
    for (unsigned long l=0; l<imagedata->lines; ++l)
    {
        imagedata->pixels[l] = (struct Pixel*)malloc(imagedata->linesize * sizeof(struct Pixel));
        if (imagedata->pixels[l] == NULL)
            FatalError("Cannot allocate Pixel memory for a line");
        // act on initialisation if required (if NONE ignore)
        if (initialisation != NONE)
        {
            for (unsigned long p=0; p<imagedata->linesize; ++p)
            {
                if (initialisation == RANDOM)
                {
                    imagedata->pixels[l][p].red=rand() % 255;
                    imagedata->pixels[l][p].green=rand() % 255;
                    imagedata->pixels[l][p].blue=rand() % 255;
                }
                else // assume ZERO as a fallback
                {
                    imagedata->pixels[l][p].red=0;
                    imagedata->pixels[l][p].green=0;
                    imagedata->pixels[l][p].blue=0;
                }
            }
        }
    }

    // Image items allocated
}

// Print a nicely space-padded 3 place integer
void PrintRGBValue(int value)
{
    if (value<100) printf(" ");
    if (value<10) printf(" ");
    printf("%d",value);
}

// Print the image to the terminal in (RRR,GGG,BBB) format one line per line
// (caution if using this on big images!)
// imagedata - the Image struct to print
void PrintImage(struct Image *imagedata)
{
    for (unsigned long l=0; l<imagedata->lines; ++l)
    {
        for(unsigned long p=0; p<imagedata->linesize; ++p)
        {
            printf("(");
            PrintRGBValue(imagedata->pixels[l][p].red);
            printf(",");
            PrintRGBValue(imagedata->pixels[l][p].green);
            printf(",");
            PrintRGBValue(imagedata->pixels[l][p].blue);
            printf(") ");
        }
        printf("\n");
    }
}

// Write an Image to a file
// filename - the filename to write to (will overwrite or create), fatal error if can't open
// imagedata - the Image struct to save
void WriteFile(const char *filename, struct Image *imagedata)
{
    FILE* fp = fopen(filename,"wb");
    if(fp == NULL)
        FatalError("Cannot open file for writing");
    for (unsigned long l=0; l<imagedata->lines; ++l)
    {
        for(unsigned long p=0; p<imagedata->linesize; ++p)
        {
            fwrite(&(imagedata->pixels[l][p]), sizeof(struct Pixel), 1, fp);
        }
    }
    fclose(fp);
}

// Load an image from a file
// filename - the filename to load (fatal error if can't open)
// imagedata - the Imact struct to load the image into
// linesize = line size to break into (0 means on one line)
void LoadFile(const char *filename, struct Image *imagedata, unsigned long linesize)
{
    FILE *fp = fopen(filename, "rb");
    if (fp == NULL) FatalError("Cannot open file for reading");

    fseek(fp,0,SEEK_END); // go to the end of the file
    unsigned long rawlength = ftell(fp); // get the raw length of the file
    unsigned long length = rawlength / sizeof(struct Pixel); // get the pixel length of the file
    fseek(fp,0,SEEK_SET); // and return to the beginning

    //printf("Raw length: %lu\n",rawlength);
    //printf("Length: %lu\n",length);

    ImageData(imagedata, length, linesize, NONE);

    unsigned long counter = 0; // number of data elements loaded from file
    for (unsigned long l=0; l<imagedata->lines; ++l)
    {
        for (unsigned long p=0; p<imagedata->linesize; ++p)
        {
            if (counter < length) // we can read "real data"
            {
                fread(&(imagedata->pixels[l][p]), sizeof(struct Pixel), 1, fp);
            }
            else // we're out of real data from the file so zero-filled pixels
            {
                imagedata->pixels[l][p].red = 0;
                imagedata->pixels[l][p].blue = 0;
                imagedata->pixels[l][p].green = 0;
            }
        }
    }

    fclose(fp);
}

// Greyscale - turn a pixel into the greyscale version of itself
// p - the Pixel to update
void Greyscale(struct Pixel *p)
{
    int avg = (p->red + p->green + p->blue) / 3;
    p->red = avg;
    p->green = avg;
    p->blue = avg;
}

// XOR - XOR the RGB values of a pixel against the value
// p - the Pixel to update
// val - the value to XOR the RGB values against
void XOR(struct Pixel *p, int val)
{
    p->red = p->red ^ val;
    p->green = p->green ^ val;
    p->blue = p->blue ^ val;
}

