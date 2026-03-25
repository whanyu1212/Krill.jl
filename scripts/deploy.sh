#!/usr/bin/env bash
# scripts/deploy.sh — build and deploy Krill to Cloud Run
#
# Prerequisites:
#   gcloud auth login
#   gcloud config set project YOUR_PROJECT_ID
#   gcloud auth configure-docker us-central1-docker.pkg.dev
#
# First-time setup: run scripts/setup_gcp.sh first.
# Edit cloudrun.yaml to set your PROJECT_ID and secrets before running.
#
# Usage:
#   ./scripts/deploy.sh

set -euo pipefail

PROJECT_ID="$(gcloud config get-value project)"
REGION="us-central1"
SERVICE_NAME="krill"
IMAGE="us-central1-docker.pkg.dev/${PROJECT_ID}/krill/krill:latest"

# ── Build & push ───────────────────────────────────────────────────────────────
echo "▶ Building image..."
docker build -t "${IMAGE}" .

echo "▶ Pushing image..."
docker push "${IMAGE}"

# ── Apply service spec ─────────────────────────────────────────────────────────
echo "▶ Deploying to Cloud Run..."
gcloud run services replace cloudrun.yaml --region "${REGION}"

echo "✓ Deployed. Service URL:"
gcloud run services describe "${SERVICE_NAME}" \
  --region "${REGION}" \
  --format "value(status.url)"
