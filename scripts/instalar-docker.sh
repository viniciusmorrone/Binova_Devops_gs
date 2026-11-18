#!/usr/bin/env bash
# Instala Docker Engine + Docker Compose plugin na VM Ubuntu (executar dentro da VM)
set -euo pipefail
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker
docker --version || sudo docker --version
sudo docker compose version
echo "Docker instalado. Saia (exit) e entre novamente via SSH para usar docker sem sudo."
