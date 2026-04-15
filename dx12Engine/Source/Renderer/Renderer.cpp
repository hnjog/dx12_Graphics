#include "Renderer/Renderer.h"

#include <iostream>

namespace dx12
{
bool Renderer::Initialize(HWND windowHandle, u32 width, u32 height)
{
    if (device_.Initialize() == false)
    {
        return false;
    }

    if (swapChain_.Initialize(device_, windowHandle, width, height) == false)
    {
        return false;
    }

    std::wcout << L"DX12 device and swap chain initialized successfully." << L'\n';
    return true;
}

void Renderer::Tick()
{
    // Rendering work will be added after the initial DX12 startup milestone.
}
}

