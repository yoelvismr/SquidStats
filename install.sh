#! /bin/bash

# =============================================
# FUNCIONES DE UTILIDAD PARA MENSAJES
# =============================================

function error() {
    echo -e "\n\033[1;41m$1\033[0m\n"
}

function ok() {
    echo -e "\n\033[1;42m$1\033[0m\n"
}

function info() {
    echo -e "\n\033[1;44m$1\033[0m\n"
}

function checkSudo() {
    if [ "$EUID" -ne 0 ]; then
        error "ERROR: Este script debe ejecutarse con privilegios de superusuario."
        exit 1
    fi
}

# =============================================
# 🆕 CONFIGURACIÓN DE PROXY PARA PIP
# =============================================

function setupPipProxy() {
    local proxy_url="$1"
    
    if [ -n "$proxy_url" ]; then
        echo "🔌 Configurando proxy para pip: $proxy_url"
        export PIP_PROXY="$proxy_url"
        
        # Crear archivo de configuración de pip
        mkdir -p /root/.config/pip
        cat > /root/.config/pip/pip.conf << EOF
[global]
proxy = $proxy_url
trusted-host = pypi.org pypi.python.org files.pythonhosted.org
timeout = 60
retries = 3
EOF
        ok "Proxy configurado para pip"
    else
        echo "🌐 Sin proxy - conexión directa"
        # Limpiar configuración previa
        rm -f /root/.config/pip/pip.conf
    fi
}

function askForProxy() {
    echo "🔍 Configuración de red detectada:"
    echo "   Git funciona ✓"
    echo "   Pip falla ✗ (necesita proxy)"
    echo ""
    echo "¿Estás detrás de un proxy corporativo?"
    echo "Ejemplos:"
    echo "  http://ip_proxy:3128"
    echo "  http://usuario:contraseña@ip_proxy:3128"
    echo "  o dejar vacío para sin proxy"
    echo ""
    read -p "🔧 URL del proxy (o Enter para sin proxy): " proxy_input
    
    if [ -n "$proxy_input" ]; then
        setupPipProxy "$proxy_input"
        return 0
    else
        setupPipProxy ""
        return 0
    fi
}

# =============================================
# 🎯 INSTALACIÓN SOLO PARA PRODUCCIÓN
# =============================================

function showWelcome() {
    info "🚀 INSTALADOR DE SQUIDSTATS - MODO PRODUCCIÓN"
    echo "Este script instalará SquidStats en modo producción"
    echo "Este script instalará SquidStats en modo producción con:"
    echo "  • Nginx como proxy reverso"
    echo "  • Gunicorn como servidor de aplicación"
    echo "  • Servicio systemd automático"
    echo "  • Logs en /var/log/squidstats/"
    echo ""
    echo "📝 Para desarrollo: Clone el repositorio manualmente y ejecute con 'python app.py'"
    echo ""
}

function installDependencies() {
    local venv_dir="/opt/SquidStats/venv"

    if [ ! -d "$venv_dir" ]; then
        echo "Creando entorno virtual..."
        python3 -m venv "$venv_dir" || {
            error "Error creando entorno virtual"
            return 1
        }
        ok "Entorno virtual creado"
    fi

    echo "Instalando dependencias..."
    source "$venv_dir/bin/activate"

    # 🆕 ESTRATEGIA INTELIGENTE PARA PIP
    echo "🔧 Configurando pip..."
    
    # Opción 1: Con proxy si está configurado
    if [ -n "$PIP_PROXY" ]; then
        echo "📡 Usando proxy: $PIP_PROXY"
        pip install --proxy "$PIP_PROXY" --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org --upgrade pip || {
            echo "⚠️  Falló con proxy, intentando sin proxy..."
            pip install --upgrade pip
        }
    else
        # Opción 2: Sin proxy
        pip install --upgrade pip
    fi

    # Instalar dependencias con estrategia similar
    echo "📦 Instalando paquetes desde requirements.txt..."
    
    if [ -n "$PIP_PROXY" ]; then
        pip install --proxy "$PIP_PROXY" --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org -r /opt/SquidStats/requirements.txt || {
            echo "⚠️  Falló con proxy, intentando sin proxy..."
            pip install -r /opt/SquidStats/requirements.txt
        }
    else
        pip install -r /opt/SquidStats/requirements.txt
    fi

    if [ $? -eq 0 ]; then
        ok "✅ Dependencias instaladas correctamente"
        deactivate
        return 0
    else
        error "❌ Error crítico instalando dependencias"
        echo "💡 Soluciones:"
        echo "   1. Verificar conexión a internet"
        echo "   2. Configurar proxy correctamente"
        echo "   3. Instalar dependencias manualmente"
        deactivate
        return 1
    fi
}

function checkPackages() {
    local packages=("python3" "python3-pip" "python3-venv" "nginx" "git")
    local missing=()

    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "Instalando paquetes del sistema: ${missing[*]}"
        apt-get update
        apt-get install -y "${missing[@]}" || {
            error "Error instalando paquetes del sistema"
            return 1
        }
        ok "Paquetes del sistema instalados"
    else
        echo "✅ Paquetes del sistema OK"
    fi
}

function cloneOrUpdateRepo() {
    local repo_url="https://github.com/kaelthasmanu/SquidStats.git"
    local branch="main"

    if [ -d "/opt/SquidStats" ]; then
        echo "🔄 Actualizando código existente..."
        cd /opt/SquidStats
        
        if [ -f ".env" ]; then
            cp .env /tmp/squidstats_env_backup
            echo "⚙️  Configuración .env preservada"
        fi

        if git pull origin "$branch"; then
            [ -f "/tmp/squidstats_env_backup" ] && mv /tmp/squidstats_env_backup .env
            ok "✅ Código actualizado"
            return 0
        else
            error "❌ Error actualizando código"
            return 1
        fi
    else
        echo "📥 Clonando repositorio..."
        if git clone "$repo_url" /opt/SquidStats; then
            cd /opt/SquidStats
            git checkout "$branch"
            ok "✅ Repositorio clonado"
            return 0
        else
            error "❌ Error clonando repositorio"
            return 1
        fi
    fi
}

function checkSquidLog() {
    local log_file="/var/log/squid/access.log"
    if [ ! -f "$log_file" ]; then
        echo "⚠️  No se encontró log de Squid en $log_file"
        echo "   Esto es normal si Squid no está instalado"
        return 1
    else
        echo "✅ Log de Squid encontrado"
        return 0
    fi
}

function createProductionEnv() {
    local env_file="/opt/SquidStats/.env"

    if [ -f "$env_file" ]; then
        echo "⚙️  Manteniendo configuración existente"
        return 0
    fi

    echo "📝 Creando configuración de producción..."
    cat >"$env_file" <<EOF
# =============================================
# CONFIGURACIÓN DE PRODUCCIÓN
# =============================================
VERSION=2
FLASK_DEBUG=False
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
DATABASE_TYPE=SQLITE
DATABASE_STRING_CONNECTION=/var/lib/squidstats/squidstats.db
SQUID_LOG=/var/log/squid/access.log
LOG_FORMAT=DETAILED
SQUID_HOST=127.0.0.1
SQUID_PORT=3128
HOST=0.0.0.0
PORT=5000
REFRESH_INTERVAL=60
BLACKLIST_DOMAINS="facebook.com,twitter.com,instagram.com,tiktok.com,youtube.com,netflix.com"
HTTP_PROXY=""
SQUID_CONFIG_PATH=/etc/squid/squid.conf
ACL_FILES_DIR=/etc/squid/config/acls
LOG_FILE=/var/log/squidstats/app.log
EOF

    mkdir -p /var/lib/squidstats /var/log/squidstats
    chown -R proxy:proxy /var/lib/squidstats /var/log/squidstats 2>/dev/null || true
    
    ok "✅ Configuración creada"
}

function setupNginx() {
    echo "🌐 Configurando Nginx..."
    
    if ! command -v nginx &> /dev/null; then
        echo "📦 Instalando Nginx..."
        apt-get install -y nginx
    fi

    cat > "/etc/nginx/sites-available/squidstats" << 'EOF'
server {
    listen 80;
    server_name _;
    
    location /static {
        alias /opt/SquidStats/static;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
        log_not_found off;
    }
    
    location /socket.io {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
    }
    
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";
    
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
}
EOF

    ln -sf "/etc/nginx/sites-available/squidstats" "/etc/nginx/sites-enabled/"
    rm -f "/etc/nginx/sites-enabled/default"
    
    if nginx -t; then
        systemctl reload nginx
        systemctl enable nginx
        ok "✅ Nginx configurado"
    else
        error "❌ Error en configuración de Nginx"
        return 1
    fi
}

function createService() {
    local service_file="/etc/systemd/system/squidstats.service"

    if [ -f "$service_file" ]; then
        echo "🔄 Reiniciando servicio existente..."
        systemctl restart squidstats.service
        return 0
    fi

    echo "⚙️  Creando servicio systemd..."
    cat >"$service_file" <<EOF
[Unit]
Description=SquidStats Web Application
After=network.target nginx.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/SquidStats
ExecStart=/opt/SquidStats/venv/bin/gunicorn --config /opt/SquidStats/gunicorn.conf.py wsgi:app
Restart=always
RestartSec=5
EnvironmentFile=/opt/SquidStats/.env
Environment=PATH=/opt/SquidStats/venv/bin:\$PATH

MemoryLimit=2048M
TimeoutStartSec=30
TimeoutStopSec=10

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/SquidStats /var/lib/squidstats /var/log/squidstats

StandardOutput=journal
StandardError=journal
SyslogIdentifier=squidstats

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable squidstats.service
    systemctl start squidstats.service
    
    ok "✅ Servicio creado e iniciado"
}

function uninstallSquidStats() {
    echo -e "\n\033[1;43mDESINSTALACIÓN DE SQUIDSTATS\033[0m"
    read -p "¿Está seguro? (s/N): " confirm

    if [[ ! "$confirm" =~ ^[sS]$ ]]; then
        echo "Desinstalación cancelada."
        return 0
    fi

    echo "🗑️  Desinstalando..."
    
    systemctl stop squidstats.service 2>/dev/null
    systemctl disable squidstats.service 2>/dev/null
    rm -f "/etc/systemd/system/squidstats.service"
    systemctl daemon-reload
    
    [ -d "/opt/SquidStats" ] && rm -rf "/opt/SquidStats"
    [ -d "/var/lib/squidstats" ] && rm -rf "/var/lib/squidstats"
    [ -d "/var/log/squidstats" ] && rm -rf "/var/log/squidstats"
    
    if [ -f "/etc/nginx/sites-enabled/squidstats" ]; then
        rm -f "/etc/nginx/sites-enabled/squidstats"
        rm -f "/etc/nginx/sites-available/squidstats"
        systemctl reload nginx
    fi

    ok "✅ SquidStats desinstalado completamente"
}

function main() {
    checkSudo
    showWelcome
    
    # 🆕 DETECCIÓN INTERACTIVA DE PROXY
    askForProxy

    if [ "$1" = "--update" ]; then
        echo "🔄 Actualizando..."
        checkPackages
        installDependencies
        cloneOrUpdateRepo
        systemctl restart squidstats.service
        ok "✅ Actualización completada"

    elif [ "$1" = "--uninstall" ]; then
        uninstallSquidStats

    else
        echo "🚀 Iniciando instalación..."
        checkPackages
        cloneOrUpdateRepo || exit 1
        checkSquidLog
        installDependencies || {
            error "❌ No se puede continuar - dependencias fallaron"
            exit 1
        }
        createProductionEnv
        setupNginx
        createService

        ok "🎉 Instalación completada!"
        echo "🌐 Acceda en: http://$(hostname -I | awk '{print $1}')"
        echo "📊 Nginx: puerto 80"
        echo "🔧 Gunicorn: puerto 5000"
        echo "📝 Logs: /var/log/squidstats/"
    fi
}

case "$1" in
"--update") main "$1" ;;
"--uninstall") main "$1" ;;
"") main ;;
*) 
    echo "Uso: $0 [--update|--uninstall]"
    echo "  El script detectará automáticamente si necesitas proxy"
    exit 1
    ;;
esac