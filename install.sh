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

# =============================================
# VERIFICACIONES INICIALES
# =============================================

function checkSudo() {
    # Verificar que el script se ejecute con privilegios de root
    if [ "$EUID" -ne 0 ]; then
        error "ERROR: Este script debe ejecutarse con privilegios de superusuario.\nPor favor, ejecútelo con el usuario: root $0"
        exit 1
    fi
}

# =============================================
# GESTIÓN DE DEPENDENCIAS Y ENTORNO
# =============================================

function installDependencies() {
    local venv_dir="/opt/SquidStats/venv"

    # Crear entorno virtual si no existe
    if [ ! -d "$venv_dir" ]; then
        echo "El entorno virtual no existe en $venv_dir, creándolo..."
        python3 -m venv "$venv_dir"
        
        if [ $? -ne 0 ]; then
            error "Error al crear el entorno virtual en $venv_dir"
            return 1
        fi
        
        ok "Entorno virtual creado correctamente en $venv_dir"
    fi

    echo "Activando entorno virtual y instalando dependencias..."
    source "$venv_dir/bin/activate"

    # Actualizar pip e instalar todas las dependencias desde requirements.txt
    pip install --upgrade pip
    pip install -r /opt/SquidStats/requirements.txt

    if [ $? -ne 0 ]; then
        error "Error al instalar dependencias"
        deactivate
        return 1
    fi

    ok "Todas las dependencias instaladas correctamente desde requirements.txt"
    deactivate
    return 0
}

function checkPackages() {
    # Lista de paquetes del sistema requeridos
    local packages=("git" "python3" "python3-pip" "python3-venv" "libmariadb-dev" "curl" "build-essential" "libssl-dev" "libicapapi-dev" "python3-dev" "libpq-dev" "nginx")
    local missing=()

    # Verificar qué paquetes faltan
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            missing+=("$pkg")
        fi
    done

    # Instalar paquetes faltantes
    if [ ${#missing[@]} -ne 0 ]; then
        echo "Instalando paquetes faltantes: ${missing[*]}"
        apt-get update

        if ! apt-get install -y "${missing[@]}"; then
            error "ERROR: Compruebe la versión de su OS se recomienda Ubuntu20.04+ o Debian12+"
            exit 1
        fi

        ok "Paquetes instalados correctamente"
    else
        echo "Todos los paquetes necesarios ya están instalados"
    fi
}

# =============================================
# VERIFICACIÓN DE SQUID
# =============================================

function checkSquidLog() {
    local log_file="/var/log/squid/access.log"

    # Verificar que el archivo de log de Squid exista
    if [ ! -f "$log_file" ]; then
        error "¡ADVERTENCIA!: No hemos encontrado el log en la ruta por defecto. Recargue su squid, navegue y genere logs para crearlo"
        return 1
    else
        echo "Archivo de log de Squid encontrado: $log_file"
        return 0
    fi
}

# =============================================
# GESTIÓN DEL REPOSITORIO GIT
# =============================================

function updateOrCloneRepo() {
    # local repo_url="https://github.com/kaelthasmanu/SquidStats.git"
    local repo_url="https://github.com/yoelvismr/SquidStats.git"
    local destinos=("/opt/SquidStats" "/usr/share/squidstats")
    local branch="main"
    local env_exists=false
    local db_exists=false
    local found_dir=""

    # BUSCAR INSTALACIÓN EXISTENTE EN LAS RUTAS POSIBLES
    for dir in "${destinos[@]}"; do
        if [ -d "$dir" ]; then
            found_dir="$dir"
            break
        fi
    done

    # 🆕 CAMBIO CRÍTICO: Para --update, solo actualizar instalaciones existentes
    # No clonar nueva instalación en modo actualización
    if [ -z "$found_dir" ]; then
        echo "❌ No se encontró ninguna instalación de SquidStats en /opt/SquidStats ni /usr/share/squidstats."
        echo "   Para instalación nueva, ejecute el script sin el parámetro --update"
        return 1
    fi

    # Manejar instalaciones .deb (no actualizables via git)
    if [ "$found_dir" = "/usr/share/squidstats" ]; then
        echo "ℹ️ Instalación detectada en /usr/share/squidstats. Esta versión fue instalada desde un .deb y no puede actualizarse con git."
        echo "Por favor, use el gestor de paquetes (apt/dpkg) para actualizar."
        return 1
    fi

    echo "El directorio $found_dir ya existe, intentando actualizar con git pull..."
    cd "$found_dir"

    # Verificar que es un repositorio git válido
    if [ -d ".git" ]; then
        # Preservar configuración existente (.env)
        if [ -f ".env" ]; then
            env_exists=true
            echo ".env existente detectado, se preservará"
            cp .env /tmp/.env.backup
        fi

        # Preservar base de datos existente
        local db_files=(*.db)
        if [ -e "${db_files[0]}" ]; then
            db_exists=true
            echo "Archivos .db detectados, se preservarán"
            mkdir -p /tmp/db_backup
            cp *.db /tmp/db_backup/
        fi

        # Actualizar código desde git
        if git fetch origin "$branch" && git checkout "$branch" && git pull origin "$branch"; then
            # Restaurar configuración preservada
            [ "$env_exists" = true ] && mv /tmp/.env.backup .env
            if [ "$db_exists" = true ]; then
                mv /tmp/db_backup/*.db . 2>/dev/null || true
                rm -rf /tmp/db_backup
                echo "📊 Archivos .db restaurados"
            fi
            echo "✅ Repositorio actualizado exitosamente en la rama '$branch'"
            return 0
        else
            echo "❌ Error al actualizar el repositorio."
            return 1
        fi
    else
        echo "⚠️ El directorio $found_dir existe pero no es un repositorio git. No se puede actualizar automáticamente."
        return 1
    fi
}

# =============================================
# GESTIÓN DE BASE DE DATOS
# =============================================

function moveDB() {
    local databaseSQlite="/opt/SquidStats/squidstats.db"
    local env_file="/opt/SquidStats/.env"
    local current_version=0

    # 🆕 MEJORA: Leer versión actual si existe el archivo
    if [ -f "$env_file" ]; then
        current_version=$(grep -E '^VERSION\s*=' "$env_file" | cut -d= -f2 | tr -dc '0-9' || echo 0)
    fi

    # Si no existe la versión, establecer versión 2
    if ! grep -qE '^VERSION\s*=' "$env_file"; then
        echo "VERSION=2" >>"$env_file"
        echo "Eliminando base de datos antigua por actualización..."
        rm -rf "$databaseSQlite"
        ok "Base de datos antigua eliminada"
    else
        echo "Base de datos no requiere actualización"
    fi

    # Eliminar BD antigua si la versión es menor a 2
    if [ -f "$databaseSQlite" ] && [ "$current_version" -lt 2 ]; then
        echo "Eliminando base de datos antigua por actualización..."
        rm -rf "$databaseSQlite"
        ok "Base de datos antigua eliminada"
    else
        echo "Base de datos no requiere actualización"
    fi

    return 0
}

# =============================================
# 🆕 NUEVA FUNCIONALIDAD: SELECCIÓN DE ENTORNO
# =============================================

function selectEnvironment() {
    info "SELECCIÓN DE ENTORNO DE DESPLIEGUE"
    echo "Seleccione el entorno de despliegue:"
    echo "1) Desarrollo (Debug habilitado, características de desarrollo)"
    echo "2) Producción (Optimizado para seguridad y rendimiento con Nginx)"
    
    while true; do
        read -p "Ingresa tu elección [1-2]: " env_choice
        case $env_choice in
            1)
                ENV_TYPE="development"
                echo "🔧 Configurando entorno de DESARROLLO..."
                break
                ;;
            2)
                ENV_TYPE="production"
                echo "🚀 Configurando entorno de PRODUCCIÓN..."
                break
                ;;
            *)
                error "Opción inválida. Intente nuevamente."
                ;;
        esac
    done
}

# =============================================
# CONFIGURACIÓN DE VARIABLES DE ENTORNO
# =============================================

function createEnvFile() {
    local env_file="/opt/SquidStats/.env"
    local env_type="${1:-production}"

    # 🆕 MEJORA: Preguntar si se desea mantener configuración existente
    if [ -f "$env_file" ]; then
        echo "El archivo .env ya existe en $env_file."
        echo "¿Desea mantener la configuración actual o generar una nueva?"
        read -p "Mantener actual (m) / Generar nueva (n) [m/N]: " keep_env
        if [[ ! "$keep_env" =~ ^[nN]$ ]]; then
            echo "Manteniendo configuración .env existente"
            return 0
        fi
    fi

    echo "Creando archivo de configuración .env para entorno $env_type..."
    
    # 🆕 NUEVA FUNCIONALIDAD: Configuración diferenciada por entorno
    if [ "$env_type" = "development" ]; then
        cat >"$env_file" <<EOF
# =============================================
# CONFIGURACIÓN DE DESARROLLO
# =============================================
VERSION=2
FLASK_DEBUG=True
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(24))")
DATABASE_TYPE=SQLITE
DATABASE_STRING_CONNECTION=/opt/SquidStats/squidstats.db
SQUID_LOG=/var/log/squid/access.log
LOG_FORMAT=DETAILED
SQUID_HOST=127.0.0.1
SQUID_PORT=3128
HOST=127.0.0.1
PORT=5000
REFRESH_INTERVAL=60
BLACKLIST_DOMAINS="facebook.com,twitter.com,instagram.com,tiktok.com,youtube.com,netflix.com"
HTTP_PROXY=""
SQUID_CONFIG_PATH=/etc/squid/squid.conf
ACL_FILES_DIR=/etc/squid/config/acls
EOF
    else
        # 🆕 PRODUCCIÓN: Claves más seguras y rutas del sistema
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
        
        # 🆕 MEJORA: Crear directorios del sistema para producción
        mkdir -p /var/lib/squidstats /var/log/squidstats
        chown -R proxy:proxy /var/lib/squidstats /var/log/squidstats 2>/dev/null || true
    fi

    ok "Archivo .env creado correctamente en $env_file para entorno $env_type"
    return 0
}

# =============================================
# 🆕 NUEVA FUNCIONALIDAD: CONFIGURACIÓN NGINX
# =============================================

function setupNginx() {
    local env_type="${1:-production}"
    
    # Solo configurar Nginx para producción
    if [ "$env_type" != "production" ]; then
        echo "Saltando configuración de Nginx para entorno desarrollo"
        return 0
    fi

    # Verificar si Nginx está instalado
    if ! command -v nginx &> /dev/null; then
        echo "Instalando Nginx..."
        apt-get install -y nginx
    fi

    # Crear configuración de Nginx optimizada para SquidStats
    local nginx_config="/etc/nginx/sites-available/squidstats"
    
    cat > "$nginx_config" << 'EOF'
server {
    listen 80;
    server_name _;
    
    # 🆕 MEJORA: Nginx sirve archivos estáticos directamente (más eficiente)
    location /static {
        alias /opt/SquidStats/static;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
        log_not_found off;
    }
    
    # 🆕 MEJORA: Proxy para WebSockets (SocketIO)
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
    
    # Proxy para el resto de la aplicación
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # 🆕 MEJORA: Headers de seguridad adicionales
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";
    
    # Compresión para mejor rendimiento
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
}
EOF

    # Habilitar el sitio y deshabilitar configuración por defecto
    ln -sf "$nginx_config" /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    # Verificar y cargar configuración
    if nginx -t; then
        systemctl reload nginx
        systemctl enable nginx
        ok "Nginx configurado correctamente"
    else
        error "Error en la configuración de Nginx"
        return 1
    fi
}

# =============================================
# CONFIGURACIÓN DEL SERVICIO SYSTEMD
# =============================================

function createService() {
    local service_file="/etc/systemd/system/squidstats.service"
    local env_type="${1:-production}"

    if [ -f "$service_file" ]; then
        echo "El servicio ya existe en $service_file, no se realizan cambios."
        return 0
    fi

    echo "Creando servicio en $service_file..."
    
    # 🆕 NUEVA FUNCIONALIDAD: Servicios diferenciados por entorno
    if [ "$env_type" = "production" ]; then
        cat >"$service_file" <<EOF
[Unit]
Description=SquidStats Web Application
After=network.target nginx.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/SquidStats
# 🆕 PRODUCCIÓN: Usa Gunicorn + configuración optimizada
ExecStart=/opt/SquidStats/venv/bin/gunicorn --config /opt/SquidStats/gunicorn.conf.py wsgi:app
Restart=always
RestartSec=5
EnvironmentFile=/opt/SquidStats/.env
Environment=PATH=/opt/SquidStats/venv/bin:\$PATH

# Límites de recursos del original
MemoryLimit=2048M
TimeoutStartSec=30
TimeoutStopSec=10

# 🆕 MEJORA: Configuración de seguridad para producción
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/SquidStats /var/lib/squidstats /var/log/squidstats

# Logging del original
StandardOutput=journal
StandardError=journal
SyslogIdentifier=squidstats

[Install]
WantedBy=multi-user.target
EOF
    else
        cat >"$service_file" <<EOF
[Unit]
Description=SquidStats Web Application (Development)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/SquidStats
# DESARROLLO: Ejecuta directamente con Python
ExecStart=/opt/SquidStats/venv/bin/python /opt/SquidStats/app.py
Restart=on-failure
RestartSec=5
EnvironmentFile=/opt/SquidStats/.env
Environment=PATH=/opt/SquidStats/venv/bin:\$PATH

# Logging del original
StandardOutput=journal
StandardError=journal
SyslogIdentifier=squidstats

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    systemctl enable squidstats.service
    
    # 🆕 MEJORA: Comportamiento diferente por entorno
    if [ "$env_type" = "production" ]; then
        systemctl start squidstats.service
        ok "Servicio de PRODUCCIÓN con Gunicorn + Nginx creado e iniciado"
    else
        echo "Servicio de DESARROLLO creado (no se inicia automáticamente)"
        ok "Servicio de DESARROLLO creado correctamente"
    fi
}

# =============================================
# CONFIGURACIÓN DE BASE DE DATOS
# =============================================

function configureDatabase() {
    local env_file="/opt/SquidStats/.env"
    local env_type="${1:-production}"

    echo -e "\n\033[1;44mCONFIGURACIÓN DE BASE DE DATOS\033[0m"
    echo "Seleccione el tipo de base de datos:"
    echo "1) SQLite (por defecto)"
    echo "2) MariaDB (necesitas tener mariadb ejecutándose)"

    while true; do
        read -p "Opción [1/2]: " choice
        case $choice in
        1 | "") break ;;
        2) break ;;
        *) error "Opción inválida. Intente nuevamente." ;;
        esac
    done

    case $choice in
    2)
        while true; do
            read -p "Ingrese cadena de conexión (mysql+pymysql://user:clave@host:port/db): " conn_str

            if [[ "$conn_str" != mysql+pymysql://* ]]; then
                error "Formato inválido. Debe comenzar con: mysql+pymysql://"
                continue
            fi

            # 🛡️ FUNCIONALIDAD ORIGINAL: Validación con script Python
            validation_result=$(python3 /opt/SquidStats/utils/validateString.py "$conn_str" 2>&1)
            exit_code=$?

            if [[ $exit_code -eq 0 ]]; then
                sed -i "s|^DATABASE_TYPE=.*|DATABASE_TYPE=MARIADB|" "$env_file"

                # validation_result tiene la cadena codificada, escapamos para sed
                escaped_conn_str=$(printf '%s\n' "$validation_result" | sed -e 's/[\/&]/\\&/g')
                sed -i "s|^DATABASE_STRING_CONNECTION=.*|DATABASE_STRING_CONNECTION=$escaped_conn_str|" "$env_file"

                ok "Configuración MariaDB actualizada!"
                break
            else
                error "Error en la cadena:\n${validation_result#ERROR: }"
            fi
        done
        ;;
    *)
        # 🆕 MEJORA: Rutas de BD diferentes por entorno
        if [ "$env_type" = "production" ]; then
            sqlite_path="/var/lib/squidstats/squidstats.db"
        else
            sqlite_path="/opt/SquidStats/squidstats.db"
        fi
        sed -i "s|^DATABASE_TYPE=.*|DATABASE_TYPE=SQLITE|" "$env_file"
        sed -i "s|^DATABASE_STRING_CONNECTION=.*|DATABASE_STRING_CONNECTION=$sqlite_path|" "$env_file"
        ok "Configuración SQLite establecida!"
        ;;
    esac
}

# =============================================
# DESINSTALACIÓN COMPLETA
# =============================================

function uninstallSquidStats() {
    local destino="/opt/SquidStats"
    local service_file="/etc/systemd/system/squidstats.service"

    echo -e "\n\033[1;43mDESINSTALACIÓN DE SQUIDSTATS\033[0m"
    echo "Esta operación eliminará completamente SquidStats del sistema."
    echo "¿Está seguro de que desea continuar? (s/N)"

    read -p "Respuesta: " confirm

    if [[ ! "$confirm" =~ ^[sS]$ ]]; then
        echo "Desinstalación cancelada."
        return 0
    fi

    echo "Iniciando desinstalación..."

    # Detener y eliminar servicio
    if [ -f "$service_file" ]; then
        echo "Deteniendo servicio squidstats..."
        systemctl stop squidstats.service 2>/dev/null || true

        echo "Deshabilitando servicio squidstats..."
        systemctl disable squidstats.service 2>/dev/null || true

        echo "Eliminando archivo de servicio..."
        rm -f "$service_file"

        systemctl daemon-reload
        ok "Servicio squidstats eliminado"
    else
        echo "Servicio squidstats no encontrado"
    fi
    
    # Eliminar directorio de instalación
    if [ -d "$destino" ]; then
        echo "Eliminando directorio de instalación $destino..."
        rm -rf "$destino"
        ok "Directorio de instalación eliminado"
    else
        echo "Directorio de instalación no encontrado"
    fi

    # 🆕 MEJORA: Limpiar directorios de producción
    if [ -d "/var/lib/squidstats" ]; then
        echo "Eliminando datos de producción..."
        rm -rf /var/lib/squidstats
    fi
    
    if [ -d "/var/log/squidstats" ]; then
        echo "Eliminando logs de producción..."
        rm -rf /var/log/squidstats
    fi

    # 🆕 MEJORA: Limpiar configuración de Nginx
    if [ -f "/etc/nginx/sites-enabled/squidstats" ]; then
        echo "Eliminando configuración de Nginx..."
        rm -f /etc/nginx/sites-enabled/squidstats
        rm -f /etc/nginx/sites-available/squidstats
        systemctl reload nginx
    fi

    ok "SquidStats ha sido desinstalado completamente del sistema"
}

# =============================================
# 🆕 FUNCIÓN PARA CLONAR NUEVA INSTALACIÓN
# =============================================

function cloneNewInstallation() {
    local repo_url="https://github.com/kaelthasmanu/SquidStats.git"
    local branch="main"

    # Verificar si ya existe alguna instalación
    if [ -d "/opt/SquidStats" ] || [ -d "/usr/share/squidstats" ]; then
        echo "ℹ️ Ya existe una instalación de SquidStats. Usando instalación existente."
        return 0
    fi

    echo "Clonando repositorio en /opt/SquidStats..."
    git clone "$repo_url" /opt/SquidStats
    if [ $? -eq 0 ]; then
        cd /opt/SquidStats
        git checkout "$branch"
        ok "Repositorio clonado correctamente"
        return 0
    else
        error "Error al clonar el repositorio"
        return 1
    fi
}

# =============================================
# FUNCIÓN PRINCIPAL
# =============================================

function main() {
    checkSudo

    # 🆕 CAMBIO CRÍTICO: Lógica separada para actualización vs instalación nueva
    if [ "$1" = "--update" ]; then
        # MODO ACTUALIZACIÓN: Solo actualiza instalaciones existentes
        echo "🔄 Modo: ACTUALIZACIÓN de instalación existente"
        echo "Verificando paquetes instalados..."
        checkPackages
        echo "Verificando Dependencias de python..."
        installDependencies
        echo "Actualizando código desde git..."
        updateOrCloneRepo  # Esta función SOLO actualiza, no clona nueva
        echo "Reiniciando Servicio..."
        systemctl restart squidstats.service

        ok "Actualización completada! Acceda en: \033[1;37mhttp://IP:5000\033[0m"

    elif [ "$1" = "--uninstall" ]; then
        # MODO DESINSTALACIÓN
        uninstallSquidStats

    else
        # MODO INSTALACIÓN NUEVA
        info "Modo: INSTALACIÓN NUEVA de SquidStats"
        
        # 🆕 CAMBIO CRÍTICO: Selección de entorno primero
        selectEnvironment
        
        echo "Instalando aplicación web en modo $ENV_TYPE..."
        checkPackages
        
        # 🆕 CAMBIO CRÍTICO: Para instalación nueva, clonar si no existe
        echo "Gestionando código fuente..."
        if [ ! -d "/opt/SquidStats" ] && [ ! -d "/usr/share/squidstats" ]; then
            cloneNewInstallation
        else
            # Si ya existe, actualizar
            updateOrCloneRepo
        fi
        
        # Resto del proceso de instalación
        checkSquidLog
        installDependencies
        createEnvFile "$ENV_TYPE"
        configureDatabase "$ENV_TYPE"
        moveDB
        
        # 🆕 MEJORA: Configurar Nginx solo para producción
        if [ "$ENV_TYPE" = "production" ]; then
            setupNginx "$ENV_TYPE"
        fi
        
        createService "$ENV_TYPE"

        # 🆕 MEJORA: Mensajes finales diferenciados por entorno
        if [ "$ENV_TYPE" = "production" ]; then
            ok "Instalación en PRODUCCIÓN completada!"
            echo "🌐 Acceda en: \033[1;37mhttp://$(hostname -I | awk '{print $1}')\033[0m"
            echo "📊 Nginx sirviendo archivos estáticos en puerto 80"
            echo "🔧 Gunicorn ejecutando la aplicación en puerto 5000"
            echo "📝 Logs disponibles en: /var/log/squidstats/"
        else
            ok "Instalación en DESARROLLO completada!"
            echo "🚀 Para iniciar: \033[1;37msystemctl start squidstats.service\033[0m"
            echo "🌐 Luego acceda en: http://127.0.0.1:5000"
            echo "💡 Recuerde: Este es un entorno de desarrollo, no para producción"
        fi
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
    echo "Parámetro no reconocido: $1"
    echo "Uso: $0 [--update|--uninstall]"
    echo "  Sin parámetros: Instala SquidStats"
    echo "  --update: Actualiza SquidStats existente"
    echo "  --uninstall: Desinstala SquidStats completamente"
    exit 1
    ;;
esac