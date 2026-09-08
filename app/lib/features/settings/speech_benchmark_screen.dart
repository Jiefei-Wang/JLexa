import 'dart:async';

import 'package:flutter/material.dart';

import 'speech_benchmark_controller.dart';

class SpeechBenchmarkScreen extends StatefulWidget {
  final SpeechBenchmarkController controller;
  const SpeechBenchmarkScreen({super.key, required this.controller});
  @override
  State<SpeechBenchmarkScreen> createState() => _SpeechBenchmarkScreenState();
}

class _SpeechBenchmarkScreenState extends State<SpeechBenchmarkScreen>
    with WidgetsBindingObserver {
  SpeechBenchmarkController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(c.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(c.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.dispose();
    super.dispose();
  }

  String seconds(int? us) =>
      us != null && us > 0 ? (us / 1000000).toStringAsFixed(2) : '—';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Whisper Benchmark')),
    body: SafeArea(
      child: AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          if (c.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(c.modelName, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  horizontalMargin: 8,
                  columnSpacing: 16,
                  dataRowMinHeight: MediaQuery.textScalerOf(context).scale(64),
                  dataRowMaxHeight: MediaQuery.textScalerOf(context).scale(64),
                  columns: const [
                    DataColumn(label: Text('Backend')),
                    DataColumn(label: Text('Short (s)'), numeric: true),
                    DataColumn(label: Text('Long (s)'), numeric: true),
                  ],
                  rows: c.backends.entries.map((b) {
                    final r = c.results[b.key];
                    final state = c.states[b.key] ?? r?.status ?? '';
                    return DataRow(
                      selected: c.selected.contains(b.key),
                      onSelectChanged: c.running
                          ? null
                          : (v) => c.toggle(b.key, v ?? false),
                      cells: [
                        DataCell(
                          SizedBox(
                            width: 132,
                            child: Text.rich(
                              TextSpan(
                                text: b.value,
                                children: [
                                  if (state == 'failed' || state == 'cancelled')
                                    TextSpan(
                                      text: '\n$state',
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                        fontSize: 11,
                                      ),
                                    ),
                                ],
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        DataCell(Text(seconds(r?.shortUs))),
                        DataCell(Text(seconds(r?.longUs))),
                      ],
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: c.running
                    ? FilledButton.icon(
                        onPressed: c.stopping ? null : c.stop,
                        icon: const Icon(Icons.stop),
                        label: Text(c.stopping ? 'Stopping…' : 'Stop'),
                      )
                    : FilledButton.icon(
                        onPressed: c.selected.isEmpty ? null : c.run,
                        icon: const Icon(Icons.speed),
                        label: const Text('Test'),
                      ),
              ),
              if (c.running) ...[
                const SizedBox(height: 16),
                Text(
                  c.stage == 'restoring'
                      ? 'Restoring…'
                      : '${c.backends[c.activeBackend] ?? ''} · ${c.sample.isEmpty ? 'Loading…' : '${c.sample} ${c.progress}%'}',
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: c.stage == 'progress'
                      ? c.progress.clamp(0, 100) / 100
                      : null,
                ),
              ],
              if (c.output.isNotEmpty) ...[
                const SizedBox(height: 16),
                SelectableText(c.output),
              ],
              if (c.error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  c.error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              for (final result in c.results.values.where(
                (r) => r.error.isNotEmpty,
              ))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${c.backends[result.backend] ?? result.backend}: ${result.error}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
