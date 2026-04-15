#include "DX12/DX12Device.h"

namespace dx12
{
bool DX12Device::Initialize()
{
    EnableDebugLayer();

    return CreateFactory() && SelectAdapter() && CreateDevice() && CreateCommandQueue();
}

void DX12Device::EnableDebugLayer()
{
#if defined(_DEBUG)
    const HRESULT hr = D3D12GetDebugInterface(IID_PPV_ARGS(debugController_.ReleaseAndGetAddressOf()));
    if (SUCCEEDED(hr))
    {
        debugController_->EnableDebugLayer();
    }
    else
    {
        LogHResult(L"D3D12GetDebugInterface", hr);
    }
#endif
}

bool DX12Device::CreateFactory()
{
    UINT factoryFlags = 0;

#if defined(_DEBUG)
    if (debugController_ != nullptr)
    {
        factoryFlags |= DXGI_CREATE_FACTORY_DEBUG;
    }
#endif

    const HRESULT hr = CreateDXGIFactory2(factoryFlags, IID_PPV_ARGS(factory_.ReleaseAndGetAddressOf()));
    if (FAILED(hr))
    {
        LogHResult(L"CreateDXGIFactory2", hr);
        return false;
    }

    return true;
}

bool DX12Device::SelectAdapter()
{
    for (UINT adapterIndex = 0;; ++adapterIndex)
    {
        ComPtr<IDXGIAdapter1> candidateAdapter;
        const HRESULT enumResult = factory_->EnumAdapters1(adapterIndex, candidateAdapter.ReleaseAndGetAddressOf());
        if (enumResult == DXGI_ERROR_NOT_FOUND)
        {
            break;
        }

        if (FAILED(enumResult))
        {
            LogHResult(L"IDXGIFactory4::EnumAdapters1", enumResult);
            return false;
        }

        DXGI_ADAPTER_DESC1 adapterDesc = {};
        candidateAdapter->GetDesc1(&adapterDesc);

        if ((adapterDesc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0)
        {
            continue;
        }

        const HRESULT testResult =
            D3D12CreateDevice(candidateAdapter.Get(), D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), nullptr);
        if (SUCCEEDED(testResult))
        {
            adapter_ = candidateAdapter;
            return true;
        }
    }

    ComPtr<IDXGIAdapter> warpAdapter;
    const HRESULT warpResult = factory_->EnumWarpAdapter(IID_PPV_ARGS(warpAdapter.ReleaseAndGetAddressOf()));
    if (FAILED(warpResult))
    {
        LogHResult(L"IDXGIFactory4::EnumWarpAdapter", warpResult);
        return false;
    }

    const HRESULT asResult = warpAdapter.As(&adapter_);
    if (FAILED(asResult))
    {
        LogHResult(L"IDXGIAdapter::As<IDXGIAdapter1>", asResult);
        return false;
    }

    return true;
}

bool DX12Device::CreateDevice()
{
    const HRESULT hr =
        D3D12CreateDevice(adapter_.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(device_.ReleaseAndGetAddressOf()));
    if (FAILED(hr))
    {
        LogHResult(L"D3D12CreateDevice", hr);
        return false;
    }

    return true;
}

bool DX12Device::CreateCommandQueue()
{
    D3D12_COMMAND_QUEUE_DESC queueDesc = {};
    queueDesc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    queueDesc.Priority = D3D12_COMMAND_QUEUE_PRIORITY_NORMAL;
    queueDesc.Flags = D3D12_COMMAND_QUEUE_FLAG_NONE;
    queueDesc.NodeMask = 0;

    const HRESULT hr = device_->CreateCommandQueue(&queueDesc, IID_PPV_ARGS(commandQueue_.ReleaseAndGetAddressOf()));
    if (FAILED(hr))
    {
        LogHResult(L"ID3D12Device::CreateCommandQueue", hr);
        return false;
    }

    return true;
}
}

