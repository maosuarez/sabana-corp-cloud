# ACI container group: decoy-admin (compartido, snet-dmz-shared 10.50.0.0/24)
# Perfil "admin": HTTP 8443 (panel de administracion falso, 401).
apiVersion: 2021-07-01
location: eastus2
name: dmz-decoy-admin
properties:
  containers:
    - name: decoy-admin
      properties:
        image: anacha1304/sabanacorp-decoy:1.0.0
        environmentVariables:
          - {name: DECOY_NAME, value: "admin-console"}
          - {name: DECOY_PROFILE, value: "admin"}
          - {name: LOG_DIR, value: "/logs"}
          - {name: CLIENT_TIMEOUT, value: "2"}
          - {name: MAX_RECEIVE_BYTES, value: "2048"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 8443}]

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
      - {protocol: tcp, port: 8443}
