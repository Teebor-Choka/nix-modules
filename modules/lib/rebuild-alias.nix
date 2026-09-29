# The `rebuild-me` shell alias, shared by the darwin and nixos core modules.
#
# cd into the flake dir before sudo so the rebuild works from ANY directory:
# <tool>-rebuild spawns bash/nix subprocesses as root that inherit the invocation
# cwd, and getcwd() fails there if root can't resolve it — aborting the switch.
# The subshell keeps the caller's cwd untouched.
#
# Pure (no module args) so the regression check in flake.nix can assert the guard
# without instantiating a host. See selfChecks.<sys>.rebuild-alias.
{
  flakeDir,
  tool,
}:
"( cd ${flakeDir} && sudo ${tool}-rebuild switch --flake ${flakeDir} )"
