#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap


# -----------------------------
# Data types
# -----------------------------

@dataclass(frozen=True)
class HrRef:
	namespace: str
	name: str


@dataclass(frozen=True)
class TargetKey:
	hr: HrRef
	controller: str
	container: str


@dataclass
class RecommendedResources:
	req_cpu_cores: Optional[float] = None
	req_mem_bytes: Optional[float] = None
	lim_cpu_cores: Optional[float] = None
	lim_mem_bytes: Optional[float] = None


@dataclass
class HrDocLoc:
	path: Path
	doc_index: int
	doc: CommentedMap


# -----------------------------
# Git helpers
# -----------------------------

def _run(cmd: List[str], *, cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
	return subprocess.run(
		cmd,
		cwd=str(cwd),
		check=check,
		stdout=subprocess.PIPE,
		stderr=subprocess.PIPE,
		text=True,
	)


def _git_root(repo: Path) -> Path:
	p = _run(["git", "-C", str(repo), "rev-parse", "--show-toplevel"], cwd=repo)
	return Path(p.stdout.strip())


def _git_ls_yaml_files(repo_root: Path) -> List[Path]:
	p = _run(
		["git", "-C", str(repo_root), "ls-files", "-z", "--", "*.yml", "*.yaml"],
		cwd=repo_root,
	)
	parts = [x for x in p.stdout.split("\0") if x]
	return [repo_root / x for x in parts]


# -----------------------------
# YAML helpers
# -----------------------------

def _mk_yaml(explicit_start: bool) -> YAML:
	yaml = YAML(typ="rt")
	yaml.preserve_quotes = True
	yaml.width = 4096
	yaml.explicit_start = explicit_start
	# keep mapping indentation sane; ruamel will still mostly preserve what exists
	yaml.indent(mapping=2, sequence=4, offset=2)
	return yaml


def _read_all_yaml_docs(path: Path) -> Tuple[str, List[Any], YAML]:
	raw = path.read_text(encoding="utf-8")
	explicit_start = raw.lstrip().startswith("---")
	yaml = _mk_yaml(explicit_start=explicit_start)
	docs = list(yaml.load_all(raw))
	return raw, docs, yaml


def _dump_all_yaml_docs(yaml: YAML, docs: List[Any]) -> str:
	from io import StringIO
	buf = StringIO()
	yaml.dump_all(docs, buf)
	return buf.getvalue()


def _insert_if_missing(m: CommentedMap, key: str, value: Any, *, after_keys: List[str]) -> None:
	if key in m:
		return
	insert_at = len(m)
	for ak in after_keys:
		if ak in m:
			insert_at = list(m.keys()).index(ak) + 1
	m.insert(insert_at, key, value)


# -----------------------------
# KRR parsing
# -----------------------------

def _safe_float(v: Any) -> Optional[float]:
	if v is None:
		return None
	if isinstance(v, str):
		s = v.strip()
		if s in ("", "?"):
			return None
		try:
			return float(s)
		except ValueError:
			return None
	try:
		return float(v)
	except (TypeError, ValueError):
		return None


def _extract_rec(scan: Dict[str, Any]) -> RecommendedResources:
	"""
	KRR structure we try to support:
	- scan["recommended"]["requests"]["cpu"]["value"]
	- scan["recommended"]["requests"]["memory"]["value"]
	- scan["recommended"]["limits"]["cpu"]["value"]
	- scan["recommended"]["limits"]["memory"]["value"]

	Also handles value == "?" safely.
	"""
	rec = scan.get("recommended") or {}
	out = RecommendedResources()

	def _num(section: str, resource: str) -> Optional[float]:
		if not isinstance(rec, dict):
			return None
		sec = rec.get(section)
		if not isinstance(sec, dict):
			return None
		res = sec.get(resource)
		if not isinstance(res, dict):
			return None
		return _safe_float(res.get("value"))

	out.req_cpu_cores = _num("requests", "cpu")
	out.req_mem_bytes = _num("requests", "memory")
	out.lim_cpu_cores = _num("limits", "cpu")
	out.lim_mem_bytes = _num("limits", "memory")
	return out


def _merge_max(a: Optional[float], b: Optional[float]) -> Optional[float]:
	if a is None:
		return b
	if b is None:
		return a
	return max(a, b)


def _aggregate_krr(json_path: Path, *, min_severity: str) -> Dict[TargetKey, RecommendedResources]:
	"""
	Returns a map:
		(HR ns/name, controller, container) -> max(recommended resources)

	We rely on Flux labels:
	- helm.toolkit.fluxcd.io/name
	- helm.toolkit.fluxcd.io/namespace

	And try to map controller using:
	- app.kubernetes.io/controller
	- app.kubernetes.io/name
	- app.kubernetes.io/instance
	- fallback to object.name
	"""
	data = json.loads(json_path.read_text(encoding="utf-8"))
	scans = data.get("scans") or []
	out: Dict[TargetKey, RecommendedResources] = {}

	severity_rank = {
		"UNKNOWN": -1,
		"OK": 0,
		"GOOD": 0,
		"WARNING": 1,
		"CRITICAL": 2,
	}
	min_rank = severity_rank.get(min_severity.upper(), 1)

	for scan in scans:
		if not isinstance(scan, dict):
			continue
		sev = str(scan.get("severity") or "UNKNOWN").upper()
		if severity_rank.get(sev, -1) < min_rank:
			continue

		obj = scan.get("object") or {}
		labels = obj.get("labels") or {}
		if not isinstance(labels, dict):
			labels = {}

		hr_name = labels.get("helm.toolkit.fluxcd.io/name")
		hr_ns = labels.get("helm.toolkit.fluxcd.io/namespace")
		if not hr_name or not hr_ns:
			continue

		controller = (
			labels.get("app.kubernetes.io/controller")
			or labels.get("app.kubernetes.io/name")
			or labels.get("app.kubernetes.io/instance")
			or obj.get("name")
			or ""
		)
		controller = str(controller)

		# container name is usually scan["container"]; sometimes it may exist under object
		container = scan.get("container") or obj.get("container") or ""
		container = str(container)

		if not controller or not container:
			continue

		rec = _extract_rec(scan)

		# skip entirely empty recs (all unknown)
		if (
			rec.req_cpu_cores is None
			and rec.req_mem_bytes is None
			and rec.lim_cpu_cores is None
			and rec.lim_mem_bytes is None
		):
			continue

		key = TargetKey(hr=HrRef(namespace=str(hr_ns), name=str(hr_name)), controller=controller, container=container)

		prev = out.get(key)
		if prev is None:
			out[key] = rec
		else:
			prev.req_cpu_cores = _merge_max(prev.req_cpu_cores, rec.req_cpu_cores)
			prev.req_mem_bytes = _merge_max(prev.req_mem_bytes, rec.req_mem_bytes)
			prev.lim_cpu_cores = _merge_max(prev.lim_cpu_cores, rec.lim_cpu_cores)
			prev.lim_mem_bytes = _merge_max(prev.lim_mem_bytes, rec.lim_mem_bytes)

	return out


# -----------------------------
# HelmRelease matching
# -----------------------------

def _is_helmrelease(doc: Any) -> bool:
	if not isinstance(doc, dict):
		return False
	if str(doc.get("kind", "")) != "HelmRelease":
		return False
	api = str(doc.get("apiVersion", ""))
	return api.startswith("helm.toolkit.fluxcd.io/")


def _hr_ref_from_doc(doc: Dict[str, Any]) -> HrRef:
	meta = doc.get("metadata") or {}
	name = str(meta.get("name") or "")
	ns = str(meta.get("namespace") or "")
	if not ns:
		ns = "default"
	return HrRef(namespace=ns, name=name)


def _infer_namespace_from_path(repo_root: Path, file_path: Path) -> Optional[str]:
	"""
	Heuristics for common homelab repo layouts:
	- .../apps/<namespace>/<app>/...
	- .../namespaces/<namespace>/...
	"""
	try:
		rel = file_path.relative_to(repo_root)
	except Exception:
		rel = file_path

	parts = list(rel.parts)
	for i, p in enumerate(parts):
		if p == "apps" and i + 1 < len(parts):
			ns = parts[i + 1]
			if ns and ns not in ("base", "common", "_templates", "templates"):
				return ns
		if p in ("namespace", "namespaces") and i + 1 < len(parts):
			ns = parts[i + 1]
			if ns:
				return ns
	return None


def _is_app_template_hr(doc: Dict[str, Any], *, chart_name: str, chartref_kind: str) -> bool:
	spec = doc.get("spec") or {}

	# chartRef style (your repo): spec.chartRef.kind/name
	chart_ref = spec.get("chartRef") or {}
	if isinstance(chart_ref, dict):
		cr_kind = str(chart_ref.get("kind") or "")
		cr_name = str(chart_ref.get("name") or "")
		if cr_kind == chartref_kind and cr_name == chart_name:
			return True

	# chart.spec.chart style: spec.chart.spec.chart
	chart = spec.get("chart") or {}
	if isinstance(chart, dict):
		chart_spec = chart.get("spec") or {}
		if isinstance(chart_spec, dict):
			ch = str(chart_spec.get("chart") or "")
			if ch == chart_name:
				return True

	return False


# -----------------------------
# app-template patching
# -----------------------------

def _cpu_qty(cores: float) -> str:
	# cores -> millicores, round up to avoid undersizing
	m = int(math.ceil(cores * 1000.0))
	if m <= 0:
		m = 1
	if m % 1000 == 0:
		return str(m // 1000)
	return f"{m}m"


def _mem_qty(bytes_val: float) -> str:
	# bytes -> Mi, round up. Use Gi if divisible by 1024Mi.
	mib = int(math.ceil(bytes_val / (1024.0 * 1024.0)))
	if mib <= 0:
		mib = 1
	if mib % 1024 == 0:
		return f"{mib // 1024}Gi"
	return f"{mib}Mi"


def _find_key_by_str(m: CommentedMap, wanted: str) -> Optional[Any]:
	for k in m.keys():
		if str(k) == wanted:
			return k
	return None


def _pick_controller_key(controllers: CommentedMap, wanted: str, hr_name: str) -> Optional[Any]:
	k = _find_key_by_str(controllers, wanted)
	if k is not None:
		return k
	k = _find_key_by_str(controllers, "main")
	if k is not None:
		return k
	k = _find_key_by_str(controllers, hr_name)
	if k is not None:
		return k
	if len(controllers.keys()) == 1:
		return next(iter(controllers.keys()))
	return None


def _pick_container_key(containers: CommentedMap, wanted: str) -> Optional[Any]:
	k = _find_key_by_str(containers, wanted)
	if k is not None:
		return k
	for fb in ("app", "main"):
		k = _find_key_by_str(containers, fb)
		if k is not None:
			return k
	if len(containers.keys()) == 1:
		return next(iter(containers.keys()))
	return None


def _apply_to_hr_doc(
	doc: CommentedMap,
	*,
	target: TargetKey,
	rec: RecommendedResources,
	only_missing: bool,
) -> Tuple[bool, List[str]]:
	changed = False
	notes: List[str] = []

	spec = doc.get("spec")
	if not isinstance(spec, CommentedMap):
		spec = CommentedMap()
		doc["spec"] = spec
		changed = True

	values = spec.get("values")
	if not isinstance(values, CommentedMap):
		values = CommentedMap()
		spec["values"] = values
		changed = True

	controllers = values.get("controllers")
	if not isinstance(controllers, CommentedMap):
		controllers = CommentedMap()
		values["controllers"] = controllers
		changed = True

	ctrl_key = _pick_controller_key(controllers, target.controller, target.hr.name)
	if ctrl_key is None:
		notes.append(f"SKIP: controller {target.controller!r} not found (controllers: {[str(k) for k in controllers.keys()]})")
		return False, notes

	ctrl_def = controllers.get(ctrl_key)
	if not isinstance(ctrl_def, CommentedMap):
		ctrl_def = CommentedMap()
		controllers[ctrl_key] = ctrl_def
		changed = True

	containers = ctrl_def.get("containers")
	if not isinstance(containers, CommentedMap):
		containers = CommentedMap()
		_insert_if_missing(ctrl_def, "containers", containers, after_keys=["pod", "cronjob", "statefulset", "deployment", "type"])
		changed = True

	ctr_key = _pick_container_key(containers, target.container)
	if ctr_key is None:
		notes.append(f"SKIP: container {target.container!r} not found (containers: {[str(k) for k in containers.keys()]})")
		return False, notes

	ctr_def = containers.get(ctr_key)
	if not isinstance(ctr_def, CommentedMap):
		ctr_def = CommentedMap()
		containers[ctr_key] = ctr_def
		changed = True

	resources = ctr_def.get("resources")
	if not isinstance(resources, CommentedMap):
		resources = CommentedMap()
		_insert_if_missing(ctr_def, "resources", resources, after_keys=["securityContext", "probes", "envFrom", "env", "args", "command", "image"])
		changed = True

	def _set(section: str, field: str, new_val: str) -> None:
		nonlocal changed
		sec = resources.get(section)
		if not isinstance(sec, CommentedMap):
			sec = CommentedMap()
			_insert_if_missing(resources, section, sec, after_keys=["requests" if section == "limits" else ""])
			changed = True

		old = sec.get(field)
		if only_missing and old is not None:
			notes.append(f"SKIP: {section}.{field} already set ({old!r})")
			return

		if old != new_val:
			sec[field] = new_val
			changed = True
			notes.append(f"{section}.{field}: {old!r} -> {new_val!r}")

	if rec.req_cpu_cores is not None:
		_set("requests", "cpu", _cpu_qty(rec.req_cpu_cores))
	if rec.req_mem_bytes is not None:
		_set("requests", "memory", _mem_qty(rec.req_mem_bytes))
	if rec.lim_cpu_cores is not None:
		_set("limits", "cpu", _cpu_qty(rec.lim_cpu_cores))
	if rec.lim_mem_bytes is not None:
		_set("limits", "memory", _mem_qty(rec.lim_mem_bytes))

	return changed, notes


# -----------------------------
# Main
# -----------------------------

def main() -> int:
	ap = argparse.ArgumentParser(
		description="Apply KRR resource recommendations to Flux HelmReleases using bjw-s app-template (git-aware).",
	)
	ap.add_argument("--krr-json", required=True, type=Path, help="Path to krr.json (KRR output JSON).")
	ap.add_argument("--repo", default=".", type=Path, help="Path anywhere inside the git repo (default: .).")
	ap.add_argument("--chart-name", default="app-template", help="Chart name to match (default: app-template).")
	ap.add_argument("--chartref-kind", default="OCIRepository", help="chartRef.kind to match (default: OCIRepository).")
	ap.add_argument("--min-severity", default="WARNING", help="Min severity: OK/GOOD/WARNING/CRITICAL (default: WARNING).")
	ap.add_argument("--only-missing", action="store_true", help="Only set fields that are currently missing.")
	ap.add_argument("--no-name-fallback", action="store_true", help="Disable unique name-only matching fallback.")
	ap.add_argument("--write", action="store_true", help="Write changes (default: dry-run).")
	ap.add_argument("--stage", action="store_true", help="git add changed files (implies --write).")
	ap.add_argument("--commit", action="store_true", help="git commit changed files (implies --stage).")
	ap.add_argument("--commit-message", default="chore: apply krr resource recommendations", help="Commit message.")
	args = ap.parse_args()

	if args.commit:
		args.stage = True
	if args.stage:
		args.write = True

	try:
		repo_root = _git_root(args.repo)
	except subprocess.CalledProcessError:
		print("ERROR: not inside a git repo (or git unavailable).", file=sys.stderr)
		return 2

	krr_map = _aggregate_krr(args.krr_json, min_severity=args.min_severity)
	if not krr_map:
		print("No applicable KRR entries found (after severity filter, or missing Flux labels).", file=sys.stderr)
		return 2

	yaml_files = _git_ls_yaml_files(repo_root)
	if not yaml_files:
		print("No tracked YAML files found in repo.", file=sys.stderr)
		return 2

	# Index HelmReleases that match app-template
	hr_index: Dict[HrRef, List[HrDocLoc]] = {}
	hr_index_by_name: Dict[str, List[HrDocLoc]] = {}

	for fp in yaml_files:
		try:
			_, docs, _ = _read_all_yaml_docs(fp)
		except Exception:
			continue

		for i, doc in enumerate(docs):
			if not _is_helmrelease(doc):
				continue
			if not _is_app_template_hr(doc, chart_name=args.chart_name, chartref_kind=args.chartref_kind):
				continue

			ref = _hr_ref_from_doc(doc)
			if not ref.name:
				continue

			# If metadata.namespace missing, infer from path to avoid "default/" mismatches
			meta = doc.get("metadata") or {}
			if (not meta.get("namespace")) and ref.namespace == "default":
				guess = _infer_namespace_from_path(repo_root, fp)
				if guess:
					ref = HrRef(namespace=guess, name=ref.name)

			loc = HrDocLoc(path=fp, doc_index=i, doc=doc)
			hr_index.setdefault(ref, []).append(loc)
			hr_index_by_name.setdefault(ref.name, []).append(loc)

	if not hr_index:
		print("No app-template HelmReleases found in repo (matching chartRef/chart name).", file=sys.stderr)
		return 2

	# We'll lazily load/write files only if we touch them
	changed_files: Dict[Path, Tuple[str, List[Any], YAML]] = {}
	total_changed_targets = 0
	unmatched: List[TargetKey] = []

	def _ensure_loaded(fp: Path) -> Tuple[str, List[Any], YAML]:
		if fp in changed_files:
			return changed_files[fp]
		raw, docs, yaml = _read_all_yaml_docs(fp)
		changed_files[fp] = (raw, docs, yaml)
		return raw, docs, yaml

	for target, rec in krr_map.items():
		locs = hr_index.get(target.hr)

		if not locs and not args.no_name_fallback:
			cands = hr_index_by_name.get(target.hr.name, [])
			if len(cands) == 1:
				locs = cands
				print(f"NOTE: matched {target.hr.namespace}/{target.hr.name} by name-only (manifest likely missing metadata.namespace).")
			else:
				locs = None

		if not locs:
			unmatched.append(target)
			continue

		for loc in locs:
			raw, docs, yaml = _ensure_loaded(loc.path)
			doc = docs[loc.doc_index]
			if not isinstance(doc, CommentedMap):
				continue

			changed, notes = _apply_to_hr_doc(
				doc,
				target=target,
				rec=rec,
				only_missing=args.only_missing,
			)

			if notes:
				print(f"- {target.hr.namespace}/{target.hr.name} controller={target.controller} container={target.container} @ {loc.path.relative_to(repo_root)}")
				for n in notes:
					print(f"\t{n}")

			if changed:
				total_changed_targets += 1

	if unmatched:
		print("\nUnmatched KRR targets (no matching app-template HelmRelease found):", file=sys.stderr)
		for t in unmatched[:200]:
			print(f"\t- {t.hr.namespace}/{t.hr.name} controller={t.controller} container={t.container}", file=sys.stderr)
		if len(unmatched) > 200:
			print(f"\t… and {len(unmatched) - 200} more", file=sys.stderr)

	if total_changed_targets == 0:
		print("\nNo changes needed.")
		return 0

	if not args.write:
		print(f"\nDRY-RUN: would update {len(changed_files)} file(s), {total_changed_targets} target(s). Use --write to apply.")
		return 0

	actually_changed: List[Path] = []
	for fp, (raw, docs, yaml) in changed_files.items():
		new_txt = _dump_all_yaml_docs(yaml, docs)
		if new_txt != raw:
			fp.write_text(new_txt, encoding="utf-8")
			actually_changed.append(fp)

	print(f"\nWROTE: updated {len(actually_changed)} file(s).")

	if args.stage and actually_changed:
		rel_paths = [str(p.relative_to(repo_root)) for p in actually_changed]
		_run(["git", "-C", str(repo_root), "add", "--", *rel_paths], cwd=repo_root)
		print("STAGED: git add on changed files.")

	if args.commit and actually_changed:
		_run(["git", "-C", str(repo_root), "commit", "-m", args.commit_message], cwd=repo_root)
		print("COMMITTED.")

	return 0


if __name__ == "__main__":
	raise SystemExit(main())
