/* fusion-box: validate the Path-2 "GDI-buffer slice promotion" idea.
 *
 *
 *   Does KWin correctly composite N wl_subsurfaces that all attach the
 *   SAME parent wl_buffer, each cropped via wp_viewport_set_source to a
 *   different sub-rect, stacked above a separate buffer-bearing sibling
 *   subsurface?
 *
 * Scene built by this test (no wine, pure wayland-client):
 *
 *   - MAIN xdg_toplevel, 800x600 wl_shm buffer painted:
 *       top half red, bottom half blue, with a CYAN 200x40 "toolbar"
 *       strip at (300, 530).
 *   - Subsurface A, sibling of MAIN, its OWN 800x600 SHM buffer, solid
 *     WHITE. Positioned at (0,0). This simulates the DXVK swapchain
 *     widget that buries the toolbar in Fusion. Created first, so by
 *     Wayland creation-order rule it sits just above MAIN's buffer.
 *   - Subsurface B, sibling of MAIN, ATTACHES MAIN'S SHARED wl_buffer,
 *     with wp_viewport_set_source cropped to the (300,530)+200x40
 *     toolbar rect and wp_viewport_set_destination set to 200x40.
 *     Positioned at (300, 530). Created AFTER A, so on top of A by
 *     creation-order rule.
 *
 * Expected (PASS):
 *   Window is solid white EXCEPT for a 200x40 cyan strip at
 *   bottom-center. The cyan was painted into MAIN's buffer; it survives
 *   the white A overlay because B is on top of A and presents the same
 *   buffer cropped to just the cyan region.
 *
 * Failure modes and what they tell us:
 *   - All white, no cyan strip: B is invisible. Either (a) KWin
 *     rejects multi-attach of the same wl_buffer (less likely - protocol
 *     allows it), (b) B's wp_viewport src is wrong, or (c) B is below A.
 *   - Red/blue background visible: A failed to cover. Probably a
 *     subsurface position or commit-order bug in this test.
 *   - Full MAIN buffer (red+blue+cyan) visible in B's 200x40 dst rect:
 *     wp_viewport_set_source was ignored. Means we can't share buffers
 *     this way; Path 2 needs per-child SHM extraction (Qt's pattern).
 *
 * Build (inside fusion-box - host doesn't have the deps):
 *
 *   cd debug/wine-tests/shared-buffer-test
 *   bash build.sh
 *   ./shared-buffer-test
 *
 * Esc closes. Compositor close-button closes. Prints OBSERVED outcome
 * via WAYLAND_DEBUG=1 traces if requested.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"

#define MAIN_W       800
#define MAIN_H       600
#define TOOLBAR_X    300
#define TOOLBAR_Y    530
#define TOOLBAR_W    200
#define TOOLBAR_H    40

/* ARGB-packed colors (we use XRGB8888 so alpha byte is ignored). */
#define ARGB(r,g,b) (0xFF000000u | ((r) << 16) | ((g) << 8) | (b))
#define COLOR_RED   ARGB(220, 30, 30)
#define COLOR_BLUE  ARGB(30, 30, 220)
#define COLOR_CYAN  ARGB(0, 220, 220)
#define COLOR_WHITE ARGB(255, 255, 255)

struct app {
    struct wl_display      *display;
    struct wl_registry     *registry;
    struct wl_compositor   *compositor;
    struct wl_subcompositor *subcompositor;
    struct wl_shm          *shm;
    struct xdg_wm_base     *wm_base;
    struct wp_viewporter   *viewporter;
    struct zxdg_decoration_manager_v1 *decoration_manager;

    struct wl_surface      *main_surface;
    struct xdg_surface     *main_xdg_surface;
    struct xdg_toplevel    *main_toplevel;
    struct wl_buffer       *main_buffer;
    int                     main_configured;

    struct wl_surface      *a_surface;
    struct wl_subsurface   *a_subsurface;
    struct wl_buffer       *a_buffer;

    struct wl_surface      *b_surface;
    struct wl_subsurface   *b_subsurface;
    struct wp_viewport     *b_viewport;

    int                     should_exit;
};

/* ---------- SHM helpers ---------- */

static int create_anon_fd(off_t size) {
    char name[32];
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    snprintf(name, sizeof(name), "/sbtest-%ld-%d", ts.tv_nsec, getpid());

    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        perror("shm_open");
        return -1;
    }
    shm_unlink(name);

    if (ftruncate(fd, size) < 0) {
        perror("ftruncate");
        close(fd);
        return -1;
    }
    return fd;
}

static struct wl_buffer *make_buffer(struct app *a, int w, int h, uint32_t **out_pixels) {
    int stride = w * 4;
    int size = stride * h;
    int fd = create_anon_fd(size);
    if (fd < 0) {
        return NULL;
    }

    void *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return NULL;
    }

    struct wl_shm_pool *pool = wl_shm_create_pool(a->shm, fd, size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    *out_pixels = (uint32_t *)map;
    return buf;
}

static void paint_main(uint32_t *px) {
    /* Top half red, bottom half blue. */
    for (int y = 0; y < MAIN_H; ++y) {
        uint32_t c = (y < MAIN_H / 2) ? COLOR_RED : COLOR_BLUE;
        for (int x = 0; x < MAIN_W; ++x) {
            px[y * MAIN_W + x] = c;
        }
    }
    /* Cyan toolbar strip at (TOOLBAR_X, TOOLBAR_Y). */
    for (int y = TOOLBAR_Y; y < TOOLBAR_Y + TOOLBAR_H && y < MAIN_H; ++y) {
        for (int x = TOOLBAR_X; x < TOOLBAR_X + TOOLBAR_W && x < MAIN_W; ++x) {
            px[y * MAIN_W + x] = COLOR_CYAN;
        }
    }
}

static void paint_solid(uint32_t *px, int w, int h, uint32_t color) {
    for (int i = 0; i < w * h; ++i) {
        px[i] = color;
    }
}

/* ---------- xdg-shell listeners ---------- */

static void wm_base_ping(void *data, struct xdg_wm_base *wb, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wb, serial);
}
static const struct xdg_wm_base_listener wm_base_listener = { wm_base_ping };

static void xdg_surface_configure(void *data, struct xdg_surface *xs, uint32_t serial) {
    struct app *a = data;
    xdg_surface_ack_configure(xs, serial);
    a->main_configured = 1;
}
static const struct xdg_surface_listener xdg_surface_listener = { xdg_surface_configure };

static void xdg_toplevel_configure(void *d, struct xdg_toplevel *tl, int32_t w, int32_t h, struct wl_array *states) {
    (void)d; (void)tl; (void)w; (void)h; (void)states;
}
static void xdg_toplevel_close(void *d, struct xdg_toplevel *tl) {
    (void)tl;
    ((struct app *)d)->should_exit = 1;
}
static const struct xdg_toplevel_listener xdg_toplevel_listener = {
    xdg_toplevel_configure, xdg_toplevel_close, NULL, NULL
};

/* ---------- registry ---------- */

static void registry_global(void *data, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    struct app *a = data;
    if (!strcmp(iface, "wl_compositor")) {
        a->compositor = wl_registry_bind(r, name, &wl_compositor_interface, ver < 4 ? ver : 4);
    } else if (!strcmp(iface, "wl_subcompositor")) {
        a->subcompositor = wl_registry_bind(r, name, &wl_subcompositor_interface, 1);
    } else if (!strcmp(iface, "wl_shm")) {
        a->shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    } else if (!strcmp(iface, "xdg_wm_base")) {
        a->wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(a->wm_base, &wm_base_listener, NULL);
    } else if (!strcmp(iface, "wp_viewporter")) {
        a->viewporter = wl_registry_bind(r, name, &wp_viewporter_interface, 1);
    } else if (!strcmp(iface, "zxdg_decoration_manager_v1")) {
        a->decoration_manager = wl_registry_bind(r, name, &zxdg_decoration_manager_v1_interface, 1);
    }
}
static void registry_global_remove(void *d, struct wl_registry *r, uint32_t name) {
    (void)d; (void)r; (void)name;
}
static const struct wl_registry_listener registry_listener = { registry_global, registry_global_remove };

/* ---------- main ---------- */

int main(void) {
    struct app a = {0};

    a.display = wl_display_connect(NULL);
    if (!a.display) {
        fprintf(stderr, "wl_display_connect failed\n");
        return 1;
    }

    a.registry = wl_display_get_registry(a.display);
    wl_registry_add_listener(a.registry, &registry_listener, &a);
    wl_display_roundtrip(a.display);

    if (!a.compositor || !a.subcompositor || !a.shm || !a.wm_base || !a.viewporter) {
        fprintf(stderr, "missing required globals: compositor=%p subcompositor=%p shm=%p wm_base=%p viewporter=%p\n",
                (void*)a.compositor, (void*)a.subcompositor, (void*)a.shm, (void*)a.wm_base, (void*)a.viewporter);
        return 2;
    }

    /* --- MAIN toplevel --- */
    a.main_surface = wl_compositor_create_surface(a.compositor);
    a.main_xdg_surface = xdg_wm_base_get_xdg_surface(a.wm_base, a.main_surface);
    xdg_surface_add_listener(a.main_xdg_surface, &xdg_surface_listener, &a);
    a.main_toplevel = xdg_surface_get_toplevel(a.main_xdg_surface);
    xdg_toplevel_add_listener(a.main_toplevel, &xdg_toplevel_listener, &a);
    xdg_toplevel_set_title(a.main_toplevel, "fusion-box shared-buffer-test");
    xdg_toplevel_set_app_id(a.main_toplevel, "fusion-box.shared-buffer-test");

    /* Request server-side decorations so KWin draws a title bar with a close button. Without this the test runs as a chromeless toplevel
     * and the only way to close it is pkill / Ctrl+C. */
    if (a.decoration_manager) {
        struct zxdg_toplevel_decoration_v1 *deco = zxdg_decoration_manager_v1_get_toplevel_decoration(a.decoration_manager, a.main_toplevel);
        zxdg_toplevel_decoration_v1_set_mode(deco, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    }

    wl_surface_commit(a.main_surface);

    /* Wait for first configure. */
    while (!a.main_configured) {
        if (wl_display_dispatch(a.display) < 0) {
            return 3;
        }
    }

    /* Paint MAIN's buffer and attach. */
    uint32_t *main_px = NULL;
    a.main_buffer = make_buffer(&a, MAIN_W, MAIN_H, &main_px);
    if (!a.main_buffer) {
        return 4;
    }
    paint_main(main_px);
    wl_surface_attach(a.main_surface, a.main_buffer, 0, 0);
    wl_surface_damage_buffer(a.main_surface, 0, 0, MAIN_W, MAIN_H);
    wl_surface_commit(a.main_surface);

    /* --- Subsurface A (the "DXVK widget"), own white buffer, full size --- */
    a.a_surface = wl_compositor_create_surface(a.compositor);
    a.a_subsurface = wl_subcompositor_get_subsurface(a.subcompositor, a.a_surface, a.main_surface);
    wl_subsurface_set_desync(a.a_subsurface); /* take effect independently of parent */
    wl_subsurface_set_position(a.a_subsurface, 0, 0);
    uint32_t *a_px = NULL;
    a.a_buffer = make_buffer(&a, MAIN_W, MAIN_H, &a_px);
    if (!a.a_buffer) {
        return 5;
    }
    paint_solid(a_px, MAIN_W, MAIN_H, COLOR_WHITE);
    wl_surface_attach(a.a_surface, a.a_buffer, 0, 0);
    wl_surface_damage_buffer(a.a_surface, 0, 0, MAIN_W, MAIN_H);
    wl_surface_commit(a.a_surface);

    /* --- Subsurface B (the "promoted toolbar"), SHARED main buffer + viewport crop --- */
    a.b_surface = wl_compositor_create_surface(a.compositor);
    a.b_subsurface = wl_subcompositor_get_subsurface(a.subcompositor, a.b_surface, a.main_surface);
    wl_subsurface_set_desync(a.b_subsurface);
    wl_subsurface_set_position(a.b_subsurface, TOOLBAR_X, TOOLBAR_Y);

    a.b_viewport = wp_viewporter_get_viewport(a.viewporter, a.b_surface);
    /* wp_viewport_set_source takes wl_fixed_t (24.8). Negative width means "no source clip", so use positive integers via wl_fixed_from_int. */
    wp_viewport_set_source(a.b_viewport,
                           wl_fixed_from_int(TOOLBAR_X),
                           wl_fixed_from_int(TOOLBAR_Y),
                           wl_fixed_from_int(TOOLBAR_W),
                           wl_fixed_from_int(TOOLBAR_H));
    wp_viewport_set_destination(a.b_viewport, TOOLBAR_W, TOOLBAR_H);

    /* Attach the SAME wl_buffer that MAIN has attached. Per protocol, this is legal - the compositor reference-counts wl_buffer attaches. */
    wl_surface_attach(a.b_surface, a.main_buffer, 0, 0);
    wl_surface_damage_buffer(a.b_surface, 0, 0, MAIN_W, MAIN_H);
    wl_surface_commit(a.b_surface);

    /* Commit parent to flush the subsurface state changes. */
    wl_surface_commit(a.main_surface);

    fprintf(stderr,
        "shared-buffer-test running. Expected visual:\n"
        "  - Window is mostly SOLID WHITE (subsurface A).\n"
        "  - A 200x40 CYAN strip is visible at bottom-center,\n"
        "    rect (%d,%d)-(%d,%d), drawn by subsurface B presenting\n"
        "    MAIN's shared buffer cropped via wp_viewport.\n"
        "PASS = cyan strip on white background.\n"
        "FAIL modes:\n"
        "  - All white, no cyan        -> shared-buffer attach broken OR B z-order below A\n"
        "  - Red/blue background       -> A failed to cover\n"
        "  - Cyan strip + red/blue     -> viewport src ignored, B showing full buffer\n"
        "Close with WM close button or pkill.\n",
        TOOLBAR_X, TOOLBAR_Y, TOOLBAR_X + TOOLBAR_W, TOOLBAR_Y + TOOLBAR_H);

    while (!a.should_exit) {
        if (wl_display_dispatch(a.display) < 0) {
            fprintf(stderr, "wl_display_dispatch failed (errno=%d %s)\n", errno, strerror(errno));
            return 6;
        }
    }
    fprintf(stderr, "exiting\n");
    return 0;
}
