import 'dart:io';

import 'package:flutter/services.dart';

class BackendPluginInfo {
  final String name, engine, version, backendType, status, error, fileName;
  final bool external;
  const BackendPluginInfo({
    this.name = 'Built-in',
    this.engine = 'llama.cpp',
    this.version = '1.0.0',
    this.backendType = 'CPU / Vulkan / OpenCL',
    this.status = 'Loaded',
    this.error = '',
    this.fileName = '',
    this.external = false,
  });
  factory BackendPluginInfo.fromMap(Map<dynamic, dynamic> map) =>
      BackendPluginInfo(
        name: map['name'] as String? ?? 'Built-in',
        engine: map['engine'] as String? ?? '',
        version: map['version'] as String? ?? '',
        backendType: map['backendType'] as String? ?? '',
        status: map['status'] as String? ?? 'Failed',
        error: map['error'] as String? ?? '',
        fileName: map['fileName'] as String? ?? '',
        external: map['external'] == true,
      );
}

class BackendPlugins {
  final bool supported;
  static const _channel = MethodChannel('com.jlexa.app/llama');
  BackendPlugins({bool? supported})
    : supported = supported ?? Platform.isAndroid;
  Future<BackendPluginInfo> _call(String method) async {
    if (!supported) return const BackendPluginInfo();
    final map = await _channel.invokeMapMethod<dynamic, dynamic>(method);
    if (map == null) throw StateError('No backend plugin status returned');
    return BackendPluginInfo.fromMap(map);
  }

  Future<BackendPluginInfo> status() => _call('pluginStatus');
  Future<BackendPluginInfo> importPlugin() => _call('importPlugin');
  Future<BackendPluginInfo> useBuiltin() => _call('useBuiltinPlugin');
}
