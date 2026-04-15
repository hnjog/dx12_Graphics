#pragma once

#include "Core/NonCopyable.h"
#include "Platform/Win32/Window.h"
#include "Renderer/Renderer.h"

namespace dx12
{
class EngineApp : private NonCopyable
{
public:
    bool Initialize(HINSTANCE instance);
    int Run();

private:
    Window window_;
    Renderer renderer_;
};
}

