# ACI container group: wiki-db (compartido, snet-dmz-shared 10.50.0.0/24)
# Backend MariaDB para dmz-wiki.yaml (BookStack).
#
# GAP SIN RESOLVER: en docker-compose, wiki/init/bookstack_seed.sql se monta en
# /docker-entrypoint-initdb.d para precargar las pistas criptograficas. ACI no soporta bind mount
# de un archivo local -- hay que hornear el .sql dentro de una imagen propia de mariadb (Dockerfile
# con COPY a /docker-entrypoint-initdb.d/) o usar un Azure File Share. Sin esto, wiki-db arranca
# con la base de datos vacia (BookStack solo crea sus tablas internas, no el contenido del reto).
apiVersion: 2021-07-01
location: eastus2
name: dmz-wiki-db
properties:
  containers:
    - name: wiki-db
      properties:
        image: mariadb:10.11
        environmentVariables:
          - {name: MYSQL_ROOT_PASSWORD, secureValue: "rootpass"}
          - {name: MYSQL_DATABASE, value: "bookstack"}
          - {name: MYSQL_USER, value: "bookstack"}
          - {name: MYSQL_PASSWORD, secureValue: "bookstackpass"}
        resources: {requests: {cpu: 0.5, memoryInGB: 1}}
        ports: [{port: 3306}]

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
