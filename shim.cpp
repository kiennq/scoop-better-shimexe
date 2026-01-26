// SPDX-License-Identifier: MIT
// Optimized shim for scoop - C++20

#ifdef _MSC_VER
#include <corecrt_wstdio.h>
#endif
#pragma comment(lib, "SHELL32.LIB")
#pragma comment(lib, "SHLWAPI.LIB")

#include <windows.h>
#include <shlwapi.h>

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#ifndef ERROR_ELEVATION_REQUIRED
#define ERROR_ELEVATION_REQUIRED 740
#endif

using namespace std::string_view_literals;

// Console control handler - must be a regular function with WINAPI calling convention
BOOL WINAPI CtrlHandler(DWORD /*ctrlType*/) noexcept
{
    // Ignore all signals, let child process handle them
    return TRUE;
}

namespace {

// Compile-time constants
constexpr std::wstring_view c_dirPlaceholder = L"%~dp0"sv;
constexpr std::wstring_view c_pathPrefix = L"path"sv;
constexpr std::wstring_view c_argsPrefix = L"args"sv;
constexpr std::wstring_view c_separator = L" = "sv;
constexpr wchar_t c_envDelim = L'%';

// Environment variable storage
using EnvVarList = std::vector<std::pair<std::wstring, std::wstring>>;

// RAII handle wrapper with minimal overhead
struct HandleDeleter
{
    using pointer = HANDLE;
    void operator()(HANDLE h) const noexcept
    {
        if (h && h != INVALID_HANDLE_VALUE)
        {
            CloseHandle(h);
        }
    }
};
using UniqueHandle = std::unique_ptr<HANDLE, HandleDeleter>;

// RAII file wrapper
struct FileDeleter
{
    void operator()(FILE* fp) const noexcept
    {
        if (fp)
        {
            fclose(fp);
        }
    }
};
using UniqueFile = std::unique_ptr<FILE, FileDeleter>;

struct ShimInfo
{
    std::optional<std::wstring> path;
    std::optional<std::wstring> args;
    EnvVarList envVars;
};

struct ProcessResult
{
    UniqueHandle process;
    UniqueHandle thread;
};

// Fast error output - avoids stdio buffering overhead
inline void WriteError(const char* msg) noexcept
{
    HANDLE hErr = GetStdHandle(STD_ERROR_HANDLE);
    if (hErr != INVALID_HANDLE_VALUE)
    {
        DWORD written;
        WriteFile(hErr, msg, static_cast<DWORD>(strlen(msg)), &written, nullptr);
    }
}

inline void WriteErrorW(const wchar_t* msg) noexcept
{
    HANDLE hErr = GetStdHandle(STD_ERROR_HANDLE);
    if (hErr != INVALID_HANDLE_VALUE)
    {
        DWORD written;
        WriteConsoleW(hErr, msg, static_cast<DWORD>(wcslen(msg)), &written, nullptr);
    }
}

[[nodiscard]] constexpr std::wstring_view GetDirectory(std::wstring_view exe) noexcept
{
    if (auto pos = exe.find_last_of(L"\\/"); pos != std::wstring_view::npos)
    {
        return exe.substr(0, pos);
    }
    return exe;
}

// Trim trailing newline efficiently
[[nodiscard]] constexpr std::wstring_view TrimNewline(std::wstring_view sv) noexcept
{
    if (!sv.empty() && sv.back() == L'\n')
    {
        sv.remove_suffix(1);
    }
    if (!sv.empty() && sv.back() == L'\r')
    {
        sv.remove_suffix(1);
    }
    return sv;
}

void NormalizeArgsInPlace(std::wstring& args, std::wstring_view curDir)
{
    if (auto pos = args.find(c_dirPlaceholder); pos != std::wstring::npos) [[unlikely]]
    {
        args.replace(pos, c_dirPlaceholder.size(), curDir);
    }
}

// Expand %ENV_VAR% references in a string using Windows environment variables
[[nodiscard]] std::wstring ExpandEnvVars(std::wstring_view input)
{
    std::wstring result(input);
    size_t searchPos = 0;

    while (searchPos < result.size())
    {
        auto startPos = result.find(c_envDelim, searchPos);
        if (startPos == std::wstring::npos || startPos + 1 >= result.size())
        {
            break;
        }

        auto endPos = result.find(c_envDelim, startPos + 1);
        if (endPos == std::wstring::npos)
        {
            break;
        }

        // Extract variable name between % delimiters
        std::wstring varName = result.substr(startPos + 1, endPos - startPos - 1);
        if (varName.empty())
        {
            // %% -> skip
            searchPos = endPos + 1;
            continue;
        }

        // Get environment variable value
        wchar_t* envValue = nullptr;
        size_t envLen = 0;
        std::wstring replacement;

        if (_wdupenv_s(&envValue, &envLen, varName.c_str()) == 0 && envValue)
        {
            replacement = envValue;
            free(envValue);
        }
        // If env var not found, leave the placeholder as-is (replacement stays empty means remove it)
        // Actually, we should leave it unchanged if not found for safety
        else
        {
            searchPos = endPos + 1;
            continue;
        }

        result.replace(startPos, endPos - startPos + 1, replacement);
        searchPos = startPos + replacement.size();
    }

    return result;
}

[[nodiscard]] ShimInfo GetShimInfo()
{
    // Get filename of current executable
    std::array<wchar_t, MAX_PATH + 2> filename {};
    const auto filenameSize = GetModuleFileNameW(nullptr, filename.data(), MAX_PATH);

    if (filenameSize >= MAX_PATH) [[unlikely]]
    {
        WriteError("Shim: The filename of the program is too long to handle.\n");
        return {};
    }

    // Replace .exe with .shim
    std::wmemcpy(filename.data() + filenameSize - 3, L"shim", 4);
    filename[filenameSize + 1] = L'\0';

    FILE* fp = nullptr;
    if (_wfopen_s(&fp, filename.data(), L"r,ccs=UTF-8") != 0) [[unlikely]]
    {
        WriteError("Cannot open shim file for read.\n");
        return {};
    }
    UniqueFile shimFile(fp);

    // Parse shim file
    std::array<wchar_t, 1 << 14> linebuf {};
    ShimInfo info;
    const std::wstring_view curDir = GetDirectory({filename.data(), filenameSize});

    while (std::fgetws(linebuf.data(), static_cast<int>(linebuf.size()), shimFile.get()))
    {
        std::wstring_view line(linebuf.data());
        line = TrimNewline(line);

        // Find " = " separator anywhere in the line
        auto sepPos = line.find(c_separator);
        if (sepPos == std::wstring_view::npos) [[unlikely]]
        {
            continue;
        }

        const auto name = line.substr(0, sepPos);
        const auto value = line.substr(sepPos + c_separator.size());

        if (name.empty()) [[unlikely]]
        {
            continue;
        }

        if (name == c_pathPrefix)
        {
            // Expand environment variables in path
            std::wstring expandedPath = ExpandEnvVars(value);

            // Quote path if it contains spaces and isn't already quoted
            if (expandedPath.find(L' ') != std::wstring::npos && (expandedPath.empty() || expandedPath.front() != L'"')) [[unlikely]]
            {
                info.path.emplace();
                auto& path = *info.path;
                path.reserve(expandedPath.size() + 2);
                path = L'"';
                path.append(expandedPath);
                path += L'"';
            }
            else
            {
                info.path = std::move(expandedPath);
            }
        }
        else if (name == c_argsPrefix)
        {
            info.args.emplace(value);
            NormalizeArgsInPlace(*info.args, curDir);
        }
        else
        {
            // Treat as environment variable to set before launching
            info.envVars.emplace_back(std::wstring(name), ExpandEnvVars(value));
        }
    }

    return info;
}

[[nodiscard]] ProcessResult MakeProcess(const ShimInfo& info)
{
    ProcessResult result;

    if (!info.path) [[unlikely]]
    {
        return result;
    }

    // Set environment variables before creating process
    for (const auto& [name, value] : info.envVars)
    {
        if (_wputenv_s(name.c_str(), value.c_str()) != 0) [[unlikely]]
        {
            WriteError("Shim: Could not set environment variable '");
            WriteErrorW(name.c_str());
            WriteError("'.\n");
        }
    }

    const auto& path = *info.path;
    const auto& args = info.args ? *info.args : std::wstring {};

    // Build command line: path + space + args
    std::wstring cmd;
    cmd.reserve(path.size() + 1 + args.size());
    cmd = path;
    cmd += L' ';
    cmd += args;

    STARTUPINFOW si {};
    si.cb = sizeof(si);
    GetStartupInfoW(&si);

    PROCESS_INFORMATION pi {};

    if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE, CREATE_SUSPENDED, nullptr, nullptr, &si, &pi)) [[likely]]
    {
        result.thread.reset(pi.hThread);
        result.process.reset(pi.hProcess);
        ResumeThread(result.thread.get());
    }
    else
    {
        // Handle creation failure
        const DWORD err = GetLastError();
        if (err == ERROR_ELEVATION_REQUIRED)
        {
            // Fallback to ShellExecuteEx for elevation
            SHELLEXECUTEINFOW sei {};
            sei.cbSize = sizeof(sei);
            sei.fMask = SEE_MASK_NOCLOSEPROCESS;
            sei.lpFile = path.c_str();
            sei.lpParameters = args.c_str();
            sei.nShow = SW_SHOW;

            if (!ShellExecuteExW(&sei))
            {
                WriteError("Shim: Unable to create elevated process.\n");
                return result;
            }
            result.process.reset(sei.hProcess);
        }
        else
        {
            WriteError("Shim: Could not create process with command '");
            WriteErrorW(cmd.c_str());
            WriteError("'.\n");
            return result;
        }
    }

    // Ignore Ctrl-C and other signals - let child handle them
    SetConsoleCtrlHandler(CtrlHandler, TRUE);

    return result;
}

} // anonymous namespace

int wmain(int argc, wchar_t* argv[])
{
    auto info = GetShimInfo();

    if (!info.path) [[unlikely]]
    {
        WriteError("Could not read shim file.\n");
        return 1;
    }

    if (!info.args)
    {
        info.args.emplace();
    }

    // Append command line arguments
    const wchar_t* cmd = GetCommandLineW();
    const size_t argv0Len = wcslen(argv[0]);

    if (cmd[0] == L'"')
    {
        info.args->append(cmd + argv0Len + 2);
    }
    else
    {
        info.args->append(cmd + argv0Len);
    }

    // Determine if target is a GUI app
    std::array<wchar_t, MAX_PATH> unquotedPath {};
    const size_t pathLen = (std::min)(info.path->length(), unquotedPath.size() - 1);
    std::wmemcpy(unquotedPath.data(), info.path->c_str(), pathLen);
    unquotedPath[pathLen] = L'\0';
    PathUnquoteSpacesW(unquotedPath.data());

    SHFILEINFOW sfi {};
    const auto exeType = SHGetFileInfoW(unquotedPath.data(), 0, &sfi, sizeof(sfi), SHGFI_EXETYPE);

    if (exeType == 0) [[unlikely]]
    {
        WriteError("Shim: Could not determine if target is a GUI app. Assuming console.\n");
    }

    const bool isWindowsApp = HIWORD(exeType) != 0;
    if (isWindowsApp) [[unlikely]]
    {
        FreeConsole();
    }

    // Create job object to ensure child termination with parent
    UniqueHandle jobHandle(CreateJobObjectW(nullptr, nullptr));
    if (jobHandle) [[likely]]
    {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli {};
        jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        SetInformationJobObject(jobHandle.get(), JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
    }

    auto [processHandle, threadHandle] = MakeProcess(info);

    if (!processHandle) [[unlikely]]
    {
        return 1;
    }

    AssignProcessToJobObject(jobHandle.get(), processHandle.get());
    WaitForSingleObject(processHandle.get(), INFINITE);

    DWORD exitCode = 1;
    GetExitCodeProcess(processHandle.get(), &exitCode);

    return static_cast<int>(exitCode);
}
