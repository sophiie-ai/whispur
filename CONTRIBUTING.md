# Contributing

## Development Setup

```bash
brew install xcodegen create-dmg
make generate
make all
```

Whispur targets macOS 14+ and uses XcodeGen to keep the Xcode project reproducible.

## Before Opening a Pull Request

1. Make the smallest coherent change you can.
2. Regenerate the Xcode project if `project.yml` changes.
3. Run `make all`.
4. If release packaging changed, run `./scripts/build-dmg.sh`.
5. Update docs when user-facing behavior changes.

## Style Notes

- Keep SwiftUI and AppKit code explicit and readable.
- Prefer focused changes over broad refactors.
- Do not commit secrets, certificates, or notarization material.
- Keep provider documentation aligned with what is actually implemented.

## Pull Requests

- Describe the user-visible change.
- Call out any permission, signing, or packaging implications.
- Include screenshots for UI changes when possible.
