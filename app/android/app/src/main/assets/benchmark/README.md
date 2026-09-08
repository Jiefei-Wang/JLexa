# Whisper benchmark fixtures v1

These are fixed synthetic English speech recordings of original JLexa benchmark
text, generated using Windows `System.Speech.Synthesis.SpeechSynthesizer` on
2026-09-07. No user recording or third-party reading passage is included.
The benchmark text is dedicated to the public domain (CC0).

Both files are uncompressed signed 16-bit, mono, 16,000 Hz WAV. The app reads PCM
before starting the timer. Reported seconds measure the synchronous native
transcription call, including transcript conversion, with four CPU threads and
language `en`; they exclude file decoding, plugin switching and model loading.
Each selected backend loads the current model afresh and runs short then long
once. These are single-run timings, not medians or accuracy scores.

Short (3.575 seconds):
> Please open the window and bring me a glass of water.

Long (20.205 seconds):
> On Saturday morning, a group of friends walked through the park to visit the
> public library. They looked for a book about the history of their town,
> discussed what they had learned, and made a plan to explore the old railway
> station after lunch. Before leaving, they checked the weather forecast and
> packed some water for the journey.

SHA-256:
- short.wav: `056ce52d84dd907bf677d7af69b958ccc39b139eaeaf6389dcd0755a157eab76`
- long.wav: `76e6c4924f4ddf7a43898728f91c396ecb599e47e09b33b43326b552fa9662c9`

History is stored under `speech_benchmark_v1` keyed by model path and backend
identity. Change the history version if the fixtures or timing method change.
