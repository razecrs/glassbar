#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <windows.ui.xaml.h>
#include <windows.ui.xaml.media.h>
#include <windows.ui.xaml.shapes.h>

#include <cstdio>
#include <vector>

namespace {

using ABI::Windows::UI::Xaml::IDependencyObject;
using ABI::Windows::UI::Xaml::IFrameworkElement;
using ABI::Windows::UI::Xaml::Media::IBrush;
using ABI::Windows::UI::Xaml::Media::ISolidColorBrush;
using ABI::Windows::UI::Xaml::Media::ISolidColorBrushFactory;
using ABI::Windows::UI::Xaml::Media::IVisualTreeHelperStatics;
using ABI::Windows::UI::Xaml::Shapes::IShape;

// Windows 11 24H2 build 26100.9444, exact values recovered from the live
// taskbar.dll and its matching PDB by Windissect on 2026-09-10.
constexpr DWORD kTaskbarTimestamp = 2378140881u;
constexpr DWORD kTaskbarImageSize = 3162112u;
constexpr DWORD kTrayUiVtableRva = 0x1CAE88u;
constexpr DWORD kTaskbarHostRefcountVtableRva = 0x1C52A0u;
constexpr size_t kTaskbarFrameMemberOffset = 0x10u;

HMODULE g_module;
HWND g_tray;
DWORD g_ui_thread;
UINT g_message;
void *g_root;
HRESULT g_result = E_PENDING;
volatile LONG g_ran;
FILE *g_log;

void log(const wchar_t *format, ...) {
    if (!g_log) return;
    va_list args;
    va_start(args, format);
    vfwprintf(g_log, format, args);
    fputwc(L'\n', g_log);
    fflush(g_log);
    va_end(args);
}

bool read_pointer(const void *address, void **value) {
    __try {
        *value = *reinterpret_cast<void *const *>(address);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool exact_taskbar_build(HMODULE module) {
    auto *base = reinterpret_cast<unsigned char *>(module);
    auto *dos = reinterpret_cast<IMAGE_DOS_HEADER *>(base);
    if (!module || dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    auto *nt = reinterpret_cast<IMAGE_NT_HEADERS *>(base + dos->e_lfanew);
    return nt->Signature == IMAGE_NT_SIGNATURE &&
           nt->FileHeader.TimeDateStamp == kTaskbarTimestamp &&
           nt->OptionalHeader.SizeOfImage == kTaskbarImageSize;
}

HRESULT locate_taskbar_root() {
    HMODULE taskbar = GetModuleHandleW(L"taskbar.dll");
    if (!exact_taskbar_build(taskbar)) return HRESULT_FROM_WIN32(ERROR_REVISION_MISMATCH);

    DWORD pid = 0;
    g_tray = FindWindowW(L"Shell_TrayWnd", nullptr);
    g_ui_thread = g_tray ? GetWindowThreadProcessId(g_tray, &pid) : 0;
    if (!g_tray || !g_ui_thread || pid != GetCurrentProcessId())
        return HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);

    auto *base = reinterpret_cast<unsigned char *>(taskbar);
    auto *dos = reinterpret_cast<IMAGE_DOS_HEADER *>(base);
    auto *nt = reinterpret_cast<IMAGE_NT_HEADERS *>(base + dos->e_lfanew);
    auto *section = IMAGE_FIRST_SECTION(nt);
    void *tray_vtable = base + kTrayUiVtableRva;
    std::vector<void *> tray_objects;

    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++section) {
        if (!(section->Characteristics & IMAGE_SCN_MEM_READ) ||
            !(section->Characteristics & IMAGE_SCN_MEM_WRITE) ||
            (section->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        auto *begin = base + section->VirtualAddress;
        for (size_t offset = 0; offset + sizeof(void *) <= section->Misc.VirtualSize;
             offset += sizeof(void *)) {
            void *object = nullptr;
            void *vtable = nullptr;
            if (read_pointer(begin + offset, &object) && object &&
                read_pointer(object, &vtable) && vtable == tray_vtable) {
                bool duplicate = false;
                for (void *seen : tray_objects) duplicate |= seen == object;
                if (!duplicate) tray_objects.push_back(object);
            }
        }
    }

    void *host_control_block = nullptr;
    void *host_vtable = base + kTaskbarHostRefcountVtableRva;
    for (void *tray_ui : tray_objects) {
        for (size_t offset = 0; offset < 0x800; offset += sizeof(void *)) {
            void *candidate = nullptr;
            void *vtable = nullptr;
            if (read_pointer(static_cast<unsigned char *>(tray_ui) + offset, &candidate) &&
                candidate && read_pointer(candidate, &vtable) && vtable == host_vtable) {
                if (host_control_block && host_control_block != candidate)
                    return HRESULT_FROM_WIN32(ERROR_MORE_DATA);
                host_control_block = candidate;
            }
        }
    }
    if (!host_control_block) return E_NOINTERFACE;

    // std::_Ref_count_obj2 prefix is 0x10 bytes, then TaskbarHost; its verified
    // TaskbarFrame member is another 0x10 bytes into that object on this build.
    auto *host = static_cast<unsigned char *>(host_control_block) + 0x10;
    if (!read_pointer(host + kTaskbarFrameMemberOffset, &g_root) || !g_root)
        return E_UNEXPECTED;
    log(L"TaskbarFrame=%p thread=%lu", g_root, g_ui_thread);
    return S_OK;
}

HRESULT make_transparent_brush(IBrush **result) {
    *result = nullptr;
    HSTRING class_name = nullptr;
    HRESULT hr = WindowsCreateString(L"Windows.UI.Xaml.Media.SolidColorBrush", 37,
                                     &class_name);
    ISolidColorBrushFactory *factory = nullptr;
    if (SUCCEEDED(hr)) {
        hr = RoGetActivationFactory(class_name, IID_PPV_ARGS(&factory));
        WindowsDeleteString(class_name);
    }
    ISolidColorBrush *solid = nullptr;
    if (SUCCEEDED(hr)) {
        ABI::Windows::UI::Color clear{0, 0, 0, 0};
        hr = factory->CreateInstanceWithColor(clear, &solid);
    }
    if (factory) factory->Release();
    if (SUCCEEDED(hr)) hr = solid->QueryInterface(IID_PPV_ARGS(result));
    if (solid) solid->Release();
    return hr;
}

HRESULT find_and_clear(IVisualTreeHelperStatics *tree, IDependencyObject *node,
                       IBrush *transparent, int depth) {
    if (!node || depth > 24) return S_FALSE;

    IFrameworkElement *framework = nullptr;
    if (SUCCEEDED(node->QueryInterface(IID_PPV_ARGS(&framework))) && framework) {
        HSTRING name = nullptr;
        if (SUCCEEDED(framework->get_Name(&name)) && name) {
            UINT32 length = 0;
            const wchar_t *text = WindowsGetStringRawBuffer(name, &length);
            if (length == 14 && wmemcmp(text, L"BackgroundFill", 14) == 0) {
                IShape *shape = nullptr;
                HRESULT hr = node->QueryInterface(IID_PPV_ARGS(&shape));
                if (SUCCEEDED(hr) && shape) {
                    hr = shape->put_Fill(transparent);
                    IBrush *readback = nullptr;
                    if (SUCCEEDED(hr)) hr = shape->get_Fill(&readback);
                    IUnknown *a = nullptr, *b = nullptr;
                    if (SUCCEEDED(hr) && readback) {
                        transparent->QueryInterface(IID_IUnknown, reinterpret_cast<void **>(&a));
                        readback->QueryInterface(IID_IUnknown, reinterpret_cast<void **>(&b));
                        hr = (a && a == b) ? S_OK : E_UNEXPECTED;
                    }
                    if (b) b->Release();
                    if (a) a->Release();
                    if (readback) readback->Release();
                    shape->Release();
                    WindowsDeleteString(name);
                    framework->Release();
                    log(L"BackgroundFill found depth=%d write/readback hr=0x%08lX", depth, hr);
                    return hr;
                }
            }
            WindowsDeleteString(name);
        }
        framework->Release();
    }

    INT32 count = 0;
    HRESULT hr = tree->GetChildrenCount(node, &count);
    if (FAILED(hr)) return hr;
    for (INT32 i = 0; i < count; ++i) {
        IDependencyObject *child = nullptr;
        if (FAILED(tree->GetChild(node, i, &child)) || !child) continue;
        hr = find_and_clear(tree, child, transparent, depth + 1);
        child->Release();
        if (hr == S_OK) return S_OK;
    }
    return S_FALSE;
}

HRESULT apply_on_ui_thread() {
    HRESULT init = RoInitialize(RO_INIT_SINGLETHREADED);
    const bool uninit = SUCCEEDED(init);
    if (FAILED(init) && init != RPC_E_CHANGED_MODE) return init;

    HSTRING class_name = nullptr;
    HRESULT hr = WindowsCreateString(L"Windows.UI.Xaml.Media.VisualTreeHelper", 38,
                                     &class_name);
    IVisualTreeHelperStatics *tree = nullptr;
    if (SUCCEEDED(hr)) {
        hr = RoGetActivationFactory(class_name, IID_PPV_ARGS(&tree));
        WindowsDeleteString(class_name);
    }
    IBrush *transparent = nullptr;
    if (SUCCEEDED(hr)) hr = make_transparent_brush(&transparent);
    IDependencyObject *root = nullptr;
    if (SUCCEEDED(hr))
        hr = static_cast<IUnknown *>(g_root)->QueryInterface(IID_PPV_ARGS(&root));
    if (SUCCEEDED(hr)) hr = find_and_clear(tree, root, transparent, 0);
    if (root) root->Release();
    if (transparent) transparent->Release();
    if (tree) tree->Release();
    if (uninit) RoUninitialize();
    return hr;
}

LRESULT CALLBACK hook_proc(int code, WPARAM wparam, LPARAM lparam) {
    (void)wparam;
    if (code >= 0) {
        auto *message = reinterpret_cast<const CWPSTRUCT *>(lparam);
        if (message && message->message == g_message &&
            InterlockedCompareExchange(&g_ran, 1, 0) == 0) {
            g_result = apply_on_ui_thread();
        }
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
}

HRESULT dispatch() {
    g_message = RegisterWindowMessageW(L"Glassbar.Cpp.Apply.v1");
    HHOOK hook = SetWindowsHookExW(WH_CALLWNDPROC, hook_proc, g_module, g_ui_thread);
    if (!hook) return HRESULT_FROM_WIN32(GetLastError());
    DWORD_PTR ignored = 0;
    LRESULT sent = SendMessageTimeoutW(g_tray, g_message, 0, 0,
        SMTO_ABORTIFHUNG | SMTO_BLOCK, 5000, &ignored);
    UnhookWindowsHookEx(hook);
    if (!sent) return HRESULT_FROM_WIN32(GetLastError());
    return InterlockedCompareExchange(&g_ran, 0, 0) ? g_result : E_UNEXPECTED;
}

DWORD WINAPI worker(void *) {
    wchar_t temp[MAX_PATH]{};
    GetTempPathW(MAX_PATH, temp);
    wcscat_s(temp, L"glassbar-cpp.log");
    _wfopen_s(&g_log, temp, L"w");
    HRESULT hr = locate_taskbar_root();
    if (SUCCEEDED(hr)) hr = dispatch();
    log(L"result=0x%08lX", hr);
    if (g_log) fclose(g_log);
    g_log = nullptr;
    return static_cast<DWORD>(hr);
}

} // namespace

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = instance;
        DisableThreadLibraryCalls(instance);
        HANDLE thread = CreateThread(nullptr, 0, worker, nullptr, 0, nullptr);
        if (thread) CloseHandle(thread);
    }
    return TRUE;
}
