# home-manager/agent-plugins-lib.nix
# Pure helpers: turn a skills repo's `.claude-plugin/marketplace.json` into normalized plugin
# records, so one manifest drives every agent. Two manifest shapes occur:
#   skills mode: `source = "./"` + `skills = [ "./path/to/skill" … ]` (a thin bundle of skill dirs)
#   dir mode:    `source = "./sub/dir"` — the plugin is a directory holding its own `skills/`
{ lib }:
let
  inherit (lib)
    removePrefix
    removeSuffix
    attrNames
    listToAttrs
    nameValuePair
    ;
  rel = p: removeSuffix "/" (removePrefix "./" p);
  join = src: p: if rel p == "" then src else "${src}/${rel p}";
in
{
  normalize =
    {
      src,
      exclude ? [ ],
    }:
    let
      manifest = builtins.fromJSON (builtins.readFile "${src}/.claude-plugin/marketplace.json");
      mk =
        p:
        let
          isDir = rel p.source != "";
          root = if isDir then join src p.source else null;
          skills =
            if isDir then
              listToAttrs (
                map (n: nameValuePair n "${root}/skills/${n}") (
                  attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir "${root}/skills"))
                )
              )
            else
              listToAttrs (map (s: nameValuePair (baseNameOf (rel s)) (join src s)) (p.skills or [ ]));
        in
        {
          inherit (p) name;
          description = p.description or "";
          version = p.metadata.version or "0.0.0";
          author = manifest.owner or null;
          inherit root skills;
          skillNames = attrNames skills;
        };
    in
    map mk (builtins.filter (p: !(builtins.elem p.name exclude)) manifest.plugins);
}
