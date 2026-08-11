[Unit]
Description=sabana-corp-cloud: genera targets Prometheus + metricas de control plane desde Azure
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=RESOURCE_GROUP=${RESOURCE_GROUP}
ExecStart=/usr/bin/python3 /opt/monitor/remote/gen_targets.py
