// 独立冒烟脚本：验证 sr_shim.dll + onnxruntime.dll + 模型全链路（不经 Flutter）。
// 用法: dart run tool/test_sr.dart [--cpu] [--bench] [exeDir]
// 默认在 build/windows/x64/runner/Debug 找 DLL：
//   冒烟模式：对两个模型各跑一次 sr_run，采检角/中心像素并做拼缝差分检查；
//   --bench：拟真页面基准（1536×2048 源，tile 1024 / overlap 16=app 默认）跑 5 次取中位，
//            报告 ms/MP —— 优化前后同口径对比用。
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:wnacg_pc/sr/sr_shim_ffi.dart';

Pointer<Utf16> _toNativeUtf16(String s) {
  final units = s.codeUnits;
  final p = malloc<Uint16>(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    p[i] = units[i];
  }
  p[units.length] = 0;
  return p.cast<Utf16>();
}

void main(List<String> args) {
  final useDml = !args.contains('--cpu');
  final bench = args.contains('--bench');
  final warm = bench ? 5 : 1;
  final exeDir = args.where((a) => !a.startsWith('-')).toList().isEmpty
      ? 'build/windows/x64/runner/Debug'
      : args.where((a) => !a.startsWith('-')).first;
  final shimPath = '$exeDir/sr_shim.dll';
  final ortPath = '$exeDir/onnxruntime.dll';
  if (!File(shimPath).existsSync() || !File(ortPath).existsSync()) {
    stderr.writeln('missing dll: $shimPath / $ortPath');
    exit(2);
  }
  final shim = SrShim.open(shimPath);
  final pOrt = _toNativeUtf16(ortPath);
  final rc = shim.init(pOrt);
  malloc.free(pOrt);
  if (rc != 0) {
    stderr.writeln('sr_init failed: ${shim.lastErrorText}');
    exit(3);
  }
  stdout.writeln('sr_init ok (${useDml ? 'DML' : 'CPU'})');

  final cases = bench
      ? [
          ('anime', 'assets/sr_models/2x_AnimeJaNai_HD_V3.1_Balanced.onnx', 1536, 2048, 1024, 16),
        ]
      : [
          ('anime', 'assets/sr_models/2x_AnimeJaNai_HD_V3.1_Balanced.onnx', 256, 256, 128, 16),
          ('photo', 'assets/sr_models/realesr-general-x4v3.onnx', 128, 192, 64, 16),
        ];
  for (final c in cases) {
    final name = c.$1;
    // tile/ov 在 createSession 之前就绪：作为 warmup 参数（0=不热身）。
    final tile = c.$5, ov = c.$6;
    final model = File(c.$2).readAsBytesSync();
    final pm = malloc<Uint8>(model.length);
    pm.asTypedList(model.length).setAll(0, model);
    final info = malloc<SrSessionInfo>();
    final t0 = DateTime.now();
    // --bench：建会话即热身 interior shape（与 app 内 warm() 同路径，验证预热把
    // plan 编译从首页挪到会话创建时段）；冒烟模式传 0,0 不热身。
    final rc2 =
        shim.createSession(pm, model.length, useDml ? 1 : 0, info, bench ? tile : 0, bench ? ov : 0);
    final loadMs = DateTime.now().difference(t0).inMilliseconds;
    if (rc2 != 0) {
      stderr.writeln('[$name] createSession($useDml) failed: ${shim.lastErrorText}');
      malloc.free(pm);
      malloc.free(info);
      continue;
    }
    final ref = info.ref;
    stdout.writeln(
        '[$name] session ok in ${loadMs}ms: half=${ref.inputIsHalf} scale=${ref.scale} '
        'in="${ref.inputNameStr}" out="${ref.outputNameStr}"');
    // 测试图：斜坡渐变 + 中心十字
    final inW = c.$3, inH = c.$4;
    final scale = ref.scale;
    final rgba = Uint8List(inW * inH * 4);
    for (var y = 0; y < inH; y++) {
      for (var x = 0; x < inW; x++) {
        final i = (y * inW + x) * 4;
        rgba[i] = (x * 255 / (inW - 1)).round();
        rgba[i + 1] = (y * 255 / (inH - 1)).round();
        rgba[i + 2] = ((x - inW ~/ 2).abs() < 2 || (y - inH ~/ 2).abs() < 2) ? 0 : 128;
        rgba[i + 3] = 255;
      }
    }
    final pIn = malloc<Uint8>(rgba.length);
    pIn.asTypedList(rgba.length).setAll(0, rgba);
    final outW = inW * scale, outH = inH * scale;
    final pOut = malloc<Uint8>(outW * outH * 4);
    // bench：跑 warm+1 次，第一次（残余 plan 编译成本少测，热身已在 createSession）只打印不计入，其余取中位。
    final times = <int>[];
    for (var it = 0; it <= warm; it++) {
      final t1 = DateTime.now();
      final rc3 = shim.run(info, inW, inH, pIn, pOut, tile, ov);
      final runMs = DateTime.now().difference(t1).inMilliseconds;
      if (rc3 != 0) {
        stderr.writeln('[$name] sr_run failed: ${shim.lastErrorText}');
        times.clear();
        break;
      }
      if (it == 0) {
        stdout.writeln('[$name] first run (cold) ${runMs}ms');
        if (!bench) _smokeReport(shim, name, pOut, outW, outH, inW, scale);
      }
      times.add(runMs);
    }
    if (times.length > 1) {
      times.removeAt(0); // 去掉冷跑
      times.sort();
      final med = times[times.length ~/ 2];
      final mp = inW * inH / 1e6;
      stdout.writeln('[$name] bench: warm runs=${times.join(',')}ms '
          'median=${med}ms (${(med / mp).toStringAsFixed(0)} ms/MP, ${mp.toStringAsFixed(2)}MP src)');
    }
    shim.releaseSession(info);
    malloc.free(pm);
    malloc.free(info);
    malloc.free(pIn);
    malloc.free(pOut);
  }
  stdout.writeln('done');
}

/// 冒烟采检：角/中心像素 + 拼缝差分检查。
void _smokeReport(SrShim shim, String name, Pointer<Uint8> pOut, int outW, int outH,
    int inW, int scale) {
  final out = pOut.asTypedList(outW * outH * 4);
  String px(int x, int y) =>
      '(${out[(y * outW + x) * 4]},${out[(y * outW + x) * 4 + 1]},${out[(y * outW + x) * 4 + 2]})';
  stdout.writeln('[$name] sr_run ok $outW x $outH, corners ${px(0, 0)} '
      '${px(outW - 1, 0)} ${px(0, outH - 1)} ${px(outW - 1, outH - 1)} '
      'center ${px(outW ~/ 2, outH ~/ 2)}');
  var maxDelta = 0;
  for (var y = 1; y < outH - 1; y++) {
    for (var x = 1; x < outW - 1; x++) {
      for (var ch = 0; ch < 3; ch++) {
        final int v =
            out[(y * outW + x) * 4 + ch].abs() - out[(y * outW + x - 1) * 4 + ch];
        if (v.abs() > maxDelta) maxDelta = v.abs();
      }
    }
  }
  stdout.writeln('[$name] max neighbor delta=$maxDelta (seam artifact if >60)');
}
