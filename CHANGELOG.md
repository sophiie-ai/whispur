# Changelog

## [0.13.1](https://github.com/sophiie-ai/whispur/compare/v0.13.0...v0.13.1) (2026-04-16)


### Bug Fixes

* **prompts:** reject question-shaped dictation more firmly ([a22e563](https://github.com/sophiie-ai/whispur/commit/a22e5634938112df35db972328606111c45ada0a))

## [0.13.0](https://github.com/sophiie-ai/whispur/compare/v0.12.0...v0.13.0) (2026-04-16)


### Features

* **prompts:** harden default cleanup prompt ([a1f0b3e](https://github.com/sophiie-ai/whispur/commit/a1f0b3e8ec3c80f9165f512d345528e781134671))

## [0.12.0](https://github.com/sophiie-ai/whispur/compare/v0.11.2...v0.12.0) (2026-04-16)


### Features

* **learning:** non-modal toast for vocabulary suggestions ([9ac55a6](https://github.com/sophiie-ai/whispur/commit/9ac55a64d33761677ced369fcca145a9008e2b62))
* **modes:** dictation modes with per-mode cleanup prompts ([e31e05e](https://github.com/sophiie-ai/whispur/commit/e31e05e773689835b3da161cae45411c1c6163fa))
* **rules:** per-app provider overrides ([a0c3d00](https://github.com/sophiie-ai/whispur/commit/a0c3d00e5c741dfd484b63deed9572e630fccdad))


### Performance

* **app:** defer non-critical launch work off init ([b24c09f](https://github.com/sophiie-ai/whispur/commit/b24c09ff0232ea09300c0c866f842800c2fe1187))
* **audio:** async tap writes, reusable buffers, throttled level ([b08c412](https://github.com/sophiie-ai/whispur/commit/b08c412452c2d3cd146125e5d299d384064a19a2))
* **input:** trim paste latency ([3b42c51](https://github.com/sophiie-ai/whispur/commit/3b42c512b7e91edc74dd390d23fae42950b0ffb8))
* **providers:** persistent URLSession with LLM connection warmup ([2faf94e](https://github.com/sophiie-ai/whispur/commit/2faf94e982993e99783909f26070877a27d50bad))
* **ui:** draw recording waveform via Canvas ([fcd140c](https://github.com/sophiie-ai/whispur/commit/fcd140c8033dc1163f65312f0cbdb915151b98ce))

## [0.11.2](https://github.com/sophiie-ai/whispur/compare/v0.11.1...v0.11.2) (2026-04-16)


### Bug Fixes

* honor cancellation during paste to prevent stale clipboard paste ([52ead24](https://github.com/sophiie-ai/whispur/commit/52ead24fa75e4a5e2b19c056b09788d93269f6b3))

## [0.11.1](https://github.com/sophiie-ai/whispur/compare/v0.11.0...v0.11.1) (2026-04-15)


### Bug Fixes

* single language picker with per-provider resolver ([2fa4b60](https://github.com/sophiie-ai/whispur/commit/2fa4b60d160f6b5f93ee99a3e9105a7d7d07f1bd))

## [0.11.0](https://github.com/sophiie-ai/whispur/compare/v0.10.0...v0.11.0) (2026-04-15)


### Features

* learn corrections from the user's edits (opt-in) ([cb5f54d](https://github.com/sophiie-ai/whispur/commit/cb5f54d64047f991842b504a1b4bdcfb233710c7))

## [0.10.0](https://github.com/sophiie-ai/whispur/compare/v0.9.3...v0.10.0) (2026-04-15)


### Features

* wire custom vocabulary through STT/LLM and allow cancel during post-processing ([102b2b8](https://github.com/sophiie-ai/whispur/commit/102b2b8b486004e4868218d3a7d79b8245df633c))


### Bug Fixes

* add parallel ESC monitor so cancel works inside text inputs ([9701fb6](https://github.com/sophiie-ai/whispur/commit/9701fb69d5fe8daee72c8ef1e5bc89132a1fcf4d))

## [0.9.3](https://github.com/sophiie-ai/whispur/compare/v0.9.2...v0.9.3) (2026-04-15)


### Bug Fixes

* capture audio peak before reset and restore cancel affordances ([b2ed22e](https://github.com/sophiie-ai/whispur/commit/b2ed22e40eb66f52ee13c28bd2c44b5b6c75eba2))

## [0.9.2](https://github.com/sophiie-ai/whispur/compare/v0.9.1...v0.9.2) (2026-04-15)


### Bug Fixes

* lower voice-activity threshold so quiet speech isn't rejected ([4c8e1fe](https://github.com/sophiie-ai/whispur/commit/4c8e1febaa702f9b56b8e05c3ddac62454b36e56))

## [0.9.1](https://github.com/sophiie-ai/whispur/compare/v0.9.0...v0.9.1) (2026-04-15)


### Bug Fixes

* declutter recording overlay and skip STT on silent audio ([4519993](https://github.com/sophiie-ai/whispur/commit/4519993aff152d5773c55261ed3998d7ec820677))

## [0.9.0](https://github.com/sophiie-ai/whispur/compare/v0.8.1...v0.9.0) (2026-04-14)


### Features

* add light-cleanup guardrail and uncertainty clause to default prompt ([42ba2f9](https://github.com/sophiie-ai/whispur/commit/42ba2f92a79452e8c068cda18ce92bccc55a691a))
* wire demo video + screenshots into landing page and README ([e7c65d6](https://github.com/sophiie-ai/whispur/commit/e7c65d641c9957fc5c28c57babd2042882f81033))


### Performance

* compress demo.gif 5.9MB → 1.7MB (72% smaller) ([4663cd2](https://github.com/sophiie-ai/whispur/commit/4663cd247c8c166ed545d61279015605dbd04935))

## [0.8.1](https://github.com/sophiie-ai/whispur/compare/v0.8.0...v0.8.1) (2026-04-14)


### Bug Fixes

* isolate WindowUtilities to MainActor ([3881fd5](https://github.com/sophiie-ai/whispur/commit/3881fd5ddf07a44f436f8008069e7b97ee4edf54))

## [0.8.0](https://github.com/sophiie-ai/whispur/compare/v0.7.0...v0.8.0) (2026-04-14)


### Features

* sharpen default cleanup prompt ([353a9e5](https://github.com/sophiie-ai/whispur/commit/353a9e52c665e3cf70bc7f2b05a12b73794e0b8c))
* show Dock icon while a Whispur window is open ([e81ac2b](https://github.com/sophiie-ai/whispur/commit/e81ac2b7acefd73df0ffdc5e58af5c392154d99b))


### Bug Fixes

* expand default-prompt disclosure hit target ([aa0a3bf](https://github.com/sophiie-ai/whispur/commit/aa0a3bfb933786d2335c284f75aedf7b2c325113))

## [0.7.0](https://github.com/sophiie-ai/whispur/compare/v0.6.2...v0.7.0) (2026-04-14)


### Features

* let users pick up to 3 preferred STT languages ([e07dd40](https://github.com/sophiie-ai/whispur/commit/e07dd40939986e3792b64ccf63db214e8169c11b))
* use Bedrock API key for AWS auth and wire up Bedrock LLM ([70f3b49](https://github.com/sophiie-ai/whispur/commit/70f3b492f719faa80714ae057aa2429808af9290))

## [0.6.2](https://github.com/sophiie-ai/whispur/compare/v0.6.1...v0.6.2) (2026-04-14)


### Bug Fixes

* dismiss menu bar popover and focus window on settings open ([5bb43bb](https://github.com/sophiie-ai/whispur/commit/5bb43bbc914a2a2787ecb2b1b0616474177e11da))

## [0.6.1](https://github.com/sophiie-ai/whispur/compare/v0.6.0...v0.6.1) (2026-04-14)


### Bug Fixes

* make settings sidebar rows fully clickable ([e2a2373](https://github.com/sophiie-ai/whispur/commit/e2a2373b71c25418899a86c8f440a0a5415ccbd6))

## [0.6.0](https://github.com/sophiie-ai/whispur/compare/v0.5.2...v0.6.0) (2026-04-14)


### Features

* add Fn hold threshold, ESC cancel, waveform + silence hints ([4a263ef](https://github.com/sophiie-ai/whispur/commit/4a263ef091c911644b9984154adb8336dd3a76f4))
* add Groq Whisper Large v3 as an STT provider ([55b0c6f](https://github.com/sophiie-ai/whispur/commit/55b0c6f89731e82d00d9fc18d7e349f4b9409887))

## [0.5.2](https://github.com/sophiie-ai/whispur/compare/v0.5.1...v0.5.2) (2026-04-13)


### Bug Fixes

* harden HotkeyManager state access and slow accessibility polling ([31c96fd](https://github.com/sophiie-ai/whispur/commit/31c96fd7f1e5a4c8d2c44c68bcd7d7f30e31de3e))
* log clipboard restore outcomes in TextInjector ([29f34a2](https://github.com/sophiie-ai/whispur/commit/29f34a2dfcd2c01759d61081c8bd945a28b93a72))
* replace force-unwraps in provider endpoint URLs ([ae0831a](https://github.com/sophiie-ai/whispur/commit/ae0831afe63cf5e540321dc3ed9dc6b0bf492acc))
* time out microphone permission requests after 30s ([1fdd694](https://github.com/sophiie-ai/whispur/commit/1fdd6942db0d2e84fc48e8014773a1b472199e5b))

## [0.5.1](https://github.com/sophiie-ai/whispur/compare/v0.5.0...v0.5.1) (2026-04-13)


### Performance

* reduce idle memory footprint ([7570da4](https://github.com/sophiie-ai/whispur/commit/7570da4fbc695473ed9091c001bd8e8509882ee7))

## [0.5.0](https://github.com/sophiie-ai/whispur/compare/v0.4.0...v0.5.0) (2026-04-13)


### Features

* add changelog page rendered from CHANGELOG.md ([0be33b8](https://github.com/sophiie-ai/whispur/commit/0be33b894f64a7b9847eb0c33c534ece30f0d625))
* add landing page for whispur.app ([4f416a0](https://github.com/sophiie-ai/whispur/commit/4f416a0fdea5620607d514b93dd116ac13301d07))
* add Vercel Web Analytics + Speed Insights to landing site ([07ca7c4](https://github.com/sophiie-ai/whispur/commit/07ca7c4dbf85d51a8534fdb5f4b2e149a14f28a7))


### Bug Fixes

* ESC cancels active recording + skip LLM on too-short transcripts ([287559f](https://github.com/sophiie-ai/whispur/commit/287559f7ec80ce90e9ffe1120f2a669843a4933a))
* remove incorrect SRI hash blocking marked.js on changelog page ([5baa468](https://github.com/sophiie-ai/whispur/commit/5baa468c64c7b80060fcf9045b2b3d4a1275b4b4))
* Requests tab layout compressing text into vertical letters ([824f500](https://github.com/sophiie-ai/whispur/commit/824f50082a40a64416a6ec6d7e4753c565396345))
* strip bracketed non-speech annotations from STT output ([fcc8bab](https://github.com/sophiie-ai/whispur/commit/fcc8bab3103a611dfdc726b7306b9824468696da))

## [0.4.0](https://github.com/sophiie-ai/whispur/compare/v0.3.0...v0.4.0) (2026-04-12)


### Features

* fix ElevenLabs 400 + add provider request log ([a3de65d](https://github.com/sophiie-ai/whispur/commit/a3de65dc2a4ee4c0aa4c99bbafceffff504a412f))

## [0.3.0](https://github.com/sophiie-ai/whispur/compare/v0.2.0...v0.3.0) (2026-04-12)


### Features

* app icon, About window, improved metadata and README ([3dfd808](https://github.com/sophiie-ai/whispur/commit/3dfd80848085e1d8c82aa0ad24e5bb706d4e13be))

## [0.2.0](https://github.com/sophiie-ai/whispur/compare/v0.1.0...v0.2.0) (2026-04-12)


### Features

* Sparkle auto-update, onboarding, CI release pipeline ([ff16978](https://github.com/sophiie-ai/whispur/commit/ff1697888f360145e5abc175fc922414d774df85))


### Bug Fixes

* release.yml YAML block scalar indentation ([00853f9](https://github.com/sophiie-ai/whispur/commit/00853f9e9dabead19c470486612c8a487dd0d9ad))
