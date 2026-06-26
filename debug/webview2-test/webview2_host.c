/*
 * fusion-box debug/webview2-test: minimal WebView2 host to validate that
 * Phase D's dcomp.dll is callable end-to-end under Chromium.
 *
 * Problem context: in Fusion, Edge WV2's GPU subprocess never calls
 * DCompositionCreate* because Fusion's Data Panel content fails to load
 * (chicken-and-egg with the original cross-process surface bug). We can't
 * validate the Phase D dcomp stub end-to-end under real Fusion.
 *
 * Goal: spawn an isolated WebView2 instance that loads GPU-compositor-
 * eligible content (CSS 3D transforms, canvas animation). This forces
 * Chromium's GPU subprocess into compositing → DCompositionCreateDevice3
 * → fusion-box D-0..D-3 code path lights up.
 *
 * Build: bash build.sh
 * Run:   bash run.sh
 *
 * The host uses LoadLibrary on the WebView2Loader.dll bundled by
 * Autodesk's Identity Manager and embeds a single WebView2 at full-window
 * size, navigated to test_content.html.
 */

#define INITGUID   /* emit IID constants into this TU */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
#include "webview2_minimal.h"

static HWND g_main_hwnd = NULL;
static ICoreWebView2Controller *g_controller = NULL;
static ICoreWebView2 *g_webview = NULL;

/* Logging: writes to BOTH OutputDebugString (captured by wine trace as
 * fixme/trace messages on whatever channel) AND a dedicated log file at
 * C:\webview2_host.log. Stderr doesn't propagate reliably from wine
 * console apps in some launch contexts. */
static void log_msg(const char *fmt, ...)
{
    static HANDLE hlog = INVALID_HANDLE_VALUE;
    char buf[1024];
    va_list ap;
    DWORD written;
    int len;

    if (hlog == INVALID_HANDLE_VALUE)
    {
        hlog = CreateFileA("C:\\webview2_host.log", GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hlog != INVALID_HANDLE_VALUE)
            SetFilePointer(hlog, 0, NULL, FILE_END);
    }

    va_start(ap, fmt);
    len = vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
    va_end(ap);
    if (len < 0) len = sizeof(buf) - 1;
    buf[len] = 0;

    OutputDebugStringA(buf);
    if (hlog != INVALID_HANDLE_VALUE)
        WriteFile(hlog, buf, len, &written, NULL);
}

/* ------------------------------------------------------------------ */
/* NavigationCompleted handler                                        */
/* Fires when Chromium finishes (or fails) loading a navigation.      */
/* Proves Chromium ACTUALLY processed the page — separately from the  */
/* question of whether pixels reach our HWND. If this fires, the      */
/* failure is downstream (presentation chain). If it doesn't, the     */
/* failure is upstream (page load itself broken).                     */
/* ------------------------------------------------------------------ */

typedef struct
{
    ICoreWebView2NavigationCompletedEventHandler iface;
    LONG ref;
} NavCompletedHandler;

static HRESULT STDMETHODCALLTYPE nav_QueryInterface(
        ICoreWebView2NavigationCompletedEventHandler *iface, REFIID iid, void **out)
{
    if (IsEqualIID(iid, &IID_IUnknown)
            || IsEqualIID(iid, &IID_ICoreWebView2NavigationCompletedEventHandler))
    {
        *out = iface;
        iface->lpVtbl->AddRef(iface);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE nav_AddRef(ICoreWebView2NavigationCompletedEventHandler *iface)
{
    NavCompletedHandler *self = (NavCompletedHandler *)iface;
    return InterlockedIncrement(&self->ref);
}
static ULONG STDMETHODCALLTYPE nav_Release(ICoreWebView2NavigationCompletedEventHandler *iface)
{
    NavCompletedHandler *self = (NavCompletedHandler *)iface;
    ULONG r = InterlockedDecrement(&self->ref);
    if (r == 0) free(self);
    return r;
}
static HRESULT STDMETHODCALLTYPE nav_Invoke(
        ICoreWebView2NavigationCompletedEventHandler *iface,
        ICoreWebView2 *sender, ICoreWebView2NavigationCompletedEventArgs *args)
{
    log_msg("[webview2-test] *** NavigationCompleted fired *** sender=%p args=%p\n",
            sender, args);
    log_msg("[webview2-test] (this proves Chromium loaded our page; pixels are SEPARATE issue)\n");
    return S_OK;
}
static const ICoreWebView2NavigationCompletedEventHandlerVtbl nav_vtbl =
{
    nav_QueryInterface,
    nav_AddRef,
    nav_Release,
    nav_Invoke,
};

/* ------------------------------------------------------------------ */
/* Controller-completed handler                                       */
/* Called by WV2 once CreateCoreWebView2Controller finishes.          */
/* ------------------------------------------------------------------ */

typedef struct
{
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler iface;
    LONG ref;
} ControllerHandler;

static HRESULT STDMETHODCALLTYPE ctrl_QueryInterface(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *iface,
        REFIID iid, void **out)
{
    if (IsEqualIID(iid, &IID_IUnknown)
            || IsEqualIID(iid, &IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler))
    {
        *out = iface;
        iface->lpVtbl->AddRef(iface);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE ctrl_AddRef(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *iface)
{
    ControllerHandler *self = (ControllerHandler *)iface;
    return InterlockedIncrement(&self->ref);
}
static ULONG STDMETHODCALLTYPE ctrl_Release(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *iface)
{
    ControllerHandler *self = (ControllerHandler *)iface;
    ULONG r = InterlockedDecrement(&self->ref);
    if (r == 0) free(self);
    return r;
}
static HRESULT STDMETHODCALLTYPE ctrl_Invoke(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *iface,
        HRESULT result, ICoreWebView2Controller *controller)
{
    HRESULT hr;
    RECT bounds;

    log_msg("[webview2-test] controller created: hr=0x%lx controller=%p\n",
            result, controller);
    /* log_msg auto-flushes */

    if (FAILED(result) || !controller) return result;

    g_controller = controller;
    controller->lpVtbl->AddRef(controller);

    /* Set bounds + show */
    GetClientRect(g_main_hwnd, &bounds);
    hr = controller->lpVtbl->put_Bounds(controller, bounds);
    log_msg("[webview2-test] put_Bounds: hr=0x%lx (%ld,%ld)-(%ld,%ld)\n",
            hr, bounds.left, bounds.top, bounds.right, bounds.bottom);
    hr = controller->lpVtbl->put_IsVisible(controller, TRUE);
    log_msg("[webview2-test] put_IsVisible(TRUE): hr=0x%lx\n", hr);

    hr = controller->lpVtbl->get_CoreWebView2(controller, &g_webview);
    log_msg("[webview2-test] get_CoreWebView2: hr=0x%lx webview=%p\n", hr, g_webview);

    if (SUCCEEDED(hr) && g_webview)
    {
        /* Navigate to our test_content.html — CSS 3D transform (spinning
         * gradient) + animated canvas (bouncing balls). Forces GPU
         * compositor activation and exercises both compositor layers and
         * raster paint, so we know rendering is fully working when content
         * appears. file_path resolves to C:\test_content.html in the
         * wineprefix (run.sh copies it there). */
        WCHAR url[] = L"file:///C:/test_content.html";

        /* Register NavigationCompleted handler BEFORE Navigate — proves
         * Chromium fully processed the page even if no pixels reach us. */
        NavCompletedHandler *nav_handler = (NavCompletedHandler *)calloc(1, sizeof(*nav_handler));
        if (nav_handler)
        {
            EventRegistrationToken token = {0};
            nav_handler->iface.lpVtbl = &nav_vtbl;
            nav_handler->ref = 1;
            hr = g_webview->lpVtbl->add_NavigationCompleted(g_webview,
                    &nav_handler->iface, &token);
            log_msg("[webview2-test] add_NavigationCompleted: hr=0x%lx token=%lld\n",
                    hr, (long long)token.value);
        }

        hr = g_webview->lpVtbl->Navigate(g_webview, url);
        log_msg("[webview2-test] Navigate: hr=0x%lx (NavigationCompleted should fire if Chromium processes it)\n", hr);
    }
    /* log_msg auto-flushes */

    return S_OK;
}
static const ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl ctrl_vtbl =
{
    ctrl_QueryInterface,
    ctrl_AddRef,
    ctrl_Release,
    ctrl_Invoke,
};

/* ------------------------------------------------------------------ */
/* Environment-completed handler                                      */
/* Called by WV2 once CreateCoreWebView2Environment finishes.         */
/* ------------------------------------------------------------------ */

typedef struct
{
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler iface;
    LONG ref;
} EnvHandler;

static HRESULT STDMETHODCALLTYPE env_QueryInterface(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *iface,
        REFIID iid, void **out)
{
    if (IsEqualIID(iid, &IID_IUnknown)
            || IsEqualIID(iid, &IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler))
    {
        *out = iface;
        iface->lpVtbl->AddRef(iface);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE env_AddRef(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *iface)
{
    EnvHandler *self = (EnvHandler *)iface;
    return InterlockedIncrement(&self->ref);
}
static ULONG STDMETHODCALLTYPE env_Release(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *iface)
{
    EnvHandler *self = (EnvHandler *)iface;
    ULONG r = InterlockedDecrement(&self->ref);
    if (r == 0) free(self);
    return r;
}
static HRESULT STDMETHODCALLTYPE env_Invoke(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *iface,
        HRESULT result, ICoreWebView2Environment *env)
{
    HRESULT hr;
    ControllerHandler *ctrl_handler;

    log_msg("[webview2-test] environment created: hr=0x%lx env=%p\n", result, env);
    /* log_msg auto-flushes */

    if (FAILED(result) || !env) return result;

    ctrl_handler = (ControllerHandler *)calloc(1, sizeof(*ctrl_handler));
    if (!ctrl_handler) return E_OUTOFMEMORY;
    ctrl_handler->iface.lpVtbl = &ctrl_vtbl;
    ctrl_handler->ref = 1;

    hr = env->lpVtbl->CreateCoreWebView2Controller(env, g_main_hwnd,
            &ctrl_handler->iface);
    log_msg("[webview2-test] CreateCoreWebView2Controller: hr=0x%lx\n", hr);
    /* log_msg auto-flushes */
    return hr;
}
static const ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl env_vtbl =
{
    env_QueryInterface,
    env_AddRef,
    env_Release,
    env_Invoke,
};

/* ------------------------------------------------------------------ */
/* WindowProc                                                         */
/* ------------------------------------------------------------------ */

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_SIZE:
        if (g_controller)
        {
            RECT bounds;
            GetClientRect(hwnd, &bounds);
            g_controller->lpVtbl->put_Bounds(g_controller, bounds);
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmdline, int show)
{
    WNDCLASSEXW wc = {0};   /* matches Microsoft sample — full extended class */
    HMODULE loader;
    PFN_CreateCoreWebView2EnvironmentWithOptions pCreateEnv;
    EnvHandler *env_handler;
    HRESULT hr;
    MSG msg;

    log_msg("[webview2-test] starting; pid=%lu\n", GetCurrentProcessId());

    /* Register window class — mirrors HelloWebView.cpp WNDCLASSEX pattern. */
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = wndproc;
    wc.hInstance = hInst;
    wc.hIcon = LoadIconW(hInst, (LPCWSTR)IDI_APPLICATION);
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"fusion-box-webview2-test";
    wc.hIconSm = LoadIconW(hInst, (LPCWSTR)IDI_APPLICATION);
    RegisterClassExW(&wc);

    /* Create WITHOUT WS_VISIBLE; explicit ShowWindow+UpdateWindow afterward
     * to match Microsoft sample order. UpdateWindow forces immediate WM_PAINT,
     * which may be what WebView2 needs to find a "ready" parent window. */
    g_main_hwnd = CreateWindowExW(0, L"fusion-box-webview2-test",
            L"fusion-box WebView2 DComp test",
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT, CW_USEDEFAULT, 1200, 900,
            NULL, NULL, hInst, NULL);
    if (!g_main_hwnd) { log_msg("[webview2-test] CreateWindow failed\n"); return 1; }
    ShowWindow(g_main_hwnd, show);
    UpdateWindow(g_main_hwnd);
    log_msg("[webview2-test] window created hwnd=%p, ShowWindow+UpdateWindow done\n", g_main_hwnd);

    /* Load WebView2Loader.dll */
    loader = LoadLibraryW(L"WebView2Loader.dll");
    if (!loader)
    {
        log_msg("[webview2-test] LoadLibrary(WebView2Loader.dll) failed; err=%lu\n",
                GetLastError());
        return 1;
    }
    log_msg("[webview2-test] WebView2Loader.dll loaded at %p\n", loader);

    pCreateEnv = (PFN_CreateCoreWebView2EnvironmentWithOptions)
            GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions");
    if (!pCreateEnv)
    {
        log_msg("[webview2-test] GetProcAddress failed for CreateCoreWebView2EnvironmentWithOptions\n");
        return 1;
    }
    log_msg("[webview2-test] CreateCoreWebView2EnvironmentWithOptions = %p\n", pCreateEnv);

    /* Build env handler + call WebView2 to create environment.
     * userDataFolder = NULL → use default %LOCALAPPDATA%\<exe>.WebView2\ */
    env_handler = (EnvHandler *)calloc(1, sizeof(*env_handler));
    env_handler->iface.lpVtbl = &env_vtbl;
    env_handler->ref = 1;

    hr = pCreateEnv(NULL, NULL, NULL, &env_handler->iface);
    log_msg("[webview2-test] CreateCoreWebView2EnvironmentWithOptions returned hr=0x%lx (async; handler will be invoked)\n", hr);
    /* log_msg auto-flushes */

    /* Message loop. The env handler fires asynchronously; we need a
     * running pump for COM/RPC callbacks. */
    while (GetMessageW(&msg, NULL, 0, 0))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (g_webview) g_webview->lpVtbl->Release(g_webview);
    if (g_controller) g_controller->lpVtbl->Release(g_controller);
    FreeLibrary(loader);
    return 0;
}
