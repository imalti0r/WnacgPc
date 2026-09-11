// 画质增强（FX）参数面板：神经超分 + FSR 超分 + 照片超分 + Anime4K 线条增强，滑杆实时生效。
// 阅读器底部弹层与设置页共用；仅负责 UI，参数写入由调用方处理。
// FSR 与照片超分同为上采样（引擎内互斥、photo 优先），开关联动：开启一方自动关闭另一方。
// 神经超分独立于二者：就绪页自动替代放大着色器，未就绪页仍走现有着色器（渐进替换）。
import 'package:flutter/material.dart';

import 'fx_engine.dart';
import '../sr/sr_engine.dart';

class FxPanel extends StatelessWidget {
  const FxPanel({
    super.key,
    required this.params,
    required this.onChanged,
    this.srDevice,
  });

  final FxParams params;
  final ValueChanged<FxParams> onChanged;

  /// 神经超分引擎当前状态（DirectML/CPU/不可用），用于状态行展示。
  final SrDevice? srDevice;

  void _set(FxParams p) => onChanged(p);

  String get _srStatusText {
    final engine = SrEngine.instance;
    final d = srDevice ?? engine.device;
    if (d == SrDevice.unavailable) {
      if (!engine.initialized) return '推理引擎初始化中…';
      return '推理引擎不可用${engine.initError == null ? '' : '（${engine.initError}）'}，保持现有着色器效果';
    }
    if (d == SrDevice.cpu) return '推理设备：CPU（较慢，首次打开每页需数秒）';
    return '推理设备：GPU (DirectML)';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---------- 神经超分（ONNX，实验） ----------
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('神经超分（实验）'),
          subtitle: const Text('ONNX 模型推理（动漫/写真自动选模型），就绪后自动替代放大着色器；首次使用需初始化引擎'),
          value: params.neural,
          onChanged: (v) => _set(params.copyWith(neural: v)),
        ),
        if (params.neural) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(
                  (srDevice ?? SrEngine.instance.device) == SrDevice.unavailable
                      ? Icons.warning_amber_rounded
                      : Icons.memory,
                  size: 16,
                  color: cs.outline,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _srStatusText,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.outline),
                  ),
                ),
              ],
            ),
          ),
          // ---------- 神经超分可调参数（模型为 2x/4x 同栈：1.0=模型原生倍率，>1 允许拿更多细节，上限 12MP） ----------
          _slider(
            label: '超分倍率',
            value: params.neuralScale,
            min: 0.5,
            max: 2.0,
            valueText: '${params.neuralScale.toStringAsFixed(1)}x',
            onChanged: (v) => _set(params.copyWith(neuralScale: v)),
          ),
          _tileDropdown(params),
          _slider(
            label: '分块重叠',
            value: params.neuralOverlap.toDouble(),
            min: 0,
            max: 64,
            valueText: '${params.neuralOverlap} px',
            onChanged: (v) =>
                _set(params.copyWith(neuralOverlap: v.round())),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 4),
            child: Text(
              '调参后当前页会自动重新推理（磁盘缓存按参数分开保存，旧结果保留）。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
          ),
        ],
        const Divider(height: 20),
        // ---------- 照片超分（照片向，与 FSR 互斥） ----------
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('照片超分'),
          subtitle: const Text('Lanczos3 重采样 + 噪点门控锐化，适合真实照片/写真（开启时自动关闭 FSR）'),
          value: params.photo,
          onChanged: (v) => _set(params.copyWith(photo: v, fsr: v ? false : null)),
        ),
        if (params.photo) ...[
          _slider(
            label: '放大倍数',
            value: params.photoScale,
            min: 1.2,
            max: 3.0,
            valueText: '${params.photoScale.toStringAsFixed(1)}x',
            onChanged: (v) => _set(params.copyWith(photoScale: v)),
          ),
          _slider(
            label: '锐化强度',
            value: params.photoSharp,
            onChanged: (v) => _set(params.copyWith(photoSharp: v)),
          ),
          _slider(
            label: '噪点保护',
            value: params.photoGate,
            valueText: '${(params.photoGate * 100).round()}%',
            onChanged: (v) => _set(params.copyWith(photoGate: v)),
          ),
        ],
        const Divider(height: 20),
        // ---------- FSR 超分 ----------
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('FSR 超分'),
          subtitle: const Text('边缘自适应放大 + RCAS 锐化（动漫向；开启时自动关闭照片超分）'),
          value: params.fsr,
          onChanged: (v) => _set(params.copyWith(fsr: v, photo: v ? false : null)),
        ),
        if (params.fsr) ...[
          _slider(
            label: '放大倍数',
            value: params.fsrScale,
            min: 1.2,
            max: 3.0,
            valueText: '${params.fsrScale.toStringAsFixed(1)}x',
            onChanged: (v) => _set(params.copyWith(fsrScale: v)),
          ),
          _slider(
            label: 'RCAS 锐化',
            value: params.rcas,
            onChanged: (v) => _set(params.copyWith(rcas: v)),
          ),
        ],
        const Divider(height: 20),
        // ---------- Anime4K 线条增强 ----------
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Anime4K 线条增强'),
          subtitle: const Text('锐化并加深动漫线条（单 pass 风格实现）'),
          value: params.a4k,
          onChanged: (v) => _set(params.copyWith(a4k: v)),
        ),
        if (params.a4k) ...[
          _slider(
            label: '强度',
            value: params.a4kStrength,
            onChanged: (v) => _set(params.copyWith(a4kStrength: v)),
          ),
          _slider(
            label: '边缘阈值',
            value: params.a4kEdge,
            min: 0.0,
            max: 0.6,
            onChanged: (v) => _set(params.copyWith(a4kEdge: v)),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          '处理在 GPU 上逐页进行；滤镜纹理分辨率高于屏幕，双页/缩放时可见额外细节。神经超分逐页后台推理，完成即自动换图。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
        ),
      ],
    );
  }

  /// 分块边长下拉：0=跟随模型默认（动漫 512 / 照片 256）；越小显存越省但越慢、接缝越多。
  Widget _tileDropdown(FxParams params) {
    return Row(
      children: [
        SizedBox(width: 76, child: Text('分块大小', style: const TextStyle(fontSize: 13))),
        Expanded(
          child: DropdownButtonFormField<int>(
            initialValue: params.neuralTile,
            isDense: true,
            decoration: const InputDecoration(border: UnderlineInputBorder(), isDense: true),
            items: [
              for (final t in const [0, 256, 384, 512, 768, 1024])
                DropdownMenuItem(
                  value: t,
                  child: Text(t == 0 ? '跟随模型' : '$t px', style: const TextStyle(fontSize: 13)),
                ),
            ],
            onChanged: (v) => v == null ? null : _set(params.copyWith(neuralTile: v)),
          ),
        ),
      ],
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
    double min = 0.0,
    double max = 1.0,
    String? valueText,
  }) {
    return Row(
      children: [
        SizedBox(width: 76, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            valueText ?? value.toStringAsFixed(2),
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}
