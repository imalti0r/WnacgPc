import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'debug/debug_server.dart';
import 'net/download_service.dart';
import 'net/image_bridge.dart';
import 'reader/app_log.dart';
import 'reader/reader_store.dart';
import 'pages/browse_page.dart';
import 'pages/library_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'state/app_store.dart';
import 'state/data_dirs.dart';
import 'sr/sr_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    title: 'WNACG',
    minimumSize: Size(1024, 680),
    size: Size(1440, 900),
    center: true,
  );
  windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  // 数据目录（含旧版下载目录自动并入）先于一切存储初始化
  await DataDirs.instance.init();
  await AppLog.initIn(Directory(DataDirs.instance.root));
  await AppStore.instance.load();
  await DownloadService.instance.load();
  await ReaderStore.instance.load();
  // 神经超分开启时在启动期预热引擎与会话：首次安装后杀软扫描 onnxruntime.dll
  // 可能耗时数十秒，放在阅读器打开时才开始会让首启看起来"加载失败"。
  // 直接 ensureInit 只拉 worker（无会话则面板设备状态一直"不可用"），须 warm 到
  // 会话建好、状态日志/面板设备行就位为止（v1.3.2）。
  if (ReaderStore.instance.settings.fxNeural) {
    unawaited(SrEngine.instance
        .warm(const [SrModel.anime, SrModel.photo])
        .catchError((_) {}));
  }
  // 后台初始化 WebView2 图片桥（不阻塞窗口显示）
  unawaited(ImageBridge.instance.ensureInit().catchError((_) {}));
  // 启动时按设置上限做一次缓存自动清理（后台执行）
  if (AppStore.instance.imageCacheMaxMb > 0) {
    unawaited(ImageBridge.instance
        .enforceCacheLimit(AppStore.instance.imageCacheMaxMb * 1048576)
        .catchError((_) => 0));
  }
  // 本地调试接口（设置内可关）
  if (AppStore.instance.debugEnabled) {
    unawaited(DebugServer.instance
        .start(port: AppStore.instance.debugPort)
        .catchError((_) {}));
  }
  runApp(const WnacgApp());
}

class WnacgApp extends StatelessWidget {
  const WnacgApp({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final scheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFFE91E63),
          brightness: store.darkMode ? Brightness.dark : Brightness.light,
        );
        return MaterialApp(
          title: 'WNACG',
          debugShowCheckedModeBanner: false,
          navigatorKey: DebugServer.navigatorKey,
          themeMode: store.darkMode ? ThemeMode.dark : ThemeMode.light,
          theme: _theme(scheme, Brightness.light),
          darkTheme: _theme(scheme, Brightness.dark),
          home: RepaintBoundary(
            key: DebugServer.screenKey,
            child: const HomeShell(),
          ),
        );
      },
    );
  }

  ThemeData _theme(ColorScheme scheme, Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainer,
      ),
    );
  }
}

/// 主外壳：NavigationRail 导航 + 搜索页切换
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  bool _searching = false;
  bool _extended = false;

  @override
  void initState() {
    super.initState();
    // 注册调试接口钩子：/navigate 切页面，tabGetter 报告当前页面
    DebugServer.navigateHook = (route) {
      if (!mounted) return;
      setState(() {
        switch (route) {
          case '0':
            _index = 0;
            _searching = false;
          case '1':
            _index = 1;
            _searching = false;
          case '2':
            _index = 2;
            _searching = false;
          case '3':
            _searching = true;
        }
      });
    };
    DebugServer.tabGetter = _tabGetter;
    DebugServer.backHook = () async {
      if (!mounted) return false;
      if (_searching) {
        setState(() => _searching = false);
        return true;
      }
      final nav = DebugServer.navigatorKey.currentState;
      if (nav == null) return false;
      return nav.maybePop();
    };
  }

  @override
  void dispose() {
    // 同对象方法 tear-off 判等成立：只有钩子仍是本实例注册的才清理
    if (DebugServer.tabGetter == _tabGetter) {
      DebugServer.navigateHook = null;
      DebugServer.tabGetter = null;
      DebugServer.backHook = null;
    }
    super.dispose();
  }

  int _tabGetter() => _searching ? 3 : _index;

  @override
  Widget build(BuildContext context) {
    final rail = NavigationRail(
      extended: _extended,
      selectedIndex: _index,
      onDestinationSelected: (i) => setState(() {
        _index = i;
        _searching = false;
      }),
      leading: IconButton(
        tooltip: _extended ? '收起导航' : '展开导航',
        icon: Icon(_extended ? Icons.menu_open : Icons.menu),
        onPressed: () => setState(() => _extended = !_extended),
      ),
      destinations: const [
        NavigationRailDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: Text('浏览'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.collections_bookmark_outlined),
          selectedIcon: Icon(Icons.collections_bookmark),
          label: Text('书架'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: Text('设置'),
        ),
      ],
    );

    Widget body;
    if (_searching) {
      body = SearchPage(onBack: () => setState(() => _searching = false));
    } else {
      body = switch (_index) {
        0 => BrowsePage(onOpenSearch: () => setState(() => _searching = true)),
        1 => const LibraryPage(),
        _ => const SettingsPage(),
      };
    }

    return Scaffold(
      body: Row(
        children: [
          SafeArea(child: rail),
          const VerticalDivider(width: 1),
          Expanded(
            child: SafeArea(child: body),
          ),
        ],
      ),
    );
  }
}
