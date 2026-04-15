#pragma once

#include "Core/NonCopyable.h"
#include "Core/Types.h"
#include "DX12/DX12Device.h"
#include "DX12/DX12SwapChain.h"

namespace dx12
{
class Renderer : private NonCopyable
{
public:
    bool Initialize(HWND windowHandle, u32 width, u32 height);
    void Tick();

private:
    DX12Device device_;
    DX12SwapChain swapChain_;
};
}

