# ACI container group: decoy-legacy-web (compartido, snet-dmz-shared 10.50.0.0/24)
# Perfil "legacy-web": HTTP 80 (Apache falso) + HTTP 8080 (Tomcat falso, 403).
apiVersion: 2021-07-01
location: eastus2
name: dmz-decoy-legacy-web
properties:
  containers:
    - name: decoy-legacy-web
      properties:
        image: anacha1304/sabanacorp-decoy:1.0.0
        environmentVariables:
          - {name: DECOY_NAME, value: "intranet-old"}
          - {name: DECOY_PROFILE, value: "legacy-web"}
          - {name: LOG_DIR, value: "/logs"}
          - {name: CLIENT_TIMEOUT, value: "2"}
          - {name: MAX_RECEIVE_BYTES, value: "2048"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 80}, {port: 8080}]

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
      - {protocol: tcp, port: 8080}
