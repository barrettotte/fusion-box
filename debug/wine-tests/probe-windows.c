/* fusion-box: probe the Win32 window tree visible in the current wineserver.
 *
 * Purpose: pin down whether Fusion's bottom toolbar (Qt683QWindowToolSaveBits)
 * takes the xdg_popup path or the wl_subsurface path inside winewayland.drv,
 * by reporting the exact gate inputs the role-decision logic sees:
 *
 *   - WS_POPUP / WS_CHILD / WS_VISIBLE / WS_EX_LAYERED / WS_EX_TOOLWINDOW
 *   - GW_OWNER (and whether the owner is itself a known toplevel)
 *   - GetParent() (set for WS_CHILD subsurfaces)
 *   - Screen rect
 *
 * With those values for the toolbar HWND, patch 0003's role decision in
 * dlls/winewayland.drv/window.c becomes deterministic to read off by hand.
 *
 * Run while Fusion is up and signed in, sharing the same wineprefix:
 *
 *   winegcc -m64 probe-windows.c -o probe-windows.exe.so
 *   wine ./probe-windows.exe.so
 *
 * (The launcher's WINEPREFIX must match this wine invocation's WINEPREFIX.
 * Inside fusion-box the default ~/.wine-fusion is correct for both.)
 */

#include <windows.h>
#include <stdio.h>
#include <wchar.h>

/* wprintf("%ls", ...) inside winegcc emits raw UTF-16 codepoints to stdout - unreadable on a Linux terminal
 * whose locale is C/UTF-8. Convert to UTF-8 manually with WideCharToMultiByte and printf via %s. */
static void print_utf8(const wchar_t *ws) {
    char buf[512];
    int n = WideCharToMultiByte(CP_UTF8, 0, ws, -1, buf, sizeof(buf) - 1, NULL, NULL);

    if (n <= 0) {
        printf("<encoding-error>");
        return;
    }
    buf[sizeof(buf) - 1] = 0;
    printf("%s", buf);
}

/* Pretty-print a non-trivial subset of GWL_STYLE / GWL_EXSTYLE. Not exhaustive;
 * focused on the bits the role decision in winewayland.drv reads. */
static void print_style_bits(DWORD style, DWORD exstyle) {
    printf("    style=0x%08lx  ", style);
    if (style & WS_POPUP)       printf("WS_POPUP ");
    if (style & WS_CHILD)       printf("WS_CHILD ");
    if (style & WS_VISIBLE)     printf("WS_VISIBLE ");
    if (style & WS_BORDER)      printf("WS_BORDER ");
    if (style & WS_CAPTION)     printf("WS_CAPTION ");
    if (style & WS_DISABLED)    printf("WS_DISABLED ");
    if (style & WS_MINIMIZE)    printf("WS_MINIMIZE ");
    if (style & WS_MAXIMIZE)    printf("WS_MAXIMIZE ");
    if (style & WS_THICKFRAME)  printf("WS_THICKFRAME ");
    if (style & WS_SYSMENU)     printf("WS_SYSMENU ");
    if (style & WS_CLIPCHILDREN) printf("WS_CLIPCHILDREN ");
    if (style & WS_CLIPSIBLINGS) printf("WS_CLIPSIBLINGS ");
    printf("\n");

    printf("    exstyle=0x%08lx ", exstyle);
    if (exstyle & WS_EX_TOPMOST)     printf("TOPMOST ");
    if (exstyle & WS_EX_LAYERED)     printf("LAYERED ");
    if (exstyle & WS_EX_TOOLWINDOW)  printf("TOOLWINDOW ");
    if (exstyle & WS_EX_TRANSPARENT) printf("TRANSPARENT ");
    if (exstyle & WS_EX_CONTROLPARENT) printf("CONTROLPARENT ");
    if (exstyle & WS_EX_NOACTIVATE)  printf("NOACTIVATE ");
    if (exstyle & WS_EX_DLGMODALFRAME) printf("DLGMODALFRAME ");
    if (exstyle & WS_EX_ACCEPTFILES) printf("ACCEPTFILES ");
    if (exstyle & WS_EX_APPWINDOW)   printf("APPWINDOW ");
    if (exstyle & WS_EX_NOREDIRECTIONBITMAP) printf("NOREDIRECTIONBITMAP ");
    printf("\n");
}

static void dump_window(HWND hwnd, int depth) {
    wchar_t cls[128] = {0};
    wchar_t title[128] = {0};
    GetClassNameW(hwnd, cls, 127);
    GetWindowTextW(hwnd, title, 127);

    DWORD style   = (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE);
    DWORD exstyle = (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    HWND owner    = GetWindow(hwnd, GW_OWNER);
    HWND parent   = GetAncestor(hwnd, GA_PARENT);
    HWND fg       = GetForegroundWindow();
    RECT rc;
    BOOL got_rect = GetWindowRect(hwnd, &rc);

    /* Indent by depth so we can read the tree. */
    for (int i = 0; i < depth; i++) printf("  ");

    printf("HWND=%p  class=\"", hwnd); print_utf8(cls); printf("\"\n");
    for (int i = 0; i < depth; i++) printf("  ");

    printf("    title=\""); print_utf8(title); printf("\"\n");
    for (int i = 0; i < depth; i++) printf("  ");

    print_style_bits(style, exstyle);
    for (int i = 0; i < depth; i++) printf("  ");

    printf("    owner=%p  parent=%p  isFg=%d  visible=%d\n", owner, parent, (hwnd == fg), IsWindowVisible(hwnd));
    if (got_rect) {
        for (int i = 0; i < depth; i++) printf("  ");
        printf("    rect=(%ld,%ld)-(%ld,%ld) %ldx%ld\n",
            rc.left, rc.top, rc.right, rc.bottom,
            rc.right - rc.left,
            rc.bottom - rc.top
        );
    }

    /* The two gates patch 0003 reads, evaluated up-front for human eyes. */
    BOOL gate_popup_no_child = (style & WS_POPUP) && !(style & WS_CHILD);
    BOOL has_owner = owner && owner != hwnd;
    for (int i = 0; i < depth; i++) printf("  ");
    printf("    patch0003 gates: popup&&!child=%d  owner=%d  toolwindow=%d\n",
        gate_popup_no_child, has_owner, !!(exstyle & WS_EX_TOOLWINDOW));
    printf("\n");
}

static BOOL CALLBACK child_cb(HWND hwnd, LPARAM lp) {
    int depth = (int)lp;
    /* Only print interesting children - too noisy otherwise. Filter to:
     *   - Qt683Q* windows (Fusion's Qt6 widgets)
     *   - WS_POPUP windows (popups can be deeply nested in Qt) */
    wchar_t cls[128] = {0};
    GetClassNameW(hwnd, cls, 127);
    DWORD style = (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE);

    if (wcsncmp(cls, L"Qt", 2) == 0 || (style & WS_POPUP)) {
        dump_window(hwnd, depth);
    }
    EnumChildWindows(hwnd, child_cb, depth + 1);
    return TRUE;
}

static BOOL CALLBACK top_cb(HWND hwnd, LPARAM lp) {
    wchar_t cls[128] = {0};
    GetClassNameW(hwnd, cls, 127);

    /* Only print top-levels owned by the current desktop session that look like Fusion-related.
     * Filter to Qt classes + anything containing "Fusion" or "Autodesk".
     * Everything else is e.g. clipboard/notify helpers we don't care about for this investigation. */
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (wcsncmp(cls, L"Qt", 2) == 0 || wcsstr(cls, L"Fusion") || wcsstr(cls, L"Autodesk") || (GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_POPUP)) {
        printf("======== top-level pid=%lu ========\n", pid);
        dump_window(hwnd, 0);
        EnumChildWindows(hwnd, child_cb, 1);
    }
    (void)lp;
    return TRUE;
}

/* Find a specific class name across all top-levels and their descendants.
 * The toolbar is "Qt683QWindowToolSaveBits"; the QWindowIcon overlays are "Qt683QWindowIcon". Search for both. */
typedef struct { const wchar_t *pattern; int count; } find_ctx;

static BOOL CALLBACK find_descendants(HWND hwnd, LPARAM lp) {
    find_ctx *ctx = (find_ctx *)lp;
    wchar_t cls[128] = {0};
    GetClassNameW(hwnd, cls, 127);

    if (wcsstr(cls, ctx->pattern)) {
        ctx->count++;
        printf("[match #%d]\n", ctx->count);
        dump_window(hwnd, 0);
    }
    EnumChildWindows(hwnd, find_descendants, lp);
    return TRUE;
}

static BOOL CALLBACK find_tops(HWND hwnd, LPARAM lp) {
    find_descendants(hwnd, lp);
    return TRUE;
}

static void find_class(const wchar_t *pattern) {
    find_ctx ctx = { pattern, 0 };
    printf("======== searching for class containing \"");
    print_utf8(pattern);
    printf("\" ========\n");
    EnumWindows(find_tops, (LPARAM)&ctx);
    if (!ctx.count) {
        printf("  (no matches)\n");
    }
    printf("\n");
}

int main(void) {
    printf("======== probe-windows: fusion-box ========\n");
    printf("Reports HWND/class/style of every Qt + WS_POPUP window in the current\n");
    printf("wineserver session. Run while Fusion is up and signed in.\n\n");

    /* Targeted searches first - these are the windows we explicitly care about for the toolbar-burial investigation. */
    find_class(L"Qt683QWindowToolSaveBits");    /* the toolbar */
    find_class(L"Qt683QWindowIcon");            /* the overlay siblings */
    find_class(L"Qt683QWindowToolTipSaveBits"); /* tooltips */
    find_class(L"Qt683QFusionMain");            /* speculative - guess at main class */
    find_class(L"Qt683QWindow");                /* catch-all Qt window class */

    /* Then a full sweep for visibility. */
    printf("======== full sweep (Qt + WS_POPUP only) ========\n");
    EnumWindows(top_cb, 0);

    return 0;
}
