// 独立冒烟脚本：验证 sr_shim.dll + onnxruntime.dll + 模型全链路（不经 Flutter）。
// 用法: dart run tool/test_sr.dart [--cpu] [exeDir]
// 默认在 build/windows/x64/runner/Debug 找 DLL，对两个模型各跑一次 sr_run 并报告耗时。
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
  stdout.writeln('sr_init ok');

  final cases = [
    ('anime', 'assets/sr_models/2x_AnimeJaNai_HD_V3.1_Balanced.onnx', 256, 256, 128, 16),
    ('photo', 'assets/sr_models/realesr-general-x4v3.onnx', 128, 192, 64, 16),
  ];
  for (final c in cases) {
    final name = c.$1;
    final model = File(c.$2).readAsBytesSync();
    final pm = malloc<Uint8>(model.length);
    pm.asTypedList(model.length).setAll(0, model);
    final info = malloc<SrSessionInfo>();
    final t0 = DateTime.now();
    final rc2 = shim.createSession(pm, model.length, useDml ? 1 : 0, info);
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
    final inW = c.$3, inH = c.$4, tile = c.$5, ov = c.$6;
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
    final t1 = DateTime.now();
    final rc3 = shim.run(info, inW, inH, pIn, pOut, tile, ov);
    final runMs = DateTime.now().difference(t1).inMilliseconds;
    if (rc3 != 0) {
      stderr.writeln('[$name] sr_run failed: ${shim.lastErrorText}');
    } else {
      final out = pOut.asTypedList(outW * outH * 4);
      // 采样：角、中心
      String px(int x, int y) =>
          '(${out[(y * outW + x) * 4]},${out[(y * outW + x) * 4 + 1]},${out[(y * outW + x) * 4 + 2]})';
      stdout.writeln('[$name] sr_run ok ${runMs}ms $inW x $inH -> $outW x $outH, '
          'corners ${px(0, 0)} ${px(outW - 1, 0)} ${px(0, outH - 1)} ${px(outW - 1, outH - 1)} '
          'center ${px(outW ~/ 2, outH ~/ 2)}');
      // 拼缝检查：同输入 tile 整图单跑 vs 分块跑，求最大差
      if (inW <= 256 && inH <= 256) {
        final pOut2 = malloc<Uint8>(outW * outH * 4);
        final t2 = DateTime.now();
        final rc4 = shim.run(info, inW, inH, pIn, pOut2, (inW + inH), 0);
        final singleMs = DateTime.now().difference(t2).inMilliseconds;
        if (rc4 == 0) {
          final out2 = pOut2.asTypedList(outW * outH * 4);
          var maxDiff = 0, sumDiff = 0;
          for (var i = 0; i < out2.length; i++) {
            final d = (out[i] - out2[i]).abs();
            if (d > maxDiff) maxDiff = d;
            sumDiff += d;
          }
          stdout.writeln('[$name] seam check: single-pass ${singleMs}ms, '
              'maxDiff=$maxDiff avgDiff=${(sumDiff / out2.length).toStringAsFixed(2)}');
        }
        malloc.free(pOut2);
      }
      // 拼缝检查：tile 边界附近应有平滑过渡（相邻像素差 < 40）
      var maxDelta = 0;
      for (var y = 1; y < outH - 1; y++) {
        for (var x = 1; x < outW - 1; x++) {
          for (var ch = 0; ch < 3; ch++) {
            final v = out[(y * outW + x) * 4 + ch].abs() - out[(y * outW + x - 1) * 4 + ch];
            if (v.abs() > maxDelta) maxDelta = v.abs();
          }
        }
      }
      stdout.writeln('[$name] max neighbor delta=$maxDelta (seam artifact if >60)');
    }
    shim.releaseSession(info);
    malloc.free(pm);
    malloc.free(info);
    malloc.free(pIn);
    malloc.free(pOut);
  }
  stdout.writeln('done');
}
