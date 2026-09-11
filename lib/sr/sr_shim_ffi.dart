import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// sr_shim.dll 的 dart:ffi 绑定（纯 dart:ffi，无 Flutter 依赖，可在任意 isolate 加载）。
///
/// 会话信息结构须与 windows/sr_shim/sr_shim.h 的 SrSessionInfo 保持一致：
/// void* session; int inputIsHalf; int scale; char inputName[64]; char outputName[64];
/// 会话信息结构大小（void* + 2×int + 2×char[64]，8 字节对齐）。
const int kSrSessionInfoSize = 144;

final class SrSessionInfo extends Struct {
  external Pointer<Void> session;
  @Int32()
  external int inputIsHalf;
  @Int32()
  external int scale;
  @Array(64)
  external Array<Uint8> inputName;
  @Array(64)
  external Array<Uint8> outputName;

  String get inputNameStr => _cstr(inputName);
  String get outputNameStr => _cstr(outputName);

  static String _cstr(Array<Uint8> a) {
    final b = StringBuffer();
    for (var i = 0; i < 64; i++) {
      final c = a[i];
      if (c == 0) break;
      b.writeCharCode(c);
    }
    return b.toString();
  }
}

typedef _SrInitNative = Int32 Function(Pointer<Utf16> ortPath);
typedef _SrInitDart = int Function(Pointer<Utf16> ortPath);

typedef _SrCreateSessionNative = Int32 Function(
    Pointer<Uint8> modelData, Int64 modelLen, Int32 useDml, Pointer<SrSessionInfo> out);
typedef _SrCreateSessionDart = int Function(
    Pointer<Uint8> modelData, int modelLen, int useDml, Pointer<SrSessionInfo> out);

typedef _SrReleaseNative = Void Function(Pointer<SrSessionInfo> info);
typedef _SrReleaseDart = void Function(Pointer<SrSessionInfo> info);

typedef _SrRunNative = Int32 Function(Pointer<SrSessionInfo> info, Int32 inW, Int32 inH,
    Pointer<Uint8> rgba, Pointer<Uint8> outRgba, Int32 tile, Int32 overlap);
typedef _SrRunDart = int Function(Pointer<SrSessionInfo> info, int inW, int inH,
    Pointer<Uint8> rgba, Pointer<Uint8> outRgba, int tile, int overlap);

typedef _SrLastErrorNative = Pointer<Utf16> Function();
typedef _SrLastErrorDart = Pointer<Utf16> Function();

class SrShim {
  final DynamicLibrary lib;
  late final _SrInitDart _init;
  late final _SrCreateSessionDart _createSession;
  late final _SrReleaseDart _releaseSession;
  late final _SrRunDart _run;
  late final _SrLastErrorDart _lastError;

  SrShim.open(String path) : lib = DynamicLibrary.open(path) {
    _init = lib.lookupFunction<_SrInitNative, _SrInitDart>('sr_init');
    _createSession =
        lib.lookupFunction<_SrCreateSessionNative, _SrCreateSessionDart>('sr_create_session');
    _releaseSession =
        lib.lookupFunction<_SrReleaseNative, _SrReleaseDart>('sr_release_session');
    _run = lib.lookupFunction<_SrRunNative, _SrRunDart>('sr_run');
    _lastError = lib.lookupFunction<_SrLastErrorNative, _SrLastErrorDart>('sr_last_error');
  }

  int init(Pointer<Utf16> ortPath) => _init(ortPath);

  int createSession(Pointer<Uint8> modelData, int modelLen, int useDml,
          Pointer<SrSessionInfo> out) =>
      _createSession(modelData, modelLen, useDml, out);

  void releaseSession(Pointer<SrSessionInfo> info) => _releaseSession(info);

  int run(Pointer<SrSessionInfo> info, int inW, int inH, Pointer<Uint8> rgba,
          Pointer<Uint8> outRgba, int tile, int overlap) =>
      _run(info, inW, inH, rgba, outRgba, tile, overlap);

  String get lastErrorText {
    final p = _lastError();
    if (p == nullptr) return '';
    return p.toDartString();
  }
}
