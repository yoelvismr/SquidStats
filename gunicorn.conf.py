# ⚙️ CONFIGURACIÓN DE GUNICORN PARA PRODUCCIÓN
# Optimizado para Flask + SocketIO con Eventlet

import os
import multiprocessing

# 🌐 CONFIGURACIÓN BÁSICA DEL SERVIDOR
bind = "127.0.0.1:5000"  # 🆕 Escuchar solo en localhost (Nginx hace proxy)
workers = multiprocessing.cpu_count() * 2 + 1  # 🎯 Número óptimo de workers
worker_class = "eventlet"  # 🔌 Necesario para SocketIO
worker_connections = 1000  # 🔗 Conexiones concurrentes
timeout = 30  # ⏱️ Timeout para requests
keepalive = 2  # ♻️ Conexiones keep-alive

# 📝 CONFIGURACIÓN DE LOGS
accesslog = "/var/log/squidstats/gunicorn_access.log"  # 🆕 Logs de acceso
errorlog = "/var/log/squidstats/gunicorn_error.log"    # 🆕 Logs de error
loglevel = "info"  # ℹ️ Nivel de log

# 🛡️ CONFIGURACIÓN DE SEGURIDAD Y RENDIMIENTO
preload_app = True  # 🚀 Precargar aplicación para mejor rendimiento
max_requests = 1000  # 🔄 Reciclar workers después de 1000 requests
max_requests_jitter = 100  # 🎲 Variación para evitar reciclajes simultáneos

# ❌ NO DAEMONIZAR: Systemd maneja el proceso
daemon = False

# 🔄 CONFIGURACIÓN DE PROXY PARA TRABAJAR CON NGINX
proxy_protocol = True  # 📨 Soporte para protocolo de proxy
forwarded_allow_ips = "*"  # 🌍 Aceptar headers forward de cualquier IP

# 🌿 VARIABLES DE ENTORNO
raw_env = [
    "FLASK_DEBUG=false",  # 🚫 Forzar modo producción
]