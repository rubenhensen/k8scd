#!/usr/bin/env python3
"""Render every Argo CD app in this repo the way Argo CD does and validate
the output with kubeconform, so a broken manifest or a chart bump that no
longer renders fails the PR instead of the sync.

Run from anywhere; needs helm, kustomize, kubeconform, git and PyYAML.
The apps/ chart is rendered first, then every Application found in it and
in the app folders. Sources:
- a chart: helm template with the Application's values, value files and
  parameters
- a path in this repo: helm template (Chart.yaml), kustomize build
  (kustomization.yaml) or the folder's YAML files (directory include and
  exclude)
- a path in another git repository: cloned at targetRevision, then the
  same, with the Application's kustomize patches applied
Every YAML file in the repo is also checked for duplicate keys, which
YAML parsers resolve silently by keeping the last one.
"""
import fnmatch
import os
import pathlib
import subprocess
import sys
import tempfile
import time

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
OWN_REPOS = {"https://github.com/rubenhensen/k8scd.git", "https://github.com/rubenhensen/k8scd"}
SKIP_DIRS = {".git", ".github", "nix-infra-machine", "docs", "tools", "backup-testing"}
# Helm's view of the cluster; the JSON schemas only go up to 1.34.
KUBE_VERSION = "1.36.0"
SCHEMA_VERSION = "1.34.12"
CRD_SCHEMAS = ("https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/"
               "{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")

failures = []


def run(cmd, **kw):
    # Registries rate-limit now and then (ghcr.io answers 429); try again.
    for attempt in range(3):
        try:
            return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout
        except subprocess.CalledProcessError as e:
            transient = any(s in (e.stderr or "") for s in ("429", "toomanyrequests", "timeout", "connection reset"))
            if not transient or attempt == 2:
                raise
            time.sleep(10 * (attempt + 1))


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def construct_mapping(loader, node, deep=False):
    keys = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in keys:
            raise yaml.constructor.ConstructorError(
                None, None, f"duplicate key {key!r}", key_node.start_mark)
        keys.add(key)
    return loader.construct_mapping(node, deep)


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping)


def yaml_files():
    for path in sorted(ROOT.rglob("*.y*ml")):
        rel = path.relative_to(ROOT)
        if rel.parts[0] in SKIP_DIRS or path.suffix not in (".yaml", ".yml"):
            continue
        yield path


def check_duplicate_keys():
    for path in yaml_files():
        if path.parent.name == "templates":  # Helm templates aren't YAML yet
            continue
        try:
            list(yaml.load_all(path.read_text(), Loader=UniqueKeyLoader))
        except yaml.YAMLError as e:
            failures.append(f"{path.relative_to(ROOT)}: {e}")


def validate(label, manifests):
    """kubeconform on rendered manifests; returns the parsed documents."""
    try:
        docs = [d for d in yaml.safe_load_all(manifests) if d]
    except yaml.YAMLError:
        docs = None  # kubeconform reports where
    if docs is not None:
        # Argo CD skips documents that aren't objects, like a values file
        # next to the manifests.
        objects = [d for d in docs if isinstance(d, dict) and "kind" in d]
        if len(objects) < len(docs):
            print(f"  {label}: skipping {len(docs) - len(objects)} document(s) without a kind")
        manifests = yaml.safe_dump_all(objects, sort_keys=False)
    result = subprocess.run(
        ["kubeconform", "-summary", "-output", "text", "-strict",
         "-kubernetes-version", SCHEMA_VERSION, "-ignore-missing-schemas",
         "-schema-location", "default", "-schema-location", CRD_SCHEMAS],
        input=manifests, capture_output=True, text=True)
    lines = [l for l in result.stdout.splitlines() if l.strip()]
    summary = lines[-1] if lines else ""
    print(f"  {label}: {summary.replace('Summary: ', '')}")
    if result.returncode != 0:
        for l in lines[:-1]:
            print(f"    {l}")
        failures.append(f"{label}: {summary or result.stderr.strip()}")
    return docs or []


def helm_template(name, namespace, chart_args, helm):
    with tempfile.TemporaryDirectory() as tmp:
        args = ["helm", "template", helm.get("releaseName", name), *chart_args,
                "--namespace", namespace, "--kube-version", KUBE_VERSION,
                "--include-crds"]
        if helm.get("values"):
            values = pathlib.Path(tmp, "values.yaml")
            values.write_text(helm["values"])
            args += ["-f", str(values)]
        if helm.get("valuesObject"):
            values = pathlib.Path(tmp, "values-object.yaml")
            values.write_text(yaml.safe_dump(helm["valuesObject"]))
            args += ["-f", str(values)]
        for vf in helm.get("valueFiles", []):
            # $values/<path> points at this repo through a source with ref: values
            args += ["-f", str(ROOT / vf.split("/", 1)[1]) if vf.startswith("$") else vf]
        for p in helm.get("parameters", []):
            flag = "--set-string" if p.get("forceString") else "--set"
            args += [flag, f"{p['name']}={p['value']}"]
        return run(args)


def directory(path, spec):
    include = spec.get("include", "*.yaml")
    exclude = spec.get("exclude", "")
    files = sorted(path.rglob("*") if spec.get("recurse") else path.glob("*"))
    docs = []
    for f in files:
        if f.suffix not in (".yaml", ".yml", ".json") or not f.is_file():
            continue
        name = f.name
        if not any(fnmatch.fnmatch(name, g) for g in include.strip("{}").split(",")):
            continue
        if exclude and any(fnmatch.fnmatch(name, g) for g in exclude.strip("{}").split(",")):
            continue
        docs.append(f.read_text())
    return "\n---\n".join(docs)


def kustomize(path, spec):
    if not spec:
        return run(["kustomize", "build", str(path)])
    # The Application's kustomize options on top, as Argo CD does.
    with tempfile.TemporaryDirectory() as tmp:
        k = {"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
             "resources": [os.path.relpath(path, tmp)]}
        for key in ("patches", "images", "namespace", "commonLabels", "namePrefix", "nameSuffix"):
            if key in spec:
                k[key] = spec[key]
        pathlib.Path(tmp, "kustomization.yaml").write_text(yaml.safe_dump(k))
        return run(["kustomize", "build", "--load-restrictor", "LoadRestrictionsNone", tmp])


def render_path(app, src, base):
    path = base / src.get("path", ".")
    namespace = app["spec"]["destination"].get("namespace", "default")
    if (path / "Chart.yaml").exists():
        if (path / "Chart.lock").exists():
            run(["helm", "dependency", "build", str(path)])
        return helm_template(app["metadata"]["name"], namespace, [str(path)], src.get("helm", {}))
    if (path / "kustomization.yaml").exists() or src.get("kustomize"):
        return kustomize(path, src.get("kustomize"))
    return directory(path, src.get("directory", {}))


def render(app, src, clones):
    name = app["metadata"]["name"]
    namespace = app["spec"]["destination"].get("namespace", "default")
    repo = src["repoURL"]
    if src.get("chart"):
        if repo.startswith("http"):
            chart_args = [src["chart"], "--repo", repo]
        else:
            chart_args = [f"oci://{repo.rstrip('/')}/{src['chart']}"]
        chart_args += ["--version", src["targetRevision"]]
        return helm_template(name, namespace, chart_args, src.get("helm", {}))
    if src.get("ref") and "path" not in src:
        return None  # only provides value files
    if repo in OWN_REPOS:
        return render_path(app, src, ROOT)
    key = (repo, src.get("targetRevision", "HEAD"))
    if key not in clones:
        tmp = tempfile.mkdtemp()
        run(["git", "clone", "--quiet", "--depth", "1", "--branch", key[1], repo, tmp])
        clones[key] = pathlib.Path(tmp)
    return render_path(app, src, clones[key])


def applications(docs):
    return [d for d in docs if isinstance(d, dict) and d.get("kind") == "Application"
            and d.get("apiVersion", "").startswith("argoproj.io/")]


def main():
    print("Duplicate keys")
    check_duplicate_keys()

    print("Applications")
    apps = applications(validate("apps (chart)", run(
        ["helm", "template", "apps", str(ROOT / "apps"), "--kube-version", KUBE_VERSION])))
    for path in yaml_files():
        if path.parts[len(ROOT.parts)] == "apps":
            continue
        try:
            apps += applications([d for d in yaml.safe_load_all(path.read_text()) if d])
        except yaml.YAMLError:
            pass  # reported by the duplicate key check or by the app that uses it

    clones = {}
    seen = set()
    for app in sorted(apps, key=lambda a: a["metadata"]["name"]):
        name = app["metadata"]["name"]
        if name in seen:
            continue
        seen.add(name)
        spec = app["spec"]
        sources = spec.get("sources") or [spec["source"]]
        for i, src in enumerate(sources):
            label = name if len(sources) == 1 else f"{name}[{i}]"
            try:
                manifests = render(app, src, clones)
            except subprocess.CalledProcessError as e:
                print(f"  {label}: render failed")
                lines = []
                for line in (e.stderr or e.stdout).strip().splitlines():
                    if not lines or line != lines[-1]:  # Helm repeats schema errors
                        lines.append(line)
                for line in lines[:20]:
                    print(f"    {line}")
                failures.append(f"{label}: render failed")
                continue
            if manifests is not None:
                validate(label, manifests)

    if failures:
        print(f"\n{len(failures)} problem(s):")
        for f in failures:
            print(f"- {f}")
        sys.exit(1)
    print("\nAll apps render and validate.")


if __name__ == "__main__":
    main()
