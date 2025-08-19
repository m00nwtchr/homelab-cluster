{
  description = "DevShell with Kubernetes tools";

  inputs = {
    #		nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
      };

      xentra = pkgs.stdenv.mkDerivation rec {
        name = "kubectl-xentra-bin-${version}";
        version = "0.0.19";

        src = pkgs.fetchurl {
          url = "https://github.com/xentra-ai/kube-guardian/releases/download/v${version}/advisor-linux-amd64";
          sha256 = "sha256-FC9N7uS2xFEIiuB3OAELSueafYK7uS10chBhm92RO1c=";
        };

        dontUnpack = true;

        installPhase = ''
          mkdir -p $out/bin
          cp ${src} $out/bin/kubectl-xentra
          chmod +x $out/bin/kubectl-xentra
        '';

        meta = with pkgs.lib; {
          description = "A Kubernetes tool leveraging eBPF for advanced Kubernetes security, auto-generating Network Policies, Seccomp Profiles, and more.";
          homepage = "https://github.com/xentra-ai/kube-guardian";
          license = licenses.asl20;
          platforms = platforms.linux;
        };
      };
    in {
      devShells.default = pkgs.mkShell {
        name = "k8s-devshell";
        packages = with pkgs; [
          kubectl
          kubelogin-oidc
          xentra
          talosctl

          (wrapHelm kubernetes-helm {
            plugins = with pkgs.kubernetes-helmPlugins; [
              helm-diff
            ];
          })
          helmfile
          kubeseal

          cilium-cli
          fluxcd

          go-task
          sops

          jq # JSON parser (handy for `kubectl` output)
          yq
          gh # GitHub CLI (for auth and repo ops)
        ];
      };
    });
}
