#include <corecrt_wstdio.h>
#pragma comment(lib, "SHELL32.LIB")
#pragma comment(lib, "SHLWAPI.LIB")
#include <windows.h>
#include <shlwapi.h>
#include <stdio.h>

#include <string>
#include <string_view>
#include <tuple>
#include <optional>
#include <memory>
#include <vector>

#ifndef ERROR_ELEVATION_REQUIRED
#define ERROR_ELEVATION_REQUIRED 740
#endif

using namespace std::string_view_literals;

BOOL WINAPI CtrlHandler(DWORD ctrlType)
{
    switch (ctrlType)
    {
    // Ignore all events, and let the child process
    // handle them.
    case CTRL_C_EVENT:
    case CTRL_CLOSE_EVENT:
    case CTRL_LOGOFF_EVENT:
    case CTRL_BREAK_EVENT:
    case CTRL_SHUTDOWN_EVENT:
        return TRUE;

    default:
        return FALSE;
    }
}

struct HandleDeleter
{
    typedef HANDLE pointer;
    void operator() (HANDLE handle)
    {
        if (handle)
        {
            CloseHandle(handle);
        }
    }
};

namespace std
{
    typedef unique_ptr<HANDLE, HandleDeleter> unique_handle;
    typedef optional<wstring> wstring_p;
    typedef std::vector<std::tuple<std::wstring, std::wstring>> wstring_map;
}

struct ShimInfo
{
    std::wstring_p path;
    std::wstring_p args;
    std::wstring_map vars;
};

std::wstring_view GetDirectory(std::wstring_view exe)
{
    auto pos = exe.find_last_of(L"\\/");
    return exe.substr(0, pos);
}

std::wstring_p NormalizeArgs(std::wstring_p& args, std::wstring_view curDir)
{
    static constexpr auto s_dirPlaceHolder = L"%~dp0"sv;
    if (!args)
    {
        return args;
    }

    auto pos = args->find(s_dirPlaceHolder);
    if (pos != std::wstring::npos)
    {
        args->replace(pos, s_dirPlaceHolder.size(), curDir.data(), curDir.size());
    }

    return args;
}

std::wstring GetVariableValue(std::wstring const& name)
{
    wchar_t* buf = nullptr;
    if (_wdupenv_s(&buf, nullptr, name.c_str()) || !buf)
    {
        return L"";
    }

    std::wstring value(buf);
    free(buf);

    return value;
}

std::wstring NormalizeVariable(std::wstring_view var)
{
    static constexpr auto s_startDelim = L"%"sv;
    static constexpr auto s_endDelim = L"%"sv;

    std::wstring str(var);

    for (std::wstring::size_type searchPos = 0; searchPos < str.size();)
    {
        auto startPos = str.find(s_startDelim, searchPos);
        if (startPos == std::wstring::npos || startPos + s_startDelim.size() >= str.size())
        {
            break;
        }

        auto endPos = str.find(s_endDelim, startPos + s_startDelim.size());
        if (endPos == std::wstring::npos)
        {
            break;
        }

        std::wstring name = str.substr(startPos + s_startDelim.size(), endPos - startPos - s_startDelim.size());
        std::wstring value = GetVariableValue(name);
        str.replace(startPos, endPos + s_endDelim.size() - startPos, value);

        searchPos = startPos + value.size();
    }

    return str;
}

ShimInfo GetShimInfo()
{
    // Find filename of current executable.
    wchar_t filename[MAX_PATH + 2];
    const auto filenameSize = GetModuleFileNameW(nullptr, filename, MAX_PATH);

    if (filenameSize >= MAX_PATH)
    {
        fprintf(stderr, "Shim: The filename of the program is too long to handle.\n");
        return {std::nullopt, std::nullopt};
    }

    // Use filename of current executable to find .shim
    wmemcpy(filename + filenameSize - 3, L"shim", 4U);
    filename[filenameSize + 1] = L'\0';
    FILE* fp = nullptr;

    if (_wfopen_s(&fp, filename, L"r,ccs=UTF-8") != 0)
    {
        fprintf(stderr, "Cannot open shim file for read.\n");
        return {std::nullopt, std::nullopt};
    }

    std::unique_ptr<FILE, decltype(&fclose)> shimFile(fp, &fclose);

    // Read shim
    wchar_t linebuf[1<<14];
    std::wstring_p path;
    std::wstring_p args;
    std::wstring_map vars;
    while (true)
    {
        if (!fgetws(linebuf, ARRAYSIZE(linebuf), shimFile.get()))
        {
            break;
        }

        std::wstring_view line(linebuf);

        auto pos = line.find(L" = ");
        if (pos == std::wstring_view::npos)
        {
            continue;
        }

        std::wstring_view name = line.substr(0, pos);
        std::wstring_view value = line.substr(pos + 3, line.size() - pos - 3 - (line.back() == L'\n' ? 1 : 0));

        if (name == L"path")
        {
            if (value.find(L" ") != std::wstring_view::npos && value.front() != L'"')
            {
                path.emplace(L"\"");
                auto& path_value = path.value();
                path_value.append(value);
                path_value.push_back(L'"');
            }
            else
            {
                path.emplace(value);
            }

            continue;
        }

        if (name == L"args")
        {
            args.emplace(value);
            continue;
        }

        if (!name.empty())
        {
            vars.emplace_back(name, NormalizeVariable(value));
            continue;
        }
    }

    return {path, NormalizeArgs(args, GetDirectory(filename)), vars};
}

std::tuple<std::unique_handle, std::unique_handle> MakeProcess(ShimInfo const& info)
{
    // Start subprocess
    STARTUPINFOW si = {};
    PROCESS_INFORMATION pi = {};

    auto&& [path, args, vars] = info;
    std::vector<wchar_t> cmd(path->size() + args->size() + 2);
    wmemcpy(cmd.data(), path->c_str(), path->size());
    cmd[path->size()] = L' ';
    wmemcpy(cmd.data() + path->size() + 1, args->c_str(), args->size());
    cmd[path->size() + 1 + args->size()] = L'\0';

    for (auto& [name, value] : vars)
    {
        if (_wputenv_s(name.c_str(), value.c_str()))
        {
            fprintf(stderr, "Shim: Could not set environment variable '%ls' to '%ls'.\n", name.c_str(), value.c_str());
        }
    }

    std::unique_handle threadHandle;
    std::unique_handle processHandle;

    GetStartupInfoW(&si);

    if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE, CREATE_SUSPENDED, nullptr, nullptr, &si, &pi))
    {
        threadHandle.reset(pi.hThread);
        processHandle.reset(pi.hProcess);

        ResumeThread(threadHandle.get());
    }
    else
    {
        if (GetLastError() == ERROR_ELEVATION_REQUIRED)
        {
            // We must elevate the process, which is (basically) impossible with
            // CreateProcess, and therefore we fallback to ShellExecuteEx,
            // which CAN create elevated processes, at the cost of opening a new separate
            // window.
            // Theorically, this could be fixed (or rather, worked around) using pipes
            // and IPC, but... this is a question for another day.
            SHELLEXECUTEINFOW sei = {};

            sei.cbSize = sizeof(SHELLEXECUTEINFOW);
            sei.fMask = SEE_MASK_NOCLOSEPROCESS;
            sei.lpFile = path->c_str();
            sei.lpParameters = args->c_str();
            sei.nShow = SW_SHOW;

            if (!ShellExecuteExW(&sei))
            {
                fprintf(stderr, "Shim: Unable to create elevated process: error %li.", GetLastError());
                return {std::move(processHandle), std::move(threadHandle)};
            }

            processHandle.reset(sei.hProcess);
        }
        else
        {
            fprintf(stderr, "Shim: Could not create process with command '%ls'.\n", cmd.data());
            return {std::move(processHandle), std::move(threadHandle)};
        }
    }

    // Ignore Ctrl-C and other signals
    if (!SetConsoleCtrlHandler(CtrlHandler, TRUE))
    {
        fprintf(stderr, "Shim: Could not set control handler; Ctrl-C behavior may be invalid.\n");
    }

    return {std::move(processHandle), std::move(threadHandle)};
}

int wmain(int argc, wchar_t* argv[])
{
    auto [path, args, vars] = GetShimInfo();

    if (!path)
    {
        fprintf(stderr, "Could not read shim file.\n");
        return 1;
    }

    if (!args)
    {
        args.emplace();
    }

    auto cmd = GetCommandLineW();
    if (cmd[0] == L'\"')
    {
        args->append(cmd + wcslen(argv[0]) + 2);
    }
    else
    {
        args->append(cmd + wcslen(argv[0]));
    }

    // Find out if the target program is a console app

    wchar_t unquotedPath[MAX_PATH] = {};
    wmemcpy(unquotedPath, path->c_str(), path->length());
    PathUnquoteSpacesW(unquotedPath);
    SHFILEINFOW sfi = {};
    const auto ret = SHGetFileInfoW(unquotedPath, -1, &sfi, sizeof(sfi), SHGFI_EXETYPE);

    if (ret == 0)
    {
        fprintf(stderr, "Shim: Could not determine if target is a GUI app. Assuming console.\n");
    }

    const auto isWindowsApp = HIWORD(ret) != 0;

    if (isWindowsApp)
    {
        // Unfortunately, this technique will still show a window for a fraction of time,
        // but there's just no workaround.
        FreeConsole();
    }

    // Create job object, which can be attached to child processes
    // to make sure they terminate when the parent terminates as well.
    std::unique_handle jobHandle(CreateJobObject(nullptr, nullptr));
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli = {};

    jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
    SetInformationJobObject(jobHandle.get(), JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));

    auto [processHandle, threadHandle] = MakeProcess({path, args, vars});
    if (processHandle && !isWindowsApp)
    {
        AssignProcessToJobObject(jobHandle.get(), processHandle.get());

        // Wait till end of process
        WaitForSingleObject(processHandle.get(), INFINITE);

        DWORD exitCode = 0;
        GetExitCodeProcess(processHandle.get(), &exitCode);

        return exitCode;
    }

    return processHandle ? 0 : 1;
}
