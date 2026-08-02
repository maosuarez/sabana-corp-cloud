# ACI container group: decoy-nas (compartido, snet-dmz-shared 10.50.0.0/24)
# Perfil "nas": HTTP 80 (401 storage corporativo) + SMB placeholder 445.
apiVersion: 2021-07-01
location: eastus2
name: dmz-decoy-nas
properties:
  containers:
    - name: decoy-nas
      properties:
        image: maosuarez/sabanacorp-decoy:latest
        environmentVariables:
          - {name: DECOY_NAME, value: "storage-01"}
          - {name: DECOY_PROFILE, value: "nas"}
          - {name: LOG_DIR, value: "/logs"}
          - {name: CLIENT_TIMEOUT, value: "2"}
          - {name: MAX_RECEIVE_BYTES, value: "2048"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 80}, {port: 445}]

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
      - {protocol: tcp, port: 80}
      - {protocol: tcp, port: 445}
