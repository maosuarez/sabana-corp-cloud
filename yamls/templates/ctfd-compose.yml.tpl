# docker-compose para vm-ctfd (snet-dmz-vm). Ver docs/plans/ctfd-deployment.md (F2).
#
# Adaptado de ../../../sabana-corp-CTFd/docker-compose.prod.yml (upstream ya trae el stack
# completo: nginx + ctfd/gunicorn + MariaDB + Redis) quitando los defaults `${VAR:-default}` de
# docker-compose (envsubst no los entiende, ver generate-ctfd-vm.sh) -- los defaults viven ahora
# en el generador, no en esta plantilla.
#
# Imagen: ${DOCKERHUB_IMAGE}:${IMAGE_TAG}, publicada por
# ../../../sabana-corp-CTFd/.github/workflows/deploy.yml (push a main).
services:
  ctfd:
    image: ${DOCKERHUB_IMAGE}:${IMAGE_TAG}
    restart: always
    ports:
      - "${CTFD_PORT}:8000"
    environment:
      - SECRET_KEY=${CTFD_SECRET_KEY}
      - UPLOAD_FOLDER=/var/uploads
      - DATABASE_URL=mysql+pymysql://${CTFD_DB_USER}:${CTFD_DB_PASSWORD}@db/${CTFD_DB_NAME}
      - REDIS_URL=redis://cache:6379
      - WORKERS=${WORKERS}
      - LOG_FOLDER=/var/log/CTFd
      - ACCESS_LOG=-
      - ERROR_LOG=-
      - REVERSE_PROXY=true
      - TRUSTED_HOSTS=${TRUSTED_HOSTS}
      - PRESET_ADMIN_NAME=${CTFD_PRESET_ADMIN_NAME}
      - PRESET_ADMIN_EMAIL=${CTFD_PRESET_ADMIN_EMAIL}
      - PRESET_ADMIN_PASSWORD=${CTFD_PRESET_ADMIN_PASSWORD}
      # Token fijo que CTFd acepta como si fuera un Access Token de admin (crea el preset admin al
      # vuelo si no existe -- ver CTFd/utils/security/auth.py:lookup_user_token). Cierra el hueco
      # de "generar el Access Token a mano" del plan: create_ctfd_vm() en lab-azure.sh lo usa para
      # correr seed_challenges.py automaticamente justo despues del deploy. Mismo nivel de secreto
      # que una password de admin -- ver yamls/.env.secrets.
      - PRESET_ADMIN_TOKEN=${CTFD_PRESET_ADMIN_TOKEN}
      # No son variables nativas de CTFd -- las lee seed/seed_setup.py (vendored desde
      # sabana-corp-CTFd, corre via 'docker compose exec ctfd' justo despues del deploy) para
      # completar /setup sin pasar por el wizard del navegador. CTFd las ignora si no las usa.
      - CTFD_EVENT_NAME=${CTFD_EVENT_NAME}
      - CTFD_EVENT_DESCRIPTION=${CTFD_EVENT_DESCRIPTION}
      - CTFD_TEAM_SIZE=${CTFD_TEAM_SIZE}
    volumes:
      - .data/CTFd/logs:/var/log/CTFd
      - .data/CTFd/uploads:/var/uploads
    depends_on:
      permissions:
        condition: service_completed_successfully
      db:
        condition: service_started
      cache:
        condition: service_started
    networks:
        default:
        internal:

  permissions:
    image: alpine:3.23
    user: root
    volumes:
      - .data/CTFd/logs:/var/log/CTFd
      - .data/CTFd/uploads:/var/uploads
    command: chown -R 1001:1001 /var/uploads /var/log/CTFd

  nginx:
    image: nginx:stable
    restart: always
    volumes:
      - ./conf/nginx/http.conf:/etc/nginx/nginx.conf
    ports:
      - "0.0.0.0:${HTTP_PORT}:80"
    depends_on:
      - ctfd

  db:
    image: mariadb:10.11
    restart: always
    environment:
      - MARIADB_ROOT_PASSWORD=${CTFD_DB_ROOT_PASSWORD}
      - MARIADB_USER=${CTFD_DB_USER}
      - MARIADB_PASSWORD=${CTFD_DB_PASSWORD}
      - MARIADB_DATABASE=${CTFD_DB_NAME}
      - MARIADB_AUTO_UPGRADE=1
    volumes:
      - .data/mysql:/var/lib/mysql
    networks:
        internal:
    command: [mysqld, --character-set-server=utf8mb4, --collation-server=utf8mb4_unicode_ci, --wait_timeout=28800, --log-warnings=0]

  cache:
    image: redis:4
    restart: always
    volumes:
    - .data/redis:/data
    networks:
        internal:

networks:
    default:
    internal:
        internal: true
