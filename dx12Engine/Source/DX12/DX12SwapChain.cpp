#include "DX12/DX12SwapChain.h"

namespace dx12
{
bool DX12SwapChain::Initialize(const DX12Device& device, HWND windowHandle, u32 width, u32 height)
{
    DXGI_SWAP_CHAIN_DESC1 swapChainDesc = {};
    swapChainDesc.Width = width;
    swapChainDesc.Height = height;
    swapChainDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swapChainDesc.Stereo = FALSE;
    swapChainDesc.SampleDesc.Count = 1;
    swapChainDesc.SampleDesc.Quality = 0;
    swapChainDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swapChainDesc.BufferCount = kBackBufferCount;
    swapChainDesc.Scaling = DXGI_SCALING_STRETCH;
    swapChainDesc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    swapChainDesc.AlphaMode = DXGI_ALPHA_MODE_UNSPECIFIED;
    swapChainDesc.Flags = 0;

    ComPtr<IDXGISwapChain1> swapChain1;
    const HRESULT createResult = device.GetFactory()->CreateSwapChainForHwnd(
        device.GetCommandQueue(),
        windowHandle,
        &swapChainDesc,
        nullptr,
        nullptr,
        swapChain1.ReleaseAndGetAddressOf());
    if (FAILED(createResult))
    {
        LogHResult(L"IDXGIFactory4::CreateSwapChainForHwnd", createResult);
        return false;
    }

    const HRESULT associationResult = device.GetFactory()->MakeWindowAssociation(windowHandle, DXGI_MWA_NO_ALT_ENTER);
    if (FAILED(associationResult))
    {
        LogHResult(L"IDXGIFactory4::MakeWindowAssociation", associationResult);
        return false;
    }

    const HRESULT castResult = swapChain1.As(&swapChain_);
    if (FAILED(castResult))
    {
        LogHResult(L"IDXGISwapChain1::As<IDXGISwapChain4>", castResult);
        return false;
    }

    currentBackBufferIndex_ = swapChain_->GetCurrentBackBufferIndex();
    return true;
}
}

