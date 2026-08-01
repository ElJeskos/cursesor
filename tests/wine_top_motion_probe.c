#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE

#include <windows.h>
#include <windowsx.h>

#include <stdarg.h>
#include <stdio.h>

static FILE *g_log_file;
static ULONGLONG g_started_at;

static void log_line(const char *format, ...);

static void log_line(const char *format, ...) {
    va_list arguments;

    va_start(arguments, format);
    vprintf(format, arguments);
    va_end(arguments);
    fflush(stdout);

    if (!g_log_file) {
        return;
    }

    va_start(arguments, format);
    vfprintf(g_log_file, format, arguments);
    va_end(arguments);
    fflush(g_log_file);
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM w_param, LPARAM l_param) {
    (void)w_param;

    switch (message) {
        case WM_CREATE: {
            RAWINPUTDEVICE device = {
                .usUsagePage = 0x01,
                .usUsage = 0x02,
                .dwFlags = RIDEV_INPUTSINK,
                .hwndTarget = window,
            };
            if (!RegisterRawInputDevices(&device, 1, sizeof(device))) {
                log_line("RAW_REGISTER_ERROR code=%lu\n", GetLastError());
            }
            SetCapture(window);
            SetTimer(window, 1, 60000, NULL);
            return 0;
        }
        case WM_MOUSEMOVE: {
            int x = GET_X_LPARAM(l_param);
            int y = GET_Y_LPARAM(l_param);
            log_line("WM_MOUSEMOVE x=%d y=%d\n", x, y);
            return 0;
        }
        case WM_LBUTTONDOWN:
            log_line("WM_LBUTTONDOWN\n");
            return 0;
        case WM_LBUTTONUP: {
            log_line("WM_LBUTTONUP\n");
            POINT cursor;
            if (GetCursorPos(&cursor)) {
                log_line("CLICK_CURSOR_POS x=%ld y=%ld\n", cursor.x, cursor.y);
                if (cursor.y <= 36) {
                    log_line("PROTECTED_TOP_CLICK y=%ld\n", cursor.y);
                }
            }
            return 0;
        }
        case WM_SETCURSOR:
            SetCursor(NULL);
            return TRUE;
        case WM_INPUT: {
            UINT size = 0;
            BYTE buffer[1024];

            if (GetRawInputData((HRAWINPUT)l_param, RID_INPUT, NULL, &size, sizeof(RAWINPUTHEADER)) != 0 ||
                size == 0 ||
                size > sizeof(buffer)) {
                return 0;
            }
            if (GetRawInputData((HRAWINPUT)l_param, RID_INPUT, buffer, &size, sizeof(RAWINPUTHEADER)) != size) {
                return 0;
            }

            RAWINPUT *input = (RAWINPUT *)buffer;
            if (input->header.dwType == RIM_TYPEMOUSE) {
                log_line("WM_INPUT dx=%ld dy=%ld flags=%u\n",
                         input->data.mouse.lLastX,
                         input->data.mouse.lLastY,
                         input->data.mouse.usFlags);
                POINT cursor;
                if ((input->data.mouse.lLastX || input->data.mouse.lLastY) &&
                    GetCursorPos(&cursor)) {
                    int width = GetSystemMetrics(SM_CXSCREEN);
                    int height = GetSystemMetrics(SM_CYSCREEN);
                    BOOL in_bounds = cursor.x >= 0 && cursor.x < width &&
                                     cursor.y >= 0 && cursor.y < height;
                    log_line("CURSOR_POS x=%ld y=%ld in_bounds=%s\n",
                             cursor.x,
                             cursor.y,
                             in_bounds ? "true" : "false");
                }
            }
            return 0;
        }
        case WM_TIMER:
            if (GetTickCount64() - g_started_at >= 60000) {
                DestroyWindow(window);
            }
            return 0;
        case WM_DESTROY:
            ClipCursor(NULL);
            ReleaseCapture();
            PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProcW(window, message, w_param, l_param);
    }
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: wine_top_motion_probe.exe <log-file>\n");
        return 2;
    }

    g_log_file = fopen(argv[1], "w");
    if (!g_log_file) {
        fprintf(stderr, "Unable to open probe log: %s\n", argv[1]);
        return 3;
    }

    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW window_class = {
        .lpfnWndProc = window_proc,
        .hInstance = instance,
        .lpszClassName = L"GcfWineTopMotionProbe",
        .hCursor = NULL,
    };
    if (!RegisterClassW(&window_class)) {
        fprintf(stderr, "RegisterClass failed: %lu\n", GetLastError());
        fclose(g_log_file);
        return 4;
    }

    int screen_width = GetSystemMetrics(SM_CXSCREEN);
    int screen_height = GetSystemMetrics(SM_CYSCREEN);
    HWND window = CreateWindowExW(
        WS_EX_TOPMOST,
        window_class.lpszClassName,
        L"Game Cursor Fence Wine Input Probe",
        WS_POPUP,
        0,
        0,
        screen_width,
        screen_height,
        NULL,
        NULL,
        instance,
        NULL
    );
    if (!window) {
        fprintf(stderr, "CreateWindow failed: %lu\n", GetLastError());
        fclose(g_log_file);
        return 5;
    }

    ShowWindow(window, SW_SHOW);
    SetForegroundWindow(window);
    SetFocus(window);
    while (ShowCursor(FALSE) >= 0) {
    }
    RECT clip_rect = {0};
    if (!GetWindowRect(window, &clip_rect)) {
        log_line("WINDOW_RECT_ERROR code=%lu\n", GetLastError());
        DestroyWindow(window);
        fclose(g_log_file);
        return 6;
    } else {
        clip_rect.top += 36;
    }
    if (!ClipCursor(&clip_rect)) {
        log_line("CLIP_CURSOR_ERROR code=%lu\n", GetLastError());
    }
    g_started_at = GetTickCount64();
    log_line("READY\n");

    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    fclose(g_log_file);
    return 0;
}
