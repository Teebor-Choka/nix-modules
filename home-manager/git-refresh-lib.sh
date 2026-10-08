# git-refresh-lib.sh — per-repo update step for `home.gitRefresh` (git-refresh.nix).
#
# Factored out of the activation script so it is unit-testable against throwaway git repos — see
# tests/git-refresh-suite.sh. Sourced by the activation script and by the test; function
# definitions only, no side effects at source time.
#
# Honours GIT (git binary, default `git`) and DRY_RUN_CMD (home-manager's dry-run prefix).

# _git_refresh_default_branch <target> — print the remote's default branch name, or nothing.
#   Reads the local origin/HEAD pointer (no network); falls back to origin/main, origin/master.
_git_refresh_default_branch() {
  local git=${GIT:-git} target=$1 ref b
  ref=$("$git" -C "$target" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || ref=""
  if [ -n "$ref" ]; then printf '%s\n' "${ref#origin/}"; return 0; fi
  for b in main master; do
    if "$git" -C "$target" show-ref -q --verify "refs/remotes/origin/$b"; then
      printf '%s\n' "$b"; return 0
    fi
  done
  return 0
}

# git_refresh_update <target> <label>
#   Run AFTER `git fetch origin`. Never discards local work, never merges non-fast-forward, never
#   rebases.
#   - Default branch not checked out (feature branch or detached HEAD, clean or dirty): advance the
#     local default ref via `fetch origin <b>:<b>` (fast-forward-only; the working tree is not
#     touched). A diverged default is left alone and reported. A local default ahead of origin
#     (unpushed work) is left alone silently.
#   - Checked-out branch with a clean tree: fast-forward to its upstream.
#   - Default branch checked out and dirty: nothing can move; warn with how far behind it is.
git_refresh_update() {
  local git=${GIT:-git} target=$1 label=$2
  local default current before after behind

  default=$(_git_refresh_default_branch "$target")
  current=$("$git" -C "$target" symbolic-ref -q --short HEAD 2>/dev/null || true)
  before=$("$git" -C "$target" rev-parse --short HEAD 2>/dev/null || true)

  if [ -n "$default" ] && [ "$current" != "$default" ] \
    && "$git" -C "$target" show-ref -q --verify "refs/heads/$default"; then
    if "$git" -C "$target" merge-base --is-ancestor "refs/heads/$default" "refs/remotes/origin/$default" 2>/dev/null; then
      # Already equal is a no-op; strictly behind fast-forwards.
      ${DRY_RUN_CMD:-} "$git" -C "$target" fetch --quiet origin "$default:$default" 2>/dev/null \
        || echo "gitRefresh: WARNING $label: could not fast-forward $default" >&2
    elif ! "$git" -C "$target" merge-base --is-ancestor "refs/remotes/origin/$default" "refs/heads/$default" 2>/dev/null; then
      echo "gitRefresh: WARNING $label: $default has diverged from origin/$default - not updated" >&2
    fi
  fi

  if [ -z "$("$git" -C "$target" status --porcelain 2>/dev/null)" ]; then
    if ${DRY_RUN_CMD:-} "$git" -C "$target" merge --ff-only --quiet '@{u}' 2>/dev/null; then
      after=$("$git" -C "$target" rev-parse --short HEAD 2>/dev/null || true)
      if [ "$before" = "$after" ]; then
        echo "gitRefresh: $label up to date ($after)"
      else
        echo "gitRefresh: $label fast-forward $before -> $after"
      fi
    else
      echo "gitRefresh: $label not fast-forwardable — left as-is"
    fi
  else
    echo "gitRefresh: $label has local changes — fetched only"
    if [ -n "$default" ] && [ "$current" = "$default" ]; then
      behind=$("$git" -C "$target" rev-list --count "HEAD..refs/remotes/origin/$default" 2>/dev/null || echo 0)
      if [ "$behind" -gt 0 ]; then
        echo "gitRefresh: WARNING $label: $default is $behind commits behind origin" >&2
      fi
    fi
  fi
  return 0
}
