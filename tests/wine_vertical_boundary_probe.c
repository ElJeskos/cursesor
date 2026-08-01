#define WIN32_LEAN_AND_MEAN
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <shellapi.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

static FILE *g_log_file;
static ULONGLONG g_started_at;
static ULONGLONG g_duration_ms;
static ULONGLONG g_last_state_at;
static int g_screen_width;
static int g_screen_height;
static int g_window_y;
static int g_start_x;
static int g_start_y;
static int g_clip_mode;
static BOOL g_set_capture;
static RECT g_desired_clip;

static void log_line(const char *format, ...) {
    if (!g_log_file) {
        return;
    }

    va_list arguments;
    va_start(arguments, format);
    vfprintf(g_log_file, format, arguments);
    va_end(arguments);
    fflush(g_log_file);
}

static void log_state(const char *label) {
    POINT cursor = {0};
    RECT clip = {0};
    BOOL has_cursor = GetCursorPos(&cursor);
    BOOL has_clip = GetClipCursor(&clip);
    HWND foreground = GetForegroundWindow();
    DWORD foreground_process_id = 0;
    if (foreground) {
        GetWindowThreadProcessId(foreground, &foreground_process_id);
    }

    log_line("STATE t=%llu label=%s cursor=%s x=%ld y=%ld clip=%s left=%ld top=%ld right=%ld bottom=%ld foreground=%p foreground_pid=%lu\n",
             GetTickCount64() - g_started_at,
             label,
             has_cursor ? "true" : "false",
             cursor.x,
             cursor.y,
             has_clip ? "true" : "false",
             clip.left,
             clip.top,
             clip.right,
             clip.bottom,
             (void *)foreground,
             foreground_process_id);
}

static BOOL apply_desired_clip(const char *label) {
    if (g_clip_mode == 0) {
        return TRUE;
    }

    SetLastError(ERROR_SUCCESS);
    BOOL clipped = ClipCursor(&g_desired_clip);
    log_line("CLIP_APPLY t=%llu label=%s result=%s error=%lu left=%ld top=%ld right=%ld bottom=%ld\n",
             GetTickCount64() - g_started_at,
             label,
             clipped ? "true" : "false",
             GetLastError(),
             g_desired_clip.left,
             g_desired_clip.top,
             g_desired_clip.right,
             g_desired_clip.bottom);
    return clipped;
}

static void position_cursor(const char *label) {
    SetLastError(ERROR_SUCCESS);
    BOOL positioned = SetCursorPos(g_start_x, g_start_y);
    log_line("SET_CURSOR t=%llu label=%s result=%s error=%lu x=%d y=%d\n",
             GetTickCount64() - g_started_at,
             label,
             positioned ? "true" : "false",
             GetLastError(),
             g_start_x,
             g_start_y);
}

static LRESULT CALLBACK probe_window_proc(HWND window,
                                          UINT message,
                                          WPARAM w_param,
                                          LPARAM l_param) {
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
                return -1;
            }
            if (!SetTimer(window, 1, 10, NULL)) {
                log_line("TIMER_ERROR code=%lu\n", GetLastError());
                return -1;
            }
            return 0;
        }
        case WM_ACTIVATE:
            log_line("ACTIVATE t=%llu state=%u\n",
                     GetTickCount64() - g_started_at,
                     LOWORD(w_param));
            if (LOWORD(w_param) != WA_INACTIVE && g_screen_width > 0 && g_screen_height > 0) {
                if (g_set_capture) {
                    SetCapture(window);
                }
                if (!apply_desired_clip("activate")) {
                    log_line("CLIP_ERROR t=%llu label=activate\n",
                             GetTickCount64() - g_started_at);
                }
                position_cursor("activate");
            }
            return 0;
        case WM_SETCURSOR:
            SetCursor(NULL);
            return TRUE;
        case WM_INPUT: {
            UINT size = 0;
            if (GetRawInputData((HRAWINPUT)l_param,
                                RID_INPUT,
                                NULL,
                                &size,
                                sizeof(RAWINPUTHEADER)) != 0 ||
                size == 0) {
                return 0;
            }

            BYTE *buffer = malloc(size);
            if (!buffer) {
                return 0;
            }
            UINT read_size = size;
            if (GetRawInputData((HRAWINPUT)l_param,
                                RID_INPUT,
                                buffer,
                                &read_size,
                                sizeof(RAWINPUTHEADER)) == read_size) {
                RAWINPUT *input = (RAWINPUT *)buffer;
                if (input->header.dwType == RIM_TYPEMOUSE) {
                    POINT cursor = {0};
                    BOOL has_cursor = GetCursorPos(&cursor);
                    log_line("RAW t=%llu dx=%ld dy=%ld flags=%u buttons=%u cursor=%s x=%ld y=%ld\n",
                             GetTickCount64() - g_started_at,
                             input->data.mouse.lLastX,
                             input->data.mouse.lLastY,
                             input->data.mouse.usFlags,
                             input->data.mouse.usButtonFlags,
                             has_cursor ? "true" : "false",
                             cursor.x,
                             cursor.y);
                }
            }
            free(buffer);
            return 0;
        }
        case WM_TIMER: {
            ULONGLONG elapsed = GetTickCount64() - g_started_at;
            if (g_clip_mode == 2) {
                RECT current_clip = {0};
                if (!GetClipCursor(&current_clip) ||
                    current_clip.left != g_desired_clip.left ||
                    current_clip.top != g_desired_clip.top ||
                    current_clip.right != g_desired_clip.right ||
                    current_clip.bottom != g_desired_clip.bottom) {
                    log_state("clip-drift");
                    if (!apply_desired_clip("repair")) {
                        log_line("CLIP_ERROR t=%llu label=repair\n", elapsed);
                    }
                }
            }
            if (elapsed - g_last_state_at >= 1000) {
                log_state("heartbeat");
                g_last_state_at = elapsed;
            }
            if (elapsed >= g_duration_ms) {
                DestroyWindow(window);
            }
            return 0;
        }
        case WM_DESTROY:
            if (g_clip_mode != 0) {
                ClipCursor(NULL);
            }
            if (g_set_capture) {
                ReleaseCapture();
            }
            while (ShowCursor(TRUE) < 0) {
            }
            log_state("destroy");
            PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProcW(window, message, w_param, l_param);
    }
}

int WINAPI wWinMain(HINSTANCE instance,
                    HINSTANCE previous_instance,
                    PWSTR command_line,
                    int show_command) {
    (void)previous_instance;
    (void)command_line;
    (void)show_command;

    int argument_count = 0;
    wchar_t **arguments = CommandLineToArgvW(GetCommandLineW(), &argument_count);
    if (!arguments || argument_count != 8) {
        if (arguments) {
            LocalFree(arguments);
        }
        return 2;
    }

    wchar_t *duration_end = NULL;
    unsigned long duration = wcstoul(arguments[2], &duration_end, 10);
    if (duration_end == arguments[2] || *duration_end != L'\0' || duration < 1000) {
        LocalFree(arguments);
        return 3;
    }
    g_duration_ms = duration;

    wchar_t *window_y_end = NULL;
    wchar_t *clip_top_end = NULL;
    wchar_t *clip_bottom_end = NULL;
    wchar_t *clip_mode_end = NULL;
    wchar_t *capture_end = NULL;
    long window_y = wcstol(arguments[3], &window_y_end, 10);
    long clip_top = wcstol(arguments[4], &clip_top_end, 10);
    long clip_bottom = wcstol(arguments[5], &clip_bottom_end, 10);
    long clip_mode = wcstol(arguments[6], &clip_mode_end, 10);
    long set_capture = wcstol(arguments[7], &capture_end, 10);
    if (window_y_end == arguments[3] || *window_y_end != L'\0' ||
        clip_top_end == arguments[4] || *clip_top_end != L'\0' ||
        clip_bottom_end == arguments[5] || *clip_bottom_end != L'\0' ||
        clip_mode_end == arguments[6] || *clip_mode_end != L'\0' ||
        capture_end == arguments[7] || *capture_end != L'\0' ||
        window_y < -10000 || window_y > 10000 ||
        clip_top < -10000 || clip_top > 10000 ||
        clip_bottom <= clip_top || clip_bottom > 20000 ||
        clip_mode < 0 || clip_mode > 2 ||
        (set_capture != 0 && set_capture != 1)) {
        LocalFree(arguments);
        return 4;
    }
    g_window_y = (int)window_y;
    g_clip_mode = (int)clip_mode;
    g_set_capture = set_capture ? TRUE : FALSE;
    g_desired_clip.left = 0;
    g_desired_clip.top = clip_top;
    g_desired_clip.bottom = clip_bottom;
    g_log_file = _wfopen(arguments[1], L"w");
    LocalFree(arguments);
    if (!g_log_file) {
        return 5;
    }

    const wchar_t *class_name = L"GcfVerticalBoundaryProbe";
    WNDCLASSW window_class = {
        .lpfnWndProc = probe_window_proc,
        .hInstance = instance,
        .lpszClassName = class_name,
    };
    if (!RegisterClassW(&window_class)) {
        fclose(g_log_file);
        return 6;
    }

    int screen_width = GetSystemMetrics(SM_CXSCREEN);
    int screen_height = GetSystemMetrics(SM_CYSCREEN);
    g_screen_width = screen_width;
    g_screen_height = screen_height;
    g_start_x = screen_width / 2;
    g_start_y = screen_height - 64;
    if (g_clip_mode != 0 && g_start_y >= g_desired_clip.bottom) {
        g_start_y = g_desired_clip.bottom - 64;
    }
    if (g_clip_mode != 0 && g_start_y <= g_desired_clip.top) {
        g_start_y = g_desired_clip.top + 64;
    }
    g_desired_clip.right = screen_width;
    HWND window = CreateWindowExW(WS_EX_TOPMOST,
                                  class_name,
                                  L"GCF Autonomous Vertical Boundary Probe",
                                  WS_POPUP,
                                  0,
                                  g_window_y,
                                  screen_width,
                                  screen_height,
                                  NULL,
                                  NULL,
                                  instance,
                                  NULL);
    if (!window) {
        fclose(g_log_file);
        return 7;
    }

    g_started_at = GetTickCount64();
    ShowWindow(window, SW_SHOW);
    SetForegroundWindow(window);
    SetFocus(window);
    if (g_set_capture) {
        SetCapture(window);
    }
    while (ShowCursor(FALSE) >= 0) {
    }

    RECT window_rect = {0};
    if (!GetWindowRect(window, &window_rect)) {
        log_line("WINDOW_RECT_ERROR code=%lu\n", GetLastError());
        DestroyWindow(window);
        fclose(g_log_file);
        return 8;
    }
    log_line("CONFIG window_y=%d clip_mode=%d set_capture=%s desired_left=%ld desired_top=%ld desired_right=%ld desired_bottom=%ld screen_width=%d screen_height=%d\n",
             g_window_y,
             g_clip_mode,
             g_set_capture ? "true" : "false",
             g_desired_clip.left,
             g_desired_clip.top,
             g_desired_clip.right,
             g_desired_clip.bottom,
             screen_width,
             screen_height);
    log_line("WINDOW_RECT left=%ld top=%ld right=%ld bottom=%ld\n",
             window_rect.left,
             window_rect.top,
             window_rect.right,
             window_rect.bottom);
    if (!apply_desired_clip("start")) {
        log_line("CLIP_ERROR t=%llu label=start\n",
                 GetTickCount64() - g_started_at);
        DestroyWindow(window);
        fclose(g_log_file);
        return 9;
    }
    position_cursor("start");
    log_state("ready");
    log_line("READY pid=%lu\n", GetCurrentProcessId());

    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    fclose(g_log_file);
    return 0;
}
