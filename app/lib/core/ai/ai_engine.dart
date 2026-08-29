import 'ai_models.dart';
import 'prompt_builder.dart';

abstract class AiEngine {
  bool get isLoaded;
  String? get loadedModelPath;
  AiModelState get state;

  Future<void> loadModel(String modelPath, {AiGenerationSettings? settings});
  Stream<String> generate(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
  });
  AiGenerationHandle startGeneration(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
    AiRequestPriority priority = AiRequestPriority.user,
  });
  Future<void> cancel();
  Future<void> cancelRequest(String requestId);
  Future<void> unload();
}
