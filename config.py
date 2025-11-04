import os
import logging
from pathlib import Path
from dotenv import load_dotenv

# 🆕 CARGA MEJORADA: Cargar variables de entorno al inicio
load_dotenv()

# 🆕 CONFIGURACIÓN BÁSICA DE LOGGING
logging.basicConfig(
    level=logging.INFO, 
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)

class ProductionConfig:
    """🛡️ CONFIGURACIÓN PARA PRODUCCIÓN - Optimizada para seguridad y rendimiento"""
    
    # 🆕 SEGURIDAD: Deshabilitar API del scheduler en producción
    SCHEDULER_API_ENABLED = False
    
    # 🆕 CLAVE SEGURA: Usar variable de entorno o fallback
    SECRET_KEY = os.getenv("SECRET_KEY", "fallback-insecure-key-change-in-production")
    
    # 🆕 COMPATIBILIDAD: Soporte para DATABASE_URL y DATABASE_STRING_CONNECTION
    DATABASE_URL = os.getenv("DATABASE_URL") or os.getenv("DATABASE_STRING_CONNECTION", "sqlite:///squidstats.db")
    
    # Configuraciones existentes
    SQUID_LOG = os.getenv("SQUID_LOG", "/var/log/squid/access.log")
    BLACKLIST_DOMAINS = os.getenv("BLACKLIST_DOMAINS", "")
    DEBUG = os.getenv("FLASK_DEBUG", "false").lower() == "true"
    LOG_FORMAT = os.getenv("LOG_FORMAT", "DETAILED").upper()
    
    def __init__(self):
        # 🆕 MEJORA: Configurar logging específico para producción
        self._setup_production_logging()
    
    def _setup_production_logging(self):
        """🆕 CONFIGURAR LOGGING PARA PRODUCCIÓN - Archivos y menos verbosidad"""
        log_file = os.getenv("LOG_FILE", "/var/log/squidstats/app.log")
        
        try:
            # 🆕 MEJORA: Crear directorio de logs si no existe
            log_dir = os.path.dirname(log_file)
            os.makedirs(log_dir, exist_ok=True)
            
            # 🆕 MEJORA: Agregar handler de archivo para logs persistentes
            file_handler = logging.FileHandler(log_file)
            file_handler.setLevel(logging.INFO)
            formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
            file_handler.setFormatter(formatter)
            logging.getLogger().addHandler(file_handler)
            
        except Exception as e:
            print(f"⚠️ Warning: Could not setup file logging: {e}")
        
        # 🆕 SEGURIDAD: Reducir verbosidad de librerías en producción
        logging.getLogger('werkzeug').setLevel(logging.WARNING)
        logging.getLogger('engineio').setLevel(logging.WARNING)
        logging.getLogger('socketio').setLevel(logging.WARNING)


class DevelopmentConfig:
    """🔧 CONFIGURACIÓN PARA DESARROLLO - Optimizada para debugging"""
    
    # 🆕 DESARROLLO: Habilitar características de debugging
    SCHEDULER_API_ENABLED = True
    SECRET_KEY = os.getenv("SECRET_KEY", "dev-key-insecure-change-in-production")
    
    # 🆕 COMPATIBILIDAD: Soporte para ambas variables de BD
    DATABASE_URL = os.getenv("DATABASE_URL") or os.getenv("DATABASE_STRING_CONNECTION", "sqlite:///squidstats.db")
    
    # Configuraciones existentes
    SQUID_LOG = os.getenv("SQUID_LOG", "/var/log/squid/access.log")
    BLACKLIST_DOMAINS = os.getenv("BLACKLIST_DOMAINS", "")
    DEBUG = os.getenv("FLASK_DEBUG", "true").lower() == "true"
    LOG_FORMAT = os.getenv("LOG_FORMAT", "DETAILED").upper()
    
    def __init__(self):
        # 🆕 DESARROLLO: Logging más verboso para debugging
        logging.getLogger().setLevel(logging.DEBUG)


class Config:
    """🎯 CONFIGURACIÓN DINÁMICA - Detecta automáticamente el entorno"""
    
    def __init__(self):
        # 🆕 DETECCIÓN AUTOMÁTICA: Basada en FLASK_DEBUG
        self._is_production = os.getenv("FLASK_DEBUG", "true").lower() == "false"
        
        # 🆕 SELECCIÓN DE CONFIGURACIÓN SEGÚN ENTORNO
        if self._is_production:
            self._config = ProductionConfig()
            self._env_name = "PRODUCTION"
        else:
            self._config = DevelopmentConfig()
            self._env_name = "DEVELOPMENT"
        
        # 🆕 VALIDACIONES DE SEGURIDAD
        self._validate_security()
        
        # 🆕 LOG INFORMATIVO DEL ENTORNO CARGADO
        logger = logging.getLogger(__name__)
        logger.info(f"🔧 Configuración de {self._env_name} cargada")
    
    def _validate_security(self):
        """🛡️ VALIDACIONES DE SEGURIDAD - Advertencias para configuraciones peligrosas"""
        logger = logging.getLogger(__name__)
        
        # 🆕 LISTA DE CLAVES INSECURAS CONOCIDAS
        insecure_keys = [
            "fallback-insecure-key-change-in-production",
            "dev-key-insecure-change-in-production", 
            "secret",
            "password",
            "123456"
        ]
        
        # 🆕 ADVERTENCIA: Clave insegura en producción
        if self._is_production and self.SECRET_KEY in insecure_keys:
            logger.error("🚨 CRÍTICO: SECRET_KEY insegura en producción!")
            logger.error("   Ejecuta: ./install.sh --update para regenerar claves")
        
        # 🆕 ADVERTENCIA: API del scheduler habilitada en producción
        if self._is_production and self.SCHEDULER_API_ENABLED:
            logger.error("❌ RIESGO DE SEGURIDAD: Scheduler API habilitado en producción!")
    
    # 🆕 PROPIEDADES PARA ACCESO DIRECTO - Mantienen compatibilidad
    @property
    def SCHEDULER_API_ENABLED(self):
        return self._config.SCHEDULER_API_ENABLED
    
    @property
    def SECRET_KEY(self):
        return self._config.SECRET_KEY
    
    @property
    def DATABASE_URL(self):
        return self._config.DATABASE_URL
    
    @property
    def SQUID_LOG(self):
        return self._config.SQUID_LOG
    
    @property
    def BLACKLIST_DOMAINS(self):
        return self._config.BLACKLIST_DOMAINS
    
    @property
    def DEBUG(self):
        return self._config.DEBUG
    
    @property
    def LOG_FORMAT(self):
        return self._config.LOG_FORMAT


# 🆕 INSTANCIA GLOBAL DE CONFIGURACIÓN
config_instance = Config()

# 🔄 COMPATIBILIDAD HACIA ATRÁS - Acceso directo a propiedades
DEBUG = config_instance.DEBUG
SCHEDULER_API_ENABLED = config_instance.SCHEDULER_API_ENABLED
SECRET_KEY = config_instance.SECRET_KEY
DATABASE_URL = config_instance.DATABASE_URL
SQUID_LOG = config_instance.SQUID_LOG
BLACKLIST_DOMAINS = config_instance.BLACKLIST_DOMAINS
LOG_FORMAT = config_instance.LOG_FORMAT

# 📝 LOGGER PRINCIPAL
logger = logging.getLogger(__name__)

# 🔄 ALIAS PARA MANTENER COMPATIBILIDAD
def Config():
    return config_instance