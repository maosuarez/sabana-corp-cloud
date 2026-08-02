# ACI container group: filesrv (compartido, snet-dmz-shared 10.50.0.0/24)
# Imagen propia (maosuarez/sabanacorp-filesrv): filebrowser con el contenido de
# sabana-corp-dmz/file-srv/{data,config} horneado dentro va Dockerfile -- ya no depende de un
# bind mount, resuelve el gap de persistencia que tenia la imagen generica filebrowser/filebrowser.
apiVersion: 2021-07-01
location: eastus2
name: dmz-filesrv
properties:
  containers:
    - name: filesrv
      properties:
        image: maosuarez/sabanacorp-filesrv:latest
        environmentVariables:
          - {name: FB_DATABASE, value: "/database/filebrowser.db"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 80}]

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
