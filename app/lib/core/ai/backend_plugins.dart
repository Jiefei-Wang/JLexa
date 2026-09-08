import 'dart:io';

import 'package:flutter/services.dart';

import 'llama_runtime_settings.dart';

class InstalledBackend {
  final String id, name, engine, version, backendType, fileName;
  const InstalledBackend({
    required this.id,
    required this.name,
    this.engine = '',
    this.version = '',
    this.backendType = '',
    this.fileName = '',
  });
  factory InstalledBackend.fromMap(Map<dynamic, dynamic> map) =>
      InstalledBackend(
        id: map['id'] as String,
        name: map['name'] as String,
        engine: map['engine'] as String? ?? '',
        version: map['version'] as String? ?? '',
        backendType: map['backendType'] as String? ?? '',
        fileName: map['fileName'] as String? ?? '',
      );
}

class BackendPluginInfo {
  final String name, engine, version, backendType, status, error, fileName;
  final bool external;
  final String id;
  final List<InstalledBackend> installed;
  final List<LlamaBackendInfo> builtinBackends;
  const BackendPluginInfo({
    this.name = 'Built-in',
    this.engine = 'llama.cpp',
    this.version = '1.0.0',
    this.backendType = 'CPU / Vulkan / OpenCL',
    this.status = 'Loaded',
    this.error = '',
    this.fileName = '',
    this.external = false,
    this.id = '',
    this.installed = const [],
    this.builtinBackends = const [],
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
        id: map['id'] as String? ?? '',
        installed: (map['installed'] as List? ?? [])
            .map((e) => InstalledBackend.fromMap(e as Map))
            .toList(),
        builtinBackends: (map['builtinBackends'] as List? ?? [])
            .map((e) => LlamaBackendInfo.fromMap(e as Map))
            .toList(),
      );
}

class BackendPlugins {
  final bool supported;
  static const _channel = MethodChannel('com.jlexa.app/llama');
  BackendPlugins({bool? supported})
    : supported = supported ?? Platform.isAndroid;
  Future<BackendPluginInfo> _call(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    if (!supported) return const BackendPluginInfo();
    final map = await _channel.invokeMapMethod<dynamic, dynamic>(method, args);
    if (map == null) throw StateError('No backend plugin status returned');
    return BackendPluginInfo.fromMap(map);
  }

  Future<BackendPluginInfo> status() => _call('pluginStatus');
  Future<BackendPluginInfo> importPlugin() => _call('importPlugin');
  Future<BackendPluginInfo> useBuiltin() => _call('useBuiltinPlugin');
  Future<BackendPluginInfo> select(String id) =>
      _call('selectPlugin', {'id': id});
  Future<BackendPluginInfo> delete(String id) =>
      _call('deletePlugin', {'id': id});
}
