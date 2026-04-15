#include "App/EngineApp.h"

#include <iostream>

namespace
{
constexpr dx12::u32 kDefaultWindowWidth = 1280;
constexpr dx12::u32 kDefaultWindowHeight = 720;
constexpr wchar_t kWindowTitle[] = L"dx12Engine";
}

namespace dx12
{
bool EngineApp::Initialize(HINSTANCE instance)
{
    if (window_.Initialize(instance, kWindowTitle, kDefaultWindowWidth, kDefaultWindowHeight) == false)
    {
        return false;
    }

    if (renderer_.Initialize(window_.GetHandle(), window_.GetClientWidth(), window_.GetClientHeight()) == false)
    {
        std::wcerr << L"Renderer initialization failed." << L'\n';
        return false;
    }

    return true;
}

int EngineApp::Run()
{
    while (window_.PumpMessages() == true)
    {
        renderer_.Tick();
        ::Sleep(1);
    }

    return 0;
}
}

