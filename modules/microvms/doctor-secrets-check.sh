# Guest-side check for `nix-vm doctor --secrets`. Sourced into a bash on the guest after the host
# runs `set -- NAME…`. Prints "NAME length=N" or "NAME MISSING" per variable; never the value.
# Exit 1 if any variable is unset or empty.
[ -r "$HOME/.local/share/injected-env.sh" ] && . "$HOME/.local/share/injected-env.sh"
rc=0
for n in "$@"; do
  v=${!n-}
  if [ -n "$v" ]; then printf '%s length=%d\n' "$n" "${#v}"; else printf '%s MISSING\n' "$n"; rc=1; fi
done
exit $rc
