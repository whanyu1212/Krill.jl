#!/usr/bin/env bash
# scripts/setup_gcp.sh — one-time GCP resource provisioning for Krill
#
# Run this once before your first deploy:
#   gcloud auth login
#   gcloud config set project YOUR_PROJECT_ID
#   ./scripts/setup_gcp.sh

set -euo pipefail

PROJECT_ID="$(gcloud config get-value project)"
REGION="us-central1"
GCS_BUCKET="krill-data"
SA_NAME="krill-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "▶ Enabling APIs..."
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  storage.googleapis.com

echo "▶ Creating Artifact Registry repository..."
gcloud artifacts repositories create krill \
  --repository-format=docker \
  --location="${REGION}" \
  --description="Krill agent Docker images" 2>/dev/null || echo "  (already exists)"

echo "▶ Configuring Docker auth..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

echo "▶ Creating GCS bucket gs://${GCS_BUCKET}..."
gcloud storage buckets create "gs://${GCS_BUCKET}" \
  --location="${REGION}" 2>/dev/null || echo "  (already exists)"

echo "▶ Creating service account ${SA_EMAIL}..."
gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="Krill agent service account" 2>/dev/null || echo "  (already exists)"

echo "▶ Granting GCS access to service account..."
gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin"

echo ""
echo "✓ GCP setup complete for project: ${PROJECT_ID}"
echo ""
echo "Next steps:"
echo "  1. Copy your secrets into your shell environment (or .env):"
echo "     export TELEGRAM_BOT_TOKEN=..."
echo "     export OPENAI_API_KEY=..."
echo "  2. Run: ./scripts/deploy.sh"
