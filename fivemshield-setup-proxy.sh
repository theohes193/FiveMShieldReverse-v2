#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "Erreur : Ce script doit être exécuté en tant que root."
    exit 1
fi

read -p "Entrez le domaine pour le reverse proxy (ex: proxy-votreclient.com): " DOMAIN
read -p "Entrez l'IP de la machine à protéger (ex: 192.168.1.100): " TARGET_IP
read -p "Entrez le port de la machine à protéger (ex: 30120): " TARGET_PORT
read -p "Entrez une clé CDN pour le serveur (ex: MaCleCDN123): " CDN_KEY

if [ -z "$DOMAIN" ] || [ -z "$TARGET_IP" ] || [ -z "$TARGET_PORT" ] || [ -z "$CDN_KEY" ]; then
    echo "Erreur : Tous les champs doivent être remplis."
    exit 1
fi

echo "Configuration du reverse proxy pour $DOMAIN vers $TARGET_IP:$TARGET_PORT..."


echo "Mise à jour des paquets et installation de Nginx..."
apt update && apt install -y nginx certbot python3-certbot-nginx

if ! systemctl is-active --quiet nginx; then
    echo "Démarrage de Nginx..."
    systemctl start nginx
    systemctl enable nginx
fi

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
echo "Création de la configuration Nginx..."

cat <<EOF > $NGINX_CONF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://$TARGET_IP:$TARGET_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Désactiver la mise en cache et buffer pour un trafic direct
        proxy_cache off;
        proxy_buffering off;
    }
}
EOF

ln -s $NGINX_CONF /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t
if [ $? -ne 0 ]; then
    echo "Erreur : La configuration Nginx contient des erreurs."
    exit 1
fi

echo "Rechargement de Nginx..."
systemctl reload nginx


read -p "Voulez-vous activer HTTPS avec Let's Encrypt ? (o/n): " ENABLE_HTTPS
if [[ "$ENABLE_HTTPS" =~ ^[Oo]$ ]]; then
    certbot --nginx -d $DOMAIN
fi

echo
echo "Reverse proxy configuré avec succès ! Voici les lignes à ajouter dans le fichier de configuration FiveM :"
echo
echo "sv_useDirectListing false"
echo "sv_forceIndirectListing true"
echo "sv_endpoints \"$TARGET_IP:$TARGET_PORT\""
echo "sv_listingIpOverride \"$DOMAIN:443\""
echo "sv_listingHostOverride \"$DOMAIN:443\""
echo "sv_proxyIPRanges \"$TARGET_IP/32\""
echo "fileserver_add \".*\" \"https://$DOMAIN/files\""
echo "set adhesive_cdnKey \"$CDN_KEY\""
