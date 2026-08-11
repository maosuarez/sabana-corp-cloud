networks:
  monitor:
    driver: bridge

volumes:
  grafana-data:

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    networks: [monitor]
    volumes:
      - /opt/monitor/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      # OJO: gen_targets.py (yamls/monitor/remote/gen_targets.py) escribe en ESTA ruta absoluta
      # del host, no en /opt/monitor/targets -- tienen que coincidir literalmente.
      - /etc/prometheus/targets:/etc/prometheus/targets:ro
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --web.enable-lifecycle

  blackbox-exporter:
    image: prom/blackbox-exporter:latest
    container_name: blackbox-exporter
    restart: unless-stopped
    networks: [monitor]
    volumes:
      - /opt/monitor/blackbox/blackbox.yml:/etc/blackbox_exporter/config.yml:ro

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    networks: [monitor]
    # Metricas propias de vm-monitor + textfile collector (gen-targets.sh escribe ahi las
    # metricas de control plane -- ver "Decision de diseño: descubrimiento" en el plan).
    volumes:
      # Mismo cuidado que arriba: gen_targets.py escribe en /etc/node_exporter/textfile del host.
      - /etc/node_exporter/textfile:/etc/node_exporter/textfile:ro
    command:
      - --collector.textfile.directory=/etc/node_exporter/textfile

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    networks: [monitor]
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_AUTH_ANONYMOUS_ENABLED=false
      - GF_ALERTING_ENABLED=false
      - GF_UNIFIED_ALERTING_ENABLED=true
    volumes:
      - /opt/monitor/grafana/provisioning:/etc/grafana/provisioning:ro
      - /opt/monitor/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana
