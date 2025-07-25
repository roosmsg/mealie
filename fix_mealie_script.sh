#!/usr/bin/env bash

# Fixed Mealie Install Script using TTeck's helper functions
# Author: Adapted from community-scripts
# License: MIT

# Source TTeck Proxmox helper functions
source <(curl -fsSL https://raw.githubusercontent.com/tteck/Proxmox/0a35b1a5bb3bb8c61aa1e8f95e14048667263101/misc/install.func)

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
apt-get install -y \
  build-essential \
  libpq-dev \
  libwebp-dev \
  libsasl2-dev \
  libldap2-dev \
  libssl-dev
msg_ok "Installed Dependencies"

PYTHON_VERSION="3.12" setup_uv
POSTGRES_VERSION="16" setup_postgresql
NODE_MODULE="yarn" NODE_VERSION="20" setup_nodejs

fetch_and_deploy_gh_release "mealie" "mealie-recipes/mealie" "tarball" "latest" "/opt/mealie"

msg_info "Setup Database"
DB_NAME=mealie_db
DB_USER=mealie__user
DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | cut -c1-13)
sudo -u postgres psql -c "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';"
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME WITH OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET client_encoding TO 'utf8';"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET default_transaction_isolation TO 'read committed';"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET timezone TO 'UTC'"
sudo -u postgres psql -c "ALTER USER $DB_USER WITH SUPERUSER;"
{
  echo "Mealie-Credentials"
  echo "Mealie Database User: $DB_USER"
  echo "Mealie Database Password: $DB_PASS"
  echo "Mealie Database Name: $DB_NAME"
} >>~/mealie.creds
msg_ok "Set up Database"

msg_info "Building Frontend"
export NUXT_TELEMETRY_DISABLED=1
cd /opt/mealie/frontend || exit 1
yarn install --prefer-offline --frozen-lockfile --non-interactive --production=false --network-timeout 1000000 || { echo "❌ yarn install failed"; exit 1; }
yarn generate || { echo "❌ yarn generate failed"; exit 1; }
msg_ok "Built Frontend"

msg_info "Copying Built Frontend into Backend Package"
cp -r /opt/mealie/frontend/dist /opt/mealie/mealie/frontend
msg_ok "Copied Frontend"

msg_info "Preparing Backend (Poetry)"
uv venv /opt/mealie/.venv || { echo "❌ Failed to create virtualenv"; exit 1; }
/opt/mealie/.venv/bin/python -m ensurepip --upgrade
/opt/mealie/.venv/bin/python -m pip install --upgrade pip
/opt/mealie/.venv/bin/pip install uv
cd /opt/mealie
/opt/mealie/.venv/bin/uv pip install poetry==2.0.1
/opt/mealie/.venv/bin/poetry self add "poetry-plugin-export>=1.9"
msg_ok "Prepared Poetry"

msg_info "Writing Environment File"
cat <<EOF >/opt/mealie/mealie.env
HOST=0.0.0.0
PORT=9000
DB_ENGINE=postgres
POSTGRES_SERVER=localhost
POSTGRES_PORT=5432
POSTGRES_USER=${DB_USER}
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_DB=${DB_NAME}
NLTK_DATA=/nltk_data
PRODUCTION=true
STATIC_FILES=/opt/mealie/frontend/dist
EOF
msg_ok "Wrote Environment File"

msg_info "Creating Start Script"
cat <<'EOF' >/opt/mealie/start.sh
#!/bin/bash
set -a
source /opt/mealie/mealie.env
set +a
exec /opt/mealie/.venv/bin/mealie
EOF
chmod +x /opt/mealie/start.sh
msg_ok "Created Start Script"

msg_info "Building Mealie Backend Wheel"
cd /opt/mealie
/opt/mealie/.venv/bin/poetry build --output dist
MEALIE_VERSION=$(/opt/mealie/.venv/bin/poetry version --short)
/opt/mealie/.venv/bin/poetry export --only=main --extras=pgsql --output=dist/requirements.txt
echo "mealie[pgsql]==$MEALIE_VERSION \\" >>dist/requirements.txt
/opt/mealie/.venv/bin/poetry run pip hash dist/mealie-$MEALIE_VERSION*.whl | tail -n1 | tr -d '\n' >>dist/requirements.txt
echo " \\" >>dist/requirements.txt
/opt/mealie/.venv/bin/poetry run pip hash dist/mealie-$MEALIE_VERSION*.tar.gz | tail -n1 >>dist/requirements.txt
msg_ok "Built Wheel + Requirements"

msg_info "Installing Mealie via uv"
/opt/mealie/.venv/bin/uv pip install --require-hashes -r /opt/mealie/dist/requirements.txt --find-links dist || { echo "❌ Mealie install failed"; exit 1; }
msg_ok "Installed Mealie"

msg_info "Downloading NLTK Data"
mkdir -p /nltk_data/
/opt/mealie/.venv/bin/python -m nltk.downloader -d /nltk_data averaged_perceptron_tagger_eng
msg_ok "Downloaded NLTK Data"

msg_info "Set Symbolic Links for Mealie"
ln -sf /opt/mealie/.venv/bin/mealie /usr/local/bin/mealie
ln -sf /opt/mealie/.venv/bin/poetry /usr/local/bin/poetry
msg_ok "Set Symbolic Links"

msg_info "Creating Systemd Service"
cat <<EOF >/etc/systemd/system/mealie.service
[Unit]
Description=Mealie Backend Server
After=network.target postgresql.service

[Service]
User=root
WorkingDirectory=/opt/mealie
ExecStart=/opt/mealie/start.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now mealie
msg_ok "Created Service"

motd_ssh
customize

msg_info "Cleaning up"
apt-get -y autoremove
apt-get -y autoclean
msg_ok "Cleaned"
