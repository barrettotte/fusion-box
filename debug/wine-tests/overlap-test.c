/* fusion-box: minimal Vulkan reproducer for winewayland.drv bugs that hit
 * Autodesk Fusion 360 (and any Qt-QStackedWidget-style Win32 app).
 *
 * What this app simulates:
 *   - 5 same-size overlapping child Win32 windows (WS_CHILD | WS_VISIBLE),
 *     each with its own Vulkan swapchain. Mirrors Fusion's 6 overlapping
 *     Qt683QWindowIcon children (Splash, Sign-in WebView, Home tab,
 *     Data Panel WebView, 3D viewport, Comments WebView) - each backed
 *     by its own DXVK swapchain -> wayland_client_surface.
 *   - 1 bottom toolbar (WS_POPUP + WS_EX_TOOLWINDOW). Mirrors Fusion's
 *     `Qt683QWindowToolSaveBits` bottom playback bar.
 *   - 1 on-demand popup menu (WS_POPUP). Mirrors Fusion's CREATE dropdown.
 *
 * Each rendering path is what Fusion uses; matching wine code paths get
 * exercised - no Fusion install, no Qt, no DXVK app, no Chromium required.
 *
 * Build:
 *   winegcc -m64 -mwindows overlap-test.c -lvulkan-1 -o overlap-test.exe.so
 * Run (must force winewayland.drv - wine defaults to winex11.drv on KDE):
 *   WINEDLLOVERRIDES="winewayland.drv=b;winex11.drv=;bcp47langs=" \
 *     WAYLAND_DEBUG=client wine ./overlap-test.exe.so 2>trace.log
 *
 * Keys:
 *   1-5      Bring overlap child N to top of Win32 Z-order (SetWindowPos HWND_TOP)
 *   h        Hide topmost overlap child (ShowWindow SW_HIDE)
 *   s        Show all overlap children
 *   d        Destroy topmost overlap child (DestroyWindow)
 *   r        Force re-render (re-present) each child's swapchain
 *   m        Open a popup menu (WS_POPUP, WS_EX_TOPMOST) near top-left
 *   t        Toggle bottom toolbar (WS_POPUP, WS_EX_TOOLWINDOW)
 *   q / ESC  Quit
 *
 * ============================================================================
 * TEST CASES & WHAT EACH REPRODUCES
 * ============================================================================
 *
 * Test 1 - Subsurface stack churn on focus events (FIXED by patch 0002)
 *   Bug:  On every xdg_toplevel.configure event (focus change, resize),
 *         wayland_surface_reconfigure_client calls wl_subsurface_place_above
 *         for each child subsurface in iteration order. Last caller takes
 *         the "immediately above ref" slot, pushing prior callers UP the
 *         stack - so the FIRST-iterated subsurface ends up topmost. With 5
 *         overlapping children, the first-created (Splash in Fusion) is
 *         shown on every focus event instead of the user-intended one.
 *   Repro: Step 0: open. Step 1: click window. Step 2: press 5 (3D Viewport
 *         to top). Step 3: click off window (lose focus). Step 4: click
 *         back (regain focus). On vanilla wine: step 2 shows magenta when
 *         focused, reverts to red on unfocus. With patch: stays magenta
 *         through focus changes.
 *   Validation: trace shows ZERO place_above calls after fix vs hundreds
 *         before. See `wine-patches/0002-*.patch`.
 *
 * Test 2 - Win32 SetWindowPos(HWND_TOP) z-order propagation (NOT FIXED)
 *   Bug:  After patch 0002 removes place_above thrash, Win32 z-order
 *         changes via SetWindowPos no longer reach the wayland subsurface
 *         stack. For Fusion-style apps where z-order is established once
 *         at init and rarely changes dynamically, this is acceptable; for
 *         apps that DO swap "active page" via z-order, broken.
 *   Repro: Press 1-5 - color should change to that child's color. On
 *         vanilla wine: changes briefly when focused, reverts on unfocus
 *         (same as Test 1). With patch 0002: stays at last-created child's
 *         color regardless of which 1-5 you press.
 *   Fix direction: walk Win32 GW_HWNDPREV chain on SWP_NOZORDER-cleared
 *         WindowPosChanged events, emit explicit place_above/below calls
 *         to match Win32 z-order. Complex; not yet implemented.
 *
 * Test 3 - WS_POPUP positioning (NOT FIXED - needs xdg_popup support)
 *   Bug:  Wine creates an xdg_toplevel for WS_POPUP windows. xdg_toplevel
 *         has NO client-side positioning - the compositor chooses where
 *         to place it. For popup menus that need to appear at a specific
 *         screen position (CREATE dropdown next to a toolbar button,
 *         tooltip at cursor, bottom toolbar at parent's bottom edge), the
 *         placement is arbitrary. Reproduces Fusion's CREATE-dropdown-
 *         halfway-across-screen, tooltips-at-random-positions, and
 *         bottom-toolbar-on-wrong-monitor symptoms.
 *   Repro: Press T - bottom toolbar appears somewhere random (often on a
 *         different monitor on multi-monitor setups). Press M - popup
 *         menu appears centered-ish in the main window, NOT at the
 *         top-left (160, 200) the code requested.
 *   Fix direction: implement xdg_popup + xdg_positioner for WS_POPUP
 *         windows with explicit positions. Major patch - wine currently
 *         has zero xdg_popup support. Requires xdg_wm_base.create_popup,
 *         positioner anchor/gravity/offset construction, popup_done
 *         event handling.
 *
 * Test 4 - wayland_client_surface destroy+recreate churn (FIXED by 0003)
 *   Bug:  wayland_client_surface_attach used to destroy the wl_subsurface
 *         on every transient attach(NULL) call (which fires on focus
 *         events, configure events, every reattach cycle). Each recreate
 *         puts the new subsurface at TOP of parent's substack. Caused
 *         additional z-order shuffling on top of Test 1's churn.
 *   Repro: Trace shows 25+ ATTACH(NULL) calls per focus event in vanilla.
 *         With fix: 0 destroys, subsurfaces persist their entire life.
 *   See `wine-patches/0003-*.patch`.
 *
 * Test 5 - Bottom toolbar visibility regression after patch 0002 (KNOWN)
 *   Bug:  Patch 0002 removes place_above on every reconfigure. This means
 *         subsurfaces stay in WAYLAND-CREATION-ORDER (last-created = top).
 *         For widgets that should be on top BY DESIGN even though they
 *         were created early (e.g. a bottom toolbar created before all
 *         the content children), this leaves them buried.
 *   Repro: Press T to toggle bottom toolbar - it MAY be missing
 *         entirely if its creation order put it at the bottom of the
 *         wayland stack and another opaque sibling covers it.
 *   Fix direction: needs Test 2's Win32-z-order tracking, OR the toolbar
 *         needs to be its own xdg_popup (Test 3 fix).
 *
 * ============================================================================
 * What this app does NOT reproduce
 * ============================================================================
 *   - Browser dock undock-on-click: that's likely a Qt-side bug (or a
 *     drag-threshold misinterpretation), not directly testable here.
 *   - Click hit-test off by one row in dock trees: Qt-internal, not
 *     reproducible without a real Qt widget tree.
 *   - Resolution-dependent ribbon click dead zones: likely DPI/scale
 *     handling, not subsurface-related.
 *   - Sign-in race: fixed separately via `scripts/launch-fusion.sh`
 *     prewarm; unrelated to wine source.
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>
#define VK_USE_PLATFORM_WIN32_KHR
#include <vulkan/vulkan.h>

#define N_OVERLAP 5
#define MAIN_W   800
#define MAIN_H   600
#define OVERLAP_INSET 40

static HWND main_hwnd;
static HWND overlap_hwnds[N_OVERLAP];
static HWND toolbar_hwnd;
static HWND popup_hwnd;

/* Vulkan globals */
static VkInstance       g_instance       = VK_NULL_HANDLE;
static VkPhysicalDevice g_phys           = VK_NULL_HANDLE;
static VkDevice         g_dev            = VK_NULL_HANDLE;
static VkQueue          g_queue          = VK_NULL_HANDLE;
static uint32_t         g_queue_family   = 0;
static VkCommandPool    g_cmd_pool       = VK_NULL_HANDLE;

/* Per-child Vulkan state */
typedef struct {
    VkSurfaceKHR   surface;
    VkSwapchainKHR swapchain;
    VkFormat       format;
    VkExtent2D     extent;
    uint32_t       n_images;
    VkImage        images[8];
    VkCommandBuffer cmds[8];
    VkSemaphore    acquire_sem;
    VkSemaphore    present_sem;
} ChildVk;
static ChildVk overlap_vk[N_OVERLAP];

static const float overlap_colors[N_OVERLAP][4] = {
    {0.86f, 0.24f, 0.24f, 1.0f},   /* red    - "Splash" */
    {0.24f, 0.78f, 0.24f, 1.0f},   /* green  - "Sign-in" */
    {0.24f, 0.47f, 0.94f, 1.0f},   /* blue   - "Home" */
    {0.94f, 0.86f, 0.24f, 1.0f},   /* yellow - "Data Panel" */
    {0.78f, 0.24f, 0.78f, 1.0f},   /* magenta - "3D Viewport" */
};
static const char *overlap_labels[N_OVERLAP] = {
    "Splash (1)", "Sign-in (2)", "Home (3)", "Data Panel (4)", "3D Viewport (5)"
};

#define VK_CHECK(call) do { \
    VkResult __r = (call); \
    if (__r != VK_SUCCESS) { \
        fprintf(stderr, "[overlap-test] Vulkan: %s failed: %d\n", #call, __r); \
        return -1; \
    } \
} while (0)

static int init_vulkan(HINSTANCE hi) {
    const char *ext[] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WIN32_SURFACE_EXTENSION_NAME };
    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "overlap-test",
        .applicationVersion = 1,
        .pEngineName = "fusion-box",
        .engineVersion = 1,
        .apiVersion = VK_API_VERSION_1_0,
    };
    VkInstanceCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
        .enabledExtensionCount = 2,
        .ppEnabledExtensionNames = ext,
    };
    VK_CHECK(vkCreateInstance(&ici, NULL, &g_instance));

    uint32_t n = 0;
    VK_CHECK(vkEnumeratePhysicalDevices(g_instance, &n, NULL));
    if (n == 0) {
        fprintf(stderr, "[overlap-test] no Vulkan physical devices\n");
        return -1;
    }
    VkPhysicalDevice phys[8] = {0};
    if (n > 8) {
        n = 8;
    }
    VK_CHECK(vkEnumeratePhysicalDevices(g_instance, &n, phys));

    /* Prefer NVIDIA (0x10de) since fusion-box's display is NVIDIA-driven.
     * If none found, prefer DISCRETE over INTEGRATED. Fallback to first. */
    fprintf(stderr, "[overlap-test] available GPUs:\n");
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(phys[i], &p);
        fprintf(stderr, "  [%u] vendor=%#x device=%#x type=%d name=%s\n",
            i, p.vendorID, p.deviceID, p.deviceType, p.deviceName);
        if (p.vendorID == 0x10de && !g_phys) {
            g_phys = phys[i];
        }
    }
    if (!g_phys) {
        for (uint32_t i = 0; i < n; i++) {
            VkPhysicalDeviceProperties p;
            vkGetPhysicalDeviceProperties(phys[i], &p);
            if (p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                g_phys = phys[i];
                break;
            }
        }
    }
    if (!g_phys) {
        g_phys = phys[0];
    }

    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(g_phys, &props);
    fprintf(stderr, "[overlap-test] picked GPU: %s (vendor %#x)\n", props.deviceName, props.vendorID);

    /* Find a graphics+win32-present queue family */
    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(g_phys, &nq, NULL);
    VkQueueFamilyProperties qf[8] = {0};
    if (nq > 8) {
        nq = 8;
    }
    vkGetPhysicalDeviceQueueFamilyProperties(g_phys, &nq, qf);
    int picked = -1;
    for (uint32_t i = 0; i < nq; i++) {
        if ((qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && vkGetPhysicalDeviceWin32PresentationSupportKHR(g_phys, i)) {
            picked = (int)i;
            break;
        }
    }
    if (picked < 0) {
        fprintf(stderr, "[overlap-test] no graphics+present queue\n");
        return -1;
    }
    g_queue_family = (uint32_t)picked;

    const char *devext[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = g_queue_family, .queueCount = 1, .pQueuePriorities = &prio,
    };
    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
        .enabledExtensionCount = 1, .ppEnabledExtensionNames = devext,
    };
    VK_CHECK(vkCreateDevice(g_phys, &dci, NULL, &g_dev));
    vkGetDeviceQueue(g_dev, g_queue_family, 0, &g_queue);

    VkCommandPoolCreateInfo cpci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = g_queue_family,
    };
    VK_CHECK(vkCreateCommandPool(g_dev, &cpci, NULL, &g_cmd_pool));
    return 0;
}

static int child_vk_setup(int idx, HINSTANCE hi, HWND hwnd) {
    ChildVk *cv = &overlap_vk[idx];
    if (cv->swapchain) {
        return 0; /* already set up */
    }

    VkWin32SurfaceCreateInfoKHR sci = {
        .sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
        .hinstance = hi, .hwnd = hwnd,
    };
    VK_CHECK(vkCreateWin32SurfaceKHR(g_instance, &sci, NULL, &cv->surface));
    fprintf(stderr, "[overlap-test] child %d (hwnd=%p): VkSurface=%p\n", idx, hwnd, (void *)cv->surface);

    VkBool32 supported = VK_FALSE;
    vkGetPhysicalDeviceSurfaceSupportKHR(g_phys, g_queue_family, cv->surface, &supported);
    if (!supported) {
        fprintf(stderr, "[overlap-test] child %d surface unsupported\n", idx);
        return -1;
    }

    VkSurfaceCapabilitiesKHR caps;
    VK_CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(g_phys, cv->surface, &caps));

    uint32_t nf = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(g_phys, cv->surface, &nf, NULL);
    VkSurfaceFormatKHR fmts[16] = {0};
    if (nf > 16) {
        nf = 16;
    }
    vkGetPhysicalDeviceSurfaceFormatsKHR(g_phys, cv->surface, &nf, fmts);
    cv->format = (fmts[0].format == VK_FORMAT_UNDEFINED) ? VK_FORMAT_B8G8R8A8_UNORM : fmts[0].format;
    cv->extent = caps.currentExtent.width != 0xFFFFFFFFu ? caps.currentExtent : (VkExtent2D){.width = 256, .height = 256};

    VkSwapchainCreateInfoKHR scci = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = cv->surface,
        .minImageCount = caps.minImageCount,
        .imageFormat = cv->format,
        .imageColorSpace = fmts[0].colorSpace,
        .imageExtent = cv->extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
    };
    VK_CHECK(vkCreateSwapchainKHR(g_dev, &scci, NULL, &cv->swapchain));

    vkGetSwapchainImagesKHR(g_dev, cv->swapchain, &cv->n_images, NULL);
    if (cv->n_images > 8) {
        cv->n_images = 8;
    }
    vkGetSwapchainImagesKHR(g_dev, cv->swapchain, &cv->n_images, cv->images);

    VkCommandBufferAllocateInfo cbai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = g_cmd_pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = cv->n_images,
    };
    VK_CHECK(vkAllocateCommandBuffers(g_dev, &cbai, cv->cmds));

    VkSemaphoreCreateInfo si = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VK_CHECK(vkCreateSemaphore(g_dev, &si, NULL, &cv->acquire_sem));
    VK_CHECK(vkCreateSemaphore(g_dev, &si, NULL, &cv->present_sem));

    fprintf(stderr, "[overlap-test] child %d swapchain ready: %u images %ux%u fmt=%d\n",
        idx, cv->n_images, cv->extent.width, cv->extent.height, cv->format);
    return 0;
}

static void child_vk_render(int idx) {
    ChildVk *cv = &overlap_vk[idx];
    if (!cv->swapchain) {
        return;
    }

    uint32_t img_idx = 0;
    VkResult r = vkAcquireNextImageKHR(g_dev, cv->swapchain, UINT64_MAX, cv->acquire_sem, VK_NULL_HANDLE, &img_idx);
    if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR) {
        fprintf(stderr, "[overlap-test] child %d acquire failed: %d\n", idx, r);
        return;
    }

    VkCommandBuffer cmd = cv->cmds[img_idx];
    vkResetCommandBuffer(cmd, 0);
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    vkBeginCommandBuffer(cmd, &bi);

    VkImageMemoryBarrier to_dst = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = 0, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = cv->images[img_idx],
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &to_dst);

    VkClearColorValue cc = {.float32 = {overlap_colors[idx][0], overlap_colors[idx][1], overlap_colors[idx][2], overlap_colors[idx][3]}};
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdClearColorImage(cmd, cv->images[img_idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &cc, 1, &range);

    VkImageMemoryBarrier to_present = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = 0,
        .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = cv->images[img_idx],
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &to_present);

    vkEndCommandBuffer(cmd);

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1, .pWaitSemaphores = &cv->acquire_sem, .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1, .pCommandBuffers = &cmd,
        .signalSemaphoreCount = 1, .pSignalSemaphores = &cv->present_sem,
    };
    vkQueueSubmit(g_queue, 1, &submit, VK_NULL_HANDLE);

    VkPresentInfoKHR pi = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1, .pWaitSemaphores = &cv->present_sem,
        .swapchainCount = 1, .pSwapchains = &cv->swapchain, .pImageIndices = &img_idx,
    };
    vkQueuePresentKHR(g_queue, &pi);
    vkQueueWaitIdle(g_queue);
}

static void child_vk_teardown(int idx) {
    ChildVk *cv = &overlap_vk[idx];
    if (cv->swapchain) {
        vkDeviceWaitIdle(g_dev);
        vkDestroySemaphore(g_dev, cv->acquire_sem, NULL);
        vkDestroySemaphore(g_dev, cv->present_sem, NULL);
        vkFreeCommandBuffers(g_dev, g_cmd_pool, cv->n_images, cv->cmds);
        vkDestroySwapchainKHR(g_dev, cv->swapchain, NULL);
        vkDestroySurfaceKHR(g_instance, cv->surface, NULL);
        memset(cv, 0, sizeof(*cv));
    }
}

static LRESULT CALLBACK overlap_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    /* If this is WM_CREATE, lpParam (CREATESTRUCT.lpCreateParams) carries our child index.
     * Store it before any other message fires. Must happen here because WS_VISIBLE causes WM_SHOWWINDOW to
     * fire DURING CreateWindowExA, which is before the caller can SetWindowLongPtr after the call returns. */
    if (msg == WM_CREATE) {
        CREATESTRUCTA *cs = (CREATESTRUCTA *)lp;
        SetWindowLongPtrA(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
        return 0;
    }

    int idx = (int)(LONG_PTR)GetWindowLongPtrA(hwnd, GWLP_USERDATA);
    HINSTANCE hi = (HINSTANCE)GetWindowLongPtrA(hwnd, GWLP_HINSTANCE);

    switch (msg) {
        case WM_SHOWWINDOW:
            if (wp && !overlap_vk[idx].swapchain) {
                if (child_vk_setup(idx, hi, hwnd) == 0) child_vk_render(idx);
            }
            return 0;
        case WM_PAINT: {
            PAINTSTRUCT ps;
            BeginPaint(hwnd, &ps);
            EndPaint(hwnd, &ps);
            child_vk_render(idx);
            return 0;
        }
        case WM_ERASEBKGND:
            return 1;
        case WM_DESTROY:
            child_vk_teardown(idx);
            return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static LRESULT CALLBACK toolbar_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hwnd, &ps);
            RECT r; GetClientRect(hwnd, &r);
            HBRUSH brush = CreateSolidBrush(RGB(40,40,40));

            FillRect(hdc, &r, brush);
            DeleteObject(brush);
            SetBkMode(hdc, TRANSPARENT);
            SetTextColor(hdc, RGB(255,255,255));

            const char *t = "BOTTOM TOOLBAR (GDI)";
            TextOutA(hdc, 8, 6, t, (int)strlen(t));
            EndPaint(hwnd, &ps);
            return 0;
        }
        case WM_ERASEBKGND:
            return 1;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static void log_zorder(void) {
    HWND h = GetWindow(main_hwnd, GW_CHILD);
    fprintf(stderr, "[overlap-test] Win32 z-order (top -> bottom):\n");
    int i = 0;
    while (h) {
        BOOL vis = IsWindowVisible(h);
        char buf[64];

        GetWindowTextA(h, buf, sizeof(buf));
        fprintf(stderr, "  [%d] hwnd=%p visible=%d text='%s'\n", i, h, vis, buf);
        h = GetWindow(h, GW_HWNDNEXT);

        ++;
        if (i > 50) {
            break;
        }
    }
}

static LRESULT CALLBACK main_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hwnd, &ps);
            RECT r; GetClientRect(hwnd, &r);
            HBRUSH brush = CreateSolidBrush(RGB(255,255,255));

            FillRect(hdc, &r, brush);
            DeleteObject(brush);
            EndPaint(hwnd, &ps);
            return 0;
        }
        case WM_KEYDOWN:
            if (wp >= '1' && wp <= '0' + N_OVERLAP) {
                int idx = (int)(wp - '1');
                HWND target = overlap_hwnds[idx];
                if (target) {
                    fprintf(stderr, "[overlap-test] BringWindowToTop(%p) [%s]\n", target, overlap_labels[idx]);
                    SetWindowPos(target, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                    log_zorder();
                }
            }
            else if (wp == 'H' || wp == 'h') {
                HWND top = GetWindow(hwnd, GW_CHILD);
                if (top && top != toolbar_hwnd) {
                    fprintf(stderr, "[overlap-test] ShowWindow(%p, SW_HIDE)\n", top);
                    ShowWindow(top, SW_HIDE);
                    log_zorder();
                }
            }
            else if (wp == 'S' || wp == 's') {
                for (int i = 0; i < N_OVERLAP; i++) {
                    if (overlap_hwnds[i]) {
                        ShowWindow(overlap_hwnds[i], SW_SHOW);
                    }
                }
                fprintf(stderr, "[overlap-test] All overlap children SW_SHOWn\n");
                log_zorder();
            }
            else if (wp == 'D' || wp == 'd') {
                HWND top = GetWindow(hwnd, GW_CHILD);
                if (top && top != toolbar_hwnd) {
                    fprintf(stderr, "[overlap-test] DestroyWindow(%p)\n", top);
                    DestroyWindow(top);
                    for (int i = 0; i < N_OVERLAP; i++) {
                        if (overlap_hwnds[i] == top) {
                            overlap_hwnds[i] = NULL;
                            break;
                        }
                    }
                    log_zorder();
                }
            }
            else if (wp == 'R' || wp == 'r') {
                fprintf(stderr, "[overlap-test] Force-render all children\n");
                for (int i = 0; i < N_OVERLAP; i++) {
                    if (overlap_hwnds[i]) {
                        child_vk_render(i);
                    }
                }
            }
            else if (wp == 'M' || wp == 'm') {
                /* CREATE-dropdown-style popup. WS_EX_NOACTIVATE so the main window keeps keyboard focus
                 * (matches Fusion's QMenu / tooltip behavior; without it, SW_SHOW on popup activates it and steals input). */
                if (popup_hwnd) {
                    DestroyWindow(popup_hwnd);
                }
                RECT main_rect; GetWindowRect(hwnd, &main_rect);
                int px = main_rect.left + 60;
                int py = main_rect.top + 100;
                popup_hwnd = CreateWindowExA(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
                    "OverlapTestToolbar", "POPUP MENU",
                    WS_POPUP | WS_VISIBLE | WS_BORDER,
                    px, py, 180, 240,
                    hwnd, NULL, (HINSTANCE)GetWindowLongPtrA(hwnd, GWLP_HINSTANCE), NULL);
                fprintf(stderr, "[overlap-test] Opened popup at screen (%d,%d) hwnd=%p\n", px, py, popup_hwnd);
            }
            else if (wp == 'T' || wp == 't') {
                if (toolbar_hwnd) {
                    BOOL was_vis = IsWindowVisible(toolbar_hwnd);
                    /* SW_SHOWNA = show without activate; matches Fusion-style tool windows that
                     * must not steal keyboard focus from main. */
                    ShowWindow(toolbar_hwnd, was_vis ? SW_HIDE : SW_SHOWNA);
                    fprintf(stderr, "[overlap-test] Toolbar visible: %d -> %d\n", was_vis, !was_vis);
                }
            }
            else if (wp == 'Q' || wp == 'q' || wp == VK_ESCAPE) {
                PostQuitMessage(0);
            }
            return 0;
        case WM_CLOSE:
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

int WINAPI WinMain(HINSTANCE hi, HINSTANCE hp, LPSTR cmd, int show) {
    if (init_vulkan(hi) != 0) {
        fprintf(stderr, "[overlap-test] Vulkan init failed; aborting\n");
        return 1;
    }

    WNDCLASSA wc = {0};
    wc.lpfnWndProc   = main_proc;
    wc.hInstance     = hi;
    wc.hCursor       = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.lpszClassName = "OverlapTestMain";
    RegisterClassA(&wc);

    wc.lpfnWndProc   = overlap_proc;
    wc.lpszClassName = "OverlapTestChild";
    RegisterClassA(&wc);

    wc.lpfnWndProc   = toolbar_proc;
    wc.lpszClassName = "OverlapTestToolbar";
    RegisterClassA(&wc);

    main_hwnd = CreateWindowExA(0, "OverlapTestMain", "Overlap Test Main (per-child Vulkan)",
        WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
        100, 100, MAIN_W, MAIN_H, NULL, NULL, hi, NULL);

    for (int i = 0; i < N_OVERLAP; i++) {
        overlap_hwnds[i] = CreateWindowExA(0, "OverlapTestChild", overlap_labels[i],
            WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
            OVERLAP_INSET, OVERLAP_INSET,
            MAIN_W - 2*OVERLAP_INSET, MAIN_H - 2*OVERLAP_INSET - 40,
            main_hwnd, NULL, hi, (LPVOID)(LONG_PTR)i);   /* pass i as lpParam */
        fprintf(stderr, "[overlap-test] Created overlap child %d: hwnd=%p\n", i, overlap_hwnds[i]);
    }

    /* Bottom toolbar - match Fusion's style: WS_POPUP + WS_EX_TOOLWINDOW.
     * Fusion's bottom toolbar has class 'Qt683QWindowToolSaveBits' style 0x96000000
     * (WS_POPUP|WS_VISIBLE|WS_CLIPSIBLINGS|WS_CLIPCHILDREN) + exstyle 0x80 (WS_EX_TOOLWINDOW).
     *
     * This is what makes it a different code path than the WS_CHILD overlapping siblings - and why removing
     * place_above in reconfigure_client (which fixes the splash bug) also hides this toolbar. */
    toolbar_hwnd = CreateWindowExA(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        "OverlapTestToolbar", "Bottom Toolbar",
        WS_POPUP | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
        100 + OVERLAP_INSET, 100 + MAIN_H - 60, 200, 25,
        main_hwnd, NULL, hi, NULL);
    fprintf(stderr, "[overlap-test] Created bottom toolbar (WS_POPUP) hwnd=%p\n", toolbar_hwnd);

    ShowWindow(main_hwnd, SW_SHOW);
    UpdateWindow(main_hwnd);
    for (int i = 0; i < N_OVERLAP; i++) {
        if (overlap_hwnds[i]) {
            UpdateWindow(overlap_hwnds[i]);
        }
    }

    fprintf(stderr, "[overlap-test] Initial z-order:\n");
    log_zorder();
    fprintf(stderr, "[overlap-test] Keys: 1-5=bring to top, H=hide top, S=show all, D=destroy top, R=force render, Q=quit\n");

    MSG msg;
    while (GetMessageA(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }

    for (int i = 0; i < N_OVERLAP; i++) {
        child_vk_teardown(i);
    }

    if (g_cmd_pool) {
        vkDestroyCommandPool(g_dev, g_cmd_pool, NULL);
    }
    if (g_dev) {
        vkDestroyDevice(g_dev, NULL);
    }
    if (g_instance) {
        vkDestroyInstance(g_instance, NULL);
    }
    return 0;
}
