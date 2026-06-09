/* fusion-box: probe what wine reports to Win32 about monitors / display devices.
 * Compiled with winegcc, runs inside the patched wine.
 *
 *   winegcc -m64 probe-displays.c -o probe-displays.exe.so -ldwmapi
 *   wine ./probe-displays.exe.so
 */

#include <windows.h>
#include <shellscalingapi.h>
#include <stdio.h>
#include <wchar.h>

/* GetDpiForMonitor lives in shcore.dll - load dynamically since it's Win 8.1+. */
typedef HRESULT (WINAPI *PFN_GetDpiForMonitor)(HMONITOR, MONITOR_DPI_TYPE, UINT*, UINT*);
static PFN_GetDpiForMonitor pGetDpiForMonitor = NULL;

static const char *dpi_awareness_str(MONITOR_DPI_TYPE t) {
    switch (t) {
        case MDT_EFFECTIVE_DPI: return "effective";
        case MDT_ANGULAR_DPI:   return "angular";
        case MDT_RAW_DPI:       return "raw";
        default:                return "?";
    }
}

static BOOL CALLBACK monitor_cb(HMONITOR hMon, HDC hdc, LPRECT rcClip, LPARAM lparam) {
    int *idx = (int *)lparam;
    MONITORINFOEXW info = { .cbSize = sizeof(info) };

    if (!GetMonitorInfoW(hMon, (MONITORINFO *)&info)) {
        printf("  [Monitor %d] GetMonitorInfoW FAILED\n", *idx);
        (*idx)++;
        return TRUE;
    }

    printf("  [Monitor %d] HMONITOR=%p\n", *idx, hMon);
    wprintf(L"    szDevice:     %ls\n", info.szDevice);
    printf("    rcMonitor:    (%ld,%ld) to (%ld,%ld) - %ldx%ld\n",
        info.rcMonitor.left,
        info.rcMonitor.top,
        info.rcMonitor.right,
        info.rcMonitor.bottom,
        info.rcMonitor.right - info.rcMonitor.left,
        info.rcMonitor.bottom - info.rcMonitor.top
    );
    printf("    rcWork:       (%ld,%ld) to (%ld,%ld)\n",
        info.rcWork.left,
        info.rcWork.top,
        info.rcWork.right,
        info.rcWork.bottom
    );
    printf("    dwFlags:      0x%lx%s\n", info.dwFlags, (info.dwFlags & MONITORINFOF_PRIMARY) ? " PRIMARY" : "");

    /* Per-monitor DPI (Win 8.1+ API) */
    UINT dpiX = 0, dpiY = 0;
    HRESULT hr = pGetDpiForMonitor ? pGetDpiForMonitor(hMon, MDT_EFFECTIVE_DPI, &dpiX, &dpiY) : E_NOTIMPL;
    if (SUCCEEDED(hr)) {
        printf("    DPI effective: %u x %u\n", dpiX, dpiY);
    } else {
        printf("    DPI effective: GetDpiForMonitor failed (0x%lx)\n", hr);
    }

    hr = pGetDpiForMonitor ? pGetDpiForMonitor(hMon, MDT_RAW_DPI, &dpiX, &dpiY) : E_NOTIMPL;
    if (SUCCEEDED(hr)) {
        printf("    DPI raw:       %u x %u\n", dpiX, dpiY);
    } else {
        printf("    DPI raw:       GetDpiForMonitor failed (0x%lx)\n", hr);
    }

    printf("\n");
    (*idx)++;
    return TRUE;
}

int main(void) {
    HMODULE shcore = LoadLibraryA("shcore.dll");
    if (shcore) {
        pGetDpiForMonitor = (PFN_GetDpiForMonitor)GetProcAddress(shcore, "GetDpiForMonitor");
    }
    printf("shcore.dll loaded:   %s\n", shcore ? "yes" : "no");
    printf("GetDpiForMonitor:    %s\n\n", pGetDpiForMonitor ? "available" : "missing");

    printf("======== EnumDisplayDevicesW ========\n");
    DISPLAY_DEVICEW dd = { .cb = sizeof(dd) };
    for (DWORD i = 0; EnumDisplayDevicesW(NULL, i, &dd, EDD_GET_DEVICE_INTERFACE_NAME); i++) {
        wprintf(L"[Adapter %lu]\n", i);
        wprintf(L"  DeviceName:   %ls\n", dd.DeviceName);
        wprintf(L"  DeviceString: %ls\n", dd.DeviceString);
        printf("  StateFlags:   0x%lx%s%s%s\n",
            dd.StateFlags,
            (dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) ? " ATTACHED" : "",
            (dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) ? " PRIMARY" : "",
            (dd.StateFlags & DISPLAY_DEVICE_MIRRORING_DRIVER) ? " MIRROR" : "");

        /* Get current display mode for this adapter */
        DEVMODEW dm = { .dmSize = sizeof(dm) };
        if (EnumDisplaySettingsExW(dd.DeviceName, ENUM_CURRENT_SETTINGS, &dm, 0)) {
            printf("  Current mode:\n");
            printf("    dmPosition:     (%ld, %ld)\n", dm.dmPosition.x, dm.dmPosition.y);
            printf("    dmPelsWidth:    %lu\n", dm.dmPelsWidth);
            printf("    dmPelsHeight:   %lu\n", dm.dmPelsHeight);
            printf("    dmDisplayFreq:  %lu Hz\n", dm.dmDisplayFrequency);
            printf("    dmBitsPerPel:   %lu\n", dm.dmBitsPerPel);
            printf("    dmFields:       0x%lx (DM_POSITION=%s)\n", dm.dmFields, (dm.dmFields & DM_POSITION) ? "yes" : "NO");
        } else {
            printf("  EnumDisplaySettingsExW FAILED for current\n");
        }

        /* Enumerate attached monitors for this adapter */
        DISPLAY_DEVICEW mon = { .cb = sizeof(mon) };
        for (DWORD j = 0; EnumDisplayDevicesW(dd.DeviceName, j, &mon, EDD_GET_DEVICE_INTERFACE_NAME); j++) {
            wprintf(L"  Attached monitor [%lu]: %ls // %ls\n", j, mon.DeviceName, mon.DeviceString);
        }
        printf("\n");
    }

    printf("======== EnumDisplayMonitors ========\n");
    int idx = 0;
    EnumDisplayMonitors(NULL, NULL, monitor_cb, (LPARAM)&idx);

    printf("======== GetSystemMetrics ========\n");
    printf("  SM_CXSCREEN:        %d\n", GetSystemMetrics(SM_CXSCREEN));
    printf("  SM_CYSCREEN:        %d\n", GetSystemMetrics(SM_CYSCREEN));
    printf("  SM_XVIRTUALSCREEN:  %d\n", GetSystemMetrics(SM_XVIRTUALSCREEN));
    printf("  SM_YVIRTUALSCREEN:  %d\n", GetSystemMetrics(SM_YVIRTUALSCREEN));
    printf("  SM_CXVIRTUALSCREEN: %d\n", GetSystemMetrics(SM_CXVIRTUALSCREEN));
    printf("  SM_CYVIRTUALSCREEN: %d\n", GetSystemMetrics(SM_CYVIRTUALSCREEN));
    printf("  SM_CMONITORS:       %d\n", GetSystemMetrics(SM_CMONITORS));

    printf("\n======== DPI (process & system) ========\n");
    printf("  GetDpiForSystem():  %u\n", GetDpiForSystem());
    printf("  Process DPI aware:  %d\n", IsProcessDPIAware());

    return 0;
}
