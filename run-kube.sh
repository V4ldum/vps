#!/bin/bash

# Run a command as the user who called sudo, or as root on a direct root login
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]
then
    as_user() { sudo -u "$SUDO_USER" -H "$@"; }
else
    as_user() { "$@"; }
fi

if [ "$EUID" -ne 0 ]
then
    echo "Must be run with sudo"
    exit 1;
fi

# cd into the script's directory
cd "$(dirname "$0")" || exit 1

KUBESOLO_VERSION="v1.2.0"
KUBERNETES_VERSION="v1.35.7"


# ----------------------
# Pre-flight
ERRORS=0

if dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' 2>/dev/null \
    | awk '$1=="installed" {print $2}' \
    | grep -qiE 'docker|containerd|runc'
then
    echo "> ERROR: docker packages are still installed" >&2
    ERRORS=1
fi

if iptables -L -n | grep -qi 'docker' || iptables -t nat -L -n | grep -qi 'docker'
then
    echo "> ERROR: docker iptables chains are still loaded" >&2
    ERRORS=1
fi

if ip link show docker0 &>/dev/null
then
    echo "> ERROR: the docker0 interface still exists" >&2
    ERRORS=1
fi

if [ "$ERRORS" -ne 0 ]
then
    exit 1
fi


# ----------------------
# Kubectl
echo "Installing Kubectl"

if ! which kubectl &>/dev/null
then
    curl -LOs "https://dl.k8s.io/release/$KUBERNETES_VERSION/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm ./kubectl
else
    echo "> Kubectl is already installed, skipping"
fi


# ----------------------
# Kubesolo
echo "Installing Kubesolo"

if ! which kubesolo &>/dev/null
then
    curl -sfL https://get.kubesolo.io | sh -s -- --version="$KUBESOLO_VERSION" || exit 1
else
    echo "> Kubesolo is already installed, skipping"
fi


# ----------------------
# Secrets

# GHCR Registry
SECRET_NAME="ghcr"
if ! as_user kubectl get secret "$SECRET_NAME" &>/dev/null
then
    echo "Creating GHCR registry secret"

    read -resp "Paste the \"GHCR\" token: " SECRET
    as_user kubectl create secret docker-registry "$SECRET_NAME" \
        --docker-server=ghcr.io \
        --docker-username=V4ldum \
        --docker-password="$SECRET" \
        || exit 1
    unset SECRET

    for _ in $(seq 1 30)
    do
        # Service account might not be ready when this command is run so we loop waiting for it to ready
        as_user kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"'"$SECRET_NAME"'"}]}' && break
        sleep 2
    done
fi

# SSL certificates
SECRET_NAME="tls-certs"
if ! as_user kubectl get secret "$SECRET_NAME" &>/dev/null
then
    ## CRT
    echo "Paste the \"CRT\" file content:"
    while IFS= read -rs LINE
    do
        printf '%s\n' "$LINE"
        [ "$LINE" = "-----END CERTIFICATE-----" ] && break
    done > proxy.crt

    ## KEY
    echo "Paste the \"KEY\" file content:"
    while IFS= read -rs LINE
    do
        printf '%s\n' "$LINE"
        [ "$LINE" = "-----END PRIVATE KEY-----" ] && break
    done > proxy.key

    ## Secret
    as_user kubectl create secret generic "$SECRET_NAME" --from-file=proxy.crt --from-file=proxy.key || exit 1
    rm proxy.crt proxy.key
fi

# Deployment secrets
echo "Creating deployment secrets"

## MangaNotif
SECRET_NAME="manganotif-api-secret"
if ! as_user kubectl get secret "$SECRET_NAME" &>/dev/null; then
    read -resp "Paste $SECRET_NAME: " SECRET
    as_user kubectl create secret generic "$SECRET_NAME" --from-literal=MANGANOTIF_API_SECRET="$SECRET" >/dev/null
    unset SECRET
fi

## Thorfinn
SECRET_NAME="thorfinn-discord-api-token"
if ! as_user kubectl get secret "$SECRET_NAME" &>/dev/null; then
    read -resp "Paste $SECRET_NAME: " SECRET
    as_user kubectl create secret generic "$SECRET_NAME" --from-literal=DISCORD_API_TOKEN="$SECRET" >/dev/null
    unset SECRET
fi

## Heal
SECRET_NAME="heal-discord-webhook"
if ! as_user kubectl get secret "$SECRET_NAME" &>/dev/null; then
    read -resp "Paste $SECRET_NAME: " SECRET
    as_user kubectl create secret generic "$SECRET_NAME" --from-literal=WEBHOOK="$SECRET" >/dev/null
    unset SECRET
fi

## Backoffice
SECRET_NAME="backoffice-secret"
if ! as_user kubectl get secret "$SECRET_NAME" &>/dev/null; then
    read -resp "Paste $SECRET_NAME: " SECRET
    as_user kubectl create secret generic "$SECRET_NAME" --from-literal=BACKOFFICE_SECRET="$SECRET" >/dev/null
    unset SECRET
fi


# ----------------------
# Deployments
echo "Creating deployments dependencies"

mkdir -p db/{finance,manganotif,thorfinn}
read -n 1 -srp ">> db directory created. Migrate databases into it, then press any key to continue."
chown -R 65532:65532 db

## Deploy
HEADER="Accept: application/vnd.github.raw"

echo "Deploying VPS utilities"
as_user kubectl apply -f kubernetes.yml >/dev/null || exit 1

echo "Deploying finance"
gh api repos/V4ldum/finance-back/contents/kubernetes.yml -H "$HEADER" \
    | as_user kubectl apply -f - >/dev/null || exit 1

echo "Deploying manganotif"
gh api repos/V4ldum/manganotif-back/contents/kubernetes.yml -H "$HEADER" \
    | as_user kubectl apply -f - >/dev/null || exit 1

echo "Deploying thorfinn"
gh api repos/V4ldum/thorfinn/contents/kubernetes.yml -H "$HEADER" \
    | as_user kubectl apply -f - >/dev/null || exit 1

echo "Deploying backoffice"
gh api repos/V4ldum/backoffice/contents/kubernetes.yml -H "$HEADER" \
    | as_user kubectl apply -f - >/dev/null || exit 1

echo "Deploying heal"
gh api repos/V4ldum/heal/contents/kubernetes.yml -H "$HEADER" \
    | as_user kubectl apply -f - >/dev/null || exit 1

echo "Deploying shaman"
gh api repos/V4ldum/is-shaman-good/contents/kubernetes.yml -H "$HEADER" \
    | as_user kubectl apply -f - >/dev/null || exit 1

echo "Deploying bingo"
gh api repos/V4ldum/bingo/contents/kubernetes.yml -H "$HEADER" \
    | as_user kubectl apply -f - >/dev/null || exit 1

echo "Deploying portfolio"
gh api repos/V4ldum/portfolio/contents/kubernetes.yml -H "$HEADER" \
    | as_user kubectl apply -f - >/dev/null || exit 1

echo "Deploying qe"
gh api repos/V4ldum/qe-bleeding-edge/contents/kubernetes.yml -H "$HEADER" \
    | as_user kubectl apply -f - >/dev/null || exit 1
