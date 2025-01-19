#!/bin/bash

# Vérifie si l'utilisateur est root
if [ "$EUID" -ne 0 ]; then
  echo "Veuillez exécuter ce script en tant que root ou avec sudo."
  exit 1
fi

# Chemins fixes
STREAM_CONF="/etc/nginx/stream-proxy.conf"
DEFAULT_CONF_BASE="/etc/nginx/sites-available"
CERT_PATH="/etc/CFSSL/tst/fullchain.pem"
KEY_PATH="/etc/CFSSL/tst/privkey.pem"

# Fonction pour générer une chaîne de 8 lettres aléatoires
generate_random_string() {
  echo "$(tr -dc 'a-zA-Z' < /dev/urandom | head -c 8)"
}

# Fonction pour générer un port aléatoire
generate_random_port() {
  local RANDOM_PORT
  while :; do
    RANDOM_PORT=$((RANDOM % 11 + 30130)) # Génère un port entre 30130 et 30140
    if [ "$RANDOM_PORT" -ne "$1" ]; then # S'assure qu'il est différent du port de destination
      echo "$RANDOM_PORT"
      return
    fi
  done
}

# Fonction pour ajouter un nouveau proxy
add_proxy() {
  read -p "Entrez l'adresse IP du serveur FiveM : " FIVEM_IP
  read -p "Entrez le port du serveur FiveM (par défaut 30120) : " FIVEM_PORT
  FIVEM_PORT=${FIVEM_PORT:-30120}
  read -p "Entrez le domaine pour ce proxy (ex: subdomain.yourdomain.com) : " DOMAIN

  # Vérifie si le proxy existe déjà dans le fichier stream-proxy.conf
  if grep -q "upstream backend_$FIVEM_PORT" "$STREAM_CONF"; then
    echo "Le proxy pour le port $FIVEM_PORT existe déjà dans $STREAM_CONF. Aucun changement."
    return
  fi

  # Génère un port d'écoute aléatoire
  LISTEN_PORT=$(generate_random_port "$FIVEM_PORT")

  # Génère un dossier de cache unique
  CACHE_ID=$(generate_random_string)
  CACHE_DIR="/srv/cache/$CACHE_ID"

  # Crée le dossier de cache s'il n'existe pas
  if [ ! -d "$CACHE_DIR" ]; then
    mkdir -p "$CACHE_DIR"
    echo "Création du répertoire de cache : $CACHE_DIR"
  fi

  # Bloc de configuration à ajouter
  NEW_PROXY_BLOCK="
    upstream backend_$FIVEM_PORT {
        server $FIVEM_IP:$FIVEM_PORT;
    }
    server {
        listen $LISTEN_PORT;
        proxy_pass backend_$FIVEM_PORT;
    }
    server {
        listen $LISTEN_PORT udp reuseport;
        proxy_pass backend_$FIVEM_PORT;
    }
"

  # Insère le bloc avant la dernière accolade avec awk
  awk -v block="$NEW_PROXY_BLOCK" '
    /^}/ && !x { print block; x=1 } 
    { print }
  ' "$STREAM_CONF" > "${STREAM_CONF}.tmp" && mv "${STREAM_CONF}.tmp" "$STREAM_CONF"

  # Création de la configuration Nginx pour ce domaine
  CONF_FILE="$DEFAULT_CONF_BASE/$DOMAIN"
  if [ -f "$CONF_FILE" ]; then
    echo "La configuration pour $DOMAIN existe déjà dans $CONF_FILE. Aucun changement."
  else
    echo "Création de la configuration pour $DOMAIN dans $CONF_FILE..."
    cat <<EOL > $CONF_FILE
upstream backend_$FIVEM_PORT {
    server $FIVEM_IP:$FIVEM_PORT;
}

proxy_cache_path $CACHE_DIR levels=1:2 keys_zone=assets_$FIVEM_PORT:48m max_size=20g inactive=2h;

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-Ip \$remote_addr;
        proxy_set_header X-Cfx-Source-Ip \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass_request_headers on;
        proxy_http_version 1.1;
        proxy_pass http://backend_$FIVEM_PORT;
    }

    location /files/ {
        proxy_pass http://backend_$FIVEM_PORT\$request_uri;
        add_header X-Cache-Status \$upstream_cache_status;
        proxy_cache_lock on;
        proxy_cache assets_$FIVEM_PORT;
        proxy_cache_valid 1y;
        proxy_cache_key \$request_uri\$is_args\$args;
        proxy_cache_revalidate on;
        proxy_cache_min_uses 1;
    }
}
EOL
    ln -s "$CONF_FILE" /etc/nginx/sites-enabled/
  fi

  echo "Proxy ajouté pour $DOMAIN avec IP $FIVEM_IP:$FIVEM_PORT et écoute sur le port $LISTEN_PORT."
  echo "Cache assigné : $CACHE_DIR"
  echo "=== Configuration Server CFG ==="
  echo "set sv_listingIpOverride \"$FIVEM_IP\""
  echo "set sv_forceIndirectListing false"
  echo "set sv_proxyIPRanges \"$FIVEM_IP/32\""
  echo "set sv_endpoints \"$FIVEM_IP:$FIVEM_PORT\""
  echo "set adhesive_cdnKey \"$(generate_random_string)\""
  echo "fileserver_remove \".*\""
  echo "fileserver_add \".*\" \"https://$DOMAIN/files\""
  echo "fileserver_list"
 
}

# Menu principal
while true; do
  echo "========================="
  echo "Gestionnaire de proxys FiveM"
  echo "1) Ajouter un nouveau proxy"
  echo "2) Afficher la configuration actuelle"
  echo "3) Quitter"
  echo "========================="
  read -p "Choisissez une option : " OPTION

  case $OPTION in
  1)
    add_proxy
    ;;
  2)
    echo "=== Configuration actuelle du stream ==="
    cat $STREAM_CONF
    echo "=== Fichiers disponibles dans sites-available ==="
    ls $DEFAULT_CONF_BASE
    ;;
  3)
    echo "Redémarrage de Nginx pour appliquer les modifications..."
    systemctl reload nginx
    echo "Fermeture du script."
    exit 0
    ;;
  *)
    echo "Option invalide."
    ;;
  esac
done
