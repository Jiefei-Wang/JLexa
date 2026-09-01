import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/model_file_picker.dart';

void main() {
  group('ModelFilePicker Tests', () {
    test('FakeModelFilePicker returns configured paths', () async {
      final fakePicker = FakeModelFilePicker(
        nextLlmPath: '/models/custom.gguf',
        nextSpeechPath: '/models/ggml-base.bin',
      );

      final llm = await fakePicker.pickLlmModel();
      expect(llm, '/models/custom.gguf');

      final speech = await fakePicker.pickSpeechModel();
      expect(speech, '/models/ggml-base.bin');
    });

    test('FakeModelFilePicker handles errors properly', () async {
      final fakePicker = FakeModelFilePicker(
        shouldThrow: true,
        errorMessage: 'User cancelled picker',
      );

      expect(
        () => fakePicker.pickLlmModel(),
        throwsA(isA<ModelPickerException>()),
      );
      expect(
        () => fakePicker.pickSpeechModel(),
        throwsA(isA<ModelPickerException>()),
      );
    });
  });
}
