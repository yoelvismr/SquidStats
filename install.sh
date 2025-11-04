#!/bin/bash

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
        error "ERROR: Este script debe ejecutarse con privilegios de superusuario.\nPor favor, ejecútelo con el usuario: root $0"
        exit 1
    fi
}

# =============================================
# 🎯 INSTALACIÓN SOLO PARA PRODUCCIÓN
# =============================================

function showWelcome() {
    info "🚀 INSTALADOR DE SQUIDSTATS - MODO PRODUCCIÓN"
    echo "Este script instalará SquidStats en modo producción con:"
    echo "  • Nginx como proxy reverso"
    echo "  • Gunicorn como servidor de aplicación"
    echo "  • Servicio systemd automático"
    echo "  • Logs en /var/log/squidstats/"
    echo ""
    echo "📝 Para desarrollo: Clone el repositorio manualmente y ejecute con 'python app.py'"
    echo ""
}

function cloneOrUpdateRepo() {
    local repo_url="https://github.com/yoelvismr/SquidStats.git"
    local branch="main"
    local target_dir="/opt/SquidStats"

    if [ -d "$target_dir" ]; then
        echo "Actualizando instalación existente..."
        cd "$target_dir"
        
        # Preservar configuración existente
        if [ -f ".env" ]; then
            cp .env /tmp/squidstats_env_backup
            echo "Configuración .env preservada"
        fi

        if git pull origin "$branch"; then
            [ -f "/tmp/squidstats_env_backup" ] && mv /tmp/squidstats_env_backup .env
            ok "Repositorio actualizado"
            return 0
        else
            error "Error al actualizar el repositorio"
            return 1
        fi
    else
        echo "Clonando repositorio en $target_dir..."
        if git clone "$repo_url" "$target_dir"; then
            cd "$target_dir"
            git checkout "$branch"
            
            # Verificar que se clonó correctamente
            if [ -f "requirements.txt" ]; then
                ok "Repositorio clonado correctamente"
                echo "Contenido del repositorio clonado:"
                ls -la "$target_dir"
                return 0
            else
                error "ERROR: El repositorio se clonó pero no contiene requirements.txt"
                echo "Contenido del directorio:"
                ls -la "$target_dir"
                return 1
            fi
        else
            error "Error al clonar el repositorio"
            return 1
        fi
    fi
}

function installDependencies() {
    local venv_dir="/opt/SquidStats/venv"
    local requirements_file="/opt/SquidStats/requirements.txt"

    # Verificar que requirements.txt existe ANTES de crear el entorno virtual
    if [ ! -f "$requirements_file" ]; then
        error "ERROR: No se encontró $requirements_file"
        error "El repositorio no se clonó correctamente"
        return 1
    fi

    echo "Creando entorno virtual en $venv_dir..."
    python3 -m venv "$venv_dir"
    
    if [ $? -ne 0 ]; then
        error "Error al crear el entorno virtual"
        return 1
    fi
    ok "Entorno virtual creado"

    echo "Instalando dependencias desde $requirements_file..."
    source "$venv_dir/bin/activate"
    
    # Actualizar pip primero
    pip install --upgrade pip
    
    # Verificar conexión a internet antes de instalar
    echo "Verificando conexión a internet..."
    if ! ping -c 1 -W 3 pypi.org &> /dev/null; then
        error "ERROR: Sin conexión a internet. No se pueden instalar dependencias."
        deactivate
        return 1
    fi

    echo "Instalando dependencias, esto puede tomar unos minutos..."
    pip install -r "$requirements_file"

    if [ $? -ne 0 ]; then
        error "Error al instalar dependencias"
        deactivate
        return 1
    fi

    # Verificar que las dependencias principales se instalaron
    echo "Verificando instalación de dependencias..."
    pip list | grep -E "(flask|gunicorn|sqlalchemy)"

    ok "Dependencias instaladas correctamente"
    deactivate
    return 0
}

function checkPackages() {
    local packages=("git" "python3" "python3-pip" "python3-venv" "curl" "build-essential" "libssl-dev" "python3-dev" "nginx")
    local missing=()

    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "Instalando paquetes faltantes: ${missing[*]}"
        apt-get update
        apt-get install -y "${missing[@]}" || {
            error "ERROR: No se pudieron instalar los paquetes"
            exit 1
        }
        ok "Paquetes instalados"
    else
        echo "Todos los paquetes necesarios están instalados"
    fi
}

function checkSquidLog() {
    local log_file="/var/log/squid/access.log"
    if [ ! -f "$log_file" ]; then
        error "¡ADVERTENCIA!: No se encontró el log de Squid en $log_file"
        echo "Puede crear el archivo manualmente con:"
        echo "sudo touch /var/log/squid/access.log"
        echo "sudo chown proxy:proxy /var/log/squid/access.log"
        return 1
    else
        echo "Log de Squid encontrado: $log_file"
        return 0
    fi
}

function createProductionEnv() {
    local env_file="/opt/SquidStats/.env"

    if [ -f "$env_file" ]; then
        echo "Manteniendo configuración .env existente"
        return 0
    fi

    echo "Creando configuración de producción..."
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

    # Crear directorios de producción
    mkdir -p /var/lib/squidstats /var/log/squidstats
    chown -R proxy:proxy /var/lib/squidstats /var/log/squidstats 2>/dev/null || true
    
    ok "Configuración de producción creada"
}

function setupNginx() {
    echo "Configurando Nginx..."
    
    if ! command -v nginx &> /dev/null; then
        echo "Instalando Nginx..."
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
        ok "Nginx configurado"
    else
        error "Error en configuración de Nginx"
        return 1
    fi
}

function createService() {
    local service_file="/etc/systemd/system/squidstats.service"

    if [ -f "$service_file" ]; then
        echo "Servicio ya existe, reiniciando..."
        systemctl restart squidstats.service
        return 0
    fi

    echo "Creando servicio systemd..."
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
    
    # Verificar que el servicio puede iniciarse
    if systemctl start squidstats.service; then
        sleep 2
        if systemctl is-active --quiet squidstats.service; then
            ok "Servicio creado e iniciado correctamente"
        else
            error "El servicio se inició pero no está activo"
            journalctl -u squidstats.service -n 20 --no-pager
            return 1
        fi
    else
        error "Error al iniciar el servicio"
        journalctl -u squidstats.service -n 20 --no-pager
        return 1
    fi
}

function uninstallSquidStats() {
    echo -e "\n\033[1;43mDESINSTALACIÓN DE SQUIDSTATS\033[0m"
    echo "¿Está seguro de que desea continuar? (s/N)"
    read -p "Respuesta: " confirm

    if [[ ! "$confirm" =~ ^[sS]$ ]]; then
        echo "Desinstalación cancelada."
        return 0
    fi

    echo "Desinstalando..."
    
    if [ -f "/etc/systemd/system/squidstats.service" ]; then
        systemctl stop squidstats.service
        systemctl disable squidstats.service
        rm -f "/etc/systemd/system/squidstats.service"
        systemctl daemon-reload
        echo "Servicio eliminado"
    fi
    
    [ -d "/opt/SquidStats" ] && rm -rf "/opt/SquidStats" && echo "Directorio de aplicación eliminado"
    [ -d "/var/lib/squidstats" ] && rm -rf "/var/lib/squidstats" && echo "Datos eliminados"
    [ -d "/var/log/squidstats" ] && rm -rf "/var/log/squidstats" && echo "Logs eliminados"
    
    if [ -f "/etc/nginx/sites-enabled/squidstats" ]; then
        rm -f "/etc/nginx/sites-enabled/squidstats"
        rm -f "/etc/nginx/sites-available/squidstats"
        systemctl reload nginx
        echo "Configuración Nginx eliminada"
    fi

    ok "SquidStats desinstalado completamente"
}

function main() {
    checkSudo
    showWelcome

    if [ "$1" = "--update" ]; then
        echo "🔄 Actualizando SquidStats..."
        checkPackages
        cloneOrUpdateRepo || exit 1
        installDependencies || exit 1
        systemctl restart squidstats.service
        ok "Actualización completada! Acceda en: http://$(hostname -I | awk '{print $1}')"

    elif [ "$1" = "--uninstall" ]; then
        uninstallSquidStats

    else
        echo "🚀 Instalando SquidStats en producción..."
        
        # ORDEN CORRECTO:
        # 1. Verificar paquetes del sistema
        checkPackages
        
        # 2. Clonar/actualizar el repositorio PRIMERO
        echo "📥 Paso 1: Obteniendo código fuente..."
        cloneOrUpdateRepo || {
            error "Fallo al obtener el código fuente. Abortando."
            exit 1
        }
        
        # 3. Verificar logs de Squid
        echo "📋 Paso 2: Verificando configuración..."
        checkSquidLog
        
        # 4. Crear entorno virtual e instalar dependencias
        echo "🐍 Paso 3: Configurando Python y dependencias..."
        installDependencies || {
            error "Fallo al instalar dependencias. Abortando."
            exit 1
        }
        
        # 5. Configurar entorno
        echo "⚙️  Paso 4: Configurando aplicación..."
        createProductionEnv
        
        # 6. Configurar Nginx
        echo "🌐 Paso 5: Configurando Nginx..."
        setupNginx || {
            error "Fallo al configurar Nginx. Abortando."
            exit 1
        }
        
        # 7. Crear servicio
        echo "🔧 Paso 6: Configurando servicio..."
        createService || {
            error "Fallo al configurar el servicio. Abortando."
            exit 1
        }

        ok "🎉 Instalación completada!"
        echo ""
        echo "🌐 Acceda en: http://$(hostname -I | awk '{print $1}')"
        echo "📊 Nginx escuchando en puerto 80"
        echo "🔧 Gunicorn ejecutándose en puerto 5000"
        echo "📝 Logs de aplicación en: /var/log/squidstats/"
        echo "📋 Logs del servicio: journalctl -u squidstats.service -f"
        echo ""
        echo "Para ver el estado del servicio: systemctl status squidstats.service"
    fi
}

# =============================================
# MANEJO DE PARÁMETROS
# =============================================

case "$1" in
"--update")
    main "$1"
    ;;
"--uninstall")
    main "$1"
    ;;
"")
    main
    ;;
*)
    echo "Uso: $0 [--update|--uninstall]"
    echo "  Sin parámetros: Instala en producción"
    echo "  --update: Actualiza instalación existente"
    echo "  --uninstall: Desinstala completamente"
    exit 1
    ;;
esac