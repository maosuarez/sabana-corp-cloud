# ACI container group: filesrv (compartido, snet-dmz-shared 10.50.0.0/24)
# Imagen publica (filebrowser/filebrowser), no requiere build propio.
#
# GAP SIN RESOLVER: en docker-compose ./file-srv/data se monta read-only con el contenido
# vulnerable (manuales, pistas de parqueadero, credenciales antiguas, etc.) y ./file-srv/config
# guarda filebrowser.db (usuarios/config, incluye el acceso anonimo). ACI no tiene bind mount a
# disco local del host -- para reproducir esto hay que:
#   (a) usar un Azure File Share + volume "azureFile" en este YAML, subiendo antes el contenido
#       de sabana-corp-dmz/file-srv/{data,config}, o
#   (b) construir una imagen propia con ese contenido ya copiado (COPY en un Dockerfile).
# Sin uno de los dos, este contenedor arranca vacio y el reto de acceso anonimo no tiene nada que
# encontrar. Pendiente de decidir cual opcion se usa.
apiVersion: 2021-07-01
location: eastus2
name: dmz-filesrv
properties:
  containers:
    - name: filesrv
      properties:
        image: filebrowser/filebrowser:latest
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
