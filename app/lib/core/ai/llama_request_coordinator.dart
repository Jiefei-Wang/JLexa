import 'dart:async';

import 'ai_models.dart';
import 'prompt_builder.dart';

class LlamaQueuedRequest {
  final String requestId;
  final String prompt;
  final AiGenerationSettings? settings;
  final int? seed;
  final List<ChatMessagePayload>? chatMessages;
  final AiRequestPriority priority;
  final StreamController<String> controller;
  final Completer<void> doneCompleter;
  bool isCancelled = false;
  bool hasStartedNatively = false;

  LlamaQueuedRequest({
    required this.requestId,
    required this.prompt,
    this.settings,
    this.seed,
    this.chatMessages,
    required this.priority,
    required this.controller,
    required this.doneCompleter,
  });

  void cancelBeforeStart() {
    if (isCancelled || hasStartedNatively) return;
    isCancelled = true;
    if (!controller.isClosed) {
      controller.addError(const AiCancelledException());
      controller.close();
    }
    if (!doneCompleter.isCompleted) {
      doneCompleter.complete();
    }
  }
}

class LlamaRequestCoordinator {
  final Future<void> Function(LlamaQueuedRequest request) onNativeStart;
  final Future<void> Function(String requestId) onNativeCancel;

  LlamaQueuedRequest? _activeRequest;
  LlamaQueuedRequest? _pendingRequest;

  LlamaQueuedRequest? get activeRequest => _activeRequest;
  LlamaQueuedRequest? get pendingRequest => _pendingRequest;

  LlamaRequestCoordinator({
    required this.onNativeStart,
    required this.onNativeCancel,
  });

  AiGenerationHandle queueRequest({
    required String requestId,
    required String prompt,
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    final controller = StreamController<String>();
    final doneCompleter = Completer<void>();

    final req = LlamaQueuedRequest(
      requestId: requestId,
      prompt: prompt,
      settings: settings,
      seed: seed,
      chatMessages: chatMessages,
      priority: priority,
      controller: controller,
      doneCompleter: doneCompleter,
    );

    if (_activeRequest == null) {
      // Nothing running natively, start immediately
      _startNative(req);
    } else {
      final activePriority = _activeRequest!.priority;

      if (priority == AiRequestPriority.user) {
        // Incoming USER request:
        // Always supersedes any pending request (whether USER or BACKGROUND)
        if (_pendingRequest != null) {
          _pendingRequest!.cancelBeforeStart();
          _pendingRequest = null;
        }

        _pendingRequest = req;
        // Pre-empt whatever active request is currently running
        onNativeCancel(_activeRequest!.requestId);
      } else {
        // Incoming BACKGROUND request:
        if (_pendingRequest != null &&
            _pendingRequest!.priority == AiRequestPriority.user) {
          // Pending is already a USER request: DO NOT displace pending USER!
          if (!controller.isClosed) {
            controller.addError(
              const AiBusyException('User generation in progress.'),
            );
            controller.close();
          }
          if (!doneCompleter.isCompleted) {
            doneCompleter.complete();
          }
          return AiGenerationHandle(
            requestId: requestId,
            stream: controller.stream,
            onCancel: () async {},
            done: doneCompleter.future,
          );
        }

        if (activePriority == AiRequestPriority.background) {
          // Active is BACKGROUND, incoming is BACKGROUND:
          // Supersedes pending request, cancels active BACKGROUND
          if (_pendingRequest != null) {
            _pendingRequest!.cancelBeforeStart();
            _pendingRequest = null;
          }
          _pendingRequest = req;
          onNativeCancel(_activeRequest!.requestId);
        } else {
          // Active is USER, incoming is BACKGROUND:
          // CRITICAL: DO NOT CANCEL ACTIVE USER!
          if (_pendingRequest == null) {
            // Queue as low-priority pending behind active USER
            _pendingRequest = req;
          } else {
            // Replace older pending background with latest background
            _pendingRequest!.cancelBeforeStart();
            _pendingRequest = req;
          }
        }
      }
    }

    return AiGenerationHandle(
      requestId: requestId,
      stream: controller.stream,
      onCancel: () => handleCancel(req),
      done: doneCompleter.future,
    );
  }

  Future<void> handleCancel(LlamaQueuedRequest req) async {
    if (req == _pendingRequest) {
      req.cancelBeforeStart();
      _pendingRequest = null;
    } else if (req == _activeRequest) {
      await onNativeCancel(req.requestId);
    }
  }

  Future<void> cancelRequest(String requestId) async {
    if (_pendingRequest?.requestId == requestId) {
      _pendingRequest!.cancelBeforeStart();
      _pendingRequest = null;
      return;
    }
    if (_activeRequest?.requestId == requestId) {
      await onNativeCancel(requestId);
    }
  }

  Future<void> cancelAll() async {
    if (_pendingRequest != null) {
      _pendingRequest!.cancelBeforeStart();
      _pendingRequest = null;
    }
    if (_activeRequest != null) {
      await onNativeCancel(_activeRequest!.requestId);
    }
  }

  Future<void> _startNative(LlamaQueuedRequest req) async {
    if (req.isCancelled) {
      onTerminal(req.requestId);
      return;
    }

    _activeRequest = req;
    req.hasStartedNatively = true;

    try {
      await onNativeStart(req);
    } catch (e) {
      if (!req.controller.isClosed) {
        req.controller.addError(
          e is Exception ? e : AiGenerationException(e.toString()),
        );
        req.controller.close();
      }
      if (!req.doneCompleter.isCompleted) {
        req.doneCompleter.complete();
      }
      onTerminal(req.requestId);
    }
  }

  void onToken(String requestId, String token) {
    if (_activeRequest?.requestId == requestId) {
      final ctrl = _activeRequest!.controller;
      if (!ctrl.isClosed) {
        ctrl.add(token);
      }
    }
  }

  void onDone(String requestId) {
    if (_activeRequest?.requestId == requestId) {
      final active = _activeRequest!;
      if (!active.controller.isClosed) {
        active.controller.close();
      }
      if (!active.doneCompleter.isCompleted) {
        active.doneCompleter.complete();
      }
      onTerminal(requestId);
    }
  }

  void onCancelled(String requestId) {
    if (_activeRequest?.requestId == requestId) {
      final active = _activeRequest!;
      if (!active.controller.isClosed) {
        active.controller.addError(const AiCancelledException());
        active.controller.close();
      }
      if (!active.doneCompleter.isCompleted) {
        active.doneCompleter.complete();
      }
      onTerminal(requestId);
    }
  }

  void onError(String requestId, String message) {
    if (_activeRequest?.requestId == requestId) {
      final active = _activeRequest!;
      if (!active.controller.isClosed) {
        active.controller.addError(AiGenerationException(message));
        active.controller.close();
      }
      if (!active.doneCompleter.isCompleted) {
        active.doneCompleter.complete();
      }
      onTerminal(requestId);
    }
  }

  void onTerminal(String requestId) {
    if (_activeRequest?.requestId == requestId) {
      _activeRequest = null;
    }

    while (_pendingRequest != null) {
      final nextReq = _pendingRequest!;
      _pendingRequest = null;
      if (!nextReq.isCancelled) {
        _startNative(nextReq);
        return;
      }
    }
  }

  void dispose() {
    if (_pendingRequest != null) {
      _pendingRequest!.cancelBeforeStart();
      _pendingRequest = null;
    }
    if (_activeRequest != null) {
      if (!_activeRequest!.controller.isClosed) {
        _activeRequest!.controller.close();
      }
      if (!_activeRequest!.doneCompleter.isCompleted) {
        _activeRequest!.doneCompleter.complete();
      }
      _activeRequest = null;
    }
  }
}
