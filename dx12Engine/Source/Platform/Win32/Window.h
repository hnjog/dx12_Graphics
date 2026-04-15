#pragma once

#include "Core/NonCopyable.h"
#include "Core/Types.h"
#include "Platform/Win32/Win32Common.h"

namespace dx12
{
class Window : private NonCopyable
{
public:
    bool Initialize(HINSTANCE instance, const wchar_t* title, u32 width, u32 height);
    bool PumpMessages();

    HWND GetHandle() const
    {
        return windowHandle_;
    }

    u32 GetClientWidth() const
    {
        return clientWidth_;
    }

    u32 GetClientHeight() const
    {
        return clientHeight_;
    }

private:
    void RegisterWindowClass(HINSTANCE instance);

    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT HandleMessage(UINT message, WPARAM wParam, LPARAM lParam);

    HWND windowHandle_ = nullptr;
    const wchar_t* windowClassName_ = L"dx12EngineWindowClass";
    u32 clientWidth_ = 0;
    u32 clientHeight_ = 0;
    bool isClassRegistered_ = false;
};
}

