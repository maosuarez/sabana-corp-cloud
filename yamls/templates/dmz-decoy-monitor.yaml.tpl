# ACI container group: decoy-monitor (compartido, snet-dmz-shared 10.50.0.0/24)
# Perfil "monitor": HTTP 3000 (Grafana falso) + HTTP 9090 (Prometheus falso, 403).
# No confundir con el Monitor real (Prometheus+Grafana para staff) mencionado en la arquitectura --
# este es un decoy, no el servicio de monitoreo real.
apiVersion: 2021-07-01
location: eastus2
name: dmz-decoy-monitor
properties:
  containers:
    - name: decoy-monitor
      properties:
        image: maosuarez/sabanacorp-decoy:latest
        environmentVariables:
          - {name: DECOY_NAME, value: "monitor-old"}
          - {name: DECOY_PROFILE, value: "monitor"}
          - {name: LOG_DIR, value: "/logs"}
          - {name: CLIENT_TIMEOUT, value: "2"}
          - {name: MAX_RECEIVE_BYTES, value: "2048"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 3000}, {port: 9090}]

  osType: Linux
  restartPolicy: Always

  imageRegistryCredentials:
    - server: index.docker.io
      username: "${DOCKERHUB_USER}"
      password: "${DOCKERHUB_TOKEN}"

  subnetIds:
    - id: "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET}/subnets/snet-dmz-shared"

  ipAddress:
    type: Private
    ports:
      - {protocol: tcp, port: 3000}
      - {protocol: tcp, port: 9090}
