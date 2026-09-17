/*
 * png.h - just enough PNG decoding to turn a RetroArch screenshot into an
 * SDL_Surface, without a build-time dependency on libpng or zlib headers.
 *
 * cleanup_filesystem.sh (repo root) strips libpng-dev AND zlib1g-dev off the
 * device image while needed_packages.txt keeps libsdl2-dev, so SDL2 headers
 * survive the on-device build path this project relies on but zlib's do
 * not -- #include <zlib.h> would break exactly the build gs-install.sh's
 * install_ui() falls back to when there's no compiler at all. libz.so.1
 * itself is always present regardless (SDL2, ffmpeg, apt and systemd all
 * hard-depend on it), so the one symbol this needs -- uncompress() -- is
 * resolved at runtime with dlopen()/dlsym() instead. uncompress()'s
 * signature has been stable since zlib 1.0, and PNG gives the exact
 * decompressed size up front (height * (1 + stride)), so there's no reason
 * to hand-roll an inflate implementation just to avoid one dlopen call.
 *
 * Supports what RetroArch's own screenshot code actually writes: 8-bit,
 * non-interlaced, colour type 2 (RGB) or 6 (RGBA). Anything else -- 16-bit,
 * interlaced, palette/grayscale -- is rejected rather than guessed at;
 * gameswitcher.c already treats a NULL surface as "no preview yet" (the
 * same placeholder a missing/corrupt thumbnail file has always produced),
 * so there is no new failure mode to handle at the call site.
 */

#ifndef GS_PNG_H
#define GS_PNG_H

#include <SDL2/SDL.h>

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* zlib's uncompress(): declared locally rather than #include <zlib.h> --
 * see the file comment for why the header can't be assumed present. */
typedef int (*gs_uncompress_fn)(unsigned char *dest, unsigned long *destLen,
                                 const unsigned char *source, unsigned long sourceLen);

static gs_uncompress_fn gs_zlib_uncompress(void)
{
    static gs_uncompress_fn fn = NULL;
    static int tried = 0;
    void *handle;

    if (tried)
        return fn;
    tried = 1;

    /* RTLD_NODELETE: this may run once per thumbnail decode; there is no
     * reason to pay dlopen/dlclose's bookkeeping cost repeatedly for a
     * library that's already mapped into every SDL2 process on this OS. */
    handle = dlopen("libz.so.1", RTLD_NOW | RTLD_NODELETE);
    if (!handle)
        handle = dlopen("libz.so", RTLD_NOW | RTLD_NODELETE);
    if (!handle)
        return NULL;

    fn = (gs_uncompress_fn)dlsym(handle, "uncompress");
    return fn;
}

/* ------------------------------------------------------------------ */
/* Chunk walking                                                       */
/* ------------------------------------------------------------------ */

#define GS_PNG_SIG_LEN 8

static uint32_t gs_png_be32(const unsigned char *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] << 8)  | (uint32_t)p[3];
}

/* One PNG filter type's unfilter, row by row.  `cur` is overwritten in
 * place; `prev` is the already-unfiltered previous row (all zero for the
 * first row) or NULL. `bpp` is bytes per pixel, used by Paeth/Up/Average as
 * the byte distance that corresponds to "the pixel to the left". */
static void gs_png_unfilter_row(unsigned char *cur, const unsigned char *prev,
                                 size_t n, int bpp, int filter)
{
    size_t i;

    switch (filter) {
    case 0: /* None */
        break;
    case 1: /* Sub */
        for (i = bpp; i < n; i++)
            cur[i] = (unsigned char)(cur[i] + cur[i - bpp]);
        break;
    case 2: /* Up */
        if (prev)
            for (i = 0; i < n; i++)
                cur[i] = (unsigned char)(cur[i] + prev[i]);
        break;
    case 3: /* Average */
        for (i = 0; i < n; i++) {
            int a = (i >= (size_t)bpp) ? cur[i - bpp] : 0;
            int b = prev ? prev[i] : 0;
            cur[i] = (unsigned char)(cur[i] + (a + b) / 2);
        }
        break;
    case 4: /* Paeth */
        for (i = 0; i < n; i++) {
            int a = (i >= (size_t)bpp) ? cur[i - bpp] : 0;
            int b = prev ? prev[i] : 0;
            int c = (prev && i >= (size_t)bpp) ? prev[i - bpp] : 0;
            int p = a + b - c;
            int pa = abs(p - a), pb = abs(p - b), pc = abs(p - c);
            int pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
            cur[i] = (unsigned char)(cur[i] + pred);
        }
        break;
    default:
        break; /* unknown filter byte -- leave the row as-is */
    }
}

/*
 * gs_load_png - decode a PNG file straight into a new SDL_Surface.
 * Returns NULL on anything it can't handle (I/O error, bad signature,
 * unsupported IHDR, corrupt IDAT); the caller treats that exactly like a
 * missing file.
 */
static SDL_Surface *gs_load_png(const char *path)
{
    static const unsigned char sig[GS_PNG_SIG_LEN] =
        { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

    FILE *fh = NULL;
    unsigned char hdr[GS_PNG_SIG_LEN];
    unsigned char *filedata = NULL;
    long filelen;
    size_t pos;

    int32_t width = 0, height = 0;
    int bitdepth = 0, colortype = -1, interlace = 0;
    int channels = 0;

    unsigned char *idat = NULL;
    unsigned long idat_len = 0;

    unsigned char *raw = NULL;
    unsigned long raw_len;
    gs_uncompress_fn uncompress_fn;

    SDL_Surface *surf = NULL;
    unsigned char *prev_row = NULL;
    size_t stride, y;
    int rc = -1;

    fh = fopen(path, "rb");
    if (!fh)
        return NULL;

    if (fseek(fh, 0, SEEK_END) != 0) { fclose(fh); return NULL; }
    filelen = ftell(fh);
    if (filelen <= GS_PNG_SIG_LEN || filelen > 64 * 1024 * 1024) {
        fclose(fh);
        return NULL;
    }
    if (fseek(fh, 0, SEEK_SET) != 0) { fclose(fh); return NULL; }

    filedata = (unsigned char *)malloc((size_t)filelen);
    if (!filedata) { fclose(fh); return NULL; }
    if (fread(filedata, 1, (size_t)filelen, fh) != (size_t)filelen) {
        fclose(fh);
        free(filedata);
        return NULL;
    }
    fclose(fh);

    memcpy(hdr, filedata, GS_PNG_SIG_LEN);
    if (memcmp(hdr, sig, GS_PNG_SIG_LEN) != 0) {
        free(filedata);
        return NULL;
    }

    pos = GS_PNG_SIG_LEN;
    while (pos + 8 <= (size_t)filelen) {
        uint32_t clen = gs_png_be32(filedata + pos);
        const unsigned char *ctype = filedata + pos + 4;
        const unsigned char *cdata = filedata + pos + 8;

        if (pos + 8 + (size_t)clen + 4 > (size_t)filelen)
            break; /* truncated chunk -- stop, don't read past the buffer */

        if (memcmp(ctype, "IHDR", 4) == 0 && clen >= 13) {
            width     = (int32_t)gs_png_be32(cdata);
            height    = (int32_t)gs_png_be32(cdata + 4);
            bitdepth  = cdata[8];
            colortype = cdata[9];
            interlace = cdata[12];
        } else if (memcmp(ctype, "IDAT", 4) == 0) {
            unsigned char *grown = (unsigned char *)realloc(idat, idat_len + clen);
            if (!grown) {
                free(idat);
                free(filedata);
                return NULL;
            }
            idat = grown;
            memcpy(idat + idat_len, cdata, clen);
            idat_len += clen;
        } else if (memcmp(ctype, "IEND", 4) == 0) {
            break;
        }

        pos += 8 + (size_t)clen + 4;
    }
    free(filedata);
    filedata = NULL;

    if (width <= 0 || height <= 0 || width > 16384 || height > 16384)
        goto done;
    if (bitdepth != 8 || interlace != 0)
        goto done; /* RetroArch writes plain 8-bit, non-interlaced PNGs */
    switch (colortype) {
    case 2: channels = 3; break; /* RGB  */
    case 6: channels = 4; break; /* RGBA */
    default: goto done;          /* grayscale/palette: not what we expect */
    }
    if (!idat || idat_len == 0)
        goto done;

    uncompress_fn = gs_zlib_uncompress();
    if (!uncompress_fn)
        goto done;

    stride = 1 + (size_t)width * (size_t)channels; /* +1 filter byte/row */
    raw_len = (unsigned long)(stride * (size_t)height);
    if (raw_len == 0 || raw_len / (unsigned long)height != stride)
        goto done; /* overflow guard */

    raw = (unsigned char *)malloc(raw_len);
    if (!raw)
        goto done;

    {
        unsigned long out_len = raw_len;
        rc = uncompress_fn(raw, &out_len, idat, idat_len);
        if (rc != 0 /* Z_OK */ || out_len != raw_len)
            goto done;
    }

    surf = SDL_CreateRGBSurfaceWithFormat(0, width, height, channels * 8,
                                          channels == 4 ? SDL_PIXELFORMAT_RGBA32
                                                        : SDL_PIXELFORMAT_RGB24);
    if (!surf)
        goto done;

    prev_row = (unsigned char *)calloc((size_t)width * (size_t)channels, 1);
    if (!prev_row) {
        SDL_FreeSurface(surf);
        surf = NULL;
        goto done;
    }

    SDL_LockSurface(surf);
    for (y = 0; y < (size_t)height; y++) {
        unsigned char *row = raw + y * stride;
        int filter = row[0];
        unsigned char *pixels = row + 1;
        size_t rowbytes = (size_t)width * (size_t)channels;
        unsigned char *dst = (unsigned char *)surf->pixels + y * surf->pitch;

        gs_png_unfilter_row(pixels, y == 0 ? NULL : prev_row, rowbytes, channels, filter);
        memcpy(dst, pixels, rowbytes);
        memcpy(prev_row, pixels, rowbytes);
    }
    SDL_UnlockSurface(surf);

done:
    free(idat);
    free(raw);
    free(prev_row);
    return surf;
}

#endif /* GS_PNG_H */
