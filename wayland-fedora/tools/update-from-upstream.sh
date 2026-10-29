#!/bin/bash
# update-from-upstream.sh -- move the Wayland/Qt6 patch set onto the current upstream OpenRV main.
#
#   wayland-fedora/tools/update-from-upstream.sh [--push] [--branch NAME] [--upstream-ref REF] [--no-patches]
#
# What it does (nothing is pushed unless --push is given; `main` is never touched):
#   1. fetches upstream main (remote `upstream`, falling back to `origin`)
#   2. creates a dated branch  wayland-qt6-YYYYMMDD  at the new upstream commit
#   3. replays, one by one, every commit of the current branch that sits on top of the last
#      `upstream-base-*` tag (the six code commits + the docs commits) with `git cherry-pick`
#   4. reports per commit: OK / CONFLICT (+ the conflicting files). A conflicting commit is rolled back
#      (cherry-pick --abort) and listed so you can redo it by hand:  git cherry-pick <hash>, fix, git cherry-pick --continue
#      Later commits are still tried (they often do not depend on the failed one).
#   5. tags the new base  upstream-base-<shorthash>  and regenerates wayland-fedora/patches/ (git format-patch of the
#      code commits + source_patches.diff) in one extra commit, unless --no-patches
#   6. with --push: pushes the branch + tag to the remote `fork` and tells you how to make it the default branch
#
# Afterwards: rebuild (BUILD_NOTES.md; run tools/make_qt_prefix.sh first if Fedora's Qt changed), rerun the checks in
# MAINTENANCE.md, then `gh repo edit homeless3d/OpenRV --default-branch <new branch>` (the old branch stays as history).
set -uo pipefail

PUSH=0; BRANCH=""; UPREF=""; PATCHES=1
while [ $# -gt 0 ]; do
  case $1 in
    --push) PUSH=1;; --branch) BRANCH=$2; shift;; --upstream-ref) UPREF=$2; shift;; --no-patches) PATCHES=0;;
    -h|--help) sed -n 2,22p "$0"; exit 0;; *) echo "unknown option $1" >&2; exit 2;;
  esac; shift
done

cd "$(git rev-parse --show-toplevel)" || exit 1
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "working tree not clean; commit or stash first" >&2; exit 1; }
START=$(git rev-parse --abbrev-ref HEAD)
START_SHA=$(git rev-parse HEAD)

# ---- 1. fetch
REMOTE=upstream; git remote get-url upstream >/dev/null 2>&1 || REMOTE=origin
if [ -z "$UPREF" ]; then
  echo "== fetching $REMOTE main"
  DEPTH=""; [ "$(git rev-parse --is-shallow-repository)" = true ] && DEPTH="--depth=50"
  git fetch $DEPTH "$REMOTE" main || { echo "fetch failed" >&2; exit 1; }
  UPREF=FETCH_HEAD
fi
NEWBASE=$(git rev-parse "$UPREF^{commit}") || exit 1
SHORT=$(git rev-parse --short=7 "$NEWBASE")

# ---- the commits to replay: everything after the newest upstream-base-* tag that is an ancestor of HEAD
OLDTAG=""
for t in $(git tag --list 'upstream-base-*' --sort=-creatordate); do
  git merge-base --is-ancestor "$t" HEAD 2>/dev/null && { OLDTAG=$t; break; }
done
[ -n "$OLDTAG" ] || { echo "no upstream-base-* tag below HEAD; create one: git tag upstream-base-<hash> <upstream commit the branch is based on>" >&2; exit 1; }
OLDBASE=$(git rev-parse "$OLDTAG^{commit}")
if [ "$OLDBASE" = "$NEWBASE" ]; then echo "already based on upstream $SHORT; nothing to do"; exit 0; fi
mapfile -t COMMITS < <(git rev-list --reverse --topo-order "$OLDBASE..HEAD")
echo "== base $OLDTAG -> upstream $SHORT; replaying ${#COMMITS[@]} commits"

# ---- 2. dated branch
BRANCH=${BRANCH:-wayland-qt6-$(date +%Y%m%d)}
git rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null && { echo "branch $BRANCH exists; use --branch" >&2; exit 1; }
git checkout -q -b "$BRANCH" "$NEWBASE" || exit 1

# ---- 3/4. replay
OK=(); FAIL=()
for c in "${COMMITS[@]}"; do
  subj=$(git log -1 --format=%s "$c")
  if git cherry-pick --allow-empty --keep-redundant-commits "$c" >/dev/null 2>&1; then
    echo "  OK        $(git rev-parse --short "$c")  $subj"; OK+=("$c")
  else
    echo "  CONFLICT  $(git rev-parse --short "$c")  $subj"
    git diff --name-only --diff-filter=U | sed 's/^/              /'
    git cherry-pick --abort >/dev/null 2>&1 || git reset -q --hard HEAD
    FAIL+=("$c")
  fi
done

# ---- 5. tag + patches
git tag -f "upstream-base-$SHORT" "$NEWBASE" >/dev/null
if [ $PATCHES = 1 ] && [ ${#OK[@]} -gt 0 ]; then
  PD=wayland-fedora/patches
  if [ -d wayland-fedora ]; then
    mkdir -p $PD; rm -f $PD/0*.patch $PD/source_patches.diff
    git format-patch -q -o $PD "$NEWBASE..HEAD" -- . ':(exclude)wayland-fedora' >/dev/null
    git diff "$NEWBASE..HEAD" -- . ':(exclude)wayland-fedora' > $PD/source_patches.diff
    git add -A $PD
    git commit -q -m "wayland-fedora: regenerate patches against upstream $SHORT

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" && echo "== patches regenerated in $PD"
  fi
fi

# ---- report
echo
echo "== summary: branch $BRANCH on upstream $SHORT   (was $START @ $(git rev-parse --short "$START_SHA"))"
echo "   replayed OK : ${#OK[@]}"
echo "   conflicts   : ${#FAIL[@]}"
for c in "${FAIL[@]}"; do echo "      git cherry-pick $(git rev-parse --short "$c")   # $(git log -1 --format=%s "$c")"; done
[ ${#FAIL[@]} -gt 0 ] && echo "   resolve those by hand on $BRANCH, then rerun the 'regenerate patches' step (see MAINTENANCE.md)."
if [ $PUSH = 1 ]; then
  git push fork "$BRANCH" "upstream-base-$SHORT" && echo "pushed to fork; to publish it as default: gh repo edit homeless3d/OpenRV --default-branch $BRANCH"
else
  echo "   not pushed. Build + verify, then: git push fork $BRANCH upstream-base-$SHORT"
fi
[ ${#FAIL[@]} -eq 0 ]
