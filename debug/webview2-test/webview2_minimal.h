/*
 * Minimal subset of WebView2 SDK COM interfaces needed by webview2_host.cpp.
 *
 * Avoids vendoring the full Microsoft WebView2 SDK. Defined inline below
 * with the exact vtable layouts + IIDs as published by Microsoft. If WebView2
 * API ever bumps a minor version that adds methods, this file may need
 * updating — but only the methods we actually call are required to match,
 * since we never IMPLEMENT these interfaces, only call them.
 *
 * Interfaces we DO implement (and need vtable matching exactly):
 *   ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
 *   ICoreWebView2CreateCoreWebView2ControllerCompletedHandler
 *
 * Interfaces we CALL (vtable layout must match through the methods we use):
 *   ICoreWebView2Environment       — CreateCoreWebView2Controller
 *   ICoreWebView2Controller        — put_IsVisible, put_Bounds, get_CoreWebView2
 *   ICoreWebView2                  — Navigate
 */

#ifndef WEBVIEW2_MINIMAL_H
#define WEBVIEW2_MINIMAL_H

#include <windows.h>
#include <unknwn.h>

/* Forward declarations. */
typedef struct ICoreWebView2 ICoreWebView2;
typedef struct ICoreWebView2Controller ICoreWebView2Controller;
typedef struct ICoreWebView2Environment ICoreWebView2Environment;
typedef struct ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler;
typedef struct ICoreWebView2CreateCoreWebView2ControllerCompletedHandler
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler;

/* IIDs. Source: Microsoft.Web.WebView2 SDK, version 1.0.x. */
DEFINE_GUID(IID_ICoreWebView2,
    0x76eceacb, 0x0462, 0x4d94, 0xac, 0x83, 0x42, 0x3a, 0x67, 0x93, 0x77, 0x5e);
DEFINE_GUID(IID_ICoreWebView2Controller,
    0x4d00c0d1, 0x9434, 0x4eb6, 0x80, 0x78, 0x86, 0x97, 0xa5, 0x60, 0x33, 0x4f);
DEFINE_GUID(IID_ICoreWebView2Environment,
    0xb96d755e, 0x0319, 0x4e92, 0xa2, 0x96, 0x23, 0x43, 0x6f, 0x46, 0xa1, 0xfc);
DEFINE_GUID(IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
    0x4e8a3389, 0xc9d8, 0x4bd2, 0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d);
DEFINE_GUID(IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
    0x6c4819f3, 0xc9b7, 0x4260, 0x81, 0x27, 0xc9, 0xf5, 0xbd, 0xe7, 0xf6, 0x8c);
DEFINE_GUID(IID_ICoreWebView2NavigationCompletedEventHandler,
    0xd33a35bf, 0x1c49, 0x4f98, 0x93, 0xab, 0x00, 0x6e, 0x05, 0x33, 0xfe, 0x1c);

/* Event registration token used by add_xxx / remove_xxx event handler pairs. */
typedef struct { INT64 value; } EventRegistrationToken;

/* Forward-decl of args interface — we don't introspect it, just need a
 * pointer-typed signature for the handler's Invoke. */
typedef struct ICoreWebView2NavigationCompletedEventArgs
    ICoreWebView2NavigationCompletedEventArgs;
typedef struct ICoreWebView2NavigationCompletedEventHandler
    ICoreWebView2NavigationCompletedEventHandler;

/* ICoreWebView2 vtable — Navigate + add_NavigationCompleted are needed.
 * Vtable order matches the published WebView2 SDK header (Microsoft.Web.WebView2).
 * Intermediate methods we don't call are kept as `void *` placeholders to
 * preserve vtable indices. */
typedef struct ICoreWebView2Vtbl
{
    /* IUnknown */
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ICoreWebView2 *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(ICoreWebView2 *);
    ULONG (STDMETHODCALLTYPE *Release)(ICoreWebView2 *);
    /* ICoreWebView2 */
    void *get_Settings;                /* slot 3 */
    void *get_Source;                  /* slot 4 */
    HRESULT (STDMETHODCALLTYPE *Navigate)(ICoreWebView2 *, LPCWSTR uri); /* slot 5 */
    void *NavigateToString;            /* slot 6 */
    void *add_NavigationStarting;      /* slot 7 */
    void *remove_NavigationStarting;   /* slot 8 */
    void *add_ContentLoading;          /* slot 9 */
    void *remove_ContentLoading;       /* slot 10 */
    void *add_SourceChanged;           /* slot 11 */
    void *remove_SourceChanged;        /* slot 12 */
    void *add_HistoryChanged;          /* slot 13 */
    void *remove_HistoryChanged;       /* slot 14 */
    /* slot 15 — what we want: fires when navigation completes (success or failure) */
    HRESULT (STDMETHODCALLTYPE *add_NavigationCompleted)(ICoreWebView2 *,
        ICoreWebView2NavigationCompletedEventHandler *, EventRegistrationToken *);
    /* (remaining methods omitted — we don't call them) */
} ICoreWebView2Vtbl;
struct ICoreWebView2 { const ICoreWebView2Vtbl *lpVtbl; };

/* ICoreWebView2Controller vtable — put_IsVisible, put_Bounds, get_CoreWebView2 */
typedef struct ICoreWebView2ControllerVtbl
{
    /* IUnknown */
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ICoreWebView2Controller *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(ICoreWebView2Controller *);
    ULONG (STDMETHODCALLTYPE *Release)(ICoreWebView2Controller *);
    /* ICoreWebView2Controller methods, in SDK order */
    HRESULT (STDMETHODCALLTYPE *get_IsVisible)(ICoreWebView2Controller *, BOOL *);
    HRESULT (STDMETHODCALLTYPE *put_IsVisible)(ICoreWebView2Controller *, BOOL);
    HRESULT (STDMETHODCALLTYPE *get_Bounds)(ICoreWebView2Controller *, RECT *);
    HRESULT (STDMETHODCALLTYPE *put_Bounds)(ICoreWebView2Controller *, RECT);
    HRESULT (STDMETHODCALLTYPE *get_ZoomFactor)(ICoreWebView2Controller *, double *);
    HRESULT (STDMETHODCALLTYPE *put_ZoomFactor)(ICoreWebView2Controller *, double);
    void *add_ZoomFactorChanged;
    void *remove_ZoomFactorChanged;
    HRESULT (STDMETHODCALLTYPE *SetBoundsAndZoomFactor)(ICoreWebView2Controller *, RECT, double);
    HRESULT (STDMETHODCALLTYPE *MoveFocus)(ICoreWebView2Controller *, int reason);
    void *add_MoveFocusRequested;
    void *remove_MoveFocusRequested;
    void *add_GotFocus;
    void *remove_GotFocus;
    void *add_LostFocus;
    void *remove_LostFocus;
    void *add_AcceleratorKeyPressed;
    void *remove_AcceleratorKeyPressed;
    HRESULT (STDMETHODCALLTYPE *get_ParentWindow)(ICoreWebView2Controller *, HWND *);
    HRESULT (STDMETHODCALLTYPE *put_ParentWindow)(ICoreWebView2Controller *, HWND);
    HRESULT (STDMETHODCALLTYPE *NotifyParentWindowPositionChanged)(ICoreWebView2Controller *);
    HRESULT (STDMETHODCALLTYPE *Close)(ICoreWebView2Controller *);
    HRESULT (STDMETHODCALLTYPE *get_CoreWebView2)(ICoreWebView2Controller *, ICoreWebView2 **);
} ICoreWebView2ControllerVtbl;
struct ICoreWebView2Controller { const ICoreWebView2ControllerVtbl *lpVtbl; };

/* ICoreWebView2Environment vtable — CreateCoreWebView2Controller is the only call needed. */
typedef struct ICoreWebView2EnvironmentVtbl
{
    /* IUnknown */
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ICoreWebView2Environment *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(ICoreWebView2Environment *);
    ULONG (STDMETHODCALLTYPE *Release)(ICoreWebView2Environment *);
    /* ICoreWebView2Environment methods, in SDK order */
    HRESULT (STDMETHODCALLTYPE *CreateCoreWebView2Controller)(
        ICoreWebView2Environment *, HWND parentWindow,
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *handler);
    /* (rest omitted) */
} ICoreWebView2EnvironmentVtbl;
struct ICoreWebView2Environment { const ICoreWebView2EnvironmentVtbl *lpVtbl; };

/* Handler vtables — we IMPLEMENT these. */
typedef struct ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl
{
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);
    ULONG (STDMETHODCALLTYPE *Release)(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);
    HRESULT (STDMETHODCALLTYPE *Invoke)(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *,
        HRESULT result, ICoreWebView2Environment *env);
} ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl;
struct ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
{
    const ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl *lpVtbl;
};

typedef struct ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl
{
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *);
    ULONG (STDMETHODCALLTYPE *Release)(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *);
    HRESULT (STDMETHODCALLTYPE *Invoke)(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *,
        HRESULT result, ICoreWebView2Controller *controller);
} ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl;
struct ICoreWebView2CreateCoreWebView2ControllerCompletedHandler
{
    const ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl *lpVtbl;
};

/* NavigationCompleted event handler — fires after Navigate succeeds OR fails.
 * Invoke signature per WebView2 SDK. We don't inspect args; just log that
 * the event fired (proves Chromium got to the "navigation done" point). */
typedef struct ICoreWebView2NavigationCompletedEventHandlerVtbl
{
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(
        ICoreWebView2NavigationCompletedEventHandler *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(
        ICoreWebView2NavigationCompletedEventHandler *);
    ULONG (STDMETHODCALLTYPE *Release)(
        ICoreWebView2NavigationCompletedEventHandler *);
    HRESULT (STDMETHODCALLTYPE *Invoke)(
        ICoreWebView2NavigationCompletedEventHandler *,
        ICoreWebView2 *sender, ICoreWebView2NavigationCompletedEventArgs *args);
} ICoreWebView2NavigationCompletedEventHandlerVtbl;
struct ICoreWebView2NavigationCompletedEventHandler
{
    const ICoreWebView2NavigationCompletedEventHandlerVtbl *lpVtbl;
};

/* Loader DLL entry point. */
typedef HRESULT (STDMETHODCALLTYPE *PFN_CreateCoreWebView2EnvironmentWithOptions)(
    LPCWSTR browserExecutableFolder,
    LPCWSTR userDataFolder,
    IUnknown *environmentOptions,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *handler);

#endif /* WEBVIEW2_MINIMAL_H */
