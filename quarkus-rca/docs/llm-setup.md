# LLM Configuration — Provider Setup Guide

This guide covers the one-time setup required to configure an LLM provider for Quarkus RCA demo

Three providers are supported:

| Provider                                               | Description                                    |
|--------------------------------------------------------|------------------------------------------------|
| [`vertex-ai-anthropic`](#provider-vertex-ai-anthropic) | Claude via Google Cloud Vertex AI              |
| [`anthropic`](#provider-anthropic)                     | Claude via the Anthropic API (direct, API key) |
| [`bob`](#provider-bob)                                 | IBM Bob                                        |

---

## Provider: `anthropic`

The simplest option — requires only an Anthropic API key.

### Prerequisites

- An [Anthropic Console](https://console.anthropic.com) account with API access

### Step 1 — Obtain an API key

1. Log in to [https://console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys)
2. Click **Create Key**, give it a name (e.g. `quarkus-rca-demo`), and copy the value.

> ⚠️ The key is shown only once. Store it securely — never commit it to Git.

### Step 2 — Configure `llm.env`

```bash
cp llm.env.example llm.env
```

Set the following values:

| Variable         | Value                  |
|------------------|------------------------|
| `LLM_PROVIDER`   | `anthropic`            |
| `LLM_MODEL_NAME` | `claude-sonnet-4-6`    |
| `LLM_API_KEY`    | your Anthropic API key |

Example:

```bash
LLM_PROVIDER=anthropic
LLM_MODEL_NAME=claude-sonnet-4-6
LLM_API_KEY=<your-api-key>
```

> ⚠️ `llm.env` is `.gitignore`d — never commit it.

---

## Provider: `bob`

Uses IBM Bob as the backend RCA LLM. `LLM_API_KEY` is required when Bob is configured with API key authentication; `BOB_SHELL_PATH` is optional and defaults to `bob` on `PATH`.

### Step 1 — Configure `llm.env`

```bash
cp llm.env.example llm.env
```

Set the following values:

| Variable         | Value                                                            |
|------------------|------------------------------------------------------------------|
| `LLM_PROVIDER`   | `bob`                                                            |
| `LLM_API_KEY`    | your Bob API key (if required)                                   |
| `BOB_SHELL_PATH` | path to the `bob` binary (optional, defaults to `bob` on `PATH`) |

Example:

```bash
LLM_PROVIDER=bob
LLM_API_KEY=<your-bob-api-key>
# BOB_SHELL_PATH=/usr/local/bin/bob  # optional
```

> ⚠️ `llm.env` is `.gitignore`d — never commit it.

---

## Provider: `vertex-ai-anthropic`

Uses Claude through Google Cloud Vertex AI. Requires a GCP project with
Vertex AI enabled and appropriate credentials.

### Prerequisites

- [Google Cloud CLI (`gcloud`)](https://cloud.google.com/sdk/docs/install) installed and authenticated
- A GCP project with billing enabled
- Permission to create service accounts and IAM bindings in that project

---

### Step 1 — Verify Vertex AI and Claude access *(skip if already done for this project)*

These are **one-time per GCP project** steps. If your project already has
Claude on Vertex AI enabled, skip straight to [Step 2](#step-2--obtain-gcp-credentials).

**Enable the Vertex AI API:**

```bash
gcloud services enable aiplatform.googleapis.com \
  --project=<your-gcp-project-id>
```

---

### Step 2 — Obtain GCP credentials

Choose **one** of the two options below.

#### Option A — Application Default Credentials (ADC)

Quickest for local development. Uses your personal Google account.

```bash
gcloud auth application-default login
gcloud auth application-default set-quota-project <your-gcp-project-id>
```

Then set in `llm.env`:

```bash
GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/application_default_credentials.json
```

> **Note:** ADC credentials are personal and short-lived. Use Option B for
> shared or automated environments.
> The default expected credentials filename is **`causa-gcp-key.json`** (repo root) — used by Option B and pre-set in `llm.env.example`.

---

#### Option B — Service Account Key

Recommended for shared or CI/CD environments.

**Create the service account:**

```bash
gcloud iam service-accounts create causa-llm-sa \
  --project=<your-gcp-project-id>
```

**Grant Vertex AI access:**

```bash
gcloud projects add-iam-policy-binding <your-gcp-project-id> \
  --member="serviceAccount:causa-llm-sa@<your-gcp-project-id>.iam.gserviceaccount.com" \
  --role="roles/aiplatform.user" \
  --condition=None
```

**Download the key file:**

```bash
gcloud iam service-accounts keys create causa-gcp-key.json \
  --iam-account=causa-llm-sa@<your-gcp-project-id>.iam.gserviceaccount.com
```

Place `causa-gcp-key.json` in the repo root — this is the expected filename, already `.gitignored`.

Then set in `llm.env`:

```bash
GOOGLE_APPLICATION_CREDENTIALS=./causa-gcp-key.json
```

---

### Step 3 — Configure `llm.env`

```bash
cp llm.env.example llm.env
```

Fill in the following values:

| Variable                         | Value                                                                |
|----------------------------------|----------------------------------------------------------------------|
| `LLM_PROVIDER`                   | `vertex-ai-anthropic`                                                |
| `LLM_MODEL_NAME`                 | `claude-sonnet-4-6`                                                  |
| `VERTEX_PROJECT_ID`              | your GCP project ID                                                  |
| `VERTEX_LOCATION`                | one of: `us-east5`, `us-central1`, `europe-west1`, `asia-southeast1` |
| `GOOGLE_APPLICATION_CREDENTIALS` | path to your credentials file (from Step 2)                          |

> **Note:** `global` is **not** a valid `VERTEX_LOCATION` for Claude on Vertex AI.

---

## Verification

The demo script validates `llm.env` before any deployment:

```
Validating Prerequisites ✓
LLM Configuration ✓
```

If validation fails, the script exits with a clear error listing which
variables are missing or incorrect.

---

## Quick reference — `llm.env` fields by provider

| Variable                         | `anthropic` | `vertex-ai-anthropic` | `bob`      |
|----------------------------------|-------------|-----------------------|------------|
| `LLM_PROVIDER`                   | ✅ required  | ✅ required            | ✅ required |
| `LLM_MODEL_NAME`                 | ✅ required  | ✅ required            | —          |
| `LLM_API_KEY`                    | ✅ required  | —                     | optional   |
| `BOB_SHELL_PATH`                 | —           | —                     | optional   |
| `VERTEX_PROJECT_ID`              | —           | ✅ required            | —          |
| `VERTEX_LOCATION`                | —           | ✅ required            | —          |
| `GOOGLE_APPLICATION_CREDENTIALS` | —           | ✅ required            | —          |
