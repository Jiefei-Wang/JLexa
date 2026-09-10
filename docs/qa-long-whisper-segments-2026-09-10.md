# Whisper Small long-sentence segmentation — 2026-09-10

## Reproduction and evidence

Used ADB on Pixel 6 `25311FDF6004PR`, with the supplied 16:12 MP3 (972,434 ms app duration). The app catalog model was Whisper Small English (`ggml-small.en.bin`), SHA-256 `c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d`. Existing lessons and models were retained.

Before changing segmentation, the Pixel produced an automatic cut **88,130–112,015 ms (23.885 seconds)**. The actual decoder output is represented by the regression fixture `app/test/fixtures/whisper_small_long_sentence.json`. The sentence discusses the polar explorers and the continued celebration of one as a leadership role model in books, blogs, documentaries, podcasts and social media. It contains commas but no internal sentence-ending punctuation.

The same native Small model re-transcribed actual cut audio on Pixel, after cutting at the proposed and fine-adjusted boundaries:

| Bounds (seconds) | Duration | Actual fresh Pixel recognition |
|---|---:|---|
| 88.130–98.035 | 9.905 s | Well, both of these men were real polar explorers who lived during the so-called heroic age of polar exploration. And in the centuries since... |
| 98.035–107.075 | 9.040 s | One of them has been consistently celebrated as a leadership role model in best-selling books, blogs, |
| 107.075–112.015 | 4.940 s | documentaries, podcasts, and an endless stream of social media posts. |

Both sides of the two new boundaries (`since / one`, `blogs / documentaries`) survived actual recognition. `best-selling` remained complete. Recognition changes “century” to “centuries”; this is not represented as exact transcript equality. Each cut took about 25.5 seconds to recognize on Pixel CPU. A Dart hot restart also ran the final algorithm and existing fine adjustment against **Pixel-native decoded mean-square energy**, producing the identical three bounds. The original lesson was not overwritten with host transcripts or test cuts.

## General rule and ordering

1. Only automatic, valid, timestamped transcripts longer than 10 seconds are candidates. Manual cuts, missing timing, and incompletely covered audio are preserved.
2. Reconstruct whole words from Whisper BPE tokens. Do not cut inside a tokenized word, hyphenated expression, or after a function word such as an article, auxiliary, preposition, or conjunction.
3. Prefer comma/semicolon/colon and incoming clause boundaries. Require a real low-energy interval near the adjoining spoken-token timestamps; low confidence, overlapping timestamps and uninterrupted energy reject a candidate.
4. The quiet interval must last at least 120 ms and remain below 6% of the surrounding 75th-percentile mean-square energy. Ordinary word boundaries additionally require at least 200 ms. These are conservative heuristics, not phoneme alignment.
5. Choose a sequence of candidates with dynamic programming, strongly preferring spans at most 10 seconds and avoiding fragments below 2 seconds. If no safe candidate covers a long span, retain an overlong result rather than invent a timer cut.
6. Run the existing fine adjustment **after** these proposals. Restrict each new boundary to its verified quiet interval, with a 20 ms inset, so the fine-adjustment search cannot move it into a neighboring high-energy region.
7. Version-1 completed caches are repolished without requiring new recognition. Previously adjusted exterior boundaries are retained; version-2 restart is idempotent. Manual edits stay untouched.

The initial experiment accepted 60 ms dips. Whole-article re-recognition exposed unreliable ordinary-word placements, so the final rule increases the pause requirement and protects `before`/`after`. The target result remains the same. This rule currently relies on space-delimited Latin words; unsupported writing systems are conservatively left unsplit.

## Whole-article experiment and limitations

Built the repository's unchanged whisper.cpp CPU CLI locally in release mode and used the **same Small English model** to transcribe the entire source, including its introduction and conclusion (about 228 seconds inference time). Passed this real output through the app's sentence builder, then the new splitter and existing fine adjustment. This is a host corpus experiment, separate from the Pixel recognition above; full-file and windowed recognition can produce different punctuation and timestamps.

The baseline contains 125 sentence cuts, including 33 over 10 seconds. The final output contains 160 cuts, with **158 at most 10 seconds and two overlong cuts**:

- 96.450–109.085 (12.635 s): this host run gives different punctuation/timing for the target paragraph and does not offer a trusted pause meeting the final rule before 10 seconds.
- 510.220–541.600 (31.380 s): the full-file recognizer has a substantial omission and unreliable alignment around the discussion of Amundsen. The available transcript does not support a defensible extra boundary.

These exceptions are not claimed to be uninterrupted speech. They demonstrate the limitation of the available Whisper timing. Adding reliable forced alignment or recovering the missing recognition is a separate improvement; a timer cut would conceal the uncertainty.

Every changed output span is exported as actual 16 kHz PCM audio and independently recognized again with Small on the host. The accompanying comparison records original versus fresh text. Differences at unchanged outer sentence boundaries must not be attributed to new internal boundaries. Recognition equality is useful evidence but cannot prove phoneme integrity: a model can omit, normalize or hallucinate a word, and an inaccurate timestamp can assign a complete word to the other side of a quiet interval. This experiment does **not** establish zero clipped phonemes for all audio.

Local raw data, full transcript, model, decoder logs and WAV recuts remain under `artifacts/long-sentence-small/` (not committed). The committed fixture retains the target's actual token timings and acoustic envelope so its behavior is reproducible without inference or a model download.

## Verification

Regression coverage includes the real Pixel sentence, conservation of token order and text, intact compound words, no forced splitting of continuous speech/missing timing/manual edits, constrained fine adjustment, and cache migration/restart persistence. Final check and signed artifact results are recorded in the session log in `agents.md`.

The release is built from the shared workspace and also contains the separate task's Media3 MP3 seek correction; that task owns its adapter files and device playback evidence. Temporary diagnostic Dart entry, raw logging and imported CPU plugin were removed. Small English remains installed and selected for the user's future use.

## Fresh host recognition comparison

All **70 changed spans** were cut and re-recognized (239 seconds total). Of **34 new internal boundaries**, **30** retained the final two words on the left and initial two words on the right verbatim after lowercasing/punctuation removal. At 9.925, 548.655 and 561.525 seconds, complete words move to the opposite side in fresh recognition (`you`, `Passage`, `at his camp`). These are unresolved transcript-to-audio alignment discrepancies, not evidence that every phoneme was preserved. At 872.935 seconds, fresh recognition changes unconcerned to on concern. Several unchanged outer edges also have omissions/recognition differences.

| Bounds (s) | Cached text | Fresh recognition |
|---|---|---|
| 0.380–9.925 | [MUSIC] I would like to invite | [MUSIC] I would like to invite you |
| 9.925–12.640 | you on a little thought experiment. | on a little thought experiment. |
| 26.850–33.825 | One comes from a man who has already successfully achieved all four of the major polar goals, | One comes from a man who has already successfully achieved all four of the major polar goals. |
| 33.825–38.160 | the North Pole, the South Pole, and the Northeast and the Northwest Passage. | the North Pole and the South Pole, and the Northeast and the Northwest Passage. |
| 47.910–56.545 | Candidate B is a man who set off for the Antarctic four times, three times as the man in charge, | B is a man who set off for the Antarctic four times. Three times is the man in charge. |
| 56.545–65.920 | and every time resulted in failure, catastrophe, or death. | And every time resulted in failure, catastrophe, or death. |
| 87.330–96.270 | How do I know? Well, both of these men were real polar explorers who lived during the so-called heroic age of polar exploration. | How do I know? Well, both of these men were real polar explorers who lived during the so-called heroic age of polar exploration. |
| 96.450–109.085 | And in the century since, one of them has been consistently celebrated as a leadership role model in best-selling books, blogs, documentaries, podcasts, | And in the century since, one of them has been consistently celebrated as a leadership role model in best-selling books, blogs, documentaries, podcasts, |
| 109.085–112.840 | and an endless stream of social media posts. | and an endless stream of social media posts. |
| 113.020–120.915 | But surprisingly, shockingly, this is not candidate A, but candidate B, | But surprisingly, shockingly, this is not candidate A, but candidate B. |
| 120.915–127.960 | the very much disaster-prone Anglo-Irish explorer, Ernest Shackleton. | the very much disaster-prone Anglo-Irish explorer Ernest Shackleton. |
| 128.330–133.365 | Meanwhile, candidate A, the Norwegian Roald Amundsen, | candidates A, the Norwegian Roald Amundsen, |
| 133.365–142.360 | by any metric, the most successful polar explorer to have ever lived, has been largely forgotten. | by any metric, the most successful polar explorer to have ever lived has been largely forgotten. |
| 142.360–147.075 | I did a quick search in my university's library catalog before this talk, | I did a quick search in my university's library catalog before this talk. |
| 147.075–155.800 | and I found no fewer than 26 books that celebrate Shackleton's leadership qualities. | And I found no fewer than 26 books that celebrate Shackleton's leadership qualities. |
| 166.270–172.955 | Why are we obsessed with a mediocre at best leader | Why are we obsessed with a mediocre at best leader? |
| 172.955–176.600 | and overlooking a truly gifted one? | and overlooking a truly gifted one. |
| 176.770–185.825 | Well, I'm a historian who studies leadership, and I'm here to tell you we celebrate the wrong leaders, | So I'm a historian who studies leadership, and I'm here to tell you we celebrate the wrong leaders. |
| 185.825–189.480 | and not just in the realm of polar exploration. | and not just in the realm of polar exploration. |
| 198.270–204.395 | He was born an illiterate slave and rose to become one of the most influential revolutionaries ever | He was born an illiterate slave and rose to become one of the most influential revolutionaries ever. |
| 204.395–208.750 | and outsmarted the biggest empires of the day, including Napoleon's. | and outsmarted the biggest empires of the day, including Napoleon's. |
| 235.090–238.320 | For good reason. We need leaders. | For good reason. We need leaders. |
| 243.780–249.345 | And this, in turn, requires somebody who can motivate them, inspire them, coordinate the work, | And this in turn requires somebody who can motivate them, inspire them, coordinate the work. |
| 249.345–254.240 | deal with whatever hiccups might arise along the way. | deal with whatever hiccups might arise along the way. |
| 263.530–272.735 | And so in this sense, the leaders we celebrate has a direct impact on the success, or as it may be, failure | So in this sense, the leaders we celebrate has a direct impact on the success, or as it may be, failure. |
| 272.735–274.840 | of our greatest endeavors today. | of our greatest endeavors today. |
| 290.560–296.855 | But there's another culprit at work as well, what I like to call the action fallacy, | But there's another culprit at work as well, what I like to call the action fallacy. |
| 296.855–302.365 | our mistaken belief that the best leaders are those who generate the most noise, | Our mistaken belief that the best leaders are those who generate the most noise |
| 302.365–307.800 | action, and sensational activity in the most dramatic circumstances. | action and sensational activity in the most traumatic circumstances. |
| 325.740–333.625 | Imagine leadership for one moment not as a polar explorer charting a new course or a CEO motivating her staff, | Imagine leadership for one moment, not as a polar explorer, charting a new course or a CEO motivating her staff. |
| 333.625–338.920 | but as the simple act of swimming across a river. | but as the simple act of swimming across a river. |
| 350.210–355.465 | If a swimmer ventures in haphazardly without | If a swimmer ventures in haphazardly without... |
| 355.465–365.265 | being aware of his own capabilities or the currents and nearly drowns, but splashes around wildly, | being aware of his own capabilities or the currents and nearly drowns but splashes around wildly |
| 365.265–375.160 | fights with all his strength, and somehow miraculously manages to drag himself back to safety, those of us looking on will notice him. | fights with all his strength and somehow miraculously manages to drag himself back to safety, those of us looking on will notice him. |
| 385.960–392.485 | And if instead we have a swimmer who has studied the river for years | And if instead we have a swimmer who has studied the river for years. |
| 392.485–399.415 | and knows just where and when to enter the water and how to turn her body in subtle ways | and knows just where and when to enter the water, and how to turn her body in subtle ways, |
| 399.415–406.440 | and so lets the current carry her across, we probably won't notice her. | And so let's the current carry her across. We probably won't notice her. |
| 419.790–425.625 | Shackleton, our candidate B, is best known for his ill-fated endurance expedition, | or candidate B, is best known for his ill-fated endurance expedition. |
| 425.625–434.240 | which set off in the summer of 1914 and saw his ship become trapped and eventually crushed by the ice off Antarctica. | which set off in the summer of 1914 and saw his ship become trapped and eventually crushed by the ice of Antarctica. |
| 434.340–438.655 | And he and his men were then forced to undertake a dangerous trek across the ice | The heinous men were then forced to undertake a dangerous trek across the ice. |
| 438.655–446.880 | and brave some of the stormiest seas on Earth before finally reaching the safety of South Georgia in the summer of 1916. | and brave some of the stormiest seas on Earth before finally reaching the safety of South Georgia in the summer of 1916. |
| 494.050–502.055 | Rarely highlighted in the many books that celebrate his leadership qualities is the fact that the expedition's other ship, | What is fairly highlighted in the many books that celebrate his leadership qualities is the fact that the expedition's other ship |
| 502.055–510.120 | the Aurora, suffered an even graver crisis, the result of which was three lost lives. | The aurora suffered an even graver crisis, the result of which was three lost lives. |
| 541.730–548.655 | What the mighty British Navy had failed to do the previous eight decades, to find and navigate the Northwest | British Navy had failed to do the previous eight decades. To find and navigate the Northwest Passage |
| 548.655–552.280 | Passage above the Canadian mainland. | above the Canadian mainland. In 1911. |
| 552.390–561.525 | In 1911, he reached the South Pole, a journey of 3,000 kilometers across hazardous and uncharted terrain, and arrived back | He reached the South Pole, a journey of 3,000 kilometers across hazardous and uncharted terrain, and arrived back at his camp. |
| 561.525–569.480 | at his camp after 99 days, just one day off his planned schedule. | After 99 days, just one day off his planned schedule. |
| 577.750–583.285 | Amundsen is the swimmer who has spent a lifetime humbly studying the river | Amundsenist swimmer who has spent a lifetime humbly studying the river. |
| 583.285–589.190 | before entering the water in just the right spot at just the right time, and so makes it look easy. | Before entering the water in just the right spot at just the right time and so makes it look easy |
| 608.560–614.225 | But it's a dangerous feature in our offices today as well, because after all, | But it's a dangerous feature in our offices today as well. Because after all-- |
| 614.225–623.800 | the same biases and misconceptions that we bring to our reading of the past are one and the same with which we view leadership in our offices today. | The same biases and misconceptions that we bring to our reading of the past are one and the same with which we view leadership in our offices today. |
| 639.900–646.905 | We see leadership potential in people who speak more, regardless of what they say, | We see leadership potential in people who speak more, regardless of what they say. |
| 646.905–652.440 | in people who appear confident, regardless of how competent they are. | in people who appear confident regardless of how competent they are. |
| 669.240–673.185 | In other words, appearing to be a good leader, | In other words, appearing to be a good leader. |
| 673.185–679.400 | rather than actually being one behind the scenes, is the path to fame and bonus and promotion today. | rather than actually being one behind the scenes, is the path to fame and bonus and promotion today. |
| 696.250–705.575 | And perhaps worst of all, it's a self-perpetuating cycle, because by celebrating these flawed action-oriented leaders, | And perhaps worst of all, it's a self-perpetuating cycle, because by celebrating these flawed, action-oriented leaders, |
| 705.575–708.520 | we're actively creating more of them. | we're actively creating more of them. |
| 752.580–759.695 | Since we reward people who are good in crises and ignore people who are such good managers that there are few crises, | Since we reward people who are good in crises and ignore people who are such good managers, that there are few crises. |
| 759.695–764.280 | people soon learn to seek out or reframe situations as crises. | people soon learn to seek out or reframe situations as Christ. |
| 850.680–858.555 | It may not be as exciting as leading a cavalry charge from the front or giving a brash pep talk, | It may not be as exciting as leading a cavalry charge from the front or giving a brash pep talk |
| 858.555–861.110 | but it's the real toolkit of good leaders. | But it's the real toolkit of good lead. |
| 869.640–872.935 | unconcerned with what other people are thinking, | I'm concerned with what other people are thinking. |
| 872.935–880.440 | unconcerned with spilling self-aggrandizing words or exaggerating, such people are truly inspirational. | on concern with spilling self-aggrandizing words or exaggerating, such people are truly inspirational. |
| 900.780–910.225 | So the next time you're in a position to judge or reward a leader, or maybe just the next time, | So the next time you're in a position to judge or reward a leader or Maybe just the next time |
| 910.225–916.320 | you're trying to figure out whose efforts actually guided your team or organization to success. | you're trying to figure out whose efforts actually guided your team or organization to success. |
| 917.360–922.775 | Resist the temptation to be dazzled by tales of adventure and daring do, | Resist the temptation to be dazzled by tales of adventure and daring do. |
| 922.775–927.520 | and take a moment to look below the surface or in the quieter corners of your team. | and take a moment to look below the surface or in the quieter corners of your team. |
| 939.740–946.375 | who do you want in charge? The leader who responds to this ship freezing in place | Who do you want in charge? The leader who responds to the ship freezing in place? |
| 946.375–952.280 | by frantically cranking the engine, unpacking the crates of dynamite, and pushing his men to their breaking point, | by frantically cranking the engine, unpacking the crates of dynamite, and pushing his men to their breaking... |
| 957.580–961.400 | Thank you. (audience applauding) | Thank you. [APPLAUSE] |
