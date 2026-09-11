#include "webview_ghost_fix.h"

#include <windows.h>
#include <tlhelp32.h>

#include <chrono>
#include <cwchar>
#include <thread>
#include <utility>
#include <vector>

namespace {

struct GhostSweepContext {
  std::vector<DWORD> browser_pids;
  int fixed_count = 0;
};

std::vector<DWORD> FindWebViewBrowserPids(DWORD parent_pid) {
  std::vector<DWORD> pids;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    return pids;
  }
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (_wcsicmp(entry.szExeFile, L"msedgewebview2.exe") == 0 &&
          entry.th32ParentProcessID == parent_pid) {
        pids.push_back(entry.th32ProcessID);
      }
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return pids;
}

BOOL CALLBACK NeutralizeGhostWindow(HWND hwnd, LPARAM lparam) {
  auto* context = reinterpret_cast<GhostSweepContext*>(lparam);
  if (!IsWindowVisible(hwnd)) {
    return TRUE;
  }
  wchar_t class_name[32] = {};
  if (GetClassNameW(hwnd, class_name, 32) == 0 ||
      wcsncmp(class_name, L"Chrome_WidgetWin", 16) != 0) {
    return TRUE;
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  bool ours = false;
  for (DWORD browser_pid : context->browser_pids) {
    if (browser_pid == pid) {
      ours = true;
      break;
    }
  }
  if (!ours) {
    return TRUE;
  }
  // Click-through; visibility/position/size stay untouched so Chromium's
  // page-visibility logic (and thus the bridge's network stack) is unaffected.
  LONG_PTR ex_style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex_style | WS_EX_TRANSPARENT);
  SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  context->fixed_count++;
  return TRUE;
}

void SweepGhosts() {
  auto browser_pids = FindWebViewBrowserPids(GetCurrentProcessId());
  if (browser_pids.empty()) {
    return;
  }
  GhostSweepContext context{std::move(browser_pids), 0};
  EnumWindows(NeutralizeGhostWindow, reinterpret_cast<LPARAM>(&context));
}

}  // namespace

void StartWebViewGhostWatcher() {
  std::thread([] {
    // The browser process and its ghost window appear asynchronously after
    // the Dart bridge creates the controller; sweep for a while so late
    // creation is covered too.
    for (int sweeps = 0; sweeps < 240; ++sweeps) {
      SweepGhosts();
      std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
  }).detach();
}
