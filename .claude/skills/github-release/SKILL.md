---
name: github-release
description: Publishes a Whisperer build as a real GitHub release — everything merged to main and pushed, a git tag on the exact built commit, a published (never draft) release with the zip and release log attached, verified. Use when the user says "release to GitHub", "upload the release", "publish the build", "merge to main and release", or after /local when they want the build on GitHub.
---

# github-release — publish a build to GitHub properly

A release is **published**, **tagged at the commit that was built**, and **has the zip attached**.
Never leave a draft and never use an `untagged-…` URL: those are invisible to everyone but the
owner and were the mistake this skill exists to prevent (nine of them piled up on 2026-11-09…12).

Repo: `mralexivy/whisperer` (**public**), default branch `main`. `gh` is logged in as `mralexivy`.
Only publish when the user asked for a release in this turn — a public release is outward-facing.

## 1. Everything merged to main and pushed

```bash
git status -sb                 # on main; nothing tracked left uncommitted
git fetch origin
git log --oneline origin/main..main    # unpushed commits → push them
git log --oneline main..origin/main    # must be empty (else: pull --rebase first)
git push origin main
```

- Untracked files that are the user's own data (`Tools/omni-eval/results/dictation-*.jsonl`,
  transcripts, recordings) are **never** committed or attached.
- Work on another branch that belongs in the release is merged into `main` first
  (`git merge --no-ff <branch>`), tested, then pushed. Branches that are other people's / other
  features (`feature/*`, worktrees) are left alone unless the user names them.
- Before building, list what is *not* in main: `git branch -a --no-merged main` and
  `git cherry main <branch>` (a `+` line is a patch main does not have). Report each one in the
  release message — "left out on purpose: …" — and ask before merging work from another feature.
- Build from the pushed commit: `SHA=$(git rev-parse HEAD)` and `git status` clean of tracked changes.

## 2. Build the artifact

Run the `/local` steps (clean Release build, `~/Downloads/Whisperer.zip`,
`~/Downloads/Whisperer-release-log.txt`). The log header names version and build.

## 3. Create the release — published, tagged, attached

```bash
TAG="local-$(date +%Y-%m-%d-%H%M)"            # local builds; App Store builds are not GitHub releases
SHA=$(git rev-parse HEAD)
VERSION=…; BUILD=…                             # from Info.plist, as in /local
gh release create "$TAG" ~/Downloads/Whisperer.zip \
  --repo mralexivy/whisperer \
  --target "$SHA" \
  --title "Whisperer $VERSION (build $BUILD) — local build $(date '+%Y-%m-%d %H:%M')" \
  --notes-file ~/Downloads/Whisperer-release-notes.md \
  --prerelease
```

- **No `--draft`.** `--prerelease` because the build is unsigned and has every feature on (not the App Store build);
  drop it only if the user wants it as "Latest".
- `--target "$SHA"` is the exact commit built, not the moving `main`.
- The notes are a **real changelog**, not the `/local` one-line log: everything merged to `main` since
  the last *published* release (or, if there is none, since the start of the version line), grouped by
  area — new in this build, then older days, developer notes, known limits. Write it from
  `git log --since=<date> --no-merges --format='%ad %s'` and the plan/knowledge docs; user-visible
  wording, measured numbers where they exist. Save it to `~/Downloads/Whisperer-release-notes.md`
  and pass `--notes-file` that file. A 15-line commit list is not a changelog.

## 4. Verify — do not report success from the command's exit code

```bash
gh release view "$TAG" --repo mralexivy/whisperer \
  --json tagName,isDraft,isPrerelease,targetCommitish,url,assets \
  --jq '{tagName,isDraft,isPrerelease,targetCommitish,url,asset:(.assets[0]|{name,size,state})}'
git ls-remote --tags origin "$TAG"      # the tag exists on the remote and equals $SHA
git log -1 --format=%H origin/main      # main on the remote is the released commit (or ahead of it)
```

Required: `isDraft: false`, `targetCommitish == $SHA`, asset `state: "uploaded"` with the expected size,
the tag present on the remote. The URL to give the user is
`https://github.com/mralexivy/whisperer/releases/tag/$TAG` (never an `untagged-…` URL), and the download is
`https://github.com/mralexivy/whisperer/releases/download/$TAG/Whisperer.zip`.

## 5. Report

One short message: tag, commit, URL, asset size, "main is pushed at <sha>", and anything left
unmerged on purpose. If a draft or untagged release already exists from an earlier run, say so and
offer to publish or delete it — do not delete releases unasked.

## Fixing a wrong release

- Draft → `gh release edit "$TAG" --repo mralexivy/whisperer --draft=false --prerelease --target "$SHA"`
  (this creates the tag at `$SHA` on the remote).
- Wrong asset → `gh release upload "$TAG" file --clobber`.
- Wrong tag/commit → `gh release delete "$TAG" --cleanup-tag --yes`, then create again (ask first).
