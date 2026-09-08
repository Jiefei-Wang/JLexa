import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai/backend_benchmark.dart';
import 'backend_benchmark_controller.dart';

class BackendBenchmarkScreen extends StatefulWidget {
  final BackendBenchmarkController controller;
  const BackendBenchmarkScreen({super.key, required this.controller});
  @override
  State<BackendBenchmarkScreen> createState() => _BackendBenchmarkScreenState();
}

class _BackendBenchmarkScreenState extends State<BackendBenchmarkScreen>
    with WidgetsBindingObserver {
  BackendBenchmarkController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.initialize();
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

  String speed(double? value) => value == null ? '—' : value.toStringAsFixed(1);
  String status(String s) => switch (s) {
    'loading' => 'Loading model',
    'prefill' => 'Prefill',
    'input' => 'Prefill',
    'token' => 'Decoding',
    'decode' => 'Decoding',
    'restoring' => 'Restoring previous backend',
    'finished' => 'Finished',
    'cancelled' => 'Stopped',
    'failed' => 'Failed',
    'queued' => 'Queued',
    'completed' => 'Completed',
    _ => s,
  };
  void details(BackendBenchmarkResult r) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${r.backend.toUpperCase()} result'),
        content: SingleChildScrollView(
          child: SelectableText(
            '${r.time}\n${status(r.status)}\n'
            'Source: ${r.sourceTokens} tokens\nPrefill: ${r.promptTokens} tokens / ${(r.prefillUs / 1000).toStringAsFixed(1)} ms\n'
            'Output: ${r.generatedTokens} tokens\nDecode: ${r.decodedTokens} tokens / ${(r.decodeUs / 1000).toStringAsFixed(1)} ms\n'
            'Threads: ${r.runtime['threads'] ?? '—'} · Batch: ${r.runtime['batchSize'] ?? '—'}\n'
            '${r.error}\n\n${r.output}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      return PopScope(
        canPop: !c.running,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) unawaited(c.stop());
        },
        child: Scaffold(
          appBar: AppBar(title: const Text('Backend Benchmark')),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        c.modelName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Translate 100 English source tokens into Chinese. Output stops at 100 tokens or the model’s end token.',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Speeds are native model tokens/s. Prefill includes instruction and chat-template tokens; model loading and UI time are excluded.',
                      ),
                      const SizedBox(height: 12),
                      if (c.loading) const LinearProgressIndicator(),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columnSpacing: 16,
                          horizontalMargin: 4,
                          columns: const [
                            DataColumn(label: Text('Select')),
                            DataColumn(label: Text('Backend')),
                            DataColumn(
                              label: Text('Prefill\ntok/s'),
                              numeric: true,
                            ),
                            DataColumn(
                              label: Text('Decode\ntok/s'),
                              numeric: true,
                            ),
                          ],
                          rows: c.backends.map((b) {
                            final r = c.results[b.backend];
                            final state = c.rowStates[b.backend];
                            final current =
                                state != null &&
                                state != 'completed' &&
                                state != r?.status;
                            return DataRow(
                              cells: [
                                DataCell(
                                  Checkbox(
                                    value: c.selected.contains(b.backend),
                                    onChanged: c.running || !b.available
                                        ? null
                                        : (v) =>
                                              c.toggle(b.backend, v ?? false),
                                  ),
                                ),
                                DataCell(
                                  Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(b.backend.toUpperCase()),
                                      Text(
                                        !b.available
                                            ? 'Unavailable'
                                            : state != null
                                            ? status(state)
                                            : r == null
                                            ? 'Not tested'
                                            : 'Last result',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall,
                                      ),
                                    ],
                                  ),
                                  onTap: r == null || c.running
                                      ? null
                                      : () => details(r),
                                ),
                                DataCell(
                                  Text(speed(current ? null : r?.prefillSpeed)),
                                ),
                                DataCell(
                                  Text(speed(current ? null : r?.decodeSpeed)),
                                ),
                              ],
                            );
                          }).toList(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Tap a backend result for its timestamp, token counts and translation.',
                      ),
                      if (c.error.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            c.error,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      for (final b in c.backends.where((b) => !b.available))
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '${b.backend.toUpperCase()}: ${b.reasonUnavailable ?? 'Not supported by this plugin/device'}',
                          ),
                        ),
                      if (c.stage.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Text(
                          c.stopping
                              ? 'Stopping… The previous backend will be restored.'
                              : '${c.activeBackend.toUpperCase()} · ${status(c.stage)}',
                        ),
                        if (c.running)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: LinearProgressIndicator(),
                          ),
                      ],
                      if (c.source.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Text(
                          'Source · 100 tokens',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SelectableText(c.source),
                      ],
                      if (c.livePrefill != null)
                        Text(
                          'Prefill: ${speed(c.livePrefill)} tok/s · ${c.promptTokens} input tokens',
                        ),
                      if (c.output.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Text(
                          'Live translation',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SelectableText(c.output),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: c.running
                        ? FilledButton.icon(
                            onPressed: c.stopping ? null : c.stop,
                            icon: const Icon(Icons.stop),
                            label: const Text('Stop benchmark'),
                          )
                        : FilledButton.icon(
                            onPressed:
                                c.loading || !c.supported || c.selected.isEmpty
                                ? null
                                : c.run,
                            icon: const Icon(Icons.speed),
                            label: const Text('Run again'),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
