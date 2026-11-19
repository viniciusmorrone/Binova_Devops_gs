
#!/usr/bin/env bash
# Testa o CRUD da API Binova e seus relacionamentos.
# Uso: bash scripts/testar-crud.sh http://IP_PUBLICO_DA_VM:8080

set -euo pipefail

API="${1:?Informe a URL da API, ex.: http://IP_PUBLICO_DA_VM:8080}"
API="${API%/}"

SENHA_ADMIN="${APP_DEMO_ADMIN_PASSWORD:-AdminLocal2026}"
JSON="Content-Type: application/json"

# Extrai um campo da resposta JSON.
campo() {
    local nome="$1"

    python3 -c '
import json
import sys

nome = sys.argv[1]

try:
    dados = json.load(sys.stdin)
    valor = dados.get(nome) if isinstance(dados, dict) else None

    if valor is None or valor == "":
        raise ValueError("Campo ausente: " + nome)

    print(valor)

except (ValueError, json.JSONDecodeError) as erro:
    print("Erro ao ler JSON:", erro, file=sys.stderr)
    sys.exit(1)
' "$nome"
}

# Realiza login e valida o token JWT.
echo "== Login ADMIN (JWT)"

TOKEN=$(curl -fsS -X POST "$API/api/auth/login" \
    -H "$JSON" \
    -d "{\"email\":\"admin@binova.local\",\"senha\":\"$SENHA_ADMIN\"}" \
    | campo token)

if [[ -z "$TOKEN" ]]; then
    echo "Erro: token JWT não recebido."
    exit 1
fi

AUTH="Authorization: Bearer $TOKEN"
echo "Login realizado com sucesso."

# CREATE: cadastra um ponto de coleta.
echo
echo "== CREATE POST /api/pontos-coleta"

PONTO=$(curl -fsS -X POST "$API/api/pontos-coleta" \
    -H "$JSON" -H "$AUTH" \
    -d '{"nome":"Lixeira Praca Central","descricaoLocalizacao":"Praca Central - Bloco A","capacidadeLitros":80}')

echo "$PONTO"
PONTO_ID=$(printf '%s' "$PONTO" | campo id)

# READ: consulta o ponto cadastrado.
echo
echo "== READ GET /api/pontos-coleta/$PONTO_ID"

curl -fsS "$API/api/pontos-coleta/$PONTO_ID"
echo

# UPDATE: atualiza os dados do ponto.
echo
echo "== UPDATE PUT /api/pontos-coleta/$PONTO_ID"

curl -fsS -X PUT "$API/api/pontos-coleta/$PONTO_ID" \
    -H "$JSON" -H "$AUTH" \
    -d '{"nome":"Lixeira Praca Central (atualizada)","descricaoLocalizacao":"Praca Central - Bloco B","capacidadeLitros":120}'
echo

# CREATE: registra uma leitura relacionada ao ponto.
echo
echo "== CREATE POST /api/pontos-coleta/$PONTO_ID/leituras"

curl -fsS -X POST "$API/api/pontos-coleta/$PONTO_ID/leituras" \
    -H "$JSON" -H "$AUTH" \
    -d '{"distanciaCm":12,"nivelPercentual":85}'
echo

# CREATE: registra uma ocorrência relacionada ao ponto.
echo
echo "== CREATE POST /api/ocorrencias"

OCOR=$(curl -fsS -X POST "$API/api/ocorrencias" \
    -H "$JSON" -H "$AUTH" \
    -d "{\"pontoColetaId\":$PONTO_ID,\"tipo\":\"LIXEIRA_CHEIA\",\"descricao\":\"Lixeira cheia na praca\"}")

echo "$OCOR"
OCOR_ID=$(printf '%s' "$OCOR" | campo id)

# READ: consulta a ocorrência criada.
echo
echo "== READ GET /api/ocorrencias/$OCOR_ID"

curl -fsS "$API/api/ocorrencias/$OCOR_ID" -H "$AUTH"
echo

# UPDATE: altera a ocorrência.
echo
echo "== UPDATE PUT /api/ocorrencias/$OCOR_ID"

curl -fsS -X PUT "$API/api/ocorrencias/$OCOR_ID" \
    -H "$JSON" -H "$AUTH" \
    -d '{"tipo":"DESCARTE_IRREGULAR","descricao":"Lixo descartado ao redor da lixeira"}'
echo

# DELETE: remove fisicamente a ocorrência.
echo
echo "== DELETE /api/ocorrencias/$OCOR_ID"

STATUS=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X DELETE "$API/api/ocorrencias/$OCOR_ID" -H "$AUTH")

echo "HTTP $STATUS"

if [[ "$STATUS" != "200" && "$STATUS" != "204" ]]; then
    echo "Erro: exclusão não confirmada."
    exit 1
fi

# Verifica se a ocorrência removida retorna HTTP 404.
echo
echo "== READ após DELETE (esperado 404)"

STATUS=$(curl -sS -o /dev/null -w "%{http_code}" \
    "$API/api/ocorrencias/$OCOR_ID" -H "$AUTH")

echo "HTTP $STATUS"

if [[ "$STATUS" != "404" ]]; then
    echo "Erro: esperado HTTP 404 após exclusão."
    exit 1
fi

# Resultado final.
echo
echo "== TESTES FINALIZADOS COM SUCESSO"
echo "Ponto de coleta criado: ID=$PONTO_ID"
echo "Ocorrência removida: ID=$OCOR_ID"
echo "Ponto mantido para consulta SELECT/JOIN no PostgreSQL."
