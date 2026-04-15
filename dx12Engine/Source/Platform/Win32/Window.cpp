#include "Platform/Win32/Window.h"

#include <iostream>

namespace
{
constexpr DWORD kWindowStyle = WS_OVERLAPPEDWINDOW;
}

namespace dx12
{
bool Window::Initialize(HINSTANCE instance, const wchar_t* title, u32 width, u32 height)
{
    clientWidth_ = width;
    clientHeight_ = height;

    RegisterWindowClass(instance);

    RECT windowRect = { 0, 0, static_cast<LONG>(width), static_cast<LONG>(height) };
    AdjustWindowRect(&windowRect, kWindowStyle, FALSE);

    const int windowWidth = windowRect.right - windowRect.left;
    const int windowHeight = windowRect.bottom - windowRect.top;

    windowHandle_ = CreateWindowExW(
        0,
        windowClassName_,
        title,
        kWindowStyle,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        windowWidth,
        windowHeight,
        nullptr,
        nullptr,
        instance,
        this);

    if (windowHandle_ == nullptr)
    {
        std::wcerr << L"Failed to create the Win32 window." << L'\n';
        return false;
    }

    ShowWindow(windowHandle_, SW_SHOWDEFAULT);
    UpdateWindow(windowHandle_);

    return true;
}

bool Window::PumpMessages()
{
    MSG message = {};

    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE) != FALSE)
    {
        if (message.message == WM_QUIT)
        {
            return false;
        }

        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    return true;
}

void Window::RegisterWindowClass(HINSTANCE instance)
{
    if (isClassRegistered_ == true)
    {
        return;
    }

    WNDCLASSEXW windowClass = {};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.lpfnWndProc = &Window::WindowProc;
    windowClass.hInstance = instance;
    windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.lpszClassName = windowClassName_;
    windowClass.style = CS_HREDRAW | CS_VREDRAW;

    const ATOM result = RegisterClassExW(&windowClass);
    if ((result == 0) && (GetLastError() != ERROR_CLASS_ALREADY_EXISTS))
    {
        std::wcerr << L"Failed to register the Win32 window class." << L'\n';
        return;
    }

    isClassRegistered_ = true;
}

LRESULT CALLBACK Window::WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam)
{
    if (message == WM_NCCREATE)
    {
        auto* createStruct = reinterpret_cast<CREATESTRUCTW*>(lParam);
        auto* window = static_cast<Window*>(createStruct->lpCreateParams);

        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(window));
        window->windowHandle_ = hwnd;
    }

    auto* window = reinterpret_cast<Window*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (window != nullptr)
    {
        return window->HandleMessage(message, wParam, lParam);
    }

    return DefWindowProcW(hwnd, message, wParam, lParam);
}

LRESULT Window::HandleMessage(UINT message, WPARAM wParam, LPARAM lParam)
{
    switch (message)
    {
    case WM_SIZE:
        clientWidth_ = static_cast<u32>(LOWORD(lParam));
        clientHeight_ = static_cast<u32>(HIWORD(lParam));
        return 0;

    case WM_CLOSE:
        DestroyWindow(windowHandle_);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;

    default:
        break;
    }

    return DefWindowProcW(windowHandle_, message, wParam, lParam);
}
}

