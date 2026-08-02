# ACI container group: decoy-backup (compartido, snet-dmz-shared 10.50.0.0/24)
# Perfil "backup": rsync 873 + SSH banner falso 22.
apiVersion: 2021-07-01
location: eastus2
name: dmz-decoy-backup
properties:
  containers:
    - name: decoy-backup
      properties:
        image: anacha1304/sabanacorp-decoy:1.0.0
        environmentVariables:
          - {name: DECOY_NAME, value: "backup-old"}
          - {name: DECOY_PROFILE, value: "backup"}
          - {name: LOG_DIR, value: "/logs"}
          - {name: CLIENT_TIMEOUT, value: "2"}
          - {name: MAX_RECEIVE_BYTES, value: "2048"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 873}, {port: 22}]

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
      - {protocol: tcp, port: 873}
      - {protocol: tcp, port: 22}
