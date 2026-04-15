#pragma once

#include "Core/NonCopyable.h"
#include "DX12/DX12Common.h"

namespace dx12
{
class DX12Device : private NonCopyable
{
public:
    bool Initialize();

    IDXGIFactory4* GetFactory() const
    {
        return factory_.Get();
    }

    ID3D12Device* GetDevice() const
    {
        return device_.Get();
    }

    ID3D12CommandQueue* GetCommandQueue() const
    {
        return commandQueue_.Get();
    }

private:
    void EnableDebugLayer();
    bool CreateFactory();
    bool SelectAdapter();
    bool CreateDevice();
    bool CreateCommandQueue();

    ComPtr<ID3D12Debug> debugController_;
    ComPtr<IDXGIFactory4> factory_;
    ComPtr<IDXGIAdapter1> adapter_;
    ComPtr<ID3D12Device> device_;
    ComPtr<ID3D12CommandQueue> commandQueue_;
};
}

