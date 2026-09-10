# Conservative clause-only splitting

This revision supersedes the ordinary-word and comma fallback in the earlier long-sentence experiment.

## Behavior

- A pause alone or comma alone can no longer propose an automatic boundary.
- A proposal starts at an explicit conjunction/contrast/subordinator and requires recognizable subject-predicate evidence on each side. Conjunctions stay on the right.
- Simple noun/adjective coordination, lists, shared-subject coordinated verbs, and correlative forms (either/or, neither/nor, not only/but also) are preserved. Adverb-verb and adjective-noun gaps have no candidate rule.
- Ambiguous structures are left whole, even over 10 seconds. The structural recognizer is intentionally a small conservative English heuristic, not a general syntactic parser. It recognizes pronouns, a limited set of determiner subjects and finite predicates; many legitimate clause boundaries are deliberately missed.
- Existing timing/confidence checks, >=120 ms low-energy corridor, and constrained downstream fine adjustment remain. Structure is checked before energy. There is no ordinary-word fallback regardless of silence length.
- Existing saved segments are not silently recombined. Use **Redo segments** to regenerate an existing lesson under the new rule; that operation also replaces manual segmentation.

## Actual supplied-audio experiment

Replayed the saved real Pixel Small token output through the final code with the full decoded audio energy. The original 88.130–112.015 sentence now splits only at:

- 88.130–95.675 (7.545 seconds): `Well, both ... heroic age of polar exploration,`
- 95.675–112.015 (16.340 seconds): `and in the century since one of them has been consistently celebrated ... books, blogs, documentaries, podcasts, and an endless stream of social media posts.`

This preserves `consistently celebrated`, `leadership role model` and the entire list. The old `since / one` and `blogs / documentaries` proposals are no longer allowed. Actual PCM cut at these final times was independently transcribed with the same Small English CPU model on the host:

> Well, both of these men were real polar explorers who lived during the so-called heroic age of polar exploration.

> And in the century since, one of them has been consistently celebrated as a leadership role model in best-selling books, blogs, documentaries, podcasts, and an endless stream of social media posts.

These are fresh recognition results, not cached text; the two files were decoded in about 7 seconds wall time. This revision was not separately exercised on Pixel; the source transcript came from the prior Pixel reproduction, and fresh recognition here ran on the host.

## Whole-article audit

Reused the actual full-article Small transcript, avoiding model/punctuation differences between heuristic comparisons. The 125 baseline sentence cuts become **128**, with **30** still over 10 seconds (baseline 33). Only three additional clause boundaries qualify:

- 179.845 seconds: `... leadership, / and I'm here to tell you ...`
- 858.555 seconds: `... pep talk, / but it's the real toolkit ...`
- 906.985 seconds: `... reward a leader, / or maybe just the next time, you're trying ...`

The host whole-file transcript punctuates the target paragraph differently from Pixel; it already ends a sentence at exploration. Its following sentence remains intact. This audit is deliberately more conservative than the previous 160-cut result. It does not claim all surviving long spans are continuous speech, or that the heuristic is a complete parser.

## Regression validation

Twenty focused tests passed, including real target token conservation, acoustic protection, manual-cut preservation, persistence/idempotence, ordinary coordination, list commas, shared-subject predicates, correlatives and positive explicit and/but/or clauses. Full analysis/test/build/signing results are recorded in agents.md. Local corpus outputs and fresh recognition are under artifacts/long-sentence-small/conservative-*.
