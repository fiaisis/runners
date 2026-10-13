# AGENTS.md

Operational guidance for AI agents and developers working in the `runners` repository.

---

## 1. Repository Purpose

This repository defines and builds containerized execution environments ("runners") for ISIS neutron/muon data processing workflows under `fiaisis`. Images are published to the GitHub Container Registry (`ghcr.io/fiaisis/*`).

---

## 2. Runner Architectures

### 2.1 Mantid Runner (`mantid/`)
- **Base image:** `condaforge/miniforge3:25.3.0-1`
- **Build argument:** `MANTID_VERSION` (e.g. `6.8.0`, `6.9.0`, `6.9.1`)
- **Key components:**
  - Installs `libgl1` (apt) and `mantid=${MANTID_VERSION}`, `requests` via `mamba` (`mantid` and `conda-forge` channels).
  - Copies `Mantid.user.properties` to `/root/.mantid/` (configures ISIS facility defaults, `/archive` search path, `/output` save path).
  - Clones latest instrument definitions from `mantidproject/mantid:main` into `/opt/conda/envs/mantid/instrument` (see [3.4 Updating IDFs](#34-updating-instrument-definition-files-idfs) and [3.5 Verifying IDFs](#35-verifying-included-instrument-definition-files-idfs)).
- **Entrypoint:** `/entrypoint.sh` executing `python -c "$@"` inside the activated `mantid` conda environment.

### 2.2 Mantid Imaging Runner (`mantid-imaging/`)
- **Base image:** `nvidia/cuda:12.9.1-base-ubuntu24.04` (NVIDIA CUDA 12.9 runtime for GPU-accelerated reconstruction).
- **Key components:**
  - Installs Miniforge3 (`25.11.0-0`), `wget`, `bzip2`, `git`, `tini`.
  - Creates `mantidimaging` conda environment from upstream `https://raw.githubusercontent.com/mantidproject/mantidimaging/stable/environment.yml` with `requests` and `opencv`.
- **Entrypoint:** `/entrypoint.sh` executing `python -c "$@"` inside the activated `mantidimaging` conda environment.
- **Ignored Files:** `mantid-imaging/test.py` is ignored. Do not modify, execute, or integrate this file into CI/runners.

---

## 3. Common Operational Commands

### 3.1 Local Docker Builds

**Build Mantid Runner:**
```bash
docker build . -f ./mantid/Dockerfile -t ghcr.io/fiaisis/mantid:<VERSION> --build-arg="MANTID_VERSION=<VERSION>"
```
*(Note: Maintain lowercase `mantid/Dockerfile` to avoid case-sensitivity issues on Linux).*

**Build Mantid Imaging Runner:**
```bash
docker build . -f ./mantid-imaging/Dockerfile -t ghcr.io/fiaisis/mantid-imaging:latest
```

**Batch Build Mantid Runners:**
```bash
bash ./build_all_images.sh
```

### 3.2 Testing Image Execution

Run a one-line Python snippet through the container entrypoint:
```bash
# Mantid runner check
docker run --rm ghcr.io/fiaisis/mantid:<VERSION> "import mantid; print(mantid.__version__)"

# Mantid imaging runner check (with GPU pass-through)
docker run --rm --gpus all ghcr.io/fiaisis/mantid-imaging:latest "import mantidimaging; print(mantidimaging.__version__)"
```

### 3.3 Inspecting GHCR Image Digests

**Using the Python script:**
```bash
python3 get_runner_sha256.py
```

**Using the Bash script:**
```bash
bash ./tag_to_sha256.sh
```

### 3.4 Updating Instrument Definition Files (IDFs)

Mantid runner images disable automatic startup IDF downloads (`UpdateInstrumentDefinitions.OnStartup=0` in `Mantid.user.properties`). Instead, current IDFs are cloned from `https://github.com/mantidproject/mantid:main` directly into `/opt/conda/envs/mantid/instrument` at Docker build time.

When an instrument's IDF is updated upstream and must be deployed without a new Mantid release:
1. Rebuild and push the container with a **bumped patch number** in the container tag while keeping `MANTID_VERSION` set to the desired Mantid release.
2. **Version Parity Note:** This breaks the 1:1 mapping between the container image tag and the upstream Mantid version, since the container tag is bumped while the installed Mantid conda package remains the same.

**Example:**
To release updated IDFs for Mantid `6.9.1`, build and tag a container as `6.9.2`:
```bash
# Build with existing Mantid version but bumped image patch tag
docker build . -f ./mantid/Dockerfile \
  -t ghcr.io/fiaisis/mantid:6.9.2 \
  --build-arg="MANTID_VERSION=6.9.1"

# Push the updated runner image
docker push ghcr.io/fiaisis/mantid:6.9.2
```
After pushing, propagate the new image digest to `fiaisis/gitops` (jobcreator) and `fiaisis/LLSP` as needed.

### 3.5 Verifying Included Instrument Definition Files (IDFs)

To confirm that a newly built container includes a specific IDF update, inspect the container's instrument directory (`/opt/conda/envs/mantid/instrument/`).

**Example: Verifying the latest GEM IDF (requires `.xml` with `2026` in its filename):**

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
  import sys

  inst_dir = Path(ConfigService.Instance().getString("instrumentDefinition.directory"))
  matches = sorted(inst_dir.glob("*GEM*2026*.xml"))
  assert matches, "No 2026 GEM IDF found in Mantid config directory"
  print(f"Mantid resolved GEM IDF: {[m.name for m in matches]}")
  '
  ```

- **Option D: Inspecting XML Validity Attributes (`valid-from` / `valid-to`):**
  When checking definitions where the main file retains the base name (e.g., `GEM_Definition.xml`), inspect the XML attributes directly:
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

> **Ambiguity Rule:** If multiple files match (e.g. `GEM_Definition_before_2026.xml` vs. `GEM_Definition.xml` with `valid-from="2026-09-15"`) or if it is ambiguous which specific IDF file is expected, do not guess—ask the user for clarification.

---

## 4. CI/CD & Downstream Automation

### 4.1 `.github/workflows/build-and-push.yml`
- **Triggers:** Push to repository and daily cron (`18 14 * * *`).
- **Detection:** Queries `api.github.com/repos/mantidproject/mantid/releases/latest` and compares against tags on `ghcr.io/fiaisis/mantid`.
- **Build & Push:** Builds `mantid/Dockerfile` for the new release tag and pushes to GHCR.
- **Downstream Sync:**
  1. Clones `fiaisis/gitops`: Updates `DEFAULT_RUNNER_SHA` with the raw image digest in `./components/jobcreator/envs/staging/jobcreator.yml`.
  2. Clones `fiaisis/LLSP`: Updates `FROM ghcr.io/fiaisis/mantid:<VERSION>` in `./LLSP-Worker/Dockerfile` and commits/pushes.

### 4.2 `.github/workflows/activity_workflow.yaml`
- Monthly cron scheduled job to update `Last updated:` in `README.md` to prevent repository dormancy.
- Generates automated commits with the message `activity`. When reviewing git history, these commits should always be filtered out and ignored.

---

## 5. Agent Rules and Guidelines

1. **Ignore `mantid-imaging/test.py`:** Do not edit, test, format, or wire this script into any workflow.
2. **Case Sensitivity:** Ensure file references use exact directory casing (e.g., `./mantid/Dockerfile`, not `./Mantid/Dockerfile`).
3. **Downstream Safety:** Any changes to container tag formats, entrypoints, or image digests in CI directly affect `fiaisis/gitops` and `fiaisis/LLSP`. Verify pipeline compatibility before modifying `build-and-push.yml`.
4. **Entrypoint Contract:** Both runner images must adhere to the entrypoint pattern `python -c "$@"` to ensure compatibility with worker job dispatchers.
5. **No Extraneous Files:** Keep root directory clean; container definitions belong in dedicated subdirectories named after the respective runner.
6. **Ignore "activity" Commits:** When reviewing commit history, changelogs, or blame, filter out and ignore all automated commits containing `"activity"` (generated by `.github/workflows/activity_workflow.yaml`). Use:
   ```bash
   git log --invert-grep --grep="activity"
   ```
7. **IDF Updates & Version Parity:** Container image tags may diverge from upstream Mantid versions (breaking 1:1 parity) when a container is built with a bumped patch version specifically to bake in updated IDFs. Always verify the installed Mantid package version vs. the container tag.
8. **Clarify Ambiguous IDFs:** When checking or verifying instrument definition files, if it is unclear which specific file is the intended one (e.g., multiple files match a date/pattern, or naming is ambiguous), ask the user for clarification instead of guessing.
