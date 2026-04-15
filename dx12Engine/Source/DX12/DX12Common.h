#pragma once

#include "Platform/Win32/Win32Common.h"

#include <d3d12.h>
#include <dxgi1_6.h>
#include <iostream>
#include <wrl/client.h>

namespace dx12
{
using Microsoft::WRL::ComPtr;

inline void LogHResult(const wchar_t* context, HRESULT hr)
{
    std::wcerr << context << L" failed. HRESULT=0x" << std::hex
               << static_cast<unsigned long>(hr) << std::dec << L'\n';
}
}

