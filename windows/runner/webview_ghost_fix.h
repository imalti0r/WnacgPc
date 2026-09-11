#ifndef RUNNER_WEBVIEW_GHOST_FIX_H_
#define RUNNER_WEBVIEW_GHOST_FIX_H_

// The headless WebView2 image bridge (webview_windows) hosts the browser on
// a message-only window, so Chromium cannot make its widget window a child
// of it and the window ends up as a visible top-level window that sits above
// the desktop and silently swallows mouse clicks. The watcher below
// neutralizes those windows (click-through + bottom z-order) without
// touching visibility, position or size, so WebView2 behavior is unchanged.
void StartWebViewGhostWatcher();

#endif  // RUNNER_WEBVIEW_GHOST_FIX_H_
