#!/usr/bin/env python3
"""
🚀 WSGI ENTRY POINT PARA GUNICORN EN PRODUCCIÓN

Este archivo es el punto de entrada para servidores WSGI como Gunicorn.
Optimizado para entornos de producción con SocketIO.
"""

import os
from app import create_app, setup_scheduler_tasks
from flask_socketio import SocketIO

# 🆕 CARGA ESPECÍFICA: Variables de entorno de producción
env_file = os.path.join(os.path.dirname(__file__), '.env')
if os.path.exists(env_file):
    from dotenv import load_dotenv
    load_dotenv(env_file)

# 🏗️ CREAR APLICACIÓN FLASK
app, scheduler = create_app()

# ⏰ CONFIGURAR TAREAS PROGRAMADAS
setup_scheduler_tasks(scheduler)

# 🔌 SOCKETIO PARA PRODUCCIÓN - Sin logs para mejor rendimiento
socketio = SocketIO(
    app, 
    cors_allowed_origins="*", 
    async_mode="threading",
    logger=False,           # 🚫 Sin logs en producción
    engineio_logger=False   # 🚫 Sin logs en producción
)

# 🧵 INICIAR HILO DE DATOS EN TIEMPO REAL
from routes.stats_routes import realtime_data_thread
socketio.start_background_task(realtime_data_thread, socketio)

# 🎯 PUNTO DE ENTRADA PARA GUNICORN
if __name__ == "__main__":
    # ⚠️ Esto no debería ejecutarse directamente en producción
    socketio.run(app)