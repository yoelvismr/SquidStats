import os
from dotenv import load_dotenv
from flask import Flask
from flask_apscheduler import APScheduler
from flask_socketio import SocketIO

# 🆕 IMPORT MEJORADO: Usar la configuración unificada
from config import Config, logger
from database.database import migrate_database
from parsers.log import process_logs
from routes import register_routes
from routes.main_routes import initialize_proxy_detection
from routes.stats_routes import realtime_data_thread
from services.metrics_service import MetricsService
from services.notifications import (
    has_remote_commits_with_messages,
    set_commit_notifications,
)
from utils.filters import register_filters

# 🆕 CARGA TEMPRANA: Variables de entorno al inicio
load_dotenv()


def create_app():
    """🏗️ FACTORY FUNCTION - Crea y configura la aplicación Flask"""
    
    # 🆕 MEJORA: Log informativo de migración de BD
    logger.info("Ejecutando migración de base de datos al inicio...")
    try:
        migrate_database()
        logger.info("Migración de base de datos completada exitosamente")
    except Exception as e:
        logger.error(f"Falló la migración de base de datos: {e}")
        # 🆕 MEJORA: Continuar aunque falle la migración

    # 🆕 CREACIÓN DE APLICACIÓN con configuración estática
    app = Flask(__name__, static_folder="./static")
    app.config.from_object(Config())

    # 🆕 EXTENSIONES: Inicializar scheduler con configuración de seguridad
    scheduler = APScheduler()
    scheduler.init_app(app)
    
    # 🆕 SEGURIDAD: Configuración del scheduler por entorno
    if Config.DEBUG:
        scheduler.api_enabled = True  # 🔧 Solo en desarrollo
        logger.info("Scheduler API habilitado (modo desarrollo)")
    else:
        scheduler.api_enabled = False  # 🛡️ Deshabilitado en producción
        logger.info("Scheduler API deshabilitado (modo producción)")
    
    scheduler.start()

    # 🆕 REGISTROS: Filtros personalizados y rutas
    register_filters(app)
    register_routes(app)

    # 🆕 INICIALIZACIÓN: Detección de proxy
    initialize_proxy_detection()

    # 🆕 MEJORA: Headers de respuesta con seguridad diferenciada
    @app.after_request
    def set_response_headers(response):
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
        
        # 🆕 SEGURIDAD: Headers adicionales solo en producción
        if not Config.DEBUG:
            response.headers["X-Content-Type-Options"] = "nosniff"
            response.headers["X-Frame-Options"] = "DENY"
            response.headers["X-XSS-Protection"] = "1; mode=block"
        return response

    return app, scheduler


def setup_scheduler_tasks(scheduler):
    """⏰ CONFIGURACIÓN DE TAREAS PROGRAMADAS"""
    
    @scheduler.task(
        "interval", id="check_notifications", minutes=30, misfire_grace_time=1800
    )
    def check_notifications_task():
        """🔔 TAREA: Verificar notificaciones de Git cada 30 minutos"""
        repo_path = os.path.dirname(os.path.abspath(__file__))
        has_updates, messages = has_remote_commits_with_messages(repo_path)
        set_commit_notifications(has_updates, messages)

    @scheduler.task("interval", id="process_logs", seconds=30, misfire_grace_time=900)
    def process_logs_task():
        """📊 TAREA: Procesar logs de Squid cada 30 segundos"""
        log_file = Config.SQUID_LOG
        
        # 🆕 MEJORA: Logging diferenciado por entorno
        if Config.DEBUG:
            logger.info(f"Procesando archivo de log: {log_file}")
        else:
            logger.debug(f"Procesando log: {log_file}")  # Menos verbose en producción

        if not os.path.exists(log_file):
            logger.error(f"Archivo de log no encontrado: {log_file}")
            return
        
        try:
            process_logs(log_file)
        except Exception as e:
            logger.error(f"Error procesando logs: {e}")

    @scheduler.task("interval", id="cleanup_metrics", hours=1, misfire_grace_time=3600)
    def cleanup_old_metrics():
        """🧹 TAREA: Limpieza de métricas antiguas cada hora"""
        try:
            success = MetricsService.cleanup_old_metrics()
            # 🆕 MEJORA: Log detallado solo en desarrollo
            if success and Config.DEBUG:
                logger.info("Limpieza de métricas antiguas completada exitosamente")
            elif not success:
                logger.warning("Error durante la limpieza de métricas antiguas")
        except Exception as e:
            logger.error(f"Error en tarea de limpieza de métricas: {e}")


def main():
    """🚀 PUNTO DE ENTRADA PRINCIPAL DE LA APLICACIÓN"""
    
    # 🆕 INICIALIZACIÓN: Crear aplicación y scheduler
    app, scheduler = create_app()
    setup_scheduler_tasks(scheduler)

    # 🆕 SOCKETIO: Configuración optimizada por entorno
    socketio_config = {
        "cors_allowed_origins": "*", 
        "async_mode": "threading",
        "logger": Config.DEBUG,           # 📝 Logs solo en desarrollo
        "engineio_logger": Config.DEBUG   # 📝 Logs solo en desarrollo
    }
    
    socketio = SocketIO(app, **socketio_config)

    # 🆕 TIEMPO REAL: Iniciar hilo de datos en tiempo real
    socketio.start_background_task(realtime_data_thread, socketio)

    # 🆕 CONFIGURACIÓN DEL SERVIDOR
    debug_mode = Config.DEBUG
    
    # 🆕 MEJORA: Logs de inicio diferenciados por entorno
    if debug_mode:
        logger.info("🚀 Iniciando SquidStats en MODO DESARROLLO")
        logger.warning("⚠️  Características de desarrollo habilitadas - No usar en producción")
    else:
        logger.info("🚀 Iniciando SquidStats en MODO PRODUCCIÓN")
        logger.info("✅ Características de seguridad habilitadas")

    # 🆕 MEJORA: Compatibilidad con múltiples variables de entorno
    host = os.getenv("LISTEN_HOST") or os.getenv("FLASK_HOST") or os.getenv("HOST") or "0.0.0.0"
    port_str = os.getenv("LISTEN_PORT") or os.getenv("FLASK_PORT") or os.getenv("PORT") or "5000"
    
    try:
        port = int(port_str)
    except ValueError:
        logger.warning(f"Valor de PORT inválido '{port_str}', usando 5000 por defecto")
        port = 5000

    # 🆕 SEGURIDAD: Werkzeug solo en desarrollo
    allow_unsafe_werkzeug = Config.DEBUG
    
    if allow_unsafe_werkzeug and not Config.DEBUG:
        logger.warning("⚠️  Werkzeug inseguro permitido en producción - ¡Riesgo de seguridad!")
    
    # 🆕 INFORMACIÓN DE CONFIGURACIÓN
    logger.info(f"🌐 Servidor iniciando en {host}:{port}")
    logger.info(f"📊 Log de Squid: {Config.SQUID_LOG}")
    logger.info(f"💾 Base de datos: {Config.DATABASE_URL}")

    # 🆕 EJECUCIÓN: Sin recarga automática como solicitaste
    socketio.run(
        app, 
        debug=debug_mode, 
        host=host, 
        port=port, 
        allow_unsafe_werkzeug=allow_unsafe_werkzeug,
        use_reloader=False  # 🚫 Sin autorecarga
    )


if __name__ == "__main__":
    main()