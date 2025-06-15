{
	description = "DevShell with Kubernetes tools";

	inputs = {
#		nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
		flake-utils.url = "github:numtide/flake-utils";
	};

	outputs = { self, nixpkgs, flake-utils, ... }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = import nixpkgs {
					inherit system;
				};
			in {
				devShells.default = pkgs.mkShell {
					name = "k8s-devshell";
					packages = with pkgs; [
						kubectl
						kubelogin-oidc

     (wrapHelm kubernetes-helm {
            plugins = with pkgs.kubernetes-helmPlugins; [

              helm-diff

            ];
          })
            helmfile
						kubeseal

						cilium-cli


            sops

						jq    # JSON parser (handy for `kubectl` output)
						yq
						gh    # GitHub CLI (for auth and repo ops)
					];
				};
			});
}
