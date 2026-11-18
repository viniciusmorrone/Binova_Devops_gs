#!/usr/bin/env bash
# Demonstra o CRUD da API Binova (ponto_coleta, leitura_sensor, ocorrencia).
# Uso: bash scripts/testar-crud.sh http://IP_PUBLICO_DA_VM:8080
set -euo pipefail
API="${1:?Informe a URL da API, ex.: http://IP_PUBLICO_DA_VM:8080}"
SENHA_ADMIN="${APP_DEMO_ADMIN_PASSWORD:-AdminLocal2026}"
JSON='Content-Type: application/json'
campo() { sed -E "s/.*\"$1\":\"?([^,\"]+)\"?.*/\1/"; }

echo "== Login ADMIN (JWT)"
TOKEN=$(curl -s -X POST "$API/api/auth/login" -H "$JSON" \
  -d "{\"email\":\"admin@binova.local\",\"senha\":\"$SENHA_ADMIN\"}" | campo token)
AUTH="Authorization: Bearer $TOKEN"

echo "== CREATE  POST /api/pontos-coleta"
PONTO=$(curl -s -X POST "$API/api/pontos-coleta" -H "$JSON" -H "$AUTH" \
  -d '{"nome":"Lixeira Praca Central","descricaoLocalizacao":"Praca Central - Bloco A","capacidadeLitros":80}')
echo "$PONTO"; PONTO_ID=$(echo "$PONTO" | campo id)

echo; echo "== READ    GET /api/pontos-coleta/$PONTO_ID"
curl -s "$API/api/pontos-coleta/$PONTO_ID"

echo; echo "== UPDATE  PUT /api/pontos-coleta/$PONTO_ID"
curl -s -X PUT "$API/api/pontos-coleta/$PONTO_ID" -H "$JSON" -H "$AUTH" \
  -d '{"nome":"Lixeira Praca Central (atualizada)","descricaoLocalizacao":"Praca Central - Bloco B","capacidadeLitros":120}'

echo; echo "== CREATE  POST /api/pontos-coleta/$PONTO_ID/leituras (tabela relacionada)"
curl -s -X POST "$API/api/pontos-coleta/$PONTO_ID/leituras" -H "$JSON" -H "$AUTH" \
  -d '{"distanciaCm":12,"nivelPercentual":85}'

echo; echo "== CREATE  POST /api/ocorrencias (tabela relacionada)"
OCOR=$(curl -s -X POST "$API/api/ocorrencias" -H "$JSON" -H "$AUTH" \
  -d "{\"pontoColetaId\":$PONTO_ID,\"tipo\":\"LIXEIRA_CHEIA\",\"descricao\":\"Lixeira cheia na praca\"}")
echo "$OCOR"; OCOR_ID=$(echo "$OCOR" | campo id)

echo; echo "== READ    GET /api/ocorrencias/$OCOR_ID"
curl -s "$API/api/ocorrencias/$OCOR_ID" -H "$AUTH"

echo; echo "== UPDATE  PUT /api/ocorrencias/$OCOR_ID"
curl -s -X PUT "$API/api/ocorrencias/$OCOR_ID" -H "$JSON" -H "$AUTH" \
  -d '{"tipo":"DESCARTE_IRREGULAR","descricao":"Lixo descartado ao redor da lixeira"}'

echo; echo "== DELETE  DELETE /api/ocorrencias/$OCOR_ID (exclusao fisica)"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X DELETE "$API/api/ocorrencias/$OCOR_ID" -H "$AUTH"

echo "== READ apos DELETE (esperado 404)"
curl -s -o /dev/null -w "HTTP %{http_code}\n" "$API/api/ocorrencias/$OCOR_ID" -H "$AUTH"

echo "Ponto de coleta criado: id=$PONTO_ID (mantido para o SELECT/JOIN no banco)"
