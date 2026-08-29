import 'ai_models.dart';

abstract class AiEngine {
  bool get isLoaded;
  String? get loadedModelPath;
  AiModelState get state;

  Future<void> loadModel(String modelPath, {AiGenerationSettings? settings});
  Stream<String> generate(String prompt, {AiGenerationSettings? settings});
  Future<void> cancel();
  Future<void> unload();
}
