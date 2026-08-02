# ACI container group: decoy-mail (compartido, snet-dmz-shared 10.50.0.0/24)
# Perfil "mail": SMTP 25 + POP3 110 + IMAP 143 (banners falsos).
apiVersion: 2021-07-01
location: eastus2
name: dmz-decoy-mail
properties:
  containers:
    - name: decoy-mail
      properties:
        image: anacha1304/sabanacorp-decoy:1.0.0
        environmentVariables:
          - {name: DECOY_NAME, value: "mail-old"}
          - {name: DECOY_PROFILE, value: "mail"}
          - {name: LOG_DIR, value: "/logs"}
          - {name: CLIENT_TIMEOUT, value: "2"}
          - {name: MAX_RECEIVE_BYTES, value: "2048"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 25}, {port: 110}, {port: 143}]

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
      - {protocol: tcp, port: 25}
      - {protocol: tcp, port: 110}
      - {protocol: tcp, port: 143}
