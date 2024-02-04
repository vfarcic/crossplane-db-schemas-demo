#!/bin/sh
set -e

gum confirm '
Are you ready to start?
Select "Yes" only if you did NOT follow the story from the start (if you jumped straight into this chapter).
Feel free to say "No" and inspect the script if you prefer setting up resources manually.
' || exit 0

echo "
## You will need following tools installed:
|Name            |Required             |More info                                          |
|----------------|---------------------|---------------------------------------------------|
|Docker          |Yes                  |'https://docs.docker.com/engine/install'           |
|helm CLI        |If using Helm        |'https://helm.sh/docs/intro/install/'              |
|kubectl CLI     |Yes                  |'https://kubernetes.io/docs/tasks/tools/#kubectl'  |
|kind CLI        |Yes                  |'https://kind.sigs.k8s.io/docs/user/quick-start/#installation'|
|yq CLI          |Yes                  |'https://github.com/mikefarah/yq#install'          |
|Google Cloud account with admin permissions|If using Google Cloud|'https://cloud.google.com'|
|Google Cloud CLI|If using Google Cloud|'https://cloud.google.com/sdk/docs/install'        |
|gke-gcloud-auth-plugin|If using Google Cloud|'https://cloud.google.com/blog/products/containers-kubernetes/kubectl-auth-changes-in-gke'|
|AWS account with admin permissions|If using AWS|'https://aws.amazon.com'                  |
|AWS CLI         |If using AWS         |'https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html'|

If you are running this script from **Nix shell**, most of the requirements are already set with the exception of **Docker** and the **hyperscaler account**.
" | gum format

gum confirm "
Do you have those tools installed?
" || exit 0

rm -f .env

#############
# Variables #
#############

echo "# Variables" | gum format

echo "export HYPERSCALER=$HYPERSCALER" >> .env

#########################
# Control Plane Cluster #
#########################

echo "# Control Plane Cluster" | gum format

kind create cluster

kubectl create namespace a-team

##############
# Crossplane #
##############

echo "# Crossplane" | gum format

helm upgrade --install crossplane crossplane-stable/crossplane \
    --namespace crossplane-system --create-namespace --wait

kubectl apply --filename crossplane-packages/dot-sql.yaml

kubectl apply --filename crossplane-packages/dot-kubernetes.yaml

kubectl apply --filename crossplane-packages/helm-incluster.yaml

kubectl apply --filename crossplane-packages/kubernetes-incluster.yaml

echo "## Waiting for Crossplane Packages to be ready..." | gum format

sleep 60

kubectl wait --for=condition=healthy provider.pkg.crossplane.io \
    --all --timeout=600s

if [[ "$HYPERSCALER" == "google" ]]; then

    gcloud auth login

    # Project

    PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)

    echo "export PROJECT_ID=$PROJECT_ID" >> .env

    gcloud projects create ${PROJECT_ID}

    # APIs

    open "https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"

    echo "## LINK A BILLING ACCOUNT" | gum format
    gum input --placeholder "Press the enter key to continue."

    open "https://console.cloud.google.com/marketplace/product/google/container.googleapis.com?project=$PROJECT_ID"
    
    echo "## *ENABLE* the API" | gum format
    gum input --placeholder "Press the enter key to continue."

    open "https://console.cloud.google.com/apis/library/sqladmin.googleapis.com?project=$PROJECT_ID"

    echo "## *ENABLE* the API" | gum format
    gum input --placeholder "Press the enter key to continue."

    open "https://console.cloud.google.com/marketplace/product/google/secretmanager.googleapis.com?project=$PROJECT_ID"

    echo "## *ENABLE* the API" | gum format
    gum input --placeholder "Press the enter key to continue."

    # Service Account (general)

    export SA_NAME=devops-toolkit

    export SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

    gcloud iam service-accounts create $SA_NAME \
        --project $PROJECT_ID

    export ROLE=roles/admin

    gcloud projects add-iam-policy-binding --role $ROLE \
        $PROJECT_ID --member serviceAccount:$SA

    gcloud iam service-accounts keys create gcp-creds.json \
        --project $PROJECT_ID --iam-account $SA

    # Crossplane

    yq --inplace ".spec.projectID = \"$PROJECT_ID\"" \
        crossplane-packages/google-config.yaml

    yq --inplace ".spec.projectID = \"$PROJECT_ID\"" \
        crossplane-packages/google-config.yaml

    kubectl --namespace crossplane-system \
        create secret generic gcp-creds \
        --from-file creds=./gcp-creds.json

    kubectl apply --filename crossplane-packages/google-config.yaml

elif [[ "$HYPERSCALER" == "aws" ]]; then

    AWS_ACCESS_KEY_ID=$(gum input --placeholder "AWS Access Key ID" --value "$AWS_ACCESS_KEY_ID")
    echo "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> .env
    
    AWS_SECRET_ACCESS_KEY=$(gum input --placeholder "AWS Secret Access Key" --value "$AWS_SECRET_ACCESS_KEY" --password)
    echo "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> .env

    AWS_ACCOUNT_ID=$(gum input --placeholder "AWS Account ID" --value "$AWS_ACCOUNT_ID")
    echo "export AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID" >> .env

    echo "[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
" >aws-creds.conf

    kubectl --namespace crossplane-system \
        create secret generic aws-creds \
        --from-file creds=./aws-creds.conf \
        --from-literal accessKeyID=$AWS_ACCESS_KEY_ID \
        --from-literal secretAccessKey=$AWS_SECRET_ACCESS_KEY

    kubectl apply --filename crossplane-packages/aws-config.yaml

fi

kubectl --namespace a-team apply \
    --filename cluster/$HYPERSCALER.yaml

##################
# Atlas Operator #
##################

echo "# Atlas Operator" | gum format

helm upgrade --install atlas-operator \
    oci://ghcr.io/ariga/charts/atlas-operator \
    --namespace atlas-operator --create-namespace --wait

####################
# External Secrets #
####################

echo "# External Secrets" | gum format

helm upgrade --install \
    external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace --wait

if [[ "$HYPERSCALER" == "google" ]]; then

    yq --inplace \
        ".spec.provider.gcpsm.projectID = \"$PROJECT_ID\"" \
        external-secrets/google.yaml

    echo "{\"password\": \"IWillNeverTell\" }" \
        | gcloud secrets --project $PROJECT_ID \
        create db-password --data-file=-

elif [[ "$HYPERSCALER" == "aws" ]]; then

    set +e
    aws secretsmanager create-secret \
        --name db-password --region us-east-1 \
        --secret-string "{\"password\": \"IWillNeverTell\" }"
    set -e

fi

kubectl apply --filename external-secrets/$HYPERSCALER.yaml

###############
# App Cluster #
###############

echo "# App Cluster" | gum format

echo "## Waiting for the app cluster (<= 20 min.)..." | gum format

kubectl --namespace a-team wait --for=condition=ready \
    clusterclaim cluster --timeout=1200s

if [[ "$HYPERSCALER" == "google" ]]; then

    gcloud container clusters get-credentials a-team-cluster \
        --region us-east1 --project $PROJECT_ID

elif [[ "$HYPERSCALER" == "aws" ]]; then

    aws eks update-kubeconfig --region us-east-1 \
        --name a-team-cluster --kubeconfig $KUBECONFIG

fi

########
# Misc #
########

chmod +x destroy.sh

echo "## Setup is complete." | gum format
