import '../audio/audio_models.dart';

abstract class SpeechRecognitionEngine {
  bool get isLoaded;
  String? get loadedModelPath;

  Future<void> loadModel(String modelPath);
  Future<List<AudioSegment>> transcribeAudio({
    required String audioPath,
    required String lessonId,
    int nThreads = 4,
    void Function(double progress)? onProgress,
  });
  Future<Map<String, dynamic>?> getAudioMetadata(String audioPath);
  Future<void> cancel();
  Future<void> unload();
}
