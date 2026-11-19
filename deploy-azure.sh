#!/usr/bin/env bash
set -Eeuo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-binova-gs}"
VM_NAME="${VM_NAME:-vm-binova-gs}"
LOCATION="${LOCATION:-brazilsouth}"
VM_SIZE="${VM_SIZE:-Standard_D2s_v4}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
REPO_URL="${REPO_URL:-https://github.com/viniciusmorrone/Binova_Devops_gs.git}"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }
command -v az >/dev/null || fail "Azure CLI nao encontrada. Abra o Azure Cloud Shell em modo Bash."
az account show --query id -o tsv >/dev/null 2>&1 || fail "Faca login no Azure antes de continuar."
SUB_NAME="$(az account show --query name -o tsv)"
SUB_ID="$(az account show --query id -o tsv)"
log "Assinatura ativa: $SUB_NAME ($SUB_ID)"
printf 'Grupo: %s | VM: %s | Regiao: %s | SKU: %s\n' "$RESOURCE_GROUP" "$VM_NAME" "$LOCATION" "$VM_SIZE"
printf 'ATENCAO: criar/iniciar VM gera consumo de creditos Azure. A porta 8080 ficara publica.\n'
read -r -p "Digite CRIAR para autorizar provisionamento e deploy: " CONFIRM
[[ "$CONFIRM" == "CRIAR" ]] || fail "Operacao cancelada."

if ! az group exists --name "$RESOURCE_GROUP" | grep -qx true; then
  log "Criando grupo de recursos"
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
else
  log "Grupo de recursos existente; sera reutilizado"
fi

if az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --output none >/dev/null 2>&1; then
  log "VM existente. Nenhuma VM duplicada sera criada."
  VM_STATE="$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" -o tsv 2>/dev/null || true)"
  if [[ "$VM_STATE" != 'PowerState/running' ]]; then
    log "Iniciando VM existente"
    az vm start --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --output none
  fi
else
  log "Criando VM Ubuntu 22.04 (disponibilidade de cota e SKU depende da assinatura)"
  az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --location "$LOCATION" \
    --image Ubuntu2204 \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    --output none
fi

log "Verificando acesso SSH (22) e API (8080)"
if ! az network nsg rule list --resource-group "$RESOURCE_GROUP" \
  --nsg-name "${VM_NAME}NSG" \
  --query "[?destinationPortRange=='22' && access=='Allow' && direction=='Inbound'].name | [0]" -o tsv 2>/dev/null | grep -q .; then
  az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --port 22 --priority 1000 --output none
fi
if ! az network nsg rule list --resource-group "$RESOURCE_GROUP" \
  --nsg-name "${VM_NAME}NSG" \
  --query "[?destinationPortRange=='8080' && access=='Allow'].name | [0]" -o tsv 2>/dev/null | grep -q .; then
  az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --port 8080 --priority 1010 --output none
fi

REMOTE_SCRIPT="$(mktemp)"
RESULT_FILE="$(mktemp)"
trap 'rm -f "$REMOTE_SCRIPT" "$RESULT_FILE"' EXIT
cat > "$REMOTE_SCRIPT" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

echo '==> Verificando dependencias'
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl git openssl
  curl -fsSL https://get.docker.com | sh
fi
if ! command -v git >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq git
fi
if ! command -v openssl >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq openssl
fi
systemctl enable --now docker

PROJECT_DIR=/opt/binova
REPO_URL=https://github.com/viniciusmorrone/Binova_Devops_gs.git
if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  if [[ -e "$PROJECT_DIR" ]]; then
    echo "ERRO: $PROJECT_DIR existe e nao e clone Git. Nenhum arquivo sera sobrescrito." >&2
    exit 1
  fi
  git clone --depth 1 "$REPO_URL" "$PROJECT_DIR"
else
  if [[ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]]; then
    echo '==> Atualizando repositorio sem sobrescrever modificacoes locais'
    git -C "$PROJECT_DIR" pull --ff-only
  else
    echo '==> Repositorio com modificacoes locais; preservando os arquivos existentes'
  fi
fi
cd "$PROJECT_DIR"
[[ -f docker-compose.yml && -f .env.example ]] || { echo 'ERRO: arquivos docker-compose.yml/.env.example nao encontrados' >&2; exit 1; }
if [[ ! -f .env ]]; then
  echo '==> Criando .env com segredos gerados na VM'
  cp .env.example .env
  chmod 600 .env
  PASSWORD="$(openssl rand -hex 24)"
  JWT="$(openssl rand -base64 48 | tr -d '\n')"
  sed -i "s#TROQUE_POR_UMA_SENHA_FORTE#${PASSWORD}#" .env
  sed -i "s#TROQUE_PELA_SAIDA_DO_OPENSSL#${JWT}#" .env
else
  echo '==> Reutilizando .env existente sem substituir senhas'
fi

echo '==> Validando o Docker Compose'
docker compose config --quiet

echo '==> Construindo e iniciando os containers'
docker compose up -d --build

echo '==> Estado dos containers'
docker compose ps

echo '==> Testando healthcheck HTTP local'
healthy=0
for i in $(seq 1 24); do
  if curl -fsS --connect-timeout 3 --max-time 5 http://127.0.0.1:8080/actuator/health >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 5
done
if [[ "$healthy" -eq 1 ]]; then
  echo 'HEALTHCHECK_OK'
else
  echo 'AVISO: API nao respondeu ao healthcheck dentro da janela. Consulte os logs:'
  docker compose logs --tail=60 app
  exit 2
fi
echo 'BINOVA_DEPLOY_OK'
REMOTE

log "Instalando Docker e publicando o Binova pela propria Azure (Run Command)"
if ! az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts @"$REMOTE_SCRIPT" \
    --query "value[].message" -o tsv > "$RESULT_FILE"; then
  cat "$RESULT_FILE"
  fail "A execucao remota falhou. Consulte o Azure Run Command e os logs da VM."
fi
cat "$RESULT_FILE"
grep -q 'BINOVA_DEPLOY_OK' "$RESULT_FILE" || fail "O deploy nao confirmou sucesso. Verifique a saida acima."

PUBLIC_IP="$(az vm show -d --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query publicIps -o tsv)"
log "Deploy concluido"
printf 'API:     http://%s:8080/actuator/health\n' "$PUBLIC_IP"
printf 'Swagger: http://%s:8080/swagger-ui.html\n' "$PUBLIC_IP"
printf 'SSH:     ssh %s@%s\n' "$ADMIN_USER" "$PUBLIC_IP"
printf '\nIMPORTANTE: a API demo tem contas de teste e esta exposta na internet.\n'
printf 'Desligue a VM apos a demonstracao: az vm deallocate -g %s -n %s\n' "$RESOURCE_GROUP" "$VM_NAME"
