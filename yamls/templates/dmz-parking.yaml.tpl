# ACI container group: parking (compartido, snet-dmz-shared 10.50.0.0/24) -- reto final Parqueadero.
# Solo valida en servidor la flag final (PARKING_FINAL_FLAG); no expone la flag al navegador.
apiVersion: 2021-07-01
location: eastus2
name: dmz-parking
properties:
  containers:
    - name: parking
      properties:
        image: maosuarez/sabanacorp-parking:latest
        environmentVariables:
          - {name: PARKING_FINAL_FLAG, secureValue: "FLAG{CAMBIAR_POR_FLAG_FINAL_CTFD}"}
          - {name: TZ, value: "America/Bogota"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 8080}]

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
      - {protocol: tcp, port: 8080}
