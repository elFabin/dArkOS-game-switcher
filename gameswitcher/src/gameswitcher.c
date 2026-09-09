/*
 * gameswitcher - the dArkOS Game Switcher carousel.
 *
 * Reads the recents list written by gs-shim.sh, shows each game with the
 * screenshot taken at the moment it was suspended, and writes the player's
 * choice to /dev/shm/gs_choice for the shim to act on.
 *
 * Core SDL2 only, on purpose: cleanup_filesystem.sh strips the SDL2_image and
 * SDL2_ttf headers from the device image, so thumbnails are BMPs written by
 * ffmpeg and glyphs come from the baked-in atlas in font.h.
 *
 * Exit codes
 *   0   a choice was written to the out file
 *   10  back to EmulationStation
 *   11  sleep
 *   12  could not start at all (gs-shim.sh falls back to the text menu)
 *
 * amiberry/amiberry.sh documents EmulationStation not always having fully
 * released DRM master by the time its child's SDL2 KMS/DRM video init runs,
 * and works around it with a settle delay plus retries.  The same race can
 * happen here, between one game exiting and this carousel starting, so
 * SDL_Init/SDL_CreateWindow/SDL_CreateRenderer get the same treatment below
 * rather than a single attempt that gives up straight back to ES.
 */

#define _POSIX_C_SOURCE 200809L

#include <SDL2/SDL.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "font.h"

#define MAX_ENTRIES 64
#define MAX_PATH    1024

#define EXIT_CHOICE    0
#define EXIT_BACK      10
#define EXIT_SLEEP     11
#define EXIT_UI_FAILED 12

/* Matches amiberry.sh's own numbers: a short settle delay before each try,
 * up to five attempts total.  Overridable so tests don't have to spend
 * seconds per run waiting out a deliberately-broken video driver. */
#define DEFAULT_INIT_ATTEMPTS    5
#define DEFAULT_INIT_DELAY_MS  500

#define THUMB_W 320
#define THUMB_H 240

typedef struct {
    char key[32];
    long epoch;
    char emulator[32];
    char core[MAX_PATH];
    char system[64];
    char title[192];
    char rom[MAX_PATH];
    SDL_Texture *thumb;
    int thumb_loaded;
} Entry;

typedef struct { Uint8 r, g, b; } Color;

static const Color COL_BG     = {  20,  22,  28 };
static const Color COL_PANEL  = {  30,  33,  41 };
static const Color COL_FRAME  = {  58,  63,  78 };
static const Color COL_ACCENT = { 110, 168, 254 };
static const Color COL_TEXT   = { 232, 234, 240 };
static const Color COL_DIM    = { 139, 144, 160 };

static Entry g_entries[MAX_ENTRIES];
static int   g_count;
static int   g_sel;

static char g_state_dir[MAX_PATH] = "/home/ark/.config/gameswitcher";
static char g_recents[MAX_PATH];
static char g_thumbs[MAX_PATH];
static char g_out[MAX_PATH] = "/dev/shm/gs_choice";

/* ------------------------------------------------------------------ */
/* recents.tsv                                                         */
/* ------------------------------------------------------------------ */

static void copy_field(char *dst, size_t n, const char *src)
{
    if (!src) { dst[0] = '\0'; return; }
    strncpy(dst, src, n - 1);
    dst[n - 1] = '\0';
}

static int load_recents(const char *path)
{
    FILE *fh = fopen(path, "r");
    char line[4096];

    if (!fh)
        return 0;

    while (g_count < MAX_ENTRIES && fgets(line, sizeof(line), fh)) {
        Entry *e = &g_entries[g_count];
        char *save = NULL;
        char *f[7];
        int i;

        line[strcspn(line, "\r\n")] = '\0';
        if (line[0] == '\0')
            continue;

        /* key, epoch, emulator, core, system, title, rom */
        for (i = 0; i < 7; i++) {
            f[i] = strtok_r(i == 0 ? line : NULL, "\t", &save);
            if (!f[i])
                break;
        }
        if (i < 7)
            continue;

        memset(e, 0, sizeof(*e));
        copy_field(e->key, sizeof(e->key), f[0]);
        e->epoch = strtol(f[1], NULL, 10);
        copy_field(e->emulator, sizeof(e->emulator), f[2]);
        copy_field(e->core, sizeof(e->core), f[3]);
        copy_field(e->system, sizeof(e->system), f[4]);
        copy_field(e->title, sizeof(e->title), f[5]);
        copy_field(e->rom, sizeof(e->rom), f[6]);
        g_count++;
    }

    fclose(fh);
    return g_count;
}

static int write_choice(const char *action, const Entry *e)
{
    FILE *fh = fopen(g_out, "w");

    if (!fh)
        return -1;
    fprintf(fh, "action=%s\n", action);
    fprintf(fh, "key=%s\n", e->key);
    fprintf(fh, "emulator=%s\n", e->emulator);
    fprintf(fh, "core=%s\n", e->core);
    fprintf(fh, "rom=%s\n", e->rom);
    fclose(fh);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Text                                                                */
/* ------------------------------------------------------------------ */

static SDL_Texture *build_font_atlas(SDL_Renderer *ren)
{
    const int glyphs = GS_FONT_LAST - GS_FONT_FIRST + 1;
    SDL_Surface *surf;
    SDL_Texture *tex;
    Uint32 *px;
    int g, y, x;

    surf = SDL_CreateRGBSurfaceWithFormat(0, glyphs * GS_FONT_W, GS_FONT_H,
                                          32, SDL_PIXELFORMAT_RGBA32);
    if (!surf)
        return NULL;

    SDL_LockSurface(surf);
    px = (Uint32 *)surf->pixels;
    memset(px, 0, (size_t)surf->h * surf->pitch);
    for (g = 0; g < glyphs; g++) {
        for (y = 0; y < GS_FONT_H; y++) {
            unsigned char bits = gs_font[g][y];
            for (x = 0; x < GS_FONT_W; x++) {
                if (bits & (1 << (7 - x)))
                    px[y * (surf->pitch / 4) + g * GS_FONT_W + x] = 0xFFFFFFFFu;
            }
        }
    }
    SDL_UnlockSurface(surf);

    tex = SDL_CreateTextureFromSurface(ren, surf);
    SDL_FreeSurface(surf);
    if (tex)
        SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
    return tex;
}

static int text_w(const char *s, int scale)
{
    return (int)strlen(s) * GS_FONT_W * scale;
}

static void draw_text(SDL_Renderer *ren, SDL_Texture *atlas,
                      int x, int y, int scale, Color c, const char *s)
{
    SDL_Rect src = { 0, 0, GS_FONT_W, GS_FONT_H };
    SDL_Rect dst = { x, y, GS_FONT_W * scale, GS_FONT_H * scale };
    const unsigned char *p;

    SDL_SetTextureColorMod(atlas, c.r, c.g, c.b);
    for (p = (const unsigned char *)s; *p; p++) {
        int ch = *p;

        if (ch < GS_FONT_FIRST || ch > GS_FONT_LAST)
            ch = ' ';
        src.x = (ch - GS_FONT_FIRST) * GS_FONT_W;
        SDL_RenderCopy(ren, atlas, &src, &dst);
        dst.x += GS_FONT_W * scale;
    }
}

static void draw_text_centered(SDL_Renderer *ren, SDL_Texture *atlas,
                               int cx, int y, int scale, Color c, const char *s)
{
    draw_text(ren, atlas, cx - text_w(s, scale) / 2, y, scale, c, s);
}

/* Shorten to fit `max_chars`, marking the cut so a clipped name reads as one. */
static void fit_text(char *dst, size_t n, const char *src, size_t max_chars)
{
    size_t len = strlen(src);

    if (max_chars >= n)
        max_chars = n - 1;
    if (len <= max_chars) {
        copy_field(dst, n, src);
        return;
    }
    if (max_chars <= 3) {
        copy_field(dst, n, "...");
        return;
    }
    memcpy(dst, src, max_chars - 3);
    dst[max_chars - 3] = '\0';
    strcat(dst, "...");
}

/* ------------------------------------------------------------------ */
/* Chrome                                                              */
/* ------------------------------------------------------------------ */

static void set_color(SDL_Renderer *ren, Color c, Uint8 a)
{
    SDL_SetRenderDrawColor(ren, c.r, c.g, c.b, a);
}

static void fill_rect(SDL_Renderer *ren, int x, int y, int w, int h, Color c)
{
    SDL_Rect r = { x, y, w, h };

    set_color(ren, c, 255);
    SDL_RenderFillRect(ren, &r);
}

static void draw_border(SDL_Renderer *ren, int x, int y, int w, int h,
                        int thickness, Color c)
{
    int i;

    set_color(ren, c, 255);
    for (i = 0; i < thickness; i++) {
        SDL_Rect r = { x - i, y - i, w + 2 * i, h + 2 * i };
        SDL_RenderDrawRect(ren, &r);
    }
}

static SDL_Texture *thumb_for(SDL_Renderer *ren, Entry *e)
{
    char path[MAX_PATH + 64];
    SDL_Surface *surf;

    if (e->thumb_loaded)
        return e->thumb;
    e->thumb_loaded = 1;

    snprintf(path, sizeof(path), "%s/%s.bmp", g_thumbs, e->key);
    surf = SDL_LoadBMP(path);
    if (!surf)
        return NULL;
    e->thumb = SDL_CreateTextureFromSurface(ren, surf);
    SDL_FreeSurface(surf);
    return e->thumb;
}

static void rel_time(long epoch, char *buf, size_t n)
{
    long delta = (long)time(NULL) - epoch;

    if (delta < 0)      delta = 0;
    if (delta < 60)          snprintf(buf, n, "just now");
    else if (delta < 3600)   snprintf(buf, n, "%ldm ago", delta / 60);
    else if (delta < 86400)  snprintf(buf, n, "%ldh ago", delta / 3600);
    else                     snprintf(buf, n, "%ldd ago", delta / 86400);
}

static int battery_percent(void)
{
    FILE *fh = fopen("/sys/class/power_supply/battery/capacity", "r");
    int pct = -1;

    if (!fh)
        return -1;
    if (fscanf(fh, "%d", &pct) != 1)
        pct = -1;
    fclose(fh);
    return pct;
}

/* ------------------------------------------------------------------ */
/* Rendering                                                           */
/* ------------------------------------------------------------------ */

static void draw_card(SDL_Renderer *ren, SDL_Texture *atlas, Entry *e,
                      int cx, int cy, int w, int h, int selected)
{
    SDL_Texture *thumb = thumb_for(ren, e);
    SDL_Rect dst = { cx - w / 2, cy - h / 2, w, h };

    fill_rect(ren, dst.x, dst.y, dst.w, dst.h, COL_PANEL);

    if (thumb) {
        SDL_RenderCopy(ren, thumb, NULL, &dst);
    } else {
        /* No snapshot yet - this game has been launched but never suspended. */
        char label[8];
        int scale = selected ? 3 : 2;

        fit_text(label, sizeof(label), e->title, 3);
        draw_text_centered(ren, atlas, cx, cy - (GS_FONT_H * scale) / 2,
                           scale, COL_FRAME, label);
    }

    draw_border(ren, dst.x, dst.y, dst.w, dst.h, selected ? 3 : 1,
                selected ? COL_ACCENT : COL_FRAME);

    if (!selected) {
        /* Dim the neighbours so the focused card reads first. */
        SDL_SetRenderDrawBlendMode(ren, SDL_BLENDMODE_BLEND);
        set_color(ren, COL_BG, 130);
        SDL_RenderFillRect(ren, &dst);
        SDL_SetRenderDrawBlendMode(ren, SDL_BLENDMODE_NONE);
    }
}

static void draw_frame(SDL_Renderer *ren, SDL_Texture *atlas,
                       int W, int H, float anim)
{
    char buf[256];
    char line[320];
    int header_h = H / 11;
    int footer_h = H / 13;
    int card_h   = (int)(H * 0.40);
    int card_w   = card_h * THUMB_W / THUMB_H;
    int step     = (int)(card_w * 0.86);
    int cap_gap  = H / 24;
    int sub_gap  = H / 60;
    /* Centre the card and its two caption lines as one block. */
    int block_h  = card_h + cap_gap + GS_FONT_H * 2 + sub_gap + GS_FONT_H;
    int cy       = header_h + (H - header_h - footer_h - block_h) / 2 + card_h / 2;
    int pct;
    int i;
    time_t now;
    struct tm tmv;

    fill_rect(ren, 0, 0, W, H, COL_BG);

    /* Header */
    fill_rect(ren, 0, 0, W, header_h, COL_PANEL);
    draw_text(ren, atlas, GS_FONT_W, (header_h - GS_FONT_H * 2) / 2, 2,
              COL_TEXT, "Game Switcher");

    now = time(NULL);
    localtime_r(&now, &tmv);
    pct = battery_percent();
    if (pct >= 0)
        snprintf(buf, sizeof(buf), "%3d%%  %02d:%02d", pct, tmv.tm_hour, tmv.tm_min);
    else
        snprintf(buf, sizeof(buf), "%02d:%02d", tmv.tm_hour, tmv.tm_min);
    draw_text(ren, atlas, W - GS_FONT_W - text_w(buf, 1),
              (header_h - GS_FONT_H) / 2, 1, COL_DIM, buf);

    if (g_count == 0) {
        draw_text_centered(ren, atlas, W / 2, H / 2 - GS_FONT_H, 2, COL_DIM,
                           "No recent games yet");
        draw_text_centered(ren, atlas, W / 2, H / 2 + GS_FONT_H * 2, 1, COL_DIM,
                           "Play something and it will show up here");
    } else {
        /* Cards, furthest first so the selected one lands on top. */
        for (i = 3; i >= 1; i--) {
            int left  = g_sel - i;
            int right = g_sel + i;
            float off;

            if (left >= 0) {
                off = (float)(-i) + anim;
                draw_card(ren, atlas, &g_entries[left],
                          W / 2 + (int)(off * step), cy,
                          (int)(card_w * 0.68f), (int)(card_h * 0.68f), 0);
            }
            if (right < g_count) {
                off = (float)i + anim;
                draw_card(ren, atlas, &g_entries[right],
                          W / 2 + (int)(off * step), cy,
                          (int)(card_w * 0.68f), (int)(card_h * 0.68f), 0);
            }
        }
        draw_card(ren, atlas, &g_entries[g_sel],
                  W / 2 + (int)(anim * step), cy, card_w, card_h, 1);

        /* Caption */
        fit_text(buf, sizeof(buf), g_entries[g_sel].title,
                 (size_t)(W / (GS_FONT_W * 2)) - 2);
        draw_text_centered(ren, atlas, W / 2, cy + card_h / 2 + cap_gap, 2,
                           COL_TEXT, buf);

        rel_time(g_entries[g_sel].epoch, buf, sizeof(buf));
        snprintf(line, sizeof(line), "%s  -  %s  -  %d of %d",
                 g_entries[g_sel].system, buf, g_sel + 1, g_count);
        draw_text_centered(ren, atlas, W / 2,
                           cy + card_h / 2 + cap_gap + GS_FONT_H * 2 + sub_gap,
                           1, COL_DIM, line);
    }

    /* Footer */
    fill_rect(ren, 0, H - footer_h, W, footer_h, COL_PANEL);
    if (g_count == 0)
        snprintf(line, sizeof(line), "B  Back to EmulationStation");
    else
        snprintf(line, sizeof(line),
                 "A Resume   X Start over   Y Remove   B Back   Start Sleep");
    draw_text_centered(ren, atlas, W / 2, H - footer_h + (footer_h - GS_FONT_H) / 2,
                       1, COL_DIM, line);
}

/* ------------------------------------------------------------------ */
/* Input                                                               */
/* ------------------------------------------------------------------ */

/*
 * dArkOS handhelds are laid out Nintendo-style: global/buttonmon.sh reads the
 * face buttons as A=BTN_EAST, B=BTN_SOUTH, X=BTN_NORTH, Y=BTN_WEST, which SDL
 * reports as B, A, Y and X respectively.  Map by the label printed on the
 * shell, not by SDL's name, so the footer hints match the hardware.
 */
static SDL_GameControllerButton btn_confirm = SDL_CONTROLLER_BUTTON_B;
static SDL_GameControllerButton btn_back    = SDL_CONTROLLER_BUTTON_A;
static SDL_GameControllerButton btn_restart = SDL_CONTROLLER_BUTTON_Y;
static SDL_GameControllerButton btn_remove  = SDL_CONTROLLER_BUTTON_X;

static void apply_button_layout(void)
{
    const char *layout = SDL_getenv("GS_BUTTON_LAYOUT");

    if (layout && SDL_strcasecmp(layout, "xbox") == 0) {
        btn_confirm = SDL_CONTROLLER_BUTTON_A;
        btn_back    = SDL_CONTROLLER_BUTTON_B;
        btn_restart = SDL_CONTROLLER_BUTTON_X;
        btn_remove  = SDL_CONTROLLER_BUTTON_Y;
    }
}

static void open_controllers(void)
{
    int i;

    for (i = 0; i < SDL_NumJoysticks(); i++) {
        if (SDL_IsGameController(i))
            SDL_GameControllerOpen(i);
    }
}

/* ------------------------------------------------------------------ */

static void usage(void)
{
    fprintf(stderr,
            "usage: gameswitcher [--state DIR] [--recents FILE] [--out FILE]\n"
            "                    [--dump FILE.bmp] [--size WxH] [--select N]\n");
}

static int env_int_or(const char *name, int fallback)
{
    const char *s = SDL_getenv(name);
    int n;

    if (!s || !*s)
        return fallback;
    n = atoi(s);
    return n >= 0 ? n : fallback;
}

int main(int argc, char **argv)
{
    const char *dump = NULL;
    int forced_w = 0, forced_h = 0;
    SDL_Window *win = NULL;
    SDL_Renderer *ren = NULL;
    SDL_Texture *atlas = NULL;
    SDL_DisplayMode mode;
    int W = 640, H = 480;
    int running = 1;
    int rc = EXIT_BACK;
    float anim = 0.0f;
    int i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--state") && i + 1 < argc)
            copy_field(g_state_dir, sizeof(g_state_dir), argv[++i]);
        else if (!strcmp(argv[i], "--recents") && i + 1 < argc)
            copy_field(g_recents, sizeof(g_recents), argv[++i]);
        else if (!strcmp(argv[i], "--out") && i + 1 < argc)
            copy_field(g_out, sizeof(g_out), argv[++i]);
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc)
            dump = argv[++i];
        else if (!strcmp(argv[i], "--select") && i + 1 < argc)
            g_sel = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--size") && i + 1 < argc) {
            if (sscanf(argv[++i], "%dx%d", &forced_w, &forced_h) != 2) {
                usage();
                return 2;
            }
        }
        else {
            usage();
            return 2;
        }
    }

    if (g_recents[0] == '\0')
        snprintf(g_recents, sizeof(g_recents), "%s/recents.tsv", g_state_dir);
    snprintf(g_thumbs, sizeof(g_thumbs), "%s/thumbs", g_state_dir);

    load_recents(g_recents);
    if (g_sel >= g_count)
        g_sel = g_count > 0 ? g_count - 1 : 0;
    if (g_sel < 0)
        g_sel = 0;

    {
        int max_attempts = env_int_or("GS_UI_INIT_RETRIES", DEFAULT_INIT_ATTEMPTS);
        int delay_ms     = env_int_or("GS_UI_INIT_DELAY_MS", DEFAULT_INIT_DELAY_MS);
        int attempt;

        if (max_attempts < 1)
            max_attempts = 1;

        for (attempt = 1; attempt <= max_attempts; attempt++) {
            if (delay_ms > 0)
                SDL_Delay((Uint32)delay_ms);

            if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER) != 0) {
                /* Without a controller subsystem we can still run on a keyboard. */
                if (SDL_Init(SDL_INIT_VIDEO) != 0) {
                    fprintf(stderr, "gameswitcher: SDL_Init attempt %d/%d: %s\n",
                            attempt, max_attempts, SDL_GetError());
                    continue;
                }
            }
            apply_button_layout();
            open_controllers();

            if (SDL_GetCurrentDisplayMode(0, &mode) == 0 && mode.w > 0) {
                W = mode.w;
                H = mode.h;
            }
            if (forced_w > 0 && forced_h > 0) {
                W = forced_w;
                H = forced_h;
            }

            win = SDL_CreateWindow("Game Switcher", SDL_WINDOWPOS_CENTERED,
                                   SDL_WINDOWPOS_CENTERED, W, H,
                                   (forced_w ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP)
                                   | SDL_WINDOW_SHOWN);
            if (!win) {
                fprintf(stderr, "gameswitcher: SDL_CreateWindow attempt %d/%d: %s\n",
                        attempt, max_attempts, SDL_GetError());
                SDL_Quit();
                continue;
            }

            ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
            if (!ren)
                ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
            if (!ren) {
                fprintf(stderr, "gameswitcher: SDL_CreateRenderer attempt %d/%d: %s\n",
                        attempt, max_attempts, SDL_GetError());
                SDL_DestroyWindow(win);
                win = NULL;
                SDL_Quit();
                continue;
            }

            break; /* window + renderer both came up */
        }
    }

    if (!win || !ren) {
        fprintf(stderr, "gameswitcher: could not start video\n");
        return EXIT_UI_FAILED;
    }

    SDL_ShowCursor(SDL_DISABLE);
    if (!forced_w)
        SDL_GetRendererOutputSize(ren, &W, &H);

    atlas = build_font_atlas(ren);
    if (!atlas) {
        fprintf(stderr, "gameswitcher: font atlas: %s\n", SDL_GetError());
        SDL_DestroyRenderer(ren);
        SDL_DestroyWindow(win);
        SDL_Quit();
        return EXIT_UI_FAILED;
    }

    /* Headless render for tests: one frame, straight to a BMP. */
    if (dump) {
        SDL_Surface *shot;

        draw_frame(ren, atlas, W, H, 0.0f);
        shot = SDL_CreateRGBSurfaceWithFormat(0, W, H, 32, SDL_PIXELFORMAT_RGBA32);
        if (shot) {
            SDL_RenderReadPixels(ren, NULL, SDL_PIXELFORMAT_RGBA32,
                                 shot->pixels, shot->pitch);
            SDL_SaveBMP(shot, dump);
            SDL_FreeSurface(shot);
        }
        running = 0;
        rc = EXIT_BACK;
    }

    while (running) {
        SDL_Event ev;

        while (SDL_PollEvent(&ev)) {
            int move = 0;
            int confirm = 0, back = 0, restart = 0, remove = 0, sleep_now = 0;

            switch (ev.type) {
            case SDL_QUIT:
                running = 0;
                break;
            case SDL_CONTROLLERDEVICEADDED:
                SDL_GameControllerOpen(ev.cdevice.which);
                break;
            case SDL_CONTROLLERBUTTONDOWN:
                if (ev.cbutton.button == SDL_CONTROLLER_BUTTON_DPAD_LEFT)  move = -1;
                else if (ev.cbutton.button == SDL_CONTROLLER_BUTTON_DPAD_RIGHT) move = 1;
                else if (ev.cbutton.button == btn_confirm) confirm = 1;
                else if (ev.cbutton.button == btn_back)    back = 1;
                else if (ev.cbutton.button == btn_restart) restart = 1;
                else if (ev.cbutton.button == btn_remove)  remove = 1;
                else if (ev.cbutton.button == SDL_CONTROLLER_BUTTON_START) sleep_now = 1;
                break;
            case SDL_KEYDOWN:
                switch (ev.key.keysym.sym) {
                case SDLK_LEFT:      move = -1; break;
                case SDLK_RIGHT:     move = 1;  break;
                case SDLK_RETURN:
                case SDLK_SPACE:     confirm = 1; break;
                case SDLK_ESCAPE:
                case SDLK_BACKSPACE: back = 1; break;
                case SDLK_r:         restart = 1; break;
                case SDLK_d:         remove = 1; break;
                case SDLK_s:         sleep_now = 1; break;
                default: break;
                }
                break;
            default:
                break;
            }

            if (move && g_count > 0) {
                int next = g_sel + move;

                if (next >= 0 && next < g_count) {
                    g_sel = next;
                    anim += (float)move;
                    if (anim > 1.0f)  anim = 1.0f;
                    if (anim < -1.0f) anim = -1.0f;
                }
            }
            if (back) {
                rc = EXIT_BACK;
                running = 0;
            }
            if (sleep_now) {
                rc = EXIT_SLEEP;
                running = 0;
            }
            if (g_count > 0 && (confirm || restart || remove)) {
                const char *action = confirm ? "launch"
                                   : restart ? "restart" : "remove";

                if (write_choice(action, &g_entries[g_sel]) == 0) {
                    rc = EXIT_CHOICE;
                    running = 0;
                }
            }
        }

        /* Ease the carousel back to centre after a move. */
        if (anim > 0.001f || anim < -0.001f) {
            anim *= 0.72f;
            if (anim < 0.01f && anim > -0.01f)
                anim = 0.0f;
        }

        draw_frame(ren, atlas, W, H, anim);
        SDL_RenderPresent(ren);
        SDL_Delay(16);
    }

    for (i = 0; i < g_count; i++) {
        if (g_entries[i].thumb)
            SDL_DestroyTexture(g_entries[i].thumb);
    }
    SDL_DestroyTexture(atlas);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return rc;
}
