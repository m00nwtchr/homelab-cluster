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

						kubernetes-helm
						kubeseal

						cilium-cli

						jq    # JSON parser (handy for `kubectl` output)
						gh    # GitHub CLI (for auth and repo ops)
					];
				};
			});
}
