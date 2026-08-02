# ACI container group: decoy-database (compartido, snet-dmz-shared 10.50.0.0/24)
# Perfil "database": MySQL placeholder 3306 + Postgres placeholder 5432.
apiVersion: 2021-07-01
location: eastus2
name: dmz-decoy-database
properties:
  containers:
    - name: decoy-database
      properties:
        image: maosuarez/sabanacorp-decoy:latest
        environmentVariables:
          - {name: DECOY_NAME, value: "database-test"}
          - {name: DECOY_PROFILE, value: "database"}
          - {name: LOG_DIR, value: "/logs"}
          - {name: CLIENT_TIMEOUT, value: "2"}
          - {name: MAX_RECEIVE_BYTES, value: "2048"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 3306}, {port: 5432}]

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
      - {protocol: tcp, port: 3306}
      - {protocol: tcp, port: 5432}
