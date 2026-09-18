---
name: release-evidence
description: Check a packaged Nav Center DMG against the distribution gates and report which are met, unmet, or impossible to establish locally. Use before publishing a beta artifact, tagging a release, or answering whether a build is distributable.
disable-model-invocation: true
---

# Release evidence

`docs/RELEASE.md` and `docs/PUBLIC_RELEASE_CHECKLIST.md` define gates that are
easy to claim and tedious to verify: Developer ID signing, an `Accepted` notary
result, stapling, Gatekeeper acceptance, checksum agreement with the published
sidecar, and the absolute rule that an `-unsigned.dmg` is never distributable.
Source-only CI and the offline dependency-stub tests establish none of them.

## Usage

```sh
bash .claude/skills/release-evidence/verify-artifact.sh /path/to/NavCenter-0.1.0-beta.1-macos-arm64.dmg
```

The script is read-only. It signs nothing, submits nothing to Apple, and never
mounts or modifies the image. It checks the artifact name contract first and
stops immediately on an `-unsigned.dmg`, because no later result can redeem one.

Gates checked: name contract, sha256 and sidecar agreement, `hdiutil verify`,
`codesign --verify --strict`, `Accepted` status in the retained
`.dmg.notary.json`, `stapler validate`, and `spctl` assessment against the
primary signature. Missing sidecars are reported as `MISSING` rather than
silently passing.

## Reporting

The script ends by listing what it cannot establish — clean-machine install,
offline launch with a valid staple, version and workflow confirmation, update and
uninstall/zap scope, every advertised architecture, the minimum supported macOS,
and the secret and private-data scans over tree and history. Reproduce that list
when reporting; a passing script run means the artifact-level gates hold, not
that the build is ready to share.

Pair any result with the source revision and the packaging invocation that
produced the artifact. A failed packaging command must not be treated as a
release even when intermediate files remain on disk.

Human merge and release authority stays with the user: this skill produces
evidence, never a decision to publish, distribute, or submit to Apple.
