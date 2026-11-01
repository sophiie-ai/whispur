# Changelog

## [0.23.1](https://github.com/sophiie-ai/whispur/compare/v0.23.0...v0.23.1) (2026-11-01)


### Bug Fixes

* **input:** stop hold-to-talk on Fn release after a missed key event ([#83](https://github.com/sophiie-ai/whispur/issues/83)) ([ce26c82](https://github.com/sophiie-ai/whispur/commit/ce26c824fbbd98f8e92726a8cde4516a7ba0d6ba))
* **settings:** keep the input device picker inside its row ([#84](https://github.com/sophiie-ai/whispur/issues/84)) ([c948c68](https://github.com/sophiie-ai/whispur/commit/c948c686a30bfacc42118de7065746aba0c88578))

## [0.23.0](https://github.com/sophiie-ai/whispur/compare/v0.22.1...v0.23.0) (2026-11-01)


### Features

* **settings:** add per-app writing styles ([#80](https://github.com/sophiie-ai/whispur/issues/80)) ([d88c033](https://github.com/sophiie-ai/whispur/commit/d88c033d2b2560143dabf9cbb542d60d4e8025f1))
* **settings:** add the Dictionary page with term sources ([#79](https://github.com/sophiie-ai/whispur/issues/79)) ([4195ccf](https://github.com/sophiie-ai/whispur/commit/4195ccf8579e09e149ec67ef9b8b8d4857fd351a))
* **settings:** add the settings kit, midnight sidebar and Dictation page ([#77](https://github.com/sophiie-ai/whispur/issues/77)) ([280551f](https://github.com/sophiie-ai/whispur/commit/280551f76677dd8f175205f3d2920c7c8e8adf9c))
* **settings:** restyle the remaining settings pages on the kit ([#78](https://github.com/sophiie-ai/whispur/issues/78)) ([aaaa83a](https://github.com/sophiie-ai/whispur/commit/aaaa83aebbd81d7d6e65d342f77d221b65e7309f))

## [0.22.1](https://github.com/sophiie-ai/whispur/compare/v0.22.0...v0.22.1) (2026-11-01)


### Bug Fixes

* **release:** build releases on the macOS 26 runner ([#75](https://github.com/sophiie-ai/whispur/issues/75)) ([f61c1c9](https://github.com/sophiie-ai/whispur/commit/f61c1c9e23f2a027c0d7a98b0556a0f617bb207d))

## [0.22.0](https://github.com/sophiie-ai/whispur/compare/v0.21.0...v0.22.0) (2026-11-01)


### Features

* **stt:** add Meta Muse as a speech provider with streaming ([#72](https://github.com/sophiie-ai/whispur/issues/72)) ([a5fbcfc](https://github.com/sophiie-ai/whispur/commit/a5fbcfc9f1b1f714a34fab770230a4bc6c56fdc3))
* **stt:** add Mistral Voxtral as a speech provider ([#69](https://github.com/sophiie-ai/whispur/issues/69)) ([28a2940](https://github.com/sophiie-ai/whispur/commit/28a294060bd8e7c0c5d6822adc99705cfcc7f0ce))
* **stt:** default OpenAI to gpt-transcribe and add model pickers ([#68](https://github.com/sophiie-ai/whispur/issues/68)) ([684e64d](https://github.com/sophiie-ai/whispur/commit/684e64d4998ea2b4a20a18221b0088bc634abf75))
* **stt:** stream audio while you talk, starting with ElevenLabs ([#71](https://github.com/sophiie-ai/whispur/issues/71)) ([2c2d478](https://github.com/sophiie-ai/whispur/commit/2c2d47819c43cd6f2dc724acbcda4f5b40d7f7c5))
* **stt:** use SpeechAnalyzer for Apple dictation on macOS 26 ([#70](https://github.com/sophiie-ai/whispur/issues/70)) ([c8c971a](https://github.com/sophiie-ai/whispur/commit/c8c971a3199dc8e7c663685f82112f65501a48c5))

## [0.21.0](https://github.com/sophiie-ai/whispur/compare/v0.20.1...v0.21.0) (2026-11-01)


### Features

* **pipeline:** rewrite the default cleanup prompt and add a cleanup eval set ([#66](https://github.com/sophiie-ai/whispur/issues/66)) ([a2c88c6](https://github.com/sophiie-ai/whispur/commit/a2c88c68426bc11c6423a6d70db2b5925bfa4286))


### Bug Fixes

* **pipeline:** move cleanup to current models and stop losing dictations ([#65](https://github.com/sophiie-ai/whispur/issues/65)) ([738cf86](https://github.com/sophiie-ai/whispur/commit/738cf86aa58e2e7a566477f1fc4362f1a5c73598))
* **ui:** close the menu bar window when checking for updates ([#63](https://github.com/sophiie-ai/whispur/issues/63)) ([bdb764c](https://github.com/sophiie-ai/whispur/commit/bdb764ce8910ff8ac7ceaa7e1cf3df56195251b9))

## [0.20.1](https://github.com/sophiie-ai/whispur/compare/v0.20.0...v0.20.1) (2026-10-31)


### Bug Fixes

* **input:** make Command + Fn the default hands-free shortcut again ([#61](https://github.com/sophiie-ai/whispur/issues/61)) ([fe9fa18](https://github.com/sophiie-ai/whispur/commit/fe9fa1883f0cb3b4bc50eebdd8932607f1f9bd18))

## [0.20.0](https://github.com/sophiie-ai/whispur/compare/v0.19.0...v0.20.0) (2026-10-31)


### Features

* **input:** add double-press Fn as the default hands-free shortcut ([#59](https://github.com/sophiie-ai/whispur/issues/59)) ([66473cd](https://github.com/sophiie-ai/whispur/commit/66473cd717d9a0c08c45f062d7b3f6b846880f19))

## [0.19.0](https://github.com/sophiie-ai/whispur/compare/v0.18.0...v0.19.0) (2026-10-31)


### Features

* **ui:** redesign the settings header and provider key setup ([#56](https://github.com/sophiie-ai/whispur/issues/56)) ([ea745bc](https://github.com/sophiie-ai/whispur/commit/ea745bce8c7104ca963aa1c085bead982fda84b2))


### Bug Fixes

* **ui:** give the menu bar window a cohesive canvas and fix dark-mode contrast ([#55](https://github.com/sophiie-ai/whispur/issues/55)) ([cb87e4c](https://github.com/sophiie-ai/whispur/commit/cb87e4c4fff05e00b104d899affe4b50974d3a84))

## [0.18.0](https://github.com/sophiie-ai/whispur/compare/v0.17.0...v0.18.0) (2026-10-31)


### Features

* **brand:** new speak to cursor app icon ([#52](https://github.com/sophiie-ai/whispur/issues/52)) ([fa0955f](https://github.com/sophiie-ai/whispur/commit/fa0955fec76a5a2e59d99b7ed232eec2fbeb8df7))
* **site:** revamp whispur.app with the Sophiie design system ([#50](https://github.com/sophiie-ai/whispur/issues/50)) ([5fd6fb5](https://github.com/sophiie-ai/whispur/commit/5fd6fb5f8a25790576e8e44c4f5165fad566ee8c))
* **ui:** restyle the app with the Sophiie theme ([#51](https://github.com/sophiie-ai/whispur/issues/51)) ([e4a502e](https://github.com/sophiie-ai/whispur/commit/e4a502e85e576824749c5e74f5bf1fe1e3be7687))

## [0.17.0](https://github.com/sophiie-ai/whispur/compare/v0.16.1...v0.17.0) (2026-10-20)


### Features

* custom model override for every LLM cleanup provider ([#48](https://github.com/sophiie-ai/whispur/issues/48)) ([eb8c62f](https://github.com/sophiie-ai/whispur/commit/eb8c62f21f1816eaa2951ce0f88528d252517a3c))

## [0.16.1](https://github.com/sophiie-ai/whispur/compare/v0.16.0...v0.16.1) (2026-05-26)


### Bug Fixes

* **pipeline:** harden LLM cleanup against assistant replies ([#45](https://github.com/sophiie-ai/whispur/issues/45)) ([848617d](https://github.com/sophiie-ai/whispur/commit/848617ddc26453b810393eabc3daa3d6a01bff7b))

## [0.16.0](https://github.com/sophiie-ai/whispur/compare/v0.15.1...v0.16.0) (2026-05-23)


### Features

* add compact recording overlay option ([#44](https://github.com/sophiie-ai/whispur/issues/44)) ([3ea1d7c](https://github.com/sophiie-ai/whispur/commit/3ea1d7cb861ac05b8adc78a15d95f0d41e29cd0a))
* mute system audio while recording ([#42](https://github.com/sophiie-ai/whispur/issues/42)) ([7d2fb55](https://github.com/sophiie-ai/whispur/commit/7d2fb55b0b3e92fbbce3e130d0cca857001ab38a))

## [0.15.1](https://github.com/sophiie-ai/whispur/compare/v0.15.0...v0.15.1) (2026-05-18)


### Bug Fixes

* cancel hold arm when modifier is used as a chord ([#40](https://github.com/sophiie-ai/whispur/issues/40)) ([ea407aa](https://github.com/sophiie-ai/whispur/commit/ea407aa5442123bad5855ce58720a764f6f2c928))

## [0.15.0](https://github.com/sophiie-ai/whispur/compare/v0.14.1...v0.15.0) (2026-05-17)


### Features

* stats-first menu bar with shareable weekly recap ([#38](https://github.com/sophiie-ai/whispur/issues/38)) ([597dcac](https://github.com/sophiie-ai/whispur/commit/597dcac1558a0f8b496e4aedd0f93a56a9bcedea))

## [0.14.1](https://github.com/sophiie-ai/whispur/compare/v0.14.0...v0.14.1) (2026-05-12)


### Bug Fixes

* harden OpenAI provider settings ([#33](https://github.com/sophiie-ai/whispur/issues/33)) ([1bb4f00](https://github.com/sophiie-ai/whispur/commit/1bb4f0067b3dfcee14cec49ae2e2d9bd1587e7e3))
* run cleanup for Japanese transcripts ([#32](https://github.com/sophiie-ai/whispur/issues/32)) ([00efb64](https://github.com/sophiie-ai/whispur/commit/00efb64d220439a00f504345a044a8b9522ed324))

## [0.14.0](https://github.com/sophiie-ai/whispur/compare/v0.13.4...v0.14.0) (2026-05-10)


### Features

* allow custom OpenAI-compatible base URL for STT and LLM ([#30](https://github.com/sophiie-ai/whispur/issues/30)) ([e9c9a48](https://github.com/sophiie-ai/whispur/commit/e9c9a485644448df35af7e8475e4decee08df0d2))
* let users pick which microphone Whispur records from ([#29](https://github.com/sophiie-ai/whispur/issues/29)) ([c12e61a](https://github.com/sophiie-ai/whispur/commit/c12e61a81ccf03bab25600c681dfb85a503e747a))

## [0.13.4](https://github.com/sophiie-ai/whispur/compare/v0.13.3...v0.13.4) (2026-04-17)


### Bug Fixes

* **pipeline:** tighten pre-STT voice-activity gate ([2260202](https://github.com/sophiie-ai/whispur/commit/2260202687cee556aec5acbaff4d039b8d326301))

## [0.13.3](https://github.com/sophiie-ai/whispur/compare/v0.13.2...v0.13.3) (2026-04-17)


### Bug Fixes

* **pipeline:** dismiss overlay silently on no speech ([21811a9](https://github.com/sophiie-ai/whispur/commit/21811a988c8ed81b65488bc65457f85a8fd0f0b8))

## [0.13.2](https://github.com/sophiie-ai/whispur/compare/v0.13.1...v0.13.2) (2026-04-17)


### Bug Fixes

* **pipeline:** filter known Whisper silence hallucinations ([a4ed421](https://github.com/sophiie-ai/whispur/commit/a4ed4210e9abe1faa6e56a67b265ee081acdb5ab))

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
