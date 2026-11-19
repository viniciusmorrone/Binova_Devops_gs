
#!/usr/bin/env bash
set -Eeuo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-binova-gs}"
VM_NAME="${VM_NAME:-vm-binova-gs}"
LOCATION="${LOCATION:-brazilsouth}"
VM_SIZE="${VM_SIZE:-Standard_D2s_v4}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
REPO_URL="${REPO_URL:-https://github.com/viniciusmorrone/Binova_Devops_gs.git}"

command -v az >/dev/null 2>&1 || exit 1
az account show --query id -o tsv >/dev/null 2>&1 || exit 1

printf 'Regiao: %s | VM: %s\n' "$LOCATION" "$VM_SIZE"
read -r -p "Confirmar (CRIAR): " CONFIRM
[[ "$CONFIRM" == "CRIAR" ]] || exit 1

if [[ "$(az group exists -n "$RESOURCE_GROUP")" != "true" ]]; then
  az group create \
    -n "$RESOURCE_GROUP" \
    -l "$LOCATION" \
    -o none
fi

if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" -o none >/dev/null 2>&1; then
  VM_STATE="$(az vm get-instance-view \
    -g "$RESOURCE_GROUP" \
    -n "$VM_NAME" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" \
    -o tsv)"

  if [[ "$VM_STATE" != "PowerState/running" ]]; then
    az vm start -g "$RESOURCE_GROUP" -n "$VM_NAME" -o none
  fi
else
  az vm create \
    -g "$RESOURCE_GROUP" \
    -n "$VM_NAME" \
    -l "$LOCATION" \
    --image Ubuntu2204 \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    -o none
fi

NSG_NAME="${VM_NAME}NSG"

if [[ -z "$(az network nsg rule list \
  -g "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --query "[?destinationPortRange=='22' && access=='Allow' && direction=='Inbound'].name | [0]" \
  -o tsv)" ]]; then
  az vm open-port \
    -g "$RESOURCE_GROUP" \
    -n "$VM_NAME" \
    --port 22 \
    --priority 1000 \
    -o none
fi

if [[ -z "$(az network nsg rule list \
  -g "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --query "[?destinationPortRange=='8080' && access=='Allow' && direction=='Inbound'].name | [0]" \
  -o tsv)" ]]; then
  az vm open-port \
    -g "$RESOURCE_GROUP" \
    -n "$VM_NAME" \
    --port 8080 \
    --priority 1010 \
    -o none
fi

REMOTE_SCRIPT="$(mktemp)"
RESULT_FILE="$(mktemp)"

trap 'rm -f "$REMOTE_SCRIPT" "$RESULT_FILE"' EXIT

cat > "$REMOTE_SCRIPT" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null 2>&1 ||
   ! docker compose version >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl git openssl
  curl -fsSL https://get.docker.com | sh
fi

for PACKAGE in git curl openssl; do
  if ! command -v "$PACKAGE" >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq "$PACKAGE"
  fi
done

systemctl enable --now docker >/dev/null 2>&1

PROJECT_DIR="/opt/binova"
REPO_URL="https://github.com/viniciusmorrone/Binova_Devops_gs.git"

if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  [[ ! -e "$PROJECT_DIR" ]] || exit 1
  git clone -q --depth 1 "$REPO_URL" "$PROJECT_DIR"
elif [[ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]]; then
  git -C "$PROJECT_DIR" pull -q --ff-only
fi

cd "$PROJECT_DIR"

[[ -f docker-compose.yml && -f .env.example ]] || exit 1

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env

  PASSWORD="$(openssl rand -hex 24)"
  JWT="$(openssl rand -base64 48 | tr -d '\n')"

  sed -i "s#TROQUE_POR_UMA_SENHA_FORTE#${PASSWORD}#" .env
  sed -i "s#TROQUE_PELA_SAIDA_DO_OPENSSL#${JWT}#" .env
fi

docker compose config --quiet
docker compose up -d --build --quiet-pull

healthy=0

for i in $(seq 1 24); do
  if curl -fsS \
    --connect-timeout 3 \
    --max-time 5 \
    http://127.0.0.1:8080/actuator/health >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 5
done

[[ "$healthy" -eq 1 ]] || exit 2

echo "BINOVA_DEPLOY_OK"
REMOTE

if ! az vm run-command invoke \
  -g "$RESOURCE_GROUP" \
  -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts @"$REMOTE_SCRIPT" \
  --query "value[].message" \
  -o tsv > "$RESULT_FILE"; then
  cat "$RESULT_FILE"
  exit 1
fi

if ! grep -q "BINOVA_DEPLOY_OK" "$RESULT_FILE"; then
  cat "$RESULT_FILE"
  exit 1
fi

PUBLIC_IP="$(az vm show -d \
  -g "$RESOURCE_GROUP" \
  -n "$VM_NAME" \
  --query publicIps \
  -o tsv)"

printf '\nAPI: http://%s:8080/actuator/health\n' "$PUBLIC_IP"
printf 'Swagger: http://%s:8080/swagger-ui.html\n' "$PUBLIC_IP"
printf 'SSH: ssh %s@%s\n' "$ADMIN_USER" "$PUBLIC_IP"
