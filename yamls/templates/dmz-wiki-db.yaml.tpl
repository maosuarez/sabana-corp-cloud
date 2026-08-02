# ACI container group: wiki-db (compartido, snet-dmz-shared 10.50.0.0/24)
# Backend MariaDB para dmz-wiki.yaml (BookStack).
#
# Imagen propia (maosuarez/sabanacorp-wikidb): mariadb con wiki/init/bookstack_seed.sql horneado
# en /docker-entrypoint-initdb.d via Dockerfile -- ya no depende de un bind mount, resuelve el gap
# de persistencia que tenia la imagen generica mariadb:10.11 (arrancaba sin las pistas del reto).
apiVersion: 2021-07-01
location: eastus2
name: dmz-wiki-db
properties:
  containers:
    - name: wiki-db
      properties:
        image: maosuarez/sabanacorp-wikidb:latest
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
