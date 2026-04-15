#include "App/EngineApp.h"
#include "Platform/Win32/Win32Common.h"

#include <cstdlib>

int main()
{
    HINSTANCE instance = GetModuleHandleW(nullptr);
    if (instance == nullptr)
    {
        return EXIT_FAILURE;
    }

    dx12::EngineApp app;
    if (app.Initialize(instance) == false)
    {
        return EXIT_FAILURE;
    }

    return app.Run();
}

