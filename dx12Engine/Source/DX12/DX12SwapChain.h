#pragma once

#include "Core/NonCopyable.h"
#include "Core/Types.h"
#include "DX12/DX12Device.h"

namespace dx12
{
class DX12SwapChain : private NonCopyable
{
public:
    bool Initialize(const DX12Device& device, HWND windowHandle, u32 width, u32 height);

    IDXGISwapChain4* GetSwapChain() const
    {
        return swapChain_.Get();
    }

    UINT GetCurrentBackBufferIndex() const
    {
        return currentBackBufferIndex_;
    }

private:
    static constexpr UINT kBackBufferCount = 2;

    ComPtr<IDXGISwapChain4> swapChain_;
    UINT currentBackBufferIndex_ = 0;
};
}

