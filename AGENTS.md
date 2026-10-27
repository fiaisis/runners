# AGENTS.md

Operational guidance for AI agents and developers working in the `runners` repository.

---

## 1. Repository Purpose

This repository is, first and foremost, **a build-and-publish pipeline for container images**, not an
application. Its entire job is to build the Mantid and Mantid Imaging runner images used to execute
reduction and imaging scripts across the FIA system, and publish them to the GitHub Container
Registry at `ghcr.io/fiaisis/mantid` and `ghcr.io/fiaisis/mantid-imaging`. There is no application
service, API, or queue consumer here — only Dockerfiles, helper scripts for building/inspecting
image digests, and the CI workflows that rebuild and propagate new runner images. See `README.md`
for the project description.

---

## 1.1 Position in the FIA service

### Overarching FIA architecture

FIA is a multi-repository system (all checked out as siblings under the same parent workspace
directory) that automatically reduces instrument data, and also lets users browse, plot, and rerun
that data interactively:

```text
[ISIS Instrument Archive (/archive, /imat) & lastrun.txt]
        │
        ▼
  file-watcher (Kopf Operator + Per-Instrument Watcher Pods)
        │  publishes file path to RabbitMQ: `watched-files`
        ▼
  run-detection ◄──── fetches instrument rules (`GET /instrument/{inst}/specification`) ────► FIA-API
        │  ingests .nxs metadata, verifies rules, publishes JobRequest JSON
        │  to RabbitMQ: `scheduled-jobs` (or retries via `failed-watched-files`)
        ▼
  jobcontroller (job_creator) ◄──── requests PreScript (`GET /script/{inst}`) & posts Job ──► FIA-API ◄──► autoreduction-scripts
        │  spawns Kubernetes Job in cluster:
        ├──► Main container: runners (THIS REPO) (`ghcr.io/fiaisis/mantid` or `mantid-imaging`) -> writes reduced data to `/ceph`
        └──► Sidecar container: jobcontroller (job_watcher) -> updates job status/outputs in FIA-API (`PATCH /job/{id}`)

[Interactive / Web & Live Data Paths]
  scigateway (Host App) ──► frontend (FIA React Plugin)
                                ├──► fia-auth (UOWS login, JWT verify/refresh, `/experiments` RB lookup)
                                ├──► FIA-API (runs, jobs, scripts, specifications, reruns -> `watched-files` / `scheduled-jobs`)
                                └──► plotting-service (h5grove NeXus/HDF5 & IMAT image serving from `/ceph` & `/imat`)

  Kafka (`<INST>_events`, `<INST>_sampleEnv`, `<INST>_runInfo`)
        └──► live-data (Live Data Operator + Mantid Live Data Processor fetching `/live-data/{inst}/script` from FIA-API)

  LLSP (Long Lived Script Processors: `LLSP-API` + RabbitMQ + Celery `LLSP-Worker` built on `ghcr.io/fiaisis/mantid` — THIS REPO)

[Infrastructure & Deployment]
  k8s (Terraform + Ansible for OpenStack clusters, Redpanda, local Minikube)
  gitops (ArgoCD App-of-Apps & Kustomize `base`/`envs`/`variants` manifests for all FIA services)
```

### This repository's location (upstream, downstream & siblings)

- **Role**: Supplies the `ghcr.io/fiaisis/mantid` and `ghcr.io/fiaisis/mantid-imaging` container
  images (both pre-loaded with the `python -c "$@"` entrypoint contract) that the rest of the FIA
  system pulls to execute reduction and imaging jobs.
- **Upstream triggers**: A daily cron (`18 14 * * *`) and pushes to this repo
  (`.github/workflows/build-and-push.yml`) query `mantidproject/mantid`'s latest GitHub release and
  compare it against existing tags on `ghcr.io/fiaisis/mantid`, building and pushing a new image
  when a new release tag is found.
- **Downstream consumers (who uses images built here)**:
  - `jobcontroller`'s `job_creator` (`../jobcontroller`) — spawns Kubernetes Jobs using
    `ghcr.io/fiaisis/mantid` or `ghcr.io/fiaisis/mantid-imaging` as the main container image.
  - `gitops` (`../gitops`) — `components/jobcreator/{base,envs}/jobcreator.yml` pins
    `DEFAULT_RUNNER_SHA` / `IMAGING_RUNNER_SHA`. On a new Mantid build, `build-and-push.yml`
    automatically clones `fiaisis/gitops`, updates `DEFAULT_RUNNER_SHA` in
    `./components/jobcreator/envs/staging/jobcreator.yml`, and pushes.
  - `LLSP` (`../LLSP`) — `LLSP-Worker/Dockerfile` uses `FROM ghcr.io/fiaisis/mantid:<VERSION>`,
    which `build-and-push.yml` also updates and pushes automatically.
- **Sibling repositories to check when changing contracts**: `../jobcontroller` and `../gitops`
  (image tag/digest consumers and the entrypoint contract `python -c "$@"`), and `../LLSP`
  (`LLSP-Worker`'s base image).

---

## 2. Repository Structure & Runner Architectures

```
mantid/                      Mantid runner Dockerfile and Mantid.user.properties configuration
mantid-imaging/              Mantid Imaging (CUDA GPU) runner Dockerfile
.github/workflows/           CI/CD workflows: automated Mantid image build/push + downstream sync,
                              and monthly/push activity keep-alive workflow
Root helper scripts          Shell and Python utilities for batch building images and resolving
                              GHCR image tags to sha256 manifest digests
```

### 2.1 Mantid Runner (`mantid/`)
- **Base image:** `condaforge/miniforge3` (see `mantid/Dockerfile` for the pinned tag).
- **Build argument:** `MANTID_VERSION` (`mamba create -y -n mantid -c mantid -c conda-forge mantid=${MANTID_VERSION} requests`).
- **Key components:**
  - Installs `libgl1` (apt) and `mantid=${MANTID_VERSION}`, `requests` via `mamba`.
  - Copies `mantid/Mantid.user.properties` to `/root/.mantid/Mantid.user.properties`, which sets:
    - `default.facility=ISIS` and `default.instrument=MARI`
    - `Q.convention = Inelastic`
    - `datasearch.directories=/archive;/archive/data` and `datasearch.searcharchive=all`
    - `defaultsave.directory=/output`
    - `logging.loggers.root.level=error`
    - `UpdateInstrumentDefinitions.OnStartup=0` and `usagereports.enabled=0`
  - Replaces `/opt/conda/envs/mantid/instrument` by cloning the latest instrument definitions from
    `https://github.com/mantidproject/mantid` (default branch) at Docker build time.
- **Entrypoint:** `/entrypoint.sh` executing `python -c "$@"` with `/opt/conda/envs/mantid/bin` on
  `PATH`.

### 2.2 Mantid Imaging Runner (`mantid-imaging/`)
- **Base image:** `nvidia/cuda` Ubuntu runtime for GPU-accelerated reconstruction (see
  `mantid-imaging/Dockerfile` for the pinned CUDA/Ubuntu tag and `MINIFORGE_VERSION` build arg).
- **Key components:**
  - Installs `wget`, `bzip2`, `ca-certificates`, `git`, `tini` via `apt-get`, then installs
    Miniforge3 into `/opt/conda`.
  - Creates the `mantidimaging` conda environment from upstream
    `https://raw.githubusercontent.com/mantidproject/mantidimaging/stable/environment.yml` plus
    `requests` and `opencv` from `conda-forge`.
- **Entrypoint:** `/entrypoint.sh` executing `python -c "$@"` with
  `/opt/conda/envs/mantidimaging/bin` on `PATH`.

---

## 3. Common Operational Commands

### 3.1 Local Docker Builds

**Build Mantid Runner:**
```bash
docker build . -f ./mantid/Dockerfile -t ghcr.io/fiaisis/mantid:<VERSION> --build-arg="MANTID_VERSION=<VERSION>"
```
*(Note: Always use lowercase `./mantid/Dockerfile`. The legacy helper script `build_all_images.sh`
contains `./Mantid/Dockerfile` with an uppercase `M`, which fails on case-sensitive Linux filesystems
unless corrected.)*

**Build Mantid Imaging Runner:**
```bash
docker build . -f ./mantid-imaging/Dockerfile -t ghcr.io/fiaisis/mantid-imaging:latest
```

### 3.2 Testing Image Execution

Run a one-line Python snippet through the container entrypoint:
```bash
# Mantid runner version check
docker run --rm ghcr.io/fiaisis/mantid:<VERSION> "import mantid; print(mantid.__version__)"

# Mantid imaging runner version check (add `--gpus all` when testing on a GPU host)
docker run --rm ghcr.io/fiaisis/mantid-imaging:latest "import mantidimaging; print(mantidimaging.__version__)"
```

### 3.3 Inspecting GHCR Image Digests

`get_runner_sha256.py` and `tag_to_sha256.sh` query `ghcr.io/v2/fiaisis/mantid/manifests/<tag>` and
compute the `sha256` digest of the manifest (update the hardcoded version list inside either script
when inspecting newer tags):
```bash
python3 get_runner_sha256.py
# or
bash ./tag_to_sha256.sh
```

### 3.4 Updating Instrument Definition Files (IDFs)

Mantid runner images disable automatic startup IDF downloads
(`UpdateInstrumentDefinitions.OnStartup=0` in `mantid/Mantid.user.properties`). Instead, current
IDFs are cloned from `https://github.com/mantidproject/mantid` directly into
`/opt/conda/envs/mantid/instrument` at Docker build time.

When an instrument's IDF is updated upstream and must be deployed without a new Mantid release:
1. Rebuild and push the container with a **bumped patch number** in the container tag while keeping
   `MANTID_VERSION` set to the desired Mantid release.
2. **Version Parity Note:** This breaks the 1:1 mapping between the container image tag and the
   installed Mantid conda package version.

**Example:**
To release updated IDFs for Mantid `6.9.1`, build and tag a container as `6.9.2`:
```bash
docker build . -f ./mantid/Dockerfile \
  -t ghcr.io/fiaisis/mantid:6.9.2 \
  --build-arg="MANTID_VERSION=6.9.1"

docker push ghcr.io/fiaisis/mantid:6.9.2
```
After pushing, propagate the new image digest to `fiaisis/gitops` (jobcreator) and `fiaisis/LLSP` as
needed.

### 3.5 Verifying Included Instrument Definition Files (IDFs)

To confirm that a newly built container includes a specific IDF update, inspect
`/opt/conda/envs/mantid/instrument/`.

**Example: Verifying the latest GEM IDF:**

- **Option A: Via Python entrypoint (recommended, matches container contract):**
  ```bash
  docker run --rm ghcr.io/fiaisis/mantid:<VERSION> '
  from pathlib import Path
  import sys

  inst_dir = Path("/opt/conda/envs/mantid/instrument")
  matches = sorted(inst_dir.glob("*GEM*2026*.xml"))

  if not matches:
      print("FAIL: No 2026 GEM IDF found!", file=sys.stderr)
      sys.exit(1)

  print(f"SUCCESS: Found GEM IDF(s): {[m.name for m in matches]}")
  '
  ```

- **Option B: Querying Mantid ConfigService:**
  ```bash
  docker run --rm ghcr.io/fiaisis/mantid:<VERSION> '
  from mantid.kernel import ConfigService
  from pathlib import Path

  inst_dir = Path(ConfigService.Instance().getString("instrumentDefinition.directory"))
  matches = sorted(inst_dir.glob("*GEM*2026*.xml"))
  assert matches, "No 2026 GEM IDF found in Mantid config directory"
  print(f"Mantid resolved GEM IDF: {[m.name for m in matches]}")
  '
  ```

- **Option C: Inspecting XML Validity Attributes (`valid-from` / `valid-to`):**
  When checking definitions where the main file retains the base name (e.g., `GEM_Definition.xml`),
  inspect the XML attributes directly:
  ```bash
  docker run --rm ghcr.io/fiaisis/mantid:<VERSION> '
  import xml.etree.ElementTree as ET
  from pathlib import Path

  idf = Path("/opt/conda/envs/mantid/instrument/GEM_Definition.xml")
  root = ET.parse(idf).getroot()
  print("Instrument:", root.attrib.get("name"))
  print("Valid from:", root.attrib.get("valid-from"))
  print("Valid to:  ", root.attrib.get("valid-to"))
  '
  ```

> **Ambiguity Rule:** If multiple files match (e.g. `GEM_Definition_before_2026.xml` vs.
> `GEM_Definition.xml` with `valid-from="2026-09-15"`) or if it is ambiguous which specific IDF file
> is expected, do not guess — ask the user for clarification.

### 3.6 Updating Base Images & Dependencies (Manual Workflow & Smoke Tests)

Apart from the daily cron checking for new upstream Mantid releases
(`.github/workflows/build-and-push.yml`), this repository has no automated dependency bumper — base
images, Miniforge versions, `mantid-imaging` rebuilds, and GitHub Actions are updated manually.

#### Where to check for new versions
- **Miniforge3 (`mantid/Dockerfile` `FROM condaforge/miniforge3:<TAG>` and `mantid-imaging/Dockerfile` `ARG MINIFORGE_VERSION`)**:
  ```bash
  gh api repos/conda-forge/miniforge/releases/latest --jq .tag_name
  ```
- **Mantid release (`MANTID_VERSION` build-arg)**:
  ```bash
  gh api repos/mantidproject/mantid/releases/latest --jq .tag_name
  ```
- **Mantid Imaging & CUDA runtime (`mantid-imaging/Dockerfile` `FROM nvidia/cuda:<TAG>`)**:
  Inspect the upstream `stable` environment file to see what Python/CUDA/package versions
  `mantidimaging` currently expects before bumping the `nvidia/cuda` base tag:
  ```bash
  curl -s https://raw.githubusercontent.com/mantidproject/mantidimaging/stable/environment.yml
  gh api repos/mantidproject/mantidimaging/releases/latest --jq .tag_name
  ```
- **GitHub Actions (`.github/workflows/*.yml`)**:
  Check the latest release tag of each action via
  `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name` (e.g. `actions/checkout`,
  `docker/login-action`, `docker/build-push-action`, `mikefarah/yq`, `EndBug/add-and-commit`).

#### Building & running tiny end-to-end smoke scripts
Whenever you update a base image, Miniforge version, or package list, build the image locally
(§3.1) and run a small self-contained Python script through the default container entrypoint
(`python -c "$@"`) that exercises the core libraries and runtime assumptions:

- **Mantid runner smoke test** (verifies `mantid.simpleapi`, `requests`, `Mantid.user.properties`
  config, and the `job_watcher` JSON output pattern):
  ```bash
  docker run --rm ghcr.io/fiaisis/mantid:<VERSION> '
  import json, requests
  from mantid.kernel import ConfigService
  from mantid.simpleapi import CreateSampleWorkspace, Scale

  cfg = ConfigService.Instance()
  assert cfg.getFacility().name() == "ISIS", "Expected ISIS default facility"
  ws = CreateSampleWorkspace(OutputWorkspace="ws")
  ws_scaled = Scale(InputWorkspace=ws, Factor=2.0, OutputWorkspace="ws_scaled")
  assert ws_scaled.readY(0)[0] == ws.readY(0)[0] * 2.0
  print(json.dumps({"status": "Successful", "mantid_ok": True, "requests_version": requests.__version__}))
  '
  ```

- **Mantid Imaging runner smoke test** (verifies `mantidimaging`, `opencv`, `requests`, and a basic
  3D image stack operation; add `--gpus all` on a GPU host):
  ```bash
  docker run --rm ghcr.io/fiaisis/mantid-imaging:latest '
  import cv2, numpy as np, requests
  import mantidimaging
  from mantidimaging.core.data import ImageStack

  stack = ImageStack(np.ones((4, 16, 16), dtype=np.float32))
  assert stack.data.shape == (4, 16, 16)
  print("MantidImaging smoke test passed:", mantidimaging.__version__, "OpenCV:", cv2.__version__, "requests:", requests.__version__)
  '
  ```

---

## 4. CI/CD & Downstream Automation

### 4.1 `.github/workflows/build-and-push.yml`
- **Triggers:** Push to repository and daily cron (`18 14 * * *`).
- **Detection:** Queries `api.github.com/repos/mantidproject/mantid/releases/latest` (stripping any
  leading `v`) and checks `ghcr.io/v2/fiaisis/mantid/tags/list` to see if that tag already exists.
- **Build & Push:** Builds `./mantid/Dockerfile` via `docker/build-push-action` and pushes
  `ghcr.io/fiaisis/mantid:<TAG>` (note: `build-and-push.yml` does not currently pass
  `build-args: MANTID_VERSION=...`, so `mamba` installs the latest `mantid` from the conda channel).
- **Downstream Sync:**
  1. Checks out `fiaisis/gitops`, updates `DEFAULT_RUNNER_SHA` (stripped of the `sha256:` prefix) in
     `./components/jobcreator/envs/staging/jobcreator.yml` using `yq`, and commits/pushes at the end
     of the job.
  2. Checks out `fiaisis/LLSP` into `llsp_repo`, updates `FROM ghcr.io/fiaisis/mantid:<TAG>` in
     `./llsp_repo/LLSP-Worker/Dockerfile`, and commits/pushes.

### 4.2 `.github/workflows/activity_workflow.yaml`
- Runs on a monthly cron (`0 0 1 * *`) and on `push` to update `Last updated:` in `README.md` so
  scheduled workflows in the repository are not disabled for inactivity.
- Generates automated commits with the message `activity`. Filter these out when inspecting git
  history.

---

## Requirements for code changes

Only run image builds and smoke tests when they are **relevant to the files you actually changed** —
if a change only touches documentation (e.g. `.md` files), skip building and running containers.
When you do change a Dockerfile, base image, or build script, before considering the change
complete:
1. **Rebuild the affected image(s) locally** (§3.1) after any change to a Dockerfile, base image, or
   build argument.
2. **Run the version check and the tiny end-to-end smoke script** (§3.2, §3.6) against the freshly
   built image(s) — these are this repo's equivalent of unit tests, since there is no pytest/Jest
   suite to run.
3. **Verify included IDFs** (§3.5) for any change that touches instrument definition file handling.
4. There is no linter, formatter, or coverage tool configured for this repo (no `pyproject.toml` or
   `package.json`) — don't invent one; the build + smoke-test pass/fail is the regression check.

---

## 5. Managing Issues & Pull Requests

### 5.1 Managing issues

This repo has no local `.github/ISSUE_TEMPLATE/`; GitHub serves the org-wide default template from
`fiaisis/.github` instead. Always use it rather than inventing an ad hoc issue format:

```shell
gh issue create --template Issue
```

Check `gh issue list` / `gh issue view <number>` first to avoid duplicates.

### 5.2 Branch naming

Branches use `snake_case` descriptions of the work being done. Do not use category prefixes like
`feature/` or `fix/` (e.g. `add_safety_check`).

### 5.3 Commit messages

`main`'s history (`git log --oneline main`) is **entirely squash merges** for PRs (plus automated
`activity` commits from §4.2): one commit per PR, titled `<PR title> (#<PR number>)`, e.g.
`Add safety check (#8)`. This has two practical consequences:

- **The PR title is what actually survives into permanent history.** Individual commits on a working
  branch are squashed on merge, so getting the PR title right matters more than crafting a
  commit-by-commit history.
- **Individual commit messages still matter for review and for the squash commit body**, since
  GitHub's squash merge concatenates every commit subject on the branch into the squashed commit's
  body by default. Write focused, imperative-mood commit summaries and avoid noise like `wip`.
- Always filter out automated `activity` commits when inspecting git history (`git log --invert-grep --grep="activity"`).

### 5.4 Pull request process

1. **Local validation** before opening a PR (when Dockerfiles or scripts are changed; skip for
   `.md`-only changes): build the affected Dockerfile(s) (§3.1) and run both the version check (§3.2)
   and the tiny end-to-end smoke script (§3.6) against the freshly built image, plus §3.5 if an IDF
   change is involved.
2. **PR title**: a clear, concise description in normal grammar/sentence case (e.g. `Add safety
   check`, `Update llsp when mantid builds`). Do not use `snake_case` for PR titles.
3. **PR description**: use the org-wide default template from `fiaisis/.github`
   (`.github/pull_request_template.md` — no local override in this repo), which is just
   `Closes # <Issue Number>` followed by a `## Description` section. Ask the user for the issue
   number if one isn't evident from the task, or confirm there is none to link.
4. **AI-assistance label**: attach a label to the PR indicating that it was made with the assistance
   of AI. Check existing labels first with `gh label list` (e.g. `AI` or `AI_code` in this org) and
   apply the matching label via `gh pr create --label <label>` or
   `gh pr edit <number> --add-label <label>`; if the repo does not have an AI label yet, create one
   first (`gh label create "AI" --description "Created with the assistance of AI"`).

---

## 6. Agent Rules and Guidelines

1. **Case Sensitivity:** Ensure file references use exact directory casing (e.g.,
   `./mantid/Dockerfile`, not `./Mantid/Dockerfile`).
2. **Downstream Safety:** Any changes to container tag formats, entrypoints, or image digests in CI
   directly affect `fiaisis/gitops` and `fiaisis/LLSP`. Verify pipeline compatibility before
   modifying `build-and-push.yml`.
3. **Entrypoint Contract:** Both runner images must adhere to the entrypoint pattern
   `python -c "$@"` to ensure compatibility with worker job dispatchers.
4. **No Extraneous Files:** Keep root directory clean; container definitions belong in dedicated
   subdirectories named after the respective runner.
5. **Ignore "activity" Commits:** When reviewing commit history, changelogs, or blame, filter out
   and ignore all automated commits containing `"activity"` (generated by
   `.github/workflows/activity_workflow.yaml`):
   ```bash
   git log --invert-grep --grep="activity"
   ```
6. **IDF Updates & Version Parity:** Container image tags may diverge from upstream Mantid versions
   (breaking 1:1 parity) when a container is built with a bumped patch version specifically to bake
   in updated IDFs. Always verify the installed Mantid package version vs. the container tag.
7. **Clarify Ambiguous IDFs:** When checking or verifying instrument definition files, if it is
   unclear which specific file is the intended one (e.g., multiple files match a date/pattern, or
   naming is ambiguous), ask the user for clarification instead of guessing.
8. **Use Dedicated File Tools (`read`, `write`, `edit`):** Prefer the `read` tool (with
   `offset`/`limit`) over `sed -n`, `cat`, or shell one-liners when inspecting files, and prefer the
   `write` and `edit` tools over `bash` (`cat <<EOF`, `sed -i`, `echo >`), Python scripts, or other
   non-tool-based commands whenever creating or modifying files.

---

## 7. Keeping this document up to date

If a change you make would make any information in this `AGENTS.md` inaccurate or incomplete — e.g.
a new runner architecture, a changed base image or build argument, a new/renamed CI workflow, a new
downstream consumer of built images, or a different IDF-verification approach — update the relevant
section of this file as part of the same change. Treat it the same way you would treat `README.md`:
documentation that goes stale is worse than no documentation, so don't leave it to a future agent or
PR to notice the drift.
