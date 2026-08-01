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
static ULONGLONG g_last_state_log_at;
static POINT g_last_cursor;
static RECT g_last_clip;
static HWND g_last_foreground;
static DWORD g_last_foreground_process_id;
static BOOL g_have_last_state;
static BOOL g_repark_enabled;
static LONG g_repark_trigger_y;
static LONG g_repark_target_y;
static unsigned long g_repark_limit;
static unsigned long g_repark_count;
static BOOL g_repark_armed = TRUE;
static ULONGLONG g_stop_after;
static char g_target_image[MAX_PATH] = "RDR2.exe";

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

static void query_process_image(DWORD process_id, char *buffer, size_t buffer_size) {
    buffer[0] = '\0';
    if (!process_id || buffer_size < 2) {
        return;
    }

    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
    if (!process) {
        return;
    }

    wchar_t wide_path[1024];
    DWORD wide_path_size = (DWORD)(sizeof(wide_path) / sizeof(wide_path[0]));
    if (QueryFullProcessImageNameW(process, 0, wide_path, &wide_path_size)) {
        int converted = WideCharToMultiByte(CP_UTF8,
                                            0,
                                            wide_path,
                                            (int)wide_path_size,
                                            buffer,
                                            (int)buffer_size - 1,
                                            NULL,
                                            NULL);
        if (converted > 0) {
            buffer[converted] = '\0';
        }
    }
    CloseHandle(process);
}

static BOOL is_target_image(const char *image) {
    const char *basename = strrchr(image, '\\');
    basename = basename ? basename + 1 : image;
    return _stricmp(basename, g_target_image) == 0;
}

static void log_cursor_state(BOOL force) {
    POINT cursor = {0};
    RECT clip = {0};
    BOOL has_cursor = GetCursorPos(&cursor);
    BOOL has_clip = GetClipCursor(&clip);
    HWND foreground = GetForegroundWindow();
    DWORD foreground_process_id = 0;
    if (foreground) {
        GetWindowThreadProcessId(foreground, &foreground_process_id);
    }

    ULONGLONG elapsed = GetTickCount64() - g_started_at;
    BOOL changed = !g_have_last_state ||
                   has_cursor == FALSE ||
                   has_clip == FALSE ||
                   cursor.x != g_last_cursor.x ||
                   cursor.y != g_last_cursor.y ||
                   clip.left != g_last_clip.left ||
                   clip.top != g_last_clip.top ||
                   clip.right != g_last_clip.right ||
                   clip.bottom != g_last_clip.bottom ||
                   foreground != g_last_foreground ||
                   foreground_process_id != g_last_foreground_process_id;
    if (!force && !changed && elapsed - g_last_state_log_at < 1000) {
        return;
    }

    char image[4096];
    query_process_image(foreground_process_id, image, sizeof(image));
    log_line("STATE t=%llu cursor=%s x=%ld y=%ld clip=%s left=%ld top=%ld right=%ld bottom=%ld foreground=%p foreground_pid=%lu image=%s\n",
             elapsed,
             has_cursor ? "true" : "false",
             cursor.x,
             cursor.y,
             has_clip ? "true" : "false",
             clip.left,
             clip.top,
             clip.right,
             clip.bottom,
             (void *)foreground,
             foreground_process_id,
             image[0] ? image : "unavailable");

    g_last_cursor = cursor;
    g_last_clip = clip;
    g_last_foreground = foreground;
    g_last_foreground_process_id = foreground_process_id;
    g_last_state_log_at = elapsed;
    g_have_last_state = TRUE;

    if (!g_repark_enabled || !has_cursor || !is_target_image(image)) {
        return;
    }
    if (!g_repark_armed && cursor.y > g_repark_trigger_y + 32) {
        g_repark_armed = TRUE;
    }
    if (!g_repark_armed || g_repark_count >= g_repark_limit || cursor.y > g_repark_trigger_y) {
        return;
    }

    SetLastError(ERROR_SUCCESS);
    BOOL reparked = SetCursorPos(cursor.x, g_repark_target_y);
    DWORD repark_error = GetLastError();
    POINT after = {0};
    BOOL has_after = GetCursorPos(&after);
    g_repark_count++;
    g_repark_armed = FALSE;
    log_line("REPARK t=%llu count=%lu before_x=%ld before_y=%ld target_x=%ld target_y=%ld result=%s error=%lu after=%s after_x=%ld after_y=%ld\n",
             elapsed,
             g_repark_count,
             cursor.x,
             cursor.y,
             cursor.x,
             g_repark_target_y,
             reparked ? "true" : "false",
             repark_error,
             has_after ? "true" : "false",
             after.x,
             after.y);
    if (g_repark_count >= g_repark_limit) {
        g_stop_after = GetTickCount64() + 2000;
    }
}

static LRESULT CALLBACK observer_window_proc(HWND window,
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
            g_started_at = GetTickCount64();
            if (!SetTimer(window, 1, 10, NULL)) {
                log_line("TIMER_ERROR code=%lu\n", GetLastError());
                return -1;
            }
            log_line("READY pid=%lu\n", GetCurrentProcessId());
            log_cursor_state(TRUE);
            return 0;
        }
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
        case WM_TIMER:
            log_cursor_state(FALSE);
            if ((g_stop_after && GetTickCount64() >= g_stop_after) ||
                GetTickCount64() - g_started_at >= g_duration_ms) {
                DestroyWindow(window);
            }
            return 0;
        case WM_DESTROY:
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
    if (!arguments || (argument_count != 3 && argument_count != 6 && argument_count != 7)) {
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
    if (argument_count >= 6) {
        wchar_t *trigger_end = NULL;
        wchar_t *target_end = NULL;
        wchar_t *limit_end = NULL;
        long trigger = wcstol(arguments[3], &trigger_end, 10);
        long target = wcstol(arguments[4], &target_end, 10);
        unsigned long limit = wcstoul(arguments[5], &limit_end, 10);
        if (trigger_end == arguments[3] || *trigger_end != L'\0' ||
            target_end == arguments[4] || *target_end != L'\0' ||
            limit_end == arguments[5] || *limit_end != L'\0' ||
            trigger < 0 || target <= trigger || limit == 0) {
            LocalFree(arguments);
            return 7;
        }
        g_repark_enabled = TRUE;
        g_repark_trigger_y = trigger;
        g_repark_target_y = target;
        g_repark_limit = limit;
        if (argument_count == 7) {
            int converted = WideCharToMultiByte(CP_UTF8,
                                                0,
                                                arguments[6],
                                                -1,
                                                g_target_image,
                                                (int)sizeof(g_target_image),
                                                NULL,
                                                NULL);
            if (converted <= 1) {
                LocalFree(arguments);
                return 8;
            }
        }
    }
    g_log_file = _wfopen(arguments[1], L"w");
    LocalFree(arguments);
    if (!g_log_file) {
        return 4;
    }

    const wchar_t *class_name = L"GcfRawInputObserver";
    WNDCLASSW window_class = {
        .lpfnWndProc = observer_window_proc,
        .hInstance = instance,
        .lpszClassName = class_name,
    };
    if (!RegisterClassW(&window_class)) {
        fclose(g_log_file);
        return 5;
    }

    HWND window = CreateWindowExW(
        WS_EX_NOACTIVATE,
        class_name,
        L"",
        0,
        0,
        0,
        0,
        0,
        HWND_MESSAGE,
        NULL,
        instance,
        NULL);
    if (!window) {
        fclose(g_log_file);
        return 6;
    }

    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    fclose(g_log_file);
    return 0;
}
