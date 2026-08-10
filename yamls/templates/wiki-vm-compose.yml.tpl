# docker-compose para la VM de snet-dmz-vm (ver docs/plans/wiki-on-vm.md).
#
# Validado end-to-end 2026-08-08: desplegado en vm-wiki, wiki + wiki-db arrancan y se comunican.
#
# Adaptado de ../../../sabana-corp-dmz/docker-compose.yml (servicios wiki-db + wiki + red
# wiki_backend), quitando lo que solo tenia sentido para un host que corre TODA la DMZ a la vez:
#   - Sin red "dmz" con IP fija por macvlan/bridge: esta VM tiene su propia IP privada de Azure
#     (asignada a la NIC), no hace falta simularla con Docker.
#   - wiki publica el puerto 80 directo en la interfaz de la VM (0.0.0.0), no en 127.0.0.1 --
#     tiene que ser alcanzable desde el resto de la VNet (snet-team<N>, snet-mgmt), no solo desde
#     localhost.
# Imagenes propias maosuarez/sabanacorp-wiki y maosuarez/sabanacorp-wikidb -- Dockerfile.app de
# sabanacorp-wiki es un FROM directo de lscr.io/linuxserver/bookstack sin tocar, o sea que SI trae
# s6-overlay v3. En ACI eso crashea (ver memoria aci_platform_limitations #1); en esta VM, con
# Docker normal y PID 1 real, arranca bien -- comprobado 2026-08-08. Ese era exactamente el motivo
# de mover el wiki fuera de ACI.
services:
  wiki-db:
    image: maosuarez/sabanacorp-wikidb:latest
    container_name: wiki-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${WIKI_MYSQL_ROOT_PASSWORD}"
      MYSQL_DATABASE: bookstack
      MYSQL_USER: bookstack
      MYSQL_PASSWORD: "${WIKI_DB_PASSWORD}"
    volumes:
      - wiki_mariadb_data:/var/lib/mysql
    networks:
      - wiki_backend
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p${WIKI_MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 40s

  wiki:
    image: maosuarez/sabanacorp-wiki:latest
    container_name: wiki
    restart: unless-stopped
    depends_on:
      wiki-db:
        condition: service_healthy
    environment:
      APP_URL: "http://wiki-int.empresa.local"
      APP_KEY: "${WIKI_APP_KEY}"
      DB_HOST: wiki-db
      DB_PORT: "3306"
      DB_DATABASE: bookstack
      DB_USERNAME: bookstack
      DB_PASSWORD: "${WIKI_DB_PASSWORD}"
      PUID: "1000"
      PGID: "1000"
      TZ: America/Bogota
    volumes:
      - wiki_bookstack_config:/config
    ports:
      - "0.0.0.0:80:80"
    networks:
      - wiki_backend

networks:
  wiki_backend:
    driver: bridge
    internal: false   # 'true' en el compose original aislaba wiki-db incluso de wiki-a-internet;
                       # aqui wiki SI necesita salir (imagen se auto-actualiza/telemetria de
                       # BookStack) -- si se quiere aislar de verdad, cambiar a true y validar que
                       # BookStack sigue arrancando sin salida.

volumes:
  wiki_mariadb_data:
  wiki_bookstack_config:
