{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: {
  # https://devenv.sh/packages/
  packages = with pkgs; [
    git

    kubectl
    kubelogin-oidc
    talosctl
    kind
    k3d
    clusterctl

    gum

    helmfile
    kubeseal

    cilium-cli
    hubble
    fluxcd
    kubevirt

    go-task
    just
    sops

    jq # JSON parser (handy for `kubectl` output)
    yq
    gh # GitHub CLI (for auth and repo ops)
  ];

  # https://devenv.sh/languages/
  languages = {
    helm = {
      enable = true;
      plugins = ["helm-diff"];
    };
    opentofu.enable = true;
  };

  treefmt = {
    enable = true;
    config.programs = {
      alejandra.enable = true;
      # yamllint.enable = true;
      # yamlfmt.enable = true;
      prettier.enable = true;
    };
  };

  # https://devenv.sh/git-hooks/
  git-hooks.hooks = {
    treefmt.enable = true;
    k8s-yaml-schema = {
      enable = true;
      description = "Ensure yaml-language-server $schema directives for k8s manifests";
      entry = "python hooks/k8s_yaml_schema.py --config .k8s-schema-hook.yaml";
      types = ["yaml"];
      language = "python";
      extraPackages = with pkgs.python3Packages; [
        ruamel-yaml
        jmespath
      ];
    };
    k8s-namespace-inputs = {
      enable = true;
      description = "Generate ResourceSetInputProvider from kubernetes/apps/*/ directories";
      entry = "python hooks/generate-namespace-rsip.py";
      types = ["yaml"];
      language = "python";
      extraPackages = with pkgs.python3Packages; [
        ruamel-yaml
      ];
    };
  };
}
