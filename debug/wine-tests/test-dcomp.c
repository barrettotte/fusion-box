/* Minimal test: invoke DCompositionCreateDevice directly via LoadLibrary.
 *
 * Confirms our D-0 logging stub fires when called. Build:
 *   winegcc -m64 -mconsole -o test-dcomp.exe test-dcomp.c
 * Run:
 *   wine test-dcomp.exe
 *
 * If this works but Edge's DComp calls don't show in normal trace,
 * the issue is Edge's behavior (not loading dcomp.dll OR not calling
 * DComp), not our stub.
 */

#include <windows.h>
#include <unknwn.h>
#include <stdio.h>

typedef HRESULT (WINAPI *pDCompositionCreateDevice)(IUnknown *dxgi_device, REFIID iid, void **device);

/* IDCompositionDevice IID from dcomp.idl */
static const GUID IID_IDCompositionDevice =
    { 0xc37ea93a, 0xe7aa, 0x450d, { 0xb1, 0x6f, 0x97, 0x46, 0xcb, 0x04, 0x07, 0xf3 } };

int main(void)
{
    HMODULE dcomp;
    pDCompositionCreateDevice create_device;
    void *device = NULL;
    HRESULT hr;

    printf("[test-dcomp] LoadLibrary(dcomp.dll)\n"); fflush(stdout);
    dcomp = LoadLibraryA("dcomp.dll");
    if (!dcomp)
    {
        printf("[test-dcomp] LoadLibrary failed, GetLastError=%lu\n", GetLastError());
        return 1;
    }
    printf("[test-dcomp] dcomp.dll loaded at %p\n", dcomp); fflush(stdout);

    create_device = (pDCompositionCreateDevice)GetProcAddress(dcomp, "DCompositionCreateDevice");
    if (!create_device)
    {
        printf("[test-dcomp] GetProcAddress(DCompositionCreateDevice) failed\n");
        return 1;
    }
    printf("[test-dcomp] DCompositionCreateDevice = %p\n", create_device); fflush(stdout);

    printf("[test-dcomp] calling DCompositionCreateDevice(NULL, IID_IDCompositionDevice, &device)\n");
    fflush(stdout);

    hr = create_device(NULL, &IID_IDCompositionDevice, &device);

    printf("[test-dcomp] returned hr=0x%lx device=%p\n", hr, device);
    fflush(stdout);

    if (SUCCEEDED(hr) && device)
    {
        IUnknown *unk = (IUnknown *)device;
        ULONG rc = unk->lpVtbl->Release(unk);
        printf("[test-dcomp] released, refcount=%lu\n", rc);
    }

    return 0;
}
